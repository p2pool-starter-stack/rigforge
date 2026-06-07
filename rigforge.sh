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

    RAW_HOME=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON")
    if [ "$RAW_HOME" == "DYNAMIC_HOME" ]; then
        WORKER_ROOT="$SCRIPT_DIR/data/worker"
    else
        WORKER_ROOT="$RAW_HOME/worker"
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

    # Validate every pool: a `host:port` url (the char regex rejects the unfilled placeholder <...> and
    # shell/URL metacharacters; the port is required — we don't guess one), and a boolean tls.
    while IFS=$'\t' read -r _u _t; do
        if [ -z "$_u" ]; then
            error "A pool entry has no url — set 'pools[].url' (host:port) in $CONFIG_JSON."
        fi
        if ! [[ "$_u" =~ ^[A-Za-z0-9._:-]+$ ]]; then
            error "Pool url is not valid: '$_u'. Use host:port or ip:port (pools[].url)."
        fi
        if ! [[ "$_u" =~ :[0-9]+$ ]]; then
            error "Pool url '$_u' must include a port, e.g. $_u:3333."
        fi
        if [ "$_t" != "true" ] && [ "$_t" != "false" ]; then
            error "Pool tls must be true or false (got: $_t)."
        fi
    done < <(jq -r '.[] | [.url, (.tls | tostring)] | @tsv' <<<"$POOLS_JSON")

    # HTTP API token. The rig's label is the pool `user` (#22; defaults to the hostname — see
    # generate_xmrig_config). The token defaults to that same rig name, so the Pithead contract
    # (the dashboard authenticates as `Bearer <rig name>`) holds out of the box. An explicit
    # ACCESS_TOKEN overrides it.
    ACCESS_TOKEN=$(jq -r '.ACCESS_TOKEN // empty' "$CONFIG_JSON")
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(jq -r '.[0].user' <<<"$POOLS_JSON")
        [ -n "$ACCESS_TOKEN" ] || ACCESS_TOKEN=$(hostname)
    fi

    # XMRig config template RigForge tunes from. Internal — bundled with the project, not user-facing.
    TEMPLATE_CONFIG="$SCRIPT_DIR/worker-config/example-config.json.template"
    if [ ! -f "$TEMPLATE_CONFIG" ]; then
        error "Bundled XMRig template not found at: $TEMPLATE_CONFIG (is the RigForge install complete?)."
    fi
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
    log "Generating hardware-optimized configuration using template: $(basename "$TEMPLATE_CONFIG")..."

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
    JIT="true"
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
        PRIORITY="5"
        ASM="true"
        WRMSR="false"
        RDMSR="false"
        HUGE_PAGES="false"
        MEMORY_POOL="false"
        ONE_GB_PAGES="false"
        NUMA="true"
        HTTP_RESTRICTED="true"
        HTTP_HOST="::"
        JIT="false"

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

    # Generate config.json via jq
    jq --argjson pools "$POOLS_JSON" \
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
        '.pools = ($pools | map(.user = (if (.user // "") == "" then $user else .user end))) |
        ."log-file" = $log |
        .cpu.yield = $yield | 
        .cpu.priority = $prio | 
        .cpu.asm = $asm | 
        .cpu.rx = $rx |
        ."cpu"."huge-pages" = $huge_pages |
        ."cpu"."huge-pages-jit" = $jit |
        ."cpu"."memory-pool" = $memory_pool |
        ."donate-level" = $donation |
        ."donate-over-proxy" = $donation |
        .randomx.numa = $numa |
        .randomx."init-avx2" = $avx2 |
        .randomx.wrmsr = $wrmsr |
        .randomx.rdmsr = $rdmsr |
        .randomx."1gb-pages" = $one_gb_pages |
        .randomx.scratchpad_prefetch_mode = $prefetch |
        (if $access_token != "" then ."http"."access-token" = $access_token else . end) | 
        ."http"."restricted" = $restricted |
        ."http"."host" = $host' \
        "$TEMPLATE_CONFIG" >config.json

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
    local raw_home worker_root=""
    if [ -f "$CONFIG_JSON" ]; then
        raw_home=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON" 2>/dev/null)
        if [ "$raw_home" = "DYNAMIC_HOME" ] || [ -z "$raw_home" ] || [ "$raw_home" = "null" ]; then
            worker_root="$SCRIPT_DIR/data/worker"
        else
            worker_root="$raw_home/worker"
        fi
    fi

    # 1. systemd service
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
    local raw_home wr log_file
    if [ -f "$CONFIG_JSON" ]; then
        raw_home=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON" 2>/dev/null)
        if [ "$raw_home" = "DYNAMIC_HOME" ] || [ -z "$raw_home" ] || [ "$raw_home" = "null" ]; then
            wr="$SCRIPT_DIR/data/worker"
        else
            wr="$raw_home/worker"
        fi
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
    version | --version | -v) cmd_version ;;
    help | -h | --help) usage ;;
    *) error "Unknown command: $1. Try: setup, upgrade, apply, uninstall, doctor, bench, status, logs, start, stop, restart, enable, disable, version, help." ;;
    esac
fi
