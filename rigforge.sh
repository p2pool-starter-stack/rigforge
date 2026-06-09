#!/usr/bin/env bash
#
# XMRig Worker Deployment Script
# Automates the provisioning of a high-performance Monero mining worker.
# Handles dependency installation, kernel tuning (HugePages/MSR), and service configuration.
#

set -Eeuo pipefail

# --- Logging Utilities ---
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'

log() { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1"
    exit 1
}

# Names the phase currently running so the ERR trap can report where an unexpected failure happened.
CURRENT_STEP="starting up"
on_err() {
    local ec=$?
    echo -e "${C_RED}[ERROR]${C_RESET} rigforge aborted while ${CURRENT_STEP} (exit $ec)." >&2
    if [ -n "${BUILD_LOG:-}" ] && [ -f "${BUILD_LOG:-}" ]; then
        echo "  Build output is in: $BUILD_LOG — last lines:" >&2
        tail -n 20 "$BUILD_LOG" >&2 2>/dev/null || true
    fi
    echo "  Re-run with 'bash -x $0' to trace the exact command." >&2
}

# --- Global Variables ---
OS_TYPE="$(uname -s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
CONFIG_JSON="$SCRIPT_DIR/config.json"
REBOOT_REQUIRED=false
SERVICE_INSTALLED=false

# Pinned XMRig release for reproducible / supply-chain-hardened builds.
# Override via environment if you need a different release.
XMRIG_VERSION="${XMRIG_VERSION:-v6.26.0}"
XMRIG_COMMIT="${XMRIG_COMMIT:-b2ca72480c58d197e18c885d9fc1a0c8d517e60a}"
# Set to false when the pinned XMRig commit is already built, so a re-run/upgrade skips the (slow)
# recompile and the service restart — making re-runs idempotent (#4).
XMRIG_REBUILD=true

# System paths the script writes to. Overridable so the test suite can redirect them at a sandbox
# (the defaults are the real locations, so production behaviour is unchanged).
LOGROTATE_DIR="${LOGROTATE_DIR:-/etc/logrotate.d}"
GRUB_DEFAULT="${GRUB_DEFAULT:-/etc/default/grub}"
FSTAB="${FSTAB:-/etc/fstab}"
LIMITS_CONF="${LIMITS_CONF:-/etc/security/limits.conf}"
MODULES_LOAD_DIR="${MODULES_LOAD_DIR:-/etc/modules-load.d}"
MODULES_FILE="${MODULES_FILE:-/etc/modules}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
HUGEPAGES_1G_DIR="${HUGEPAGES_1G_DIR:-/dev/hugepages1G}"

# Read-only system paths the `doctor` health check inspects (overridable for tests).
MEMINFO="${MEMINFO:-/proc/meminfo}"
MSR_MODULE_DIR="${MSR_MODULE_DIR:-/sys/module/msr}"
GOVERNOR_FILE="${GOVERNOR_FILE:-/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor}"
HUGEPAGES_1G_NR="${HUGEPAGES_1G_NR:-/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages}"

# systemd service name for the worker.
SERVICE_NAME="${SERVICE_NAME:-xmrig}"

# Detect whether we're being sourced (e.g. by the test suite). When sourced we only define
# functions/constants and skip running main, so functions can be exercised in isolation.
_RIGFORGE_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then _RIGFORGE_SOURCED=1; fi

# Report which step failed on an unexpected error (skip when sourced by the test suite).
[ "$_RIGFORGE_SOURCED" = "0" ] && trap on_err ERR

# --- Helper Functions ---

# Append a single line to a file only if that exact line is not already present (idempotent).
# Uses sudo so it works on root-owned system files; harmless when the file is user-writable.
append_once() {
    local file="$1" line="$2"
    grep -qFx "$line" "$file" 2>/dev/null || echo "$line" | sudo tee -a "$file" >/dev/null
}

# Inverse of append_once: remove every exact-match line from a file (idempotent). Used by `uninstall`.
remove_line() { # <file> <line>
    local file="$1" line="$2" tmp
    [ -f "$file" ] || return 0
    grep -qFx "$line" "$file" 2>/dev/null || return 0
    tmp=$(mktemp)
    grep -vFx "$line" "$file" >"$tmp" 2>/dev/null || true
    sudo cp "$tmp" "$file"
    rm -f "$tmp"
}

# Choose a safe build parallelism: don't exceed core count, and cap at ~1 job per 2 GB of RAM so the
# heavy XMRig/RandomX C++ translation units don't OOM low-memory hosts. Honors MEMINFO for testing.
compute_build_jobs() { # <ncpu>
    local mem_kb mem_gb jobs="$1" max
    mem_kb=$(awk '/^MemTotal:/ {print $2}' "${MEMINFO:-/proc/meminfo}" 2>/dev/null || echo 0)
    mem_gb=$((mem_kb / 1024 / 1024))
    if [ "$mem_gb" -gt 0 ]; then
        max=$((mem_gb / 2))
        [ "$max" -lt 1 ] && max=1
        [ "$jobs" -gt "$max" ] && jobs="$max"
    fi
    [ "$jobs" -lt 1 ] && jobs=1
    echo "$jobs"
}

# True if a finished XMRig build for the pinned commit already exists, so we can skip the recompile.
# Requires BOTH the built binary and a commit marker that matches XMRIG_COMMIT (a marker without a
# binary means an incomplete build → rebuild).
xmrig_already_built() {
    local marker="$WORKER_ROOT/xmrig/.rigforge-commit"
    [ -x "$WORKER_ROOT/xmrig/build/xmrig" ] && [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$XMRIG_COMMIT" ]
}

# Merge the HugePage/MSR kernel params we manage into an existing GRUB cmdline, preserving every
# other parameter and replacing only the ones we own (so re-runs don't accumulate). Echoes the merged
# cmdline. Usage: grub_merge_cmdline "<managed params>" "<current cmdline>"
grub_merge_cmdline() {
    local managed="$1" current="$2" preserved="" tok
    for tok in $current; do
        case "$tok" in
        hugepagesz=* | hugepages=* | default_hugepagesz=* | msr.allow_writes=*) ;; # ours — drop, re-added below
        *) preserved="${preserved:+$preserved }$tok" ;;
        esac
    done
    echo "${preserved:+$preserved }$managed"
}

# Drop only the kernel params RigForge manages (HugePages/MSR), preserving everything else. The inverse
# of what tune_kernel adds — used by `uninstall` to revert the GRUB cmdline.
grub_strip_managed() { # <current cmdline>
    local current="$1" preserved="" tok
    for tok in $current; do
        case "$tok" in
        hugepagesz=* | hugepages=* | default_hugepagesz=* | msr.allow_writes=*) ;; # ours — drop
        *) preserved="${preserved:+$preserved }$tok" ;;
        esac
    done
    printf '%s' "$preserved"
}

check_prerequisites() {
    log "Verifying system prerequisites..."
    if ! command -v jq &>/dev/null; then
        if [ "$OS_TYPE" == "Darwin" ]; then
            if command -v brew &>/dev/null; then
                log "Installing prerequisite: jq..."
                brew install jq
            else
                error "Homebrew is required on macOS to install dependencies."
            fi
        else
            log "Installing prerequisite: jq..."
            if command -v apt-get &>/dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y -qq jq
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y -q jq
            elif command -v pacman &>/dev/null; then
                sudo pacman -Sy --noconfirm jq
            else
                error "jq is required and no supported package manager was found. Please install jq manually."
            fi
        fi
    fi
}

ensure_config_exists() {
    if [ ! -f "$CONFIG_JSON" ]; then
        warn "Configuration file not found: $CONFIG_JSON"
        read -r -p "Create a minimal configuration now? (y/N): " CREATE_CONF
        if [[ "$CREATE_CONF" =~ ^[Yy] ]]; then
            log "Starting interactive setup..."

            # We only need the pool URL — every other key has a sensible default (see
            # config.advanced.example.json for the full list). The URL is host:port (Pithead's proxy
            # listens on 3333).
            read -r -p "Enter your pool URL (host:port, e.g. your-stack:3333): " IN_URL

            if [ -z "$IN_URL" ]; then
                error "A pool URL is required. Aborting."
            fi
            if ! [[ "$IN_URL" =~ :[0-9]+$ ]]; then
                error "Pool URL must include a port, e.g. $IN_URL:3333. Aborting."
            fi

            # Minimal config: just the native pools array. jq writes it so the URL is safely quoted.
            jq -n --arg url "$IN_URL" '{pools: [{url: $url}]}' >"$CONFIG_JSON"
            log "Created $CONFIG_JSON successfully."
        else
            error "Configuration file required to proceed."
        fi
    fi
}

parse_config() {
    log "Parsing configuration..."
    if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
        error "$CONFIG_JSON is not valid JSON."
    fi

    # HOME_DIR becomes a filesystem path we mkdir/cd/write under (with sudo), so validate it: either the
    # sentinel DYNAMIC_HOME or a clean absolute path (no spaces, metacharacters, or traversal tricks).
    RAW_HOME=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON")
    if [ "$RAW_HOME" == "DYNAMIC_HOME" ]; then
        WORKER_ROOT="$SCRIPT_DIR/data/worker"
    elif [[ "$RAW_HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$RAW_HOME" != *..* ]]; then
        WORKER_ROOT="$RAW_HOME/worker"
    else
        error "HOME_DIR must be \"DYNAMIC_HOME\" or an absolute path (letters, digits, . _ - /); got: '$RAW_HOME'."
    fi
    DONATION=$(jq -r '.DONATION // 1' "$CONFIG_JSON")
    # donate-level is a percentage; the compile step also seds this into donate.h, so a malformed
    # value would corrupt both the XMRig config and the source patch. Require an integer 0-100.
    if ! [[ "$DONATION" =~ ^[0-9]+$ ]] || [ "$DONATION" -gt 100 ]; then
        error "DONATION must be an integer between 0 and 100 (got: $DONATION)."
    fi
    # Pool(s). The pool target is XMRig's native `pools` array — the same structure XMRig uses
    # ({"url","user","pass","keepalive","tls",...}). Each entry needs a `url` of the form `host:port`;
    # every other field falls back to a Pithead-friendly default. List multiple entries for failover.
    # The pool `user` is left blank here and filled with the rig name in generate_xmrig_config.
    if ! jq -e '.pools | type == "array" and length > 0' "$CONFIG_JSON" >/dev/null 2>&1; then
        error "No pools configured. Set a 'pools' array in $CONFIG_JSON — e.g. {\"pools\": [{\"url\": \"your-pool-host:3333\"}]}."
    fi
    POOLS_JSON=$(jq -c '
        .pools | map({
            url: (.url // ""),
            user: (.user // ""),
            pass: (.pass // "x"),
            keepalive: (.keepalive // true),
            tls: (.tls // false),
            enabled: (.enabled // true)
        })
    ' "$CONFIG_JSON") || error "Could not parse 'pools' in $CONFIG_JSON."

    # Validate every pool field — fail fast with a clear message rather than writing a config XMRig
    # would choke on. url must be host:port: a valid hostname / IPv4 / bracketed-IPv6 host and a port
    # in 1-65535; user/pass reject whitespace and shell/control characters; keepalive/tls/enabled
    # must be booleans.
    # Iterate one compact JSON object per pool (robust even when a field like user is empty), and read
    # each field back with jq.
    while IFS= read -r _pool; do
        _u=$(jq -r '.url' <<<"$_pool")
        _user=$(jq -r '.user' <<<"$_pool")
        _pass=$(jq -r '.pass' <<<"$_pool")
        [ -n "$_u" ] || error "A pool entry has no url — set 'pools[].url' (host:port) in $CONFIG_JSON."
        if ! [[ "$_u" =~ :[0-9]+$ ]]; then
            error "Pool url '$_u' must include a port, e.g. $_u:3333."
        fi
        _host="${_u%:*}"
        _port="${_u##*:}"
        if [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then
            error "Pool port must be between 1 and 65535 (got '$_port' in '$_u')."
        fi
        # The host must be a valid hostname / FQDN / IPv4, or a bracketed IPv6 literal. This also
        # rejects the unfilled template placeholder (<...>), whitespace, and shell/URL metacharacters.
        case "$_host" in
        \[*\]) [[ "$_host" =~ ^\[[0-9A-Fa-f:]+\]$ ]] || error "Pool url '$_u' has an invalid IPv6 literal (use [addr]:port)." ;;
        *) [[ "$_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || error "Pool url host '$_host' is not a valid hostname or IP." ;;
        esac
        if [ -n "$_user" ] && ! [[ "$_user" =~ ^[A-Za-z0-9._:@+-]+$ ]]; then
            error "Pool user '$_user' has invalid characters (allowed: letters, digits, . _ - : @ +)."
        fi
        if ! [[ "$_pass" =~ ^[[:graph:]]+$ ]]; then
            error "Pool pass must be non-empty with no spaces or control characters."
        fi
        for _f in keepalive tls enabled; do
            _bv=$(jq -r --arg f "$_f" '.[$f]' <<<"$_pool")
            case "$_bv" in true | false) ;; *) error "Pool $_f must be true or false (got: $_bv)." ;; esac
        done
    done < <(jq -c '.[]' <<<"$POOLS_JSON")

    # HTTP API token. The rig's label is the pool `user` (#22; defaults to the hostname — see
    # generate_xmrig_config). The token defaults to that same rig name, so the Pithead contract
    # (the dashboard authenticates as `Bearer <rig name>`) holds out of the box. An explicit
    # ACCESS_TOKEN overrides it.
    ACCESS_TOKEN=$(jq -r '.ACCESS_TOKEN // empty' "$CONFIG_JSON")
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(jq -r '.[0].user' <<<"$POOLS_JSON")
        [ -n "$ACCESS_TOKEN" ] || ACCESS_TOKEN=$(hostname)
    fi
    # The token is sent as an HTTP Authorization header, so keep it to safe, header-clean characters.
    if ! [[ "$ACCESS_TOKEN" =~ ^[A-Za-z0-9._:@+-]+$ ]]; then
        error "ACCESS_TOKEN has invalid characters (allowed: letters, digits, . _ - : @ +): '$ACCESS_TOKEN'."
    fi

    # Opt-in periodic live auto-tuning (#46): when true, setup installs a systemd timer that runs
    # `autotune` on a schedule.
    AUTOTUNE=$(jq -r '.autotune // false' "$CONFIG_JSON")
}

prepare_workspace() {
    log "Preparing workspace at $WORKER_ROOT..."

    if [ ! -d "$WORKER_ROOT" ]; then
        mkdir -p "$WORKER_ROOT" 2>/dev/null || sudo mkdir -p "$WORKER_ROOT"
    fi

    # Fix permissions to ensure the current user can write
    if [ "${EUID:-$(id -u)}" -eq 0 ] || [ ! -w "$WORKER_ROOT" ]; then
        if [ "$OS_TYPE" == "Darwin" ]; then
            sudo chown -R "$REAL_USER" "$WORKER_ROOT"
        else
            sudo chown -R "$REAL_USER":"$REAL_USER" "$WORKER_ROOT"
        fi
    fi

    cd "$WORKER_ROOT"

    GIT_DIR="xmrig"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)

    # Archive the existing installation only when we're about to rebuild (a no-op re-run keeps it).
    if [ "$XMRIG_REBUILD" = true ] && [ -d "$GIT_DIR" ]; then
        log "Archiving existing worker installation..."
        mv "$GIT_DIR" "${GIT_DIR}-${TIMESTAMP}"
    fi

    # Prune old build archives so re-runs don't grow the disk without bound (keep the most recent
    # few). Override the retention count with KEEP_ARCHIVES. The `|| true` keeps an empty glob (no
    # archives yet) from tripping `set -e`/`pipefail`.
    local keep="${KEEP_ARCHIVES:-3}" archives
    # shellcheck disable=SC2012  # archive names are controlled (xmrig-YYYYmmdd_HHMMSS); ls -t orders by recency
    archives="$(ls -dt "${GIT_DIR}-"* 2>/dev/null || true)"
    if [ -n "$archives" ]; then
        printf '%s\n' "$archives" | tail -n +"$((keep + 1))" | while IFS= read -r old; do
            [ -n "$old" ] || continue
            log "Pruning old build archive: $(basename "$old")"
            rm -rf "$old" 2>/dev/null || sudo rm -rf "$old"
        done
    fi
}

install_dependencies() {
    if [ "$OS_TYPE" == "Darwin" ]; then
        log "Installing macOS dependencies..."
        if command -v brew &>/dev/null; then
            if [ "${EUID:-$(id -u)}" -eq 0 ]; then
                # Drop privileges for Homebrew if running as root
                sudo -u "$REAL_USER" brew install cmake libuv openssl hwloc
            else
                brew install cmake libuv openssl hwloc
            fi
        else
            error "Homebrew not found."
        fi
    else
        local dependencies=""
        local install_cmd=""
        local check_cmd=""

        if command -v apt-get &>/dev/null; then
            dependencies="git build-essential cmake libuv1-dev libssl-dev libhwloc-dev gettext-base"
            if [ "$OS_TYPE" == "Linux" ]; then
                dependencies="$dependencies linux-tools-common"
                if apt-cache show "linux-tools-$(uname -r)" &>/dev/null; then
                    dependencies="$dependencies linux-tools-$(uname -r)"
                fi
            fi
            install_cmd="sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
            check_cmd="dpkg -s"
        elif command -v dnf &>/dev/null; then
            dependencies="git cmake libuv-devel openssl-devel hwloc-devel gettext gcc gcc-c++ make automake kernel-devel"
            install_cmd="sudo dnf install -y"
            check_cmd="rpm -q"
        elif command -v pacman &>/dev/null; then
            dependencies="git cmake libuv openssl hwloc gettext base-devel"
            install_cmd="sudo pacman -Sy --noconfirm --needed"
            check_cmd="pacman -Qi"
        else
            warn "No supported package manager found. Please install dependencies manually."
            return
        fi

        local missing_deps=""
        for dep in $dependencies; do
            if ! command -v "$dep" &>/dev/null && ! $check_cmd "$dep" &>/dev/null; then
                missing_deps="$missing_deps $dep"
            fi
        done

        if [ -n "$missing_deps" ]; then
            log "The following system dependencies are required:"
            echo -e "  ${C_YELLOW}$missing_deps${C_RESET}"

            read -r -p "Install these dependencies now? (y/N): " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy] ]]; then
                log "Installing dependencies..."
                eval "$install_cmd $missing_deps"
            else
                warn "Dependency installation skipped. Proceeding at your own risk."
            fi
        else
            log "All system dependencies are already installed."
        fi
    fi
}

compile_xmrig() {
    if [ "$XMRIG_REBUILD" != true ]; then
        log "XMRig $XMRIG_VERSION (commit ${XMRIG_COMMIT:0:12}) already built — skipping clone/compile."
        return 0
    fi
    log "Cloning and patching XMRig source code ($XMRIG_VERSION)..."
    git clone --quiet --branch "$XMRIG_VERSION" --depth 1 https://github.com/xmrig/xmrig.git

    # Verify we built the exact commit we pinned (supply-chain hardening).
    actual="$(git -C xmrig rev-parse HEAD)"
    [ "$actual" = "$XMRIG_COMMIT" ] || error "XMRig commit mismatch: expected $XMRIG_COMMIT, got $actual"
    log "Verified XMRig $XMRIG_VERSION at commit $XMRIG_COMMIT"

    # Build output goes to a logfile (not /dev/null) so a failed compile is diagnosable; the ERR trap
    # points the user at it. BUILD_LOG is global so on_err can find it.
    BUILD_LOG="$WORKER_ROOT/build.log"
    : >"$BUILD_LOG" 2>/dev/null || true

    local cores jobs
    if [ "$OS_TYPE" == "Darwin" ]; then
        sed -i '' "s/DonateLevel = 1;/DonateLevel = $DONATION;/g" xmrig/src/donate.h
        cores=$(sysctl -n hw.ncpu)
        jobs=$(compute_build_jobs "$cores")
        log "Compiling binary ($jobs of $cores cores; output -> $BUILD_LOG)..."
        mkdir -p xmrig/build && cd xmrig/build
        # macOS often needs explicit OpenSSL root for cmake if installed via brew
        cmake .. -DWITH_HWLOC=ON -DOPENSSL_ROOT_DIR="$(brew --prefix openssl)" >>"$BUILD_LOG" 2>&1
    else
        sed -i "s/DonateLevel = 1;/DonateLevel = $DONATION;/g" xmrig/src/donate.h
        cores=$(nproc)
        jobs=$(compute_build_jobs "$cores")
        log "Compiling binary ($jobs of $cores cores; output -> $BUILD_LOG)..."
        mkdir -p xmrig/build && cd xmrig/build
        cmake .. -DWITH_HWLOC=ON >>"$BUILD_LOG" 2>&1
    fi

    make -j"$jobs" >>"$BUILD_LOG" 2>&1

    # Record the built commit so a later run can detect "already built" and skip the recompile (#4).
    echo "$XMRIG_COMMIT" >"$WORKER_ROOT/xmrig/.rigforge-commit"
}

generate_xmrig_config() {
    log "Generating hardware-optimized XMRig configuration..."

    # Identify CPU Topology
    if [ "$OS_TYPE" == "Darwin" ]; then
        CPU_MODEL=$(sysctl -n machdep.cpu.brand_string)
    else
        CPU_MODEL=$(lscpu | grep "Model name" | cut -d':' -f2 | xargs)
    fi
    LOG_FILE_PATH="$WORKER_ROOT/xmrig.log"

    # Default optimization profile.
    #
    # We deliberately lean on XMRig's own auto-detection rather than matching CPU model names: with
    # asm=auto, rx=-1 (auto thread count, sized to L3) and wrmsr=true, XMRig picks the right assembly
    # path, thread layout and per-family MSR preset from the detected topology — and stays correct for
    # CPUs we'd never enumerate (new Zen/X3D SKUs, Intel hybrid P/E cores, etc.). See issue #44.
    #
    # On top of auto-detection we set defaults appropriate for a DEDICATED miner (issue #43):
    #   - yield=false  : busy-wait for maximum hashrate (we own the whole box)
    #   - priority=2   : win scheduling vs. background daemons (XMRig warns >2 can hang a desktop)
    #   - numa=true    : XMRig default; a no-op on single-socket, essential on multi-socket/EPYC
    #   - init-avx2=-1 : auto — already uses AVX2 for dataset init when the CPU supports it
    YIELD="false"
    PRIORITY="2"
    ASM="\"auto\""
    THREADS="-1"
    NUMA="true"
    PREFETCH=1
    WRMSR="true"
    RDMSR="true"
    HUGE_PAGES="true"
    MEMORY_POOL="true"
    ONE_GB_PAGES="true"
    # cpu.huge-pages-jit: false, matching XMRig's upstream default. XMRig documents it as only a "very
    # small boost on Ryzen, but hashrate is unstable" — not worth the jitter on a production rig (and it
    # would add noise to the `tune` search). $JIT maps to cpu.huge-pages-jit in the config below.
    JIT="false"
    INIT_AVX2="-1"
    # Lock down the HTTP API to READ-ONLY (restricted) so it can't be used to *control* the miner
    # remotely. Keep it bound to all interfaces, NOT localhost: Pithead reads per-rig stats from the
    # stack host via GET http://<rig>:8080/1/summary (read-only, authenticated by the per-rig access
    # token = rig name). Binding localhost would break that integration — see issue #24. Workers are
    # expected to live on a trusted LAN.
    HTTP_RESTRICTED="true"
    HTTP_HOST="0.0.0.0"

    # macOS Specific Overrides
    if [ "$OS_TYPE" == "Darwin" ]; then
        YIELD="false"
        # Match the Linux dedicated-miner default (2). XMRig warns a priority above 2 can make the
        # machine unresponsive, and macOS is a light-use/dev target — don't pin it to the most
        # aggressive level here.
        PRIORITY="2"
        ASM="true"
        WRMSR="false"
        RDMSR="false"
        HUGE_PAGES="false"
        MEMORY_POOL="false"
        ONE_GB_PAGES="false"
        NUMA="true"
        HTTP_RESTRICTED="true"
        HTTP_HOST="::"

        # Generate rx array [-1, -1, ...] based on core count
        CORES=$(sysctl -n hw.ncpu)
        THREADS="["
        for ((i = 0; i < CORES; i++)); do
            THREADS="${THREADS}-1"
            if [ $i -lt $((CORES - 1)) ]; then THREADS="${THREADS},"; fi
        done
        THREADS="${THREADS}]"
    fi

    # NOTE: we no longer special-case CPUs by model name (the old EPYC / Ryzen-X3D branches). XMRig's
    # auto-config is cache-aware and updated every release, so it sizes threads and picks asm/MSR/NUMA
    # better — and correctly — for any CPU, including ones a name table would miss or get wrong (the
    # old X3D branch pinned threads to ALL cores, which is wrong on dual-CCD parts like the 7950X3D
    # where only one CCD has the V-cache). See issue #44.
    if [ "$OS_TYPE" != "Darwin" ]; then
        log "Detected CPU: ${CPU_MODEL:-unknown} — using XMRig auto-tuning (threads, asm, MSR, NUMA auto-detected)."
    fi

    # Rig label for the pool `user` field (#22): any pool entry that didn't set its own `user` gets the
    # machine hostname, so the worker shows up named on the dashboard.
    FULL_USER="$(hostname)"

    # Build the whole XMRig config from scratch (issue #55). There's no template file to keep in sync:
    # the tuned parts (pools, donate-level, the http block, the cpu/randomx sections) come from the
    # variables above, and the few static defaults (autosave, randomx mode, opencl/cuda off) are
    # emitted inline. `jq -n` builds the object from null input; any tuned overrides are merged below.
    jq -n --argjson pools "$POOLS_JSON" \
        --arg user "$FULL_USER" \
        --arg access_token "$ACCESS_TOKEN" \
        --arg log "$LOG_FILE_PATH" \
        --argjson yield "$YIELD" \
        --argjson prio "$PRIORITY" \
        --argjson numa "$NUMA" \
        --argjson asm "$ASM" \
        --argjson rx "$THREADS" \
        --argjson prefetch "$PREFETCH" \
        --argjson jit "$JIT" \
        --argjson wrmsr "$WRMSR" \
        --argjson rdmsr "$RDMSR" \
        --argjson huge_pages "$HUGE_PAGES" \
        --argjson memory_pool "$MEMORY_POOL" \
        --argjson one_gb_pages "$ONE_GB_PAGES" \
        --argjson avx2 "$INIT_AVX2" \
        --argjson restricted "$HTTP_RESTRICTED" \
        --argjson donation "$DONATION" \
        --arg host "$HTTP_HOST" \
        '{
            autosave: true,
            cpu: {
                enabled: true,
                "huge-pages": $huge_pages,
                "huge-pages-jit": $jit,
                "memory-pool": $memory_pool,
                yield: $yield,
                priority: $prio,
                asm: $asm,
                rx: $rx
            },
            randomx: {
                init: -1,
                mode: "fast",
                "1gb-pages": $one_gb_pages,
                rdmsr: $rdmsr,
                wrmsr: $wrmsr,
                cache_qos: false,
                numa: $numa,
                scratchpad_prefetch_mode: $prefetch,
                "init-avx2": $avx2
            },
            pools: ($pools | map(.user = (if (.user // "") == "" then $user else .user end))),
            "donate-level": $donation,
            "donate-over-proxy": $donation,
            http: {
                enabled: true,
                host: $host,
                port: 8080,
                "access-token": (if $access_token == "" then null else $access_token end),
                restricted: $restricted
            },
            opencl: false,
            cuda: false,
            "log-file": $log
        }' >config.json

    # Overlay any tuned knobs (#46) on top — kept in a separate file (written by `tune`) so the user's
    # config.json is never touched. A recursive merge lets tuning win for just the keys it sets.
    if [ -f "$WORKER_ROOT/tune-overrides.json" ]; then
        local _ovr
        _ovr=$(mktemp)
        if jq -s '.[0] * .[1]' config.json "$WORKER_ROOT/tune-overrides.json" >"$_ovr" 2>/dev/null; then
            mv "$_ovr" config.json
            log "Applied tuned overrides from tune-overrides.json."
        else
            rm -f "$_ovr"
        fi
    fi

    if [ "$OS_TYPE" == "Linux" ]; then
        log "Configuring log rotation policy..."
        # Install logrotate configuration
        sudo tee "$LOGROTATE_DIR/xmrig" >/dev/null <<EOF
    $LOG_FILE_PATH {
        daily
        missingok
        rotate 7
        compress
        delaycompress
        notifempty
        copytruncate
        minsize 50M
        create 0644 $(whoami) $(whoami)
    }
EOF
    fi
}

install_service() {
    if [ "$OS_TYPE" == "Linux" ]; then
        log "Installing systemd service..."
        export BUILD_DIR="$WORKER_ROOT/xmrig/build"
        CPUPOWER_PATH=$(command -v cpupower || echo "/usr/bin/cpupower")
        export CPUPOWER_PATH

        # Overwrite the existing file. Only the three named vars are substituted; WORKER_ROOT is passed
        # into envsubst's environment for that one command (the template uses it in ReadWritePaths).
        WORKER_ROOT="$WORKER_ROOT" envsubst '$BUILD_DIR $CPUPOWER_PATH $WORKER_ROOT' \
            <"$SCRIPT_DIR/systemd/xmrig.service.template" | sudo tee "$SYSTEMD_DIR/xmrig.service" >/dev/null

        # Reload systemd daemon
        sudo systemctl daemon-reload

        # Enable service to start on boot
        sudo systemctl enable xmrig.service

        # Restart only when the binary was rebuilt; otherwise just ensure it's running (a running
        # service is left undisturbed on a no-op re-run).
        if [ "$XMRIG_REBUILD" = true ]; then
            log "Restarting XMRig service..."
            sudo systemctl restart xmrig.service
        else
            log "No rebuild — ensuring the service is running (no restart)."
            sudo systemctl start xmrig.service
        fi
        SERVICE_INSTALLED=true
    else
        warn "Service installation is not supported on $OS_TYPE."
    fi
}

# Install (or remove) the systemd timer that runs `autotune` periodically, based on the `autotune`
# config flag (#46). Idempotent: toggling the flag off cleanly removes the timer.
install_autotune() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    local svc="$SYSTEMD_DIR/rigforge-autotune.service" tmr="$SYSTEMD_DIR/rigforge-autotune.timer"
    if [ "${AUTOTUNE:-false}" != "true" ]; then
        if [ -f "$tmr" ]; then
            sudo systemctl disable --now rigforge-autotune.timer 2>/dev/null || true
            sudo rm -f "$svc" "$tmr"
            sudo systemctl daemon-reload 2>/dev/null || true
            log "Periodic autotune disabled."
        fi
        return 0
    fi
    log "Enabling periodic autotune (${AUTOTUNE_ONCALENDAR:-daily})..."
    sudo tee "$svc" >/dev/null <<EOF
[Unit]
Description=RigForge live autotune trial
After=$SERVICE_NAME.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/rigforge.sh autotune
EOF
    sudo tee "$tmr" >/dev/null <<EOF
[Unit]
Description=Periodic RigForge autotune

[Timer]
OnCalendar=${AUTOTUNE_ONCALENDAR:-daily}
Persistent=true

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now rigforge-autotune.timer 2>/dev/null || true
}

tune_kernel() {
    if [ "$OS_TYPE" != "Linux" ]; then
        log "Skipping kernel tuning (Not supported on $OS_TYPE)."
        return
    fi

    if [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "i686" ]]; then
        log "Enabling MSR module for hardware prefetcher tuning..."
        sudo modprobe msr 2>/dev/null || true
        if [ -d "$MODULES_LOAD_DIR" ]; then
            echo "msr" | sudo tee "$MODULES_LOAD_DIR/msr.conf" >/dev/null
        elif [ -f "$MODULES_FILE" ]; then
            append_once "$MODULES_FILE" "msr"
        fi
    fi

    log "Applying runtime memory tuning..."
    if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ]; then
        # Calculate exact requirement based on hardware and current 1GB page status
        REQUIRED_PAGES=$("$SCRIPT_DIR/util/proposed-grub.sh" --runtime)
        log "Hardware-optimized HugePages: $REQUIRED_PAGES (2MB pages) calculated."
        sudo sysctl -w vm.nr_hugepages="$REQUIRED_PAGES"
    else
        warn "Utility script not found. Fallback to safe default (3072)."
        sudo sysctl -w vm.nr_hugepages=3072
    fi

    log "Configuring bootloader (GRUB) for persistent HugePages..."
    if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ] && [ -f "$GRUB_DEFAULT" ]; then
        # proposed-grub.sh prints a generic "quiet splash" prefix plus the HugePage/MSR params we
        # manage. Keep only the params we manage and MERGE them into the existing cmdline so we don't
        # clobber other kernel parameters the user/distro set (#19 — boot-safety).
        MANAGED=$("$SCRIPT_DIR/util/proposed-grub.sh" -q)
        MANAGED="${MANAGED#quiet splash }"

        CURRENT=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_DEFAULT" | head -n1)
        MERGED=$(grub_merge_cmdline "$MANAGED" "$CURRENT")

        if [ "$CURRENT" = "$MERGED" ]; then
            log "GRUB is already configured with optimal HugePages settings."
        else
            sudo cp "$GRUB_DEFAULT" "$GRUB_DEFAULT.bak"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$MERGED\"|" "$GRUB_DEFAULT"
            if command -v update-grub >/dev/null; then
                sudo update-grub
                REBOOT_REQUIRED=true
            else
                warn "'update-grub' not found. Please manually update your bootloader."
            fi
        fi
    else
        warn "Skipping GRUB updates (Utility not found or non-GRUB system)."
    fi
}

configure_limits() {
    if [ "$OS_TYPE" != "Linux" ]; then
        return
    fi

    log "Configuring persistent HugePage mounts and memory limits..."
    sudo mkdir -p "$HUGEPAGES_1G_DIR"

    # Configure fstab for HugePage mounts (Idempotent)
    append_once "$FSTAB" "hugetlbfs /dev/hugepages hugetlbfs defaults 0 0"
    append_once "$FSTAB" "hugetlbfs_1g $HUGEPAGES_1G_DIR hugetlbfs pagesize=1G 0 0"

    sudo mount -a || warn "Mount operation returned errors. Check 'dmesg' for details."

    # Configure security limits for memlock (idempotent). Scope it to the mining user instead of every
    # account ("*") — the systemd service runs as root with its own LimitMEMLOCK=infinity, so this
    # entry only needs to cover manual/interactive runs by the operator (#13).
    append_once "$LIMITS_CONF" "$REAL_USER soft memlock unlimited"
    append_once "$LIMITS_CONF" "$REAL_USER hard memlock unlimited"
}

finish_deployment() {
    echo ""
    log "--------------------------------------------------------"
    log "Deployment Complete."
    if [ "$REBOOT_REQUIRED" = true ]; then
        warn "ACTION REQUIRED: A system reboot is mandatory to enable HugePages."
        echo "Please run: 'sudo reboot' now."
    else
        log "Worker configured successfully. No reboot required."
    fi
    log "--------------------------------------------------------"
    echo ""
    if [ "$SERVICE_INSTALLED" = true ]; then
        log "Service created. xmrig running in background."
    else
        log "You can run the miner manually:"
        echo "sudo screen -S xmrig $WORKER_ROOT/xmrig/build/xmrig --config=$WORKER_ROOT/xmrig/build/config.json"
    fi
}

# --- Main Execution ---

# Decide whether the pinned XMRig needs (re)building. Call after parse_config (needs WORKER_ROOT).
decide_rebuild() {
    if xmrig_already_built; then
        XMRIG_REBUILD=false
        log "XMRig $XMRIG_VERSION already built at the pinned commit — recompile will be skipped."
    else
        XMRIG_REBUILD=true
    fi
}

main() {
    CURRENT_STEP="verifying prerequisites"
    check_prerequisites
    CURRENT_STEP="ensuring config exists"
    ensure_config_exists
    CURRENT_STEP="parsing config"
    parse_config
    CURRENT_STEP="checking the build"
    decide_rebuild
    CURRENT_STEP="preparing workspace"
    prepare_workspace
    CURRENT_STEP="installing dependencies"
    install_dependencies
    CURRENT_STEP="compiling XMRig"
    compile_xmrig
    CURRENT_STEP="generating XMRig config"
    generate_xmrig_config
    CURRENT_STEP="tuning the kernel"
    tune_kernel
    CURRENT_STEP="configuring limits"
    configure_limits
    CURRENT_STEP="installing the service"
    install_service
    CURRENT_STEP="configuring autotune"
    install_autotune
    CURRENT_STEP="finishing up"
    finish_deployment
}

# Upgrade flow: rebuild + restart ONLY if the pinned XMRig version/commit changed. Skips the
# setup-only steps (dependency install, kernel tuning) — those don't change on a version bump.
upgrade() {
    check_prerequisites
    parse_config
    decide_rebuild
    if [ "$XMRIG_REBUILD" != true ]; then
        log "Already on the pinned XMRig $XMRIG_VERSION (commit ${XMRIG_COMMIT:0:12}); nothing to upgrade."
        return 0
    fi
    prepare_workspace
    compile_xmrig
    generate_xmrig_config
    install_service
    log "Upgraded to XMRig $XMRIG_VERSION."
    if [ -f "$WORKER_ROOT/tune-overrides.json" ]; then
        warn "Saved tuning (tune-overrides.json) carried over from the previous build. The fastest knobs can shift between XMRig versions — consider re-running 'sudo $0 tune' (or 'tune --clear' to discard)."
    fi
}

# Resolve the worker root from config.json the same way parse_config would, but WITHOUT requiring a
# valid/complete config (echoes "" when there's no config). Shared by uninstall/doctor/backup/restore.
_worker_root_from_config() {
    local raw
    [ -f "$CONFIG_JSON" ] || return 0
    raw=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON" 2>/dev/null)
    if [ "$raw" = "DYNAMIC_HOME" ] || [ -z "$raw" ] || [ "$raw" = "null" ]; then
        echo "$SCRIPT_DIR/data/worker"
    else
        echo "$raw/worker"
    fi
}

# Cleanly revert everything setup changed (#12): the service, logrotate, fstab/limits/modules edits, the
# GRUB cmdline, the 1G mount, and the worker build/logs. Idempotent and conservative — it only removes
# the exact lines/files RigForge added; your config.json is left in place.
uninstall() {
    if [ "$OS_TYPE" != "Linux" ]; then
        error "uninstall manages Linux system changes and is only supported on Linux."
    fi
    if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
        warn "This removes the xmrig service and reverts RigForge's system changes (fstab, limits, modules, GRUB)."
        read -r -p "Proceed with uninstall? (y/N): " ANS
        [[ "$ANS" =~ ^[Yy] ]] || {
            log "Aborted."
            return 0
        }
    fi

    # Work out the worker root the same way parse_config would, without requiring a valid config.
    local worker_root
    worker_root=$(_worker_root_from_config)

    # 1. systemd service (+ the optional autotune timer, #46)
    if [ -f "$SYSTEMD_DIR/rigforge-autotune.timer" ]; then
        sudo systemctl disable --now rigforge-autotune.timer 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/rigforge-autotune.timer" "$SYSTEMD_DIR/rigforge-autotune.service"
    fi
    if [ -f "$SYSTEMD_DIR/$SERVICE_NAME.service" ]; then
        sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/$SERVICE_NAME.service"
        sudo systemctl daemon-reload 2>/dev/null || true
        log "Removed the $SERVICE_NAME service."
    fi

    # 2. logrotate policy
    sudo rm -f "$LOGROTATE_DIR/xmrig"

    # 3. fstab HugePage mounts
    remove_line "$FSTAB" "hugetlbfs /dev/hugepages hugetlbfs defaults 0 0"
    remove_line "$FSTAB" "hugetlbfs_1g $HUGEPAGES_1G_DIR hugetlbfs pagesize=1G 0 0"

    # 4. memlock limits (current per-user form + the legacy wildcard form, for older installs)
    remove_line "$LIMITS_CONF" "$REAL_USER soft memlock unlimited"
    remove_line "$LIMITS_CONF" "$REAL_USER hard memlock unlimited"
    remove_line "$LIMITS_CONF" "* soft memlock unlimited"
    remove_line "$LIMITS_CONF" "* hard memlock unlimited"

    # 5. msr module autoload
    sudo rm -f "$MODULES_LOAD_DIR/msr.conf"
    remove_line "$MODULES_FILE" "msr"

    # 6. 1G HugePage mount
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$HUGEPAGES_1G_DIR" 2>/dev/null; then
        sudo umount "$HUGEPAGES_1G_DIR" 2>/dev/null || true
    fi
    sudo rmdir "$HUGEPAGES_1G_DIR" 2>/dev/null || true

    # 7. GRUB cmdline — strip only the params we added
    if [ -f "$GRUB_DEFAULT" ]; then
        local cur stripped
        cur=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_DEFAULT" | head -n1)
        stripped=$(grub_strip_managed "$cur")
        if [ "$cur" != "$stripped" ]; then
            sudo cp "$GRUB_DEFAULT" "$GRUB_DEFAULT.bak"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$stripped\"|" "$GRUB_DEFAULT"
            if command -v update-grub >/dev/null; then
                sudo update-grub
                REBOOT_REQUIRED=true
            else
                warn "'update-grub' not found — revert your bootloader config manually."
            fi
            log "Reverted RigForge's GRUB kernel parameters."
        fi
    fi

    # 8. worker build + logs (leave config.json in the repo root)
    if [ -n "$worker_root" ] && [ -d "$worker_root" ]; then
        sudo rm -rf "$worker_root"
        log "Removed worker build/logs at $worker_root."
    fi

    log "Uninstall complete. config.json was left in place."
    if [ "$REBOOT_REQUIRED" = true ]; then
        warn "Reboot to fully release the HugePages reserved at boot."
    fi
}

# --- Auto-tuning (#46, #54) ------------------------------------------------
#
# `tune` finds the fastest XMRig knob settings for THIS CPU and records the winner in a separate
# overrides file that generate_xmrig_config merges on top of the generated config — so your own
# config.json is never touched. Two state files live under the worker root:
#   tune-overrides.json — the winning knobs, merged into every generated config.
#   rigforge-tune.json  — the full search log (every candidate, its samples + median, the path taken).
#
# The search (#54) is an iterative, noise-aware coordinate hill-climb. Starting from one or more
# *seeds* it sweeps each knob in turn, measures each candidate as the MEDIAN of several runs (RandomX
# hashrate is jittery), and adopts a change only when it beats the current best by a minimum relative
# margin (TUNE_MIN_DELTA). It repeats until a full pass makes no improvement (plateau) or TUNE_MAX_ROUNDS
# is hit, memoizing every measured candidate so a combination is never benchmarked twice. The knobs are
# the ones whose best value genuinely varies per CPU: the RandomX scratchpad prefetch mode, `cpu.yield`,
# the RandomX thread count (`cpu.rx`, swept around L3/2 MB), and — only when the host actually has them
# reserved — `1gb-pages`. `cpu.priority` is available but off by default (it barely moves a dedicated-box
# benchmark; set TUNE_PRIORITIES to include it).

# The tuning session's shared state. Set by tune() and read by its helpers (kept as globals rather than
# threaded through every call, matching the rest of this script). S_* hold the current candidate.
TUNE_TMP=""
TUNE_BASE=""
TUNE_BIN=""
TUNE_OVERRIDES=""
MEMO_FILE=""
RESULTS_FILE=""
TUNE_MODE=""
S_p=""
S_y=""
S_t=""
S_g=""
S_pr=""
S_hj=""             # cpu.huge-pages-jit (off by default; swept only if TUNE_HPJIT lists >1 value)
S_cq=""             # randomx.cache_qos  (off by default; swept only if TUNE_CACHEQOS lists >1 value)
HILL_BEST=""        # set by _hillclimb (its result is returned via this global, not stdout — see below)
_TUNE_SVC_STOPPED=0 # set by tune() when it stops the live service for a --bench run (#2)

# Restart the miner that a --bench run stopped, and clean the temp dir. Installed as an EXIT trap by
# tune() so the service comes back even if the run errors or is interrupted.
_tune_bench_cleanup() {
    [ -n "${TUNE_TMP:-}" ] && rm -rf "$TUNE_TMP" 2>/dev/null
    if [ "${_TUNE_SVC_STOPPED:-0}" = 1 ]; then
        _TUNE_SVC_STOPPED=0
        log "Restarting the '$SERVICE_NAME' service."
        sudo systemctl start "$SERVICE_NAME" 2>/dev/null || true
    fi
}

# Median of the numbers passed as arguments (empty if none). RandomX hashrate is noisy, so we report
# the median of several runs per candidate rather than a single (or best) reading.
_median() {
    printf '%s\n' "$@" | sort -n | awk '
        {a[NR]=$1}
        END{ if(NR==0) exit; print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2 }'
}

# Tiny file-backed memo (bash 3.2 has no associative arrays). Keyed by the candidate tuple so the
# hill-climb — which revisits the current point as it sweeps each knob — never re-benchmarks a combo.
_memo_get() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$MEMO_FILE" 2>/dev/null; }
_memo_put() { printf '%s\t%s\n' "$1" "$2" >>"$MEMO_FILE"; }

# Best-effort temperature (°C) and power (W) for a hashrate-per-watt view (#54). Both are optional:
# temp defaults to the standard Linux thermal zone, power is opt-in via TUNE_POWER_CMD (reliable
# wattage needs a method the operator chooses — RAPL sampler, smart plug, IPMI). Either may be empty.
_read_temp() {
    if [ -n "${TUNE_TEMP_CMD:-}" ]; then
        eval "$TUNE_TEMP_CMD"
        return 0
    fi
    [ "$OS_TYPE" = "Linux" ] || return 0
    local z="${THERMAL_ZONE:-/sys/class/thermal/thermal_zone0/temp}"
    [ -r "$z" ] && awk '{printf "%.1f", $1/1000}' "$z" 2>/dev/null
    return 0
}
_read_watts() {
    [ -n "${TUNE_POWER_CMD:-}" ] && eval "$TUNE_POWER_CMD"
    return 0
}

# A candidate's knob values as an overrides snippet (the same shape tune writes for the winner).
_tune_knobs_json() { # <prefetch> <yield> <threads> <onegb> <priority> <hpjit> <cacheqos>
    jq -cn --argjson p "$1" --argjson y "$2" --arg t "$3" --argjson g "$4" --argjson pr "$5" \
        --argjson hj "$6" --argjson cq "$7" '
        { randomx: { scratchpad_prefetch_mode: $p, "1gb-pages": $g, cache_qos: $cq },
          cpu: { yield: $y, priority: $pr, "huge-pages-jit": $hj,
                 rx: (if $t == "-1" then -1 else ($t|tonumber) end) } }'
}

# Materialize a full candidate config by merging the knob snippet over the base config.
_tune_config() { # <out> <prefetch> <yield> <threads> <onegb> <priority>
    local out="$1"
    shift
    _tune_knobs_json "$@" | jq -s '.[0] * .[1]' "$TUNE_BASE" - >"$out"
}

# One offline benchmark of a config file → peak H/s (empty on failure). `|| true` keeps a non-zero
# xmrig exit from tripping pipefail; the parser yields nothing and the caller treats it as 0.
_bench_once() {
    local out
    out=$("$TUNE_BIN" --bench="${TUNE_BENCH:-10M}" --config="$1" 2>&1 || true)
    printf '%s' "$out" | _parse_hashrate
}

# Live measurement (#54): apply a candidate to the RUNNING miner, discard a warmup window, then take a
# few API samples over steady state and return their median. Heavier than --bench (it restarts the
# service per candidate) but reflects real-world conditions. Linux-only; reuses _read_api_hashrate.
_measure_live() { # <prefetch> <yield> <threads> <onegb> <priority>
    local tmp
    tmp=$(mktemp)
    _tune_knobs_json "$@" >"$tmp" && sudo cp "$tmp" "$TUNE_OVERRIDES"
    rm -f "$tmp"
    apply >/dev/null 2>&1 || true
    sleep "${TUNE_LIVE_WARMUP:-60}"
    local i s samples=() n="${TUNE_LIVE_SAMPLES:-3}"
    for i in $(seq 1 "$n"); do
        s=$(_read_api_hashrate)
        [ -n "$s" ] || s=0
        samples+=("$s")
        [ "$i" -lt "$n" ] && sleep "${TUNE_LIVE_INTERVAL:-30}"
    done
    _median "${samples[@]}"
}

# Measure one candidate (memoized): median over TUNE_ITERS bench runs, or one live window. On a cache
# miss it also records the candidate — samples, median, and any temp/watts — to the results log.
_measure() { # <prefetch> <yield> <threads> <onegb> <priority> <hpjit> <cacheqos> -> echoes median H/s
    local p="$1" y="$2" t="$3" g="$4" pr="$5" hj="$6" cq="$7" key="$1|$2|$3|$4|$5|$6|$7" cached
    cached=$(_memo_get "$key")
    if [ -n "$cached" ]; then
        printf '%s' "$cached"
        return 0
    fi

    local med samples=() s i cfg
    if [ "$TUNE_MODE" = live ]; then
        med=$(_measure_live "$p" "$y" "$t" "$g" "$pr" "$hj" "$cq")
        [ -n "$med" ] || med=0
        samples=("$med")
    else
        cfg="$TUNE_TMP/cand.json"
        _tune_config "$cfg" "$p" "$y" "$t" "$g" "$pr" "$hj" "$cq"
        for i in $(seq 1 "${TUNE_ITERS:-5}"); do
            s=$(_bench_once "$cfg")
            [ -n "$s" ] || s=0
            samples+=("$s")
        done
        med=$(_median "${samples[@]}")
        [ -n "$med" ] || med=0
    fi

    local watts temp
    watts=$(_read_watts)
    temp=$(_read_temp)
    jq -cn --argjson p "$p" --argjson y "$y" --arg t "$t" --argjson g "$g" --argjson pr "$pr" \
        --argjson hj "$hj" --argjson cq "$cq" \
        --argjson med "$med" --arg samples "${samples[*]}" --arg watts "${watts:-}" --arg temp "${temp:-}" '
        { prefetch_mode: $p, yield: $y, threads: ($t|tonumber), "1gb-pages": $g, priority: $pr,
          "huge-pages-jit": $hj, cache_qos: $cq,
          hashrate: $med, samples: ($samples|split(" ")|map(tonumber)),
          watts: (if $watts=="" then null else ($watts|tonumber) end),
          temp_c: (if $temp=="" then null else ($temp|tonumber) end),
          hs_per_watt: (if $watts=="" or ($watts|tonumber)==0 then null else ($med/($watts|tonumber)) end) }' \
        >>"$RESULTS_FILE"
    _memo_put "$key" "$med"
    printf '%s' "$med"
}

# Knob registry: the candidate values for each knob, and get/set of the current state (S_*). Encapsulates
# the bash-3.2-friendly indirection so the hill-climb loop stays generic over knob names.
_knob_values() {
    case "$1" in
    prefetch) echo "$TUNE_PREFETCH_MODES" ;;
    yield) echo "$TUNE_YIELDS" ;;
    threads) echo "$TUNE_THREADS" ;;
    onegb) echo "$TUNE_ONEGB" ;;
    priority) echo "$TUNE_PRIORITIES" ;;
    hpjit) echo "$TUNE_HPJIT" ;;
    cacheqos) echo "$TUNE_CACHEQOS" ;;
    esac
}
_knob_get() {
    case "$1" in
    prefetch) echo "$S_p" ;; yield) echo "$S_y" ;; threads) echo "$S_t" ;;
    onegb) echo "$S_g" ;; priority) echo "$S_pr" ;;
    hpjit) echo "$S_hj" ;; cacheqos) echo "$S_cq" ;;
    esac
}
_knob_set() {
    case "$1" in
    prefetch) S_p="$2" ;; yield) S_y="$2" ;; threads) S_t="$2" ;;
    onegb) S_g="$2" ;; priority) S_pr="$2" ;;
    hpjit) S_hj="$2" ;; cacheqos) S_cq="$2" ;;
    esac
}
_measure_state() { _measure "$S_p" "$S_y" "$S_t" "$S_g" "$S_pr" "$S_hj" "$S_cq"; }

# A sensible RandomX thread count for this CPU (~one thread per 2 MB of L3, clamped to the core count),
# or empty if it can't be determined. RandomX peaks near L3/2 MB; more threads thrash the cache.
_l3_thread_center() {
    [ "$OS_TYPE" = "Linux" ] || return 0
    local l3 mb cores c
    l3=$(lscpu 2>/dev/null | awk -F: '/L3 cache/ {gsub(/^[ \t]+/,"",$2); print $2; exit}') || true
    [ -n "$l3" ] || return 0
    mb=$(printf '%s' "$l3" | awk '{ v=$1; u=$2;
        if (u ~ /Ki/) v=v/1024; else if (u ~ /Gi/) v=v*1024; else if (v>100000) v=v/1024/1024;
        printf "%d", v }') || true
    [ -n "$mb" ] && [ "$mb" -gt 0 ] 2>/dev/null || return 0
    cores=$(nproc 2>/dev/null || echo 0)
    c=$((mb / 2))
    [ "$c" -lt 1 ] && c=1
    [ "$cores" -gt 0 ] && [ "$c" -gt "$cores" ] && c="$cores"
    echo "$c"
}

# Physical core count (Core(s) per socket × Socket(s) from lscpu), or empty if undeterminable. RandomX
# often peaks at one thread per PHYSICAL core, because SMT siblings share the L2/L3 a thread needs.
_physical_cores() {
    [ "$OS_TYPE" = "Linux" ] || return 0
    local cps sk
    cps=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket:/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
    sk=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\):/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
    [ -n "$cps" ] && [ -n "$sk" ] && [ "$cps" -gt 0 ] 2>/dev/null && [ "$sk" -gt 0 ] 2>/dev/null || return 0
    echo $((cps * sk))
}

# Thread-count candidates to benchmark: "-1" (XMRig's own L3-aware auto), the physical-core count and the
# logical-core count (to probe SMT-off vs SMT-on), and a ±2 window around the L3-derived center (~L3/2 MB
# per thread). All clamped to [1, logical cores] and de-duplicated. A wider, SMT-aware set than a bare
# ±1 window — thread placement/count is one of RandomX's biggest levers.
_thread_candidates() { # <center>
    local c="$1" cores phys list="-1" v
    cores=$(nproc 2>/dev/null || echo 0)
    phys=$(_physical_cores)
    for v in "$phys" "$cores" "$((c - 2))" "$((c - 1))" "$c" "$((c + 1))" "$((c + 2))"; do
        [ -n "$v" ] && [ "$v" -ge 1 ] 2>/dev/null || continue
        [ "$cores" -gt 0 ] && [ "$v" -gt "$cores" ] && continue
        case " $list " in *" $v "*) ;; *) list="$list $v" ;; esac
    done
    echo "$list"
}

# Coordinate hill-climb from the current S_* state: sweep each active knob, adopt the best value that
# beats the running best by TUNE_MIN_DELTA, and repeat rounds until a pass makes no gain (plateau).
# Echoes the best hashrate reached; leaves S_* at the winning combination.
_hillclimb() {
    # Returns its result in the HILL_BEST global and leaves S_* at the winning combination. It must be
    # called DIRECTLY (not via $(...)), because a command-substitution subshell would discard the S_*
    # mutations; the memo and results survive regardless because they are file-backed. Progress is
    # logged to stderr to keep stdout clean.
    local best round=0 improved knob cur best_v best_here v cand
    best=$(_measure_state)
    while [ "$round" -lt "${TUNE_MAX_ROUNDS:-3}" ]; do
        round=$((round + 1))
        improved=0
        for knob in $ACTIVE_KNOBS; do
            cur=$(_knob_get "$knob")
            best_v="$cur"
            best_here="$best"
            for v in $(_knob_values "$knob"); do
                [ "$v" = "$cur" ] && continue
                _knob_set "$knob" "$v"
                cand=$(_measure_state)
                _knob_set "$knob" "$cur"
                log "    try $knob=$v -> $cand H/s" >&2
                if awk "BEGIN{exit !($cand > $best_here * (1 + ${TUNE_MIN_DELTA:-0.01}))}"; then
                    best_here="$cand"
                    best_v="$v"
                fi
            done
            if [ "$best_v" != "$cur" ]; then
                _knob_set "$knob" "$best_v"
                best="$best_here"
                improved=1
                log "  adopt $knob=$best_v ($best H/s)" >&2
            fi
        done
        [ "$improved" -eq 0 ] && {
            log "  plateau after round $round." >&2
            break
        }
    done
    HILL_BEST="$best"
}

# Exhaustive grid search (#6; opt-in via TUNE_SEARCH=grid). Measures every combination of the knobs'
# candidate values and keeps the best — slower than the hill-climb but immune to local optima and knob
# interactions, worth it for this small discrete space. Inactive knobs have a single candidate, so they
# contribute one iteration each. Sets the G_* winner globals directly (tune()'s locals, via dynamic
# scope), so it must be called DIRECTLY, not in a $(...) subshell.
_gridsearch() {
    local vp vy vt vg vpr vhj vcq hr
    for vp in $(_knob_values prefetch); do
        for vy in $(_knob_values yield); do
            for vt in $(_knob_values threads); do
                for vg in $(_knob_values onegb); do
                    for vpr in $(_knob_values priority); do
                        for vhj in $(_knob_values hpjit); do
                            for vcq in $(_knob_values cacheqos); do
                                hr=$(_measure "$vp" "$vy" "$vt" "$vg" "$vpr" "$vhj" "$vcq")
                                log "    grid prefetch=$vp yield=$vy threads=$vt 1gb=$vg prio=$vpr hpjit=$vhj cacheqos=$vcq -> $hr H/s" >&2
                                if awk "BEGIN{exit !($hr > $G_best)}"; then
                                    G_best="$hr"
                                    G_p="$vp"
                                    G_y="$vy"
                                    G_t="$vt"
                                    G_g="$vg"
                                    G_pr="$vpr"
                                    G_hj="$vhj"
                                    G_cq="$vcq"
                                fi
                            done
                        done
                    done
                done
            done
        done
    done
}

# The base config's value for the two off-by-default knobs (huge-pages-jit, cache_qos), so a seed starts
# from what the generated config actually uses (both default false). Shared by the seeds.
_seed_hj() { jq -r '.cpu."huge-pages-jit" // false' "$TUNE_BASE"; }
_seed_cq() { jq -r '.randomx.cache_qos // false' "$TUNE_BASE"; }

# Seed the state with XMRig's auto baseline (the generated config's own values; threads left to auto).
_seed_auto() {
    S_p=$(jq -r '.randomx.scratchpad_prefetch_mode // 1' "$TUNE_BASE")
    S_y=$(jq -r '.cpu.yield // false' "$TUNE_BASE")
    S_g=$(jq -r '.randomx."1gb-pages" // true' "$TUNE_BASE")
    S_pr=$(jq -r '.cpu.priority // 2' "$TUNE_BASE")
    S_t="-1"
    S_hj=$(_seed_hj)
    S_cq=$(_seed_cq)
}
# Seed the state with an educated guess (a different starting point so the climb can escape a local
# optimum the auto seed lands in): prefetch=2, yield off, threads sized to L3/2 MB.
_seed_guess() {
    S_p="${TUNE_GUESS_PREFETCH:-2}"
    S_y=false
    S_pr=2
    S_g=$(jq -r '.randomx."1gb-pages" // true' "$TUNE_BASE")
    S_t="${TUNE_GUESS_THREADS:-${THREAD_CENTER:--1}}"
    [ -n "$S_t" ] || S_t="-1"
    S_hj=$(_seed_hj)
    S_cq=$(_seed_cq)
}

tune() {
    local clear=0
    TUNE_MODE="${TUNE_MODE:-bench}"
    while [ $# -gt 0 ]; do
        case "$1" in
        --clear) clear=1 ;;
        --live) TUNE_MODE=live ;;
        --bench) TUNE_MODE=bench ;;
        *) error "Unknown tune option: $1 (use --live, --bench, or --clear)." ;;
        esac
        shift
    done

    parse_config # resolves WORKER_ROOT (and validates the config)
    TUNE_OVERRIDES="$WORKER_ROOT/tune-overrides.json"
    local logf="$WORKER_ROOT/rigforge-tune.json"

    if [ "$clear" = 1 ]; then
        sudo rm -f "$TUNE_OVERRIDES" "$logf"
        log "Cleared tuning state. Run 'sudo $0 apply' to regenerate the baseline config."
        return 0
    fi

    if [ "$TUNE_MODE" = live ] && [ "$OS_TYPE" != "Linux" ]; then
        error "tune --live drives the running systemd service and is only supported on Linux."
    fi

    local build="$WORKER_ROOT/xmrig/build"
    TUNE_BIN="$build/xmrig"
    TUNE_BASE="$build/config.json"
    [ -x "$TUNE_BIN" ] && [ -f "$TUNE_BASE" ] || error "No built worker at $build. Run 'setup' first, then 'tune'."

    TUNE_BENCH="${TUNE_BENCH:-10M}" # longer = steadier and closer to sustained load. You tune once and
    # run for months, so the default favors thoroughness over speed; set TUNE_BENCH=1M for a quick pass.
    TUNE_ITERS="${TUNE_ITERS:-5}" # median of 5 short benches: steadier than 3 against RandomX jitter (#3)
    TUNE_MIN_DELTA="${TUNE_MIN_DELTA:-0.01}"
    TUNE_MAX_ROUNDS="${TUNE_MAX_ROUNDS:-3}"
    TUNE_SEARCH="${TUNE_SEARCH:-climb}" # climb = hill-climb (fast); grid = exhaustive (robust, slower) (#6)
    TUNE_SEEDS="${TUNE_SEEDS:-auto guess}"
    TUNE_PREFETCH_MODES="${TUNE_PREFETCH_MODES:-0 1 2 3}"
    TUNE_YIELDS="${TUNE_YIELDS:-true false}"
    TUNE_PRIORITIES="${TUNE_PRIORITIES:-2}" # single value => knob off by default
    # Off-by-default knobs (single value => not searched). huge-pages-jit can help some Ryzen but XMRig
    # warns it makes hashrate unstable; cache_qos is an Intel L3-CAT lever. Sweep with e.g.
    # TUNE_HPJIT="false true" (it then gets pinned only if it actually wins).
    TUNE_HPJIT="${TUNE_HPJIT:-$(jq -r '.cpu."huge-pages-jit" // false' "$TUNE_BASE")}"
    TUNE_CACHEQOS="${TUNE_CACHEQOS:-$(jq -r '.randomx.cache_qos // false' "$TUNE_BASE")}"

    # Thread-count knob: candidates around the L3-derived center (none if L3 can't be read, e.g. macOS).
    THREAD_CENTER=$(_l3_thread_center)
    if [ -n "$THREAD_CENTER" ]; then
        TUNE_THREADS="${TUNE_THREADS:-$(_thread_candidates "$THREAD_CENTER")}"
    else
        TUNE_THREADS="${TUNE_THREADS:--1}"
    fi

    # 1gb-pages is reboot-bound (#54): flipping it only matters if the host actually has 1G HugePages
    # reserved (a GRUB change + reboot, done by `setup`). Sweep it only when they're present; otherwise
    # leave it at the base value and say so, rather than benchmarking a no-op.
    local nr=0
    [ -r "$HUGEPAGES_1G_NR" ] && nr=$(cat "$HUGEPAGES_1G_NR" 2>/dev/null || echo 0)
    if [ "${nr:-0}" -gt 0 ] 2>/dev/null; then
        TUNE_ONEGB="${TUNE_ONEGB:-true false}"
    else
        TUNE_ONEGB="$(jq -r '.randomx."1gb-pages" // true' "$TUNE_BASE")"
        log "Note: 1G HugePages not reserved — skipping the 1gb-pages knob (it needs a GRUB change + reboot; run 'setup')."
    fi

    # Active knobs = those with more than one candidate value (the rest are fixed, not searched).
    ACTIVE_KNOBS=""
    local k n
    for k in prefetch yield threads onegb priority hpjit cacheqos; do
        n=$(_knob_values "$k" | wc -w | tr -d ' ')
        [ "$n" -gt 1 ] && ACTIVE_KNOBS="$ACTIVE_KNOBS $k"
    done

    TUNE_TMP=$(mktemp -d)
    MEMO_FILE="$TUNE_TMP/memo"
    RESULTS_FILE="$TUNE_TMP/results.jsonl"
    : >"$MEMO_FILE"
    : >"$RESULTS_FILE"

    if [ "$TUNE_MODE" = live ]; then
        log "Auto-tuning LIVE against the running miner (warmup ${TUNE_LIVE_WARMUP:-60}s, ${TUNE_LIVE_SAMPLES:-3} samples) — search=$TUNE_SEARCH, knobs={$ACTIVE_KNOBS}."
    else
        log "Auto-tuning via 'xmrig --bench=$TUNE_BENCH' (median of $TUNE_ITERS) — search=$TUNE_SEARCH, knobs={$ACTIVE_KNOBS}, min-delta=$TUNE_MIN_DELTA."
        log "Note: '--bench' measures Monero's RandomX (rx/0). For a different RandomX variant (e.g. rx/wow), use 'tune --live' so it measures your actual pool's algorithm."
    fi

    # In offline --bench mode, stop the running miner so the benchmark has the whole machine — CPU and the
    # reserved huge pages — to itself; a service mining alongside would contend for both and turn every
    # reading into noise. Restarted automatically afterwards (even on error/abort) via the cleanup trap.
    # --live mode measures the running service itself, so it must NOT stop it. (#2)
    if [ "$TUNE_MODE" = bench ] && [ "$OS_TYPE" = Linux ] && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log "Stopping the '$SERVICE_NAME' service for the benchmark run (restarted automatically afterwards)."
        sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        _TUNE_SVC_STOPPED=1
        trap '_tune_bench_cleanup' EXIT
    fi

    local G_best="-1" G_p="" G_y="" G_t="" G_g="" G_pr="" G_hj="" G_cq="" seed seed_hr
    if [ "$TUNE_SEARCH" = grid ]; then
        local combos=1 kk
        for kk in $ACTIVE_KNOBS; do combos=$((combos * $(_knob_values "$kk" | wc -w | tr -d ' '))); done
        log "Grid search: $combos combination(s) over {$ACTIVE_KNOBS} — exhaustive (no local-optimum risk), slower than the hill-climb."
        _gridsearch # sets the G_* winner globals directly (must NOT run in a subshell)
    else
        for seed in $TUNE_SEEDS; do
            case "$seed" in
            auto) _seed_auto ;;
            guess) _seed_guess ;;
            *)
                warn "Unknown tune seed '$seed' — skipping."
                continue
                ;;
            esac
            log "Seed '$seed': prefetch=$S_p yield=$S_y threads=$S_t 1gb=$S_g priority=$S_pr"
            _hillclimb # sets HILL_BEST and leaves S_* at this seed's winner (must NOT run in a subshell)
            seed_hr="$HILL_BEST"
            log "Seed '$seed' best: prefetch=$S_p yield=$S_y threads=$S_t ($seed_hr H/s)"
            if awk "BEGIN{exit !($seed_hr > $G_best)}"; then
                G_best="$seed_hr"
                G_p="$S_p"
                G_y="$S_y"
                G_t="$S_t"
                G_g="$S_g"
                G_pr="$S_pr"
                G_hj="$S_hj"
                G_cq="$S_cq"
            fi
        done
    fi

    if [ -z "$G_p" ] || awk "BEGIN{exit !($G_best <= 0)}"; then
        rm -rf "$TUNE_TMP"
        error "Benchmarks produced no hashrate — check that the worker is built correctly."
    fi

    # Build the overrides snippet from the winning state. Always pin prefetch + yield; pin threads only
    # if a concrete count won (not auto), and priority / 1gb-pages only if they were actually swept — so
    # we never freeze a knob the search didn't explore.
    local ovr
    ovr=$(jq -n --argjson p "$G_p" --argjson y "$G_y" '{randomx:{scratchpad_prefetch_mode:$p}, cpu:{yield:$y}}')
    [ "$G_t" != "-1" ] && ovr=$(printf '%s' "$ovr" | jq --argjson t "$G_t" '.cpu.rx = $t')
    case " $ACTIVE_KNOBS " in *" priority "*) ovr=$(printf '%s' "$ovr" | jq --argjson pr "$G_pr" '.cpu.priority = $pr') ;; esac
    case " $ACTIVE_KNOBS " in *" onegb "*) ovr=$(printf '%s' "$ovr" | jq --argjson g "$G_g" '.randomx."1gb-pages" = $g') ;; esac
    case " $ACTIVE_KNOBS " in *" hpjit "*) ovr=$(printf '%s' "$ovr" | jq --argjson hj "$G_hj" '.cpu."huge-pages-jit" = $hj') ;; esac
    case " $ACTIVE_KNOBS " in *" cacheqos "*) ovr=$(printf '%s' "$ovr" | jq --argjson cq "$G_cq" '.randomx.cache_qos = $cq') ;; esac
    printf '%s\n' "$ovr" >"$TUNE_TMP/ovr.json" && sudo cp "$TUNE_TMP/ovr.json" "$TUNE_OVERRIDES"

    # Assemble the full search log: the winner, the search parameters, and every measured candidate.
    jq -s --argjson p "$G_p" --argjson y "$G_y" --arg t "$G_t" --argjson g "$G_g" --argjson pr "$G_pr" \
        --argjson hj "$G_hj" --argjson cq "$G_cq" \
        --argjson hr "$G_best" --arg mode "$TUNE_MODE" --arg search "$TUNE_SEARCH" --arg seeds "$TUNE_SEEDS" \
        --argjson iters "$TUNE_ITERS" --argjson delta "$TUNE_MIN_DELTA" '
        { best: { scratchpad_prefetch_mode: $p, yield: $y, threads: ($t|tonumber), "1gb-pages": $g,
                  priority: $pr, "huge-pages-jit": $hj, cache_qos: $cq, hashrate: $hr },
          mode: $mode, search: $search, seeds: ($seeds|split(" ")), iterations: $iters, min_delta: $delta,
          results: . }' "$RESULTS_FILE" >"$TUNE_TMP/log.json" && sudo cp "$TUNE_TMP/log.json" "$logf"

    local hpw=""
    hpw=$(jq -r '[.results[].hs_per_watt // empty] | if length>0 then max else empty end' "$logf" 2>/dev/null || true)
    rm -rf "$TUNE_TMP"

    log "Best: prefetch_mode=$G_p yield=$G_y threads=$G_t ($G_best H/s). Saved to $TUNE_OVERRIDES (log: $logf)."
    [ -n "$hpw" ] && log "Best efficiency observed: $hpw H/s per watt."
    if [ "$G_t" != "-1" ] && [ "$OS_TYPE" = Linux ]; then
        log "Note: cpu.rx is pinned to $G_t threads. HugePages are sized by 'setup'; if 'doctor' later reports HugePages below 100%, re-run 'sudo $0 setup' (reboot) to resize the reservation for this thread count."
    fi
    if [ "$TUNE_MODE" = live ]; then
        apply >/dev/null 2>&1 || true
        log "Applied the winning config to the live miner."
    else
        log "Apply it: sudo $0 apply    (reset anytime with: sudo $0 tune --clear)"
    fi
}

# Merge a prefetch-mode change INTO the existing overrides file, preserving every other tuned knob it
# already holds (#46 fix: autotune used to overwrite the whole file, silently dropping a prior `tune`'s
# threads/yield/1gb-pages). A no-op-safe `{}` base is used when no overrides exist yet.
_autotune_set_prefetch() { # <overrides_file> <mode>
    local f="$1" m="$2" base='{}' tmp
    [ -f "$f" ] && base=$(cat "$f" 2>/dev/null)
    [ -n "$base" ] || base='{}'
    tmp=$(mktemp)
    if printf '%s' "$base" | jq --argjson m "$m" '.randomx.scratchpad_prefetch_mode = $m' >"$tmp" 2>/dev/null; then
        sudo cp "$tmp" "$f"
    fi
    rm -f "$tmp"
}

# autotune (#46): one LIVE trial against the running miner. Reads the current hashrate from the worker's
# HTTP API (median of a few samples — live numbers are noisy), tries the next candidate prefetch mode,
# applies it (MERGED into the overrides file, preserving any offline-`tune` knobs) and restarts, measures
# again over a window, and KEEPS the change only if it beats the baseline by a margin — else it rolls
# back. Meant to be run periodically: when `autotune: true` is set in config.json, setup installs a
# systemd timer that calls this. The median + margin + rollback keep noisy single readings from sticking.
autotune() {
    if [ "$OS_TYPE" != "Linux" ]; then
        error "autotune drives the live systemd service and is only supported on Linux."
    fi
    parse_config
    local overrides="$WORKER_ROOT/tune-overrides.json"
    local cur next base_hr new_hr n="${AUTOTUNE_SAMPLES:-3}" iv="${AUTOTUNE_INTERVAL:-10}"
    cur=$(jq -r '.randomx.scratchpad_prefetch_mode // 1' "$overrides" 2>/dev/null || echo 1)
    next=$(((cur + 1) % 4)) # cycle through prefetch modes 0..3 across runs
    base_hr=$(_sample_api_median "$n" "$iv")
    [ -n "$base_hr" ] && [ "$base_hr" != 0 ] || {
        warn "autotune: could not read a live hashrate from the API — is the miner running? Skipping."
        return 0
    }
    log "autotune: baseline prefetch_mode=$cur at $base_hr H/s (median of $n); trying prefetch_mode=$next..."

    # Apply the candidate (merged into the overrides overlay), regenerate + restart, then measure.
    _autotune_set_prefetch "$overrides" "$next"
    apply >/dev/null 2>&1 || true
    sleep "${AUTOTUNE_WARMUP:-60}"
    new_hr=$(_sample_api_median "$n" "$iv")
    [ -n "$new_hr" ] || new_hr=0

    # Keep only if faster by at least the margin (default 1%); else roll back to the previous mode.
    if awk "BEGIN{exit !($new_hr > $base_hr * (1 + ${AUTOTUNE_MARGIN:-0.01}))}"; then
        log "autotune: prefetch_mode=$next is faster ($new_hr vs $base_hr H/s) — keeping it."
    else
        log "autotune: prefetch_mode=$next not better ($new_hr vs $base_hr H/s) — rolling back to $cur."
        _autotune_set_prefetch "$overrides" "$cur"
        apply >/dev/null 2>&1 || true
    fi
}

# Read the current total hashrate from the worker's HTTP API (empty if unreachable). Overridable for
# tests via API_CMD. This is RigForge's own local reader (loopback) used by tune/autotune; it uses the
# `/2/summary` endpoint. Pithead's dashboard separately reads `/1/summary` from the stack host — both
# are valid XMRig endpoints, the divergence is intentional.
_read_api_hashrate() {
    local url="http://127.0.0.1:8080/2/summary"
    if [ -n "${API_CMD:-}" ]; then
        eval "$API_CMD"
        return
    fi
    command -v curl >/dev/null 2>&1 || return 0
    curl -fsS --max-time 5 -H "Authorization: Bearer ${ACCESS_TOKEN:-}" "$url" 2>/dev/null |
        jq -r '.hashrate.total[0] // empty' 2>/dev/null
}

# Median of N live API hashrate samples, <interval> seconds apart. Smooths the jittery live reading so a
# transient spike/dip can't drive an autotune keep/reject on its own. n<=1 (or interval 0) skips sleeps.
_sample_api_median() { # <n> <interval>
    local n="${1:-3}" iv="${2:-10}" i s out=()
    for i in $(seq 1 "$n"); do
        s=$(_read_api_hashrate)
        [ -n "$s" ] || s=0
        out+=("$s")
        [ "$i" -lt "$n" ] && [ "$iv" -gt 0 ] 2>/dev/null && sleep "$iv"
    done
    _median "${out[@]}"
}

# --- Backup / restore ------------------------------------------------------
#
# A worker's expensive, hard-to-recreate state is just its config and its tuning — the XMRig build and
# the system tuning are regenerated by `setup`. `backup` snapshots config.json + the tuning files into a
# portable tarball; `restore` puts them back: after data loss on this machine, or onto OTHER identical
# machines so you tune once and roll the result out across a fleet. (Tuning is CPU-specific — only reuse
# it between identical CPUs.) Mirrors Pithead's backup/restore UX.

# backup: write config.json + tuning into a timestamped tar.gz under ./backups (owner-only).
backup() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) ;; # accepted for symmetry with restore; backup has no prompt to skip
        *) error "Unexpected argument for backup: $arg. Run '$0 help'." ;;
        esac
    done
    [ -f "$CONFIG_JSON" ] || error "No config.json to back up. Run 'setup' first."

    local wr stage included="config.json" f
    wr=$(_worker_root_from_config)
    stage=$(mktemp -d)
    cp "$CONFIG_JSON" "$stage/config.json"
    # The tuning files live under the worker root; include whichever exist (a fresh worker has none yet).
    for f in tune-overrides.json rigforge-tune.json; do
        if [ -n "$wr" ] && [ -f "$wr/$f" ]; then
            cp "$wr/$f" "$stage/$f"
            included="$included $f"
        fi
    done
    # A small manifest for provenance — handy when rolling a tune out across a fleet.
    jq -n --arg v "$(cmd_version)" --arg host "$(hostname 2>/dev/null)" --arg files "$included" \
        '{rigforge: $v, source_host: $host, files: ($files | split(" "))}' >"$stage/rigforge-backup.json" 2>/dev/null || true

    local backups_dir="$SCRIPT_DIR/backups" stamp archive
    mkdir -p "$backups_dir"
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$backups_dir/rigforge-backup-$stamp.tar.gz"
    (umask 077 && tar -czf "$archive" -C "$stage" .)
    rm -rf "$stage"
    chmod 600 "$archive" 2>/dev/null || true

    log "Backed up: $included"
    log "Saved to:  $archive"
    log "Restore with: sudo $0 restore $archive"
}

# restore [-y|--yes] <archive>: put config.json + tuning back from a backup archive.
restore() {
    local assume_yes=0 archive="" arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        -*) error "Unknown option for restore: $arg. Run '$0 help'." ;;
        *) [ -n "$archive" ] || archive="$arg" ;;
        esac
    done
    [ -n "$archive" ] || error "Usage: $0 restore [-y|--yes] <archive.tar.gz>"
    [ -f "$archive" ] || error "Archive not found: $archive"

    warn "Restore will OVERWRITE config.json and any saved tuning (tune-overrides.json) on this machine."
    if [ "$assume_yes" -eq 0 ]; then
        read -r -p "Continue and overwrite? (y/N): " CONFIRM || true
        [[ "$CONFIRM" =~ ^[Yy] ]] || {
            log "Restore cancelled."
            return 0
        }
    fi

    local stage
    stage=$(mktemp -d)
    tar -xzf "$archive" -C "$stage" 2>/dev/null || {
        rm -rf "$stage"
        error "Could not extract $archive — is it a RigForge backup?"
    }
    [ -f "$stage/config.json" ] || {
        rm -rf "$stage"
        error "Archive has no config.json — not a RigForge backup."
    }
    if [ -f "$stage/rigforge-backup.json" ]; then
        local src
        src=$(jq -r '.source_host // empty' "$stage/rigforge-backup.json" 2>/dev/null)
        [ -n "$src" ] && log "Backup was made on host: $src"
    fi

    # config.json -> repo root; tuning -> the worker root resolved from the RESTORED config (so it lands
    # correctly even if this machine's paths differ from the source's).
    cp "$stage/config.json" "$CONFIG_JSON"
    local restored="config.json" wr f
    wr=$(_worker_root_from_config)
    for f in tune-overrides.json rigforge-tune.json; do
        if [ -f "$stage/$f" ]; then
            mkdir -p "$wr" 2>/dev/null || sudo mkdir -p "$wr"
            cp "$stage/$f" "$wr/$f" 2>/dev/null || sudo cp "$stage/$f" "$wr/$f"
            restored="$restored $f"
        fi
    done
    rm -rf "$stage"

    log "Restored: $restored"
    case " $restored " in
    *" tune-overrides.json "*)
        warn "Tuning is CPU-specific — only reuse it between identical CPUs; on different hardware, re-tune ('sudo $0 tune')."
        ;;
    esac
    log "Next: 'sudo $0 setup' to build + apply (or 'sudo $0 apply' if XMRig is already built)."
}

# --- Command surface (#11) -------------------------------------------------

# Service-control verbs are thin wrappers over systemd and are Linux-only.
require_linux_service() {
    if [ "$OS_TYPE" != "Linux" ]; then
        error "'$1' manages the systemd service and is only supported on Linux."
    fi
}
svc_status() {
    require_linux_service status
    sudo systemctl status "$SERVICE_NAME" || true # `status` exits non-zero when stopped; not an error
}
svc_logs() {
    require_linux_service logs
    sudo journalctl -u "$SERVICE_NAME" -f || true # follow exits 130 on Ctrl-C
}
svc_start() {
    require_linux_service start
    sudo systemctl start "$SERVICE_NAME" && log "Started $SERVICE_NAME."
}
svc_stop() {
    require_linux_service stop
    sudo systemctl stop "$SERVICE_NAME" && log "Stopped $SERVICE_NAME."
}
svc_restart() {
    require_linux_service restart
    sudo systemctl restart "$SERVICE_NAME" && log "Restarted $SERVICE_NAME."
}
svc_enable() {
    require_linux_service enable
    sudo systemctl enable "$SERVICE_NAME" && log "Enabled $SERVICE_NAME (starts on boot)."
}
svc_disable() {
    require_linux_service disable
    sudo systemctl disable "$SERVICE_NAME" && log "Disabled $SERVICE_NAME (won't start on boot)."
}
cmd_version() {
    local v="unknown"
    if [ -f "$SCRIPT_DIR/VERSION" ]; then v="$(tr -d '[:space:]' <"$SCRIPT_DIR/VERSION")"; fi
    echo "RigForge $v"
}

# Extract the peak "<N> H/s" hashrate from xmrig output (empty if none). Robust to format variations:
# it just takes the largest H/s number printed. Shared by `bench` and `tune`.
_parse_hashrate() {
    grep -oiE '[0-9]+(\.[0-9]+)?[[:space:]]*H/s' | grep -oE '[0-9]+(\.[0-9]+)?' | sort -nr | head -n1
}

# apply (#11): re-read config.json and regenerate the live XMRig config, then restart — WITHOUT
# recompiling. The fast path after editing config.json.
apply() {
    parse_config
    local build="$WORKER_ROOT/xmrig/build"
    [ -d "$build" ] || error "No built worker at $build. Run 'setup' first."
    (cd "$build" && generate_xmrig_config)
    if [ "$OS_TYPE" == "Linux" ]; then
        sudo systemctl restart "$SERVICE_NAME" && log "Applied config and restarted $SERVICE_NAME."
    else
        log "Config regenerated. Restart the miner to apply."
    fi
}

# bench (#11): run a one-off xmrig --bench and report the hashrate. A quick perf/health check.
bench() {
    parse_config
    local bin="$WORKER_ROOT/xmrig/build/xmrig" cfg="$WORKER_ROOT/xmrig/build/config.json"
    [ -x "$bin" ] || error "No built worker at $bin. Run 'setup' first."
    local b="${BENCH:-1M}" out hr
    log "Running 'xmrig --bench=$b' (this takes a few seconds)..."
    out=$("$bin" --bench="$b" ${cfg:+--config="$cfg"} 2>&1 || true)
    hr=$(printf '%s' "$out" | _parse_hashrate)
    [ -n "$hr" ] || error "Could not read a hashrate from the benchmark output."
    log "Benchmark hashrate: $hr H/s"
}

# doctor (#45): verify the optimizations actually took effect. Read-only and best-effort — it never
# changes the system, just reports PASS/WARN with actionable hints. Linux-only checks.
_ck_ok() { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
_ck_warn() { echo -e "  ${C_YELLOW}!${C_RESET} $1"; }
doctor() {
    cmd_version
    if [ "$OS_TYPE" != "Linux" ]; then
        warn "doctor's health checks are Linux-only (this host is $OS_TYPE)."
        return 0
    fi
    log "Checking the worker (read-only)..."
    local issues=0

    # Service active?
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        _ck_ok "service '$SERVICE_NAME' is active"
    else
        _ck_warn "service '$SERVICE_NAME' is not active — start it with: sudo $0 start"
        issues=$((issues + 1))
    fi

    # HugePages reserved? (the single biggest lever; needs a reboot after setup)
    local hp
    hp=$(awk '/^HugePages_Total:/ {print $2; exit}' "$MEMINFO" 2>/dev/null)
    if [ -n "$hp" ] && [ "$hp" -gt 0 ] 2>/dev/null; then
        _ck_ok "HugePages reserved (HugePages_Total=$hp)"
    else
        _ck_warn "HugePages not reserved — reboot after setup (the GRUB change needs a reboot)"
        issues=$((issues + 1))
    fi

    # 1GB HugePages (optional bonus)
    local g=0
    [ -f "$HUGEPAGES_1G_NR" ] && g=$(cat "$HUGEPAGES_1G_NR" 2>/dev/null || echo 0)
    if [ "${g:-0}" -gt 0 ] 2>/dev/null; then
        _ck_ok "1GB HugePages reserved ($g)"
    else
        _ck_warn "1GB HugePages not reserved (optional; needs a pdpe1gb CPU + reboot)"
    fi

    # MSR module loaded? (required for the MSR mod's ~10-15% hashrate)
    if [ -d "$MSR_MODULE_DIR" ]; then
        _ck_ok "msr kernel module loaded"
    else
        _ck_warn "msr module not loaded — the MSR mod won't apply; if it persists, disable Secure Boot"
        issues=$((issues + 1))
    fi

    # CPU governor
    local gov
    gov=$(cat "$GOVERNOR_FILE" 2>/dev/null || echo "")
    if [ "$gov" = "performance" ]; then
        _ck_ok "CPU governor = performance"
    else
        _ck_warn "CPU governor is '${gov:-unknown}' (expected 'performance')"
    fi

    # XMRig's own startup report, if a log exists (HUGE PAGES 100% means the dataset is fully backed).
    local wr log_file
    if [ -f "$CONFIG_JSON" ]; then
        wr=$(_worker_root_from_config)
        log_file="$wr/xmrig.log"
        if [ -f "$log_file" ]; then
            if grep -qiE 'huge pages.*100%' "$log_file"; then
                _ck_ok "XMRig log reports HUGE PAGES 100%"
            elif grep -qi 'huge pages' "$log_file"; then
                _ck_warn "XMRig log shows HUGE PAGES below 100% — not all threads are backed"
            fi
        fi
    fi

    echo ""
    if [ "$issues" -eq 0 ]; then
        log "doctor: all critical checks passed."
    else
        warn "doctor: $issues issue(s) found — see the hints above."
    fi
}

usage() {
    cat <<USAGE
RigForge — provision and maintain an XMRig mining worker.

Usage: $0 [command]

  setup      (default) provision the worker: dependencies, build, kernel tuning, service
  upgrade    rebuild + restart only if the pinned XMRig version/commit changed
  apply      re-read config.json, regenerate the XMRig config, and restart (no rebuild)
  uninstall  remove the service and revert all system changes (add --yes to skip the prompt)
  doctor     check that HugePages, the MSR mod, the governor and the service are all healthy
  bench      run a one-off 'xmrig --bench' and report the hashrate
  tune       iteratively search the XMRig knobs (prefetch, yield, threads, 1gb-pages) and keep the
             fastest; '--live' tunes against the running miner, 'tune --clear' resets
  autotune   one live trial against the running miner (enable periodic runs with autotune:true in config)
  backup     save config.json + tuning to a timestamped archive in ./backups
  restore    restore config.json + tuning from a backup archive: restore [-y] <archive>
  status     show the systemd service status
  logs       follow the live service logs
  start      start the miner service
  stop       stop the miner service
  restart    restart the miner service
  enable     start the miner service on boot
  disable    don't start the miner service on boot
  version    print the RigForge version
  help       show this help

Re-running 'setup' is idempotent: it skips the recompile when the pinned XMRig is already built.
USAGE
}

if [ "$_RIGFORGE_SOURCED" = "0" ]; then
    case "${1:-setup}" in
    setup) main ;;
    upgrade) upgrade ;;
    uninstall) uninstall "${2:-}" ;;
    tune)
        shift
        tune "$@"
        ;;
    autotune) autotune ;;
    doctor) doctor ;;
    status) svc_status ;;
    logs) svc_logs ;;
    start | up) svc_start ;;
    stop | down) svc_stop ;;
    restart) svc_restart ;;
    enable) svc_enable ;;
    disable) svc_disable ;;
    apply) apply ;;
    bench) bench ;;
    backup)
        shift
        backup "$@"
        ;;
    restore)
        shift
        restore "$@"
        ;;
    version | --version | -v) cmd_version ;;
    help | -h | --help) usage ;;
    *) error "Unknown command: $1. Try: setup, upgrade, apply, uninstall, doctor, bench, tune, autotune, backup, restore, status, logs, start, stop, restart, enable, disable, version, help." ;;
    esac
fi
