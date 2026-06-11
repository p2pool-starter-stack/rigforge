#!/usr/bin/env bash
#
# XMRig Worker Deployment Script
# Automates the provisioning of a high-performance Monero mining worker.
# Handles dependency installation, kernel tuning (HugePages/MSR), and service configuration.
#
# Sections, in order (search for "# --- "):
#   Logging utilities · Global variables · Helpers (idempotent edits, build math, GRUB)
#   Setup pipeline: prerequisites & config → workspace & deps → build → XMRig config → service/kernel
#   Orchestration (main) · Lifecycle (upgrade / uninstall)
#   Auto-tuning: memo & stats → power/thermal sensing → measurement → search → 'tune' command
#   Backup / restore · Commands (service control, version, apply, bench) · Doctor · Usage & dispatch
#

set -Eeuo pipefail

# --- Logging Utilities ---
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'
readonly C_BLUE='\033[1;34m'

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
# Resolve a path through any symlink chain and echo the directory that holds the real file (absolute).
# This is what lets an on-PATH symlink (e.g. /usr/local/bin/rigforge -> the checkout) still locate the
# repo it points into, so config.json / util/ / data/ resolve to the checkout, not the symlink's dir.
# Portable (no `readlink -f`, which BSD/macOS lacks): follow links one hop at a time.
_script_dir() {
    local src="${1:-${BASH_SOURCE[0]}}" dir
    while [ -L "$src" ]; do
        dir=$(cd -P "$(dirname "$src")" &>/dev/null && pwd)
        src=$(readlink "$src")
        case "$src" in /*) ;; *) src="$dir/$src" ;; esac
    done
    cd -P "$(dirname "$src")" &>/dev/null && pwd
}

# Base directory for the script's bundled assets (VERSION, systemd/, util/) and its runtime state
# (config.json, data/, backups/). Defaults to the directory the script lives in — resolved through any
# symlink, so a normal deploy is unchanged AND a `rigforge` symlink on PATH still finds the repo.
# Overridable via RIGFORGE_HOME so the test suite can run THIS file against a throwaway sandbox
# (keeping per-test state isolated) instead of a copy of it, which lets coverage credit the real
# script for black-box runs too (#68).
SCRIPT_DIR="${RIGFORGE_HOME:-$(_script_dir)}"
# The operator to hand root-written files back to. Under interactive `sudo` that's SUDO_USER. The
# periodic autotune runs from systemd as root with NO SUDO_USER — so its unit bakes in RIGFORGE_OPERATOR
# (the operator captured at setup time), keeping the scheduled run from re-owning files to root.
REAL_USER="${SUDO_USER:-${RIGFORGE_OPERATOR:-${USER:-$(id -un)}}}"
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
# Directory on PATH where `setup` installs the `rigforge` command (a symlink back to this script).
BIN_DIR="${BIN_DIR:-/usr/local/bin}"

# Read-only system paths the `doctor` health check inspects (overridable for tests).
MEMINFO="${MEMINFO:-/proc/meminfo}"
MSR_MODULE_DIR="${MSR_MODULE_DIR:-/sys/module/msr}"
GOVERNOR_FILE="${GOVERNOR_FILE:-/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor}"
HUGEPAGES_1G_NR="${HUGEPAGES_1G_NR:-/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages}"
# Hashrate-capping-hardware diagnostics (#67): RAM layout (dmidecode) + effective CPU clock under load.
DMIDECODE="${DMIDECODE:-dmidecode}"
RDMSR_BIN="${RDMSR_BIN:-rdmsr}" # msr-tools, for doctor's register-level MSR verification (#66)
CPUFREQ_MAX="${CPUFREQ_MAX:-/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq}"
CPU_SYSFS="${CPU_SYSFS:-/sys/devices/system/cpu}"
MIN_RAM_MTS="${MIN_RAM_MTS:-2666}"   # warn below this configured RAM speed (MT/s)
MIN_CLOCK_PCT="${MIN_CLOCK_PCT:-75}" # warn when the loaded clock is below this % of max boost
# BIOS/firmware advisory (#78): board/BIOS identity + SMT state (both world-readable from sysfs).
DMI_DIR="${DMI_DIR:-/sys/class/dmi/id}"
SMT_CONTROL="${SMT_CONTROL:-/sys/devices/system/cpu/smt/control}"

# systemd service name for the worker.
SERVICE_NAME="${SERVICE_NAME:-xmrig}"

# Detect whether we're being sourced (e.g. by the test suite). When sourced we only define
# functions/constants and skip running main, so functions can be exercised in isolation.
_RIGFORGE_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then _RIGFORGE_SOURCED=1; fi

# Report which step failed on an unexpected error (skip when sourced by the test suite).
[ "$_RIGFORGE_SOURCED" = "0" ] && trap on_err ERR

# --- Helpers: idempotent edits, build math & GRUB cmdline ---

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

# --- Setup: prerequisites & configuration ---

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
                # This is often the FIRST apt call on a fresh boot, so carry the same DPkg::Lock::Timeout
                # as install_dependencies (#74) — otherwise an unattended-upgrades lock fails it outright.
                sudo apt-get update -qq -o DPkg::Lock::Timeout=300 &&
                    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=300 jq
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
        # `|| true`: on a non-interactive stdin (EOF) `read` returns non-zero, which would abort the run
        # via the ERR trap; instead fall through to the clear "configuration required" error below.
        read -r -p "Create a minimal configuration now? (y/N): " CREATE_CONF || true
        if [[ "$CREATE_CONF" =~ ^[Yy] ]]; then
            log "Starting interactive setup..."

            # We only need the pool URL — every other key has a sensible default (see
            # config.advanced.example.json for the full list). The URL is host:port (Pithead's proxy
            # listens on 3333).
            read -r -p "Enter your pool URL (host:port, e.g. your-stack:3333): " IN_URL || true

            if [ -z "$IN_URL" ]; then
                error "A pool URL is required. Aborting."
            fi
            if ! [[ "$IN_URL" =~ :[0-9]+$ ]]; then
                error "Pool URL must include a port, e.g. $IN_URL:3333. Aborting."
            fi

            # Minimal config: just the native pools array. jq writes it so the URL is safely quoted.
            jq -n --arg url "$IN_URL" '{pools: [{url: $url}]}' >"$CONFIG_JSON"
            _reown_worker # hand the freshly-created config.json to the operator, even if setup later fails
            log "Created $CONFIG_JSON successfully."
        else
            error "Configuration file required to proceed."
        fi
    fi
}

parse_config() {
    log "Parsing configuration..."
    # A missing config (e.g. `apply`/`tune` before `setup`) is a different, clearer error than bad JSON.
    if [ ! -f "$CONFIG_JSON" ]; then
        error "No configuration at $CONFIG_JSON — run 'sudo $0 setup' first (it creates one on first run)."
    fi
    if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
        error "$CONFIG_JSON is not valid JSON."
    fi

    # HOME_DIR becomes a filesystem path we mkdir/cd/write under (with sudo), so validate it via the
    # shared resolver (the same one the privileged uninstall/backup/restore use, so none of them can act
    # on an unvalidated path).
    RAW_HOME=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON")
    if ! WORKER_ROOT=$(_worker_root_for_home "$RAW_HOME"); then
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

    # Opt-in periodic live auto-tuning (#46, #95): tri-state. "disabled" (default) installs no timer;
    # "performance" schedules a periodic tune for raw H/s; "efficiency" schedules one for hashrate-per-watt.
    # Legacy booleans still parse (true -> performance, false -> disabled); a typo hard-errors rather than
    # silently disabling tuning. AUTOTUNE_TARGET (perf|efficiency) is what autotune() and the unit consume.
    _at=$(jq -r '.autotune // "disabled"' "$CONFIG_JSON")
    case "$_at" in
    disabled | false | off | none | null | "") AUTOTUNE_MODE=disabled ;;
    performance | perf | true | on) AUTOTUNE_MODE=performance ;;
    efficiency | eff) AUTOTUNE_MODE=efficiency ;;
    *) error "Invalid \"autotune\" value '$_at' in config.json — use \"disabled\", \"performance\", or \"efficiency\"." ;;
    esac
    case "$AUTOTUNE_MODE" in efficiency) AUTOTUNE_TARGET=efficiency ;; *) AUTOTUNE_TARGET=perf ;; esac

    # Opt-in: install a `rigforge` command on PATH (a symlink in BIN_DIR). Off by default — setup makes
    # no system-wide convenience change you didn't ask for.
    ADD_TO_PATH=$(jq -r '.add_to_path // false' "$CONFIG_JSON")
}

# --- Setup: workspace & dependency install ---

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
                # msr-tools (rdmsr): lets `doctor` verify the prefetcher MSR mod actually applied (#66).
                dependencies="$dependencies linux-tools-common msr-tools"
                if apt-cache show "linux-tools-$(uname -r)" &>/dev/null; then
                    dependencies="$dependencies linux-tools-$(uname -r)"
                fi
            fi
            # DPkg::Lock::Timeout waits for the apt/dpkg lock instead of failing — fresh boots often have
            # unattended-upgrades holding it for a minute or two (#74).
            install_cmd="sudo apt-get update -qq -o DPkg::Lock::Timeout=300 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=300 -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
            check_cmd="dpkg -s"
        elif command -v dnf &>/dev/null; then
            dependencies="git cmake libuv-devel openssl-devel hwloc-devel gettext gcc gcc-c++ make automake kernel-devel msr-tools"
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

        # $dependencies are PACKAGE names (build-essential, libuv1-dev, gettext-base — most have no
        # same-named binary), so the package manager is the authority for "is it installed", not
        # `command -v` (which would both miss header-only -dev packages and let an unrelated PATH binary
        # mask a genuinely-absent package). Query $check_cmd only.
        local missing_deps=""
        for dep in $dependencies; do
            if ! $check_cmd "$dep" &>/dev/null; then
                missing_deps="$missing_deps $dep"
            fi
        done

        if [ -n "$missing_deps" ]; then
            # `setup` is an automated provisioner (often run headless / over the release e2e), so install
            # the build dependencies non-interactively rather than prompting — an interactive `read` here
            # hit EOF and aborted the whole run under `set -e` on a non-tty stdin (#74).
            log "Installing required system dependencies:"
            echo -e "  ${C_YELLOW}$missing_deps${C_RESET}"
            eval "$install_cmd $missing_deps"
        else
            log "All system dependencies are already installed."
        fi
    fi
}

# --- Setup: build XMRig from source ---

compile_xmrig() {
    if [ "$XMRIG_REBUILD" != true ]; then
        log "XMRig $XMRIG_VERSION (commit ${XMRIG_COMMIT:0:12}) already built — skipping clone/compile."
        return 0
    fi
    log "Cloning and patching XMRig source code ($XMRIG_VERSION)..."
    # Remove any partial/stale clone an interrupted or commit-mismatched prior run left behind — otherwise
    # `git clone` aborts with "destination path 'xmrig' already exists and is not empty".
    rm -rf xmrig
    git clone --quiet --branch "$XMRIG_VERSION" --depth 1 https://github.com/xmrig/xmrig.git

    # Verify we built the exact commit we pinned (supply-chain hardening). On a mismatch, drop the clone so
    # the next run starts clean rather than tripping the not-empty error above.
    actual="$(git -C xmrig rev-parse HEAD)"
    [ "$actual" = "$XMRIG_COMMIT" ] || {
        rm -rf xmrig
        error "XMRig commit mismatch: expected $XMRIG_COMMIT, got $actual"
    }
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

# --- Setup: XMRig config generation (CPU / NUMA / MSR layout) ---

generate_xmrig_config() {
    log "Generating hardware-optimized XMRig configuration..."

    # Identify CPU Topology
    if [ "$OS_TYPE" == "Darwin" ]; then
        CPU_MODEL=$(sysctl -n machdep.cpu.brand_string)
    else
        # Anchor to "^Model name:" — as root, lscpu also prints a "BIOS Model name:" line (a DMI string
        # like "...  Unknown CPU @ 4.2GHz"), and an unanchored grep would concatenate both into one line.
        CPU_MODEL=$(lscpu | grep -E '^Model name:' | cut -d':' -f2 | xargs)
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
        create 0644 $REAL_USER $REAL_USER
    }
EOF
    fi
}

# --- Setup: service, kernel tuning & deployment ---

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

        if [ "$REBOOT_REQUIRED" = true ]; then
            # HugePages aren't reserved until the GRUB change takes effect on reboot — starting the miner
            # now would run it DEGRADED (no huge-page backing, Restart=always churn) until then. So only
            # enable it; it starts automatically after the reboot. (#audit A2)
            log "Service enabled — it will start automatically after you reboot."
        elif [ "$XMRIG_REBUILD" = true ]; then
            # Restart only when the binary was rebuilt; otherwise just ensure it's running (a running
            # service is left undisturbed on a no-op re-run).
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
    if [ "${AUTOTUNE_MODE:-disabled}" = "disabled" ]; then
        if [ -f "$tmr" ]; then
            sudo systemctl disable --now rigforge-autotune.timer 2>/dev/null || true
            sudo rm -f "$svc" "$tmr"
            sudo systemctl daemon-reload 2>/dev/null || true
            log "Periodic autotune disabled."
        fi
        return 0
    fi
    log "Enabling periodic autotune: $(_autotune_desc "$AUTOTUNE_MODE"), runs ${AUTOTUNE_ONCALENDAR:-monthly}..."
    # Render the unit templates from systemd/ (kept alongside xmrig.service.template, not inline). The
    # service bakes in RIGFORGE_OPERATOR=$REAL_USER so the root timer hands files back to the operator,
    # and AUTOTUNE_TARGET (#95) so the scheduled run optimizes for the target the operator chose.
    SERVICE_NAME="$SERVICE_NAME" RIGFORGE_OPERATOR="$REAL_USER" SCRIPT_DIR="$SCRIPT_DIR" AUTOTUNE_TARGET="${AUTOTUNE_TARGET:-perf}" \
        envsubst '$SERVICE_NAME $RIGFORGE_OPERATOR $SCRIPT_DIR $AUTOTUNE_TARGET' \
        <"$SCRIPT_DIR/systemd/rigforge-autotune.service.template" | sudo tee "$svc" >/dev/null
    AUTOTUNE_ONCALENDAR="${AUTOTUNE_ONCALENDAR:-monthly}" \
        envsubst '$AUTOTUNE_ONCALENDAR' \
        <"$SCRIPT_DIR/systemd/rigforge-autotune.timer.template" | sudo tee "$tmr" >/dev/null
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

    # #65: size the HugePages reservation for the thread count we'll actually run — the tuned cpu.rx if
    # `tune` pinned one (so setup + tune stay consistent), or an explicit RIGFORGE_THREADS override (the
    # documented resize-then-re-tune path). Empty => proposed-grub.sh falls back to its L3 estimate.
    RX_SETUP_THREADS=""
    if [ -n "${RIGFORGE_THREADS:-}" ]; then
        RX_SETUP_THREADS="$RIGFORGE_THREADS"
    elif [ -f "$WORKER_ROOT/tune-overrides.json" ]; then
        RX_SETUP_THREADS=$(jq -r '.cpu.rx // empty' "$WORKER_ROOT/tune-overrides.json" 2>/dev/null) || RX_SETUP_THREADS=""
    fi
    case "$RX_SETUP_THREADS" in -1 | '' | *[!0-9]*) RX_SETUP_THREADS="" ;; esac
    [ -n "$RX_SETUP_THREADS" ] && log "Sizing the HugePages reservation for $RX_SETUP_THREADS mining thread(s) (#65)."

    log "Applying runtime memory tuning..."
    if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ]; then
        # Calculate exact requirement based on hardware, the tuned thread count, and 1GB page status
        REQUIRED_PAGES=$(RX_THREADS="$RX_SETUP_THREADS" "$SCRIPT_DIR/util/proposed-grub.sh" --runtime)
        log "Hardware-optimized HugePages: $REQUIRED_PAGES (2MB pages) calculated."
        sudo sysctl -w vm.nr_hugepages="$REQUIRED_PAGES"
    else
        # Fallback when proposed-grub.sh is missing: 3072 × 2MB = 6 GB of huge pages — enough for the
        # ~2.3 GB RandomX dataset plus per-thread scratchpads on a large desktop/server, without over-
        # reserving on smaller hosts. proposed-grub.sh computes an exact, hardware-sized value instead.
        warn "Utility script not found. Fallback to safe default (3072)."
        sudo sysctl -w vm.nr_hugepages=3072
    fi

    log "Configuring bootloader (GRUB) for persistent HugePages..."
    if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ] && [ -f "$GRUB_DEFAULT" ]; then
        # proposed-grub.sh prints a generic "quiet splash" prefix plus the HugePage/MSR params we
        # manage. Keep only the params we manage and MERGE them into the existing cmdline so we don't
        # clobber other kernel parameters the user/distro set (#19 — boot-safety).
        MANAGED=$(RX_THREADS="$RX_SETUP_THREADS" "$SCRIPT_DIR/util/proposed-grub.sh" -q)
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

# Put a `rigforge` command on PATH: a symlink in BIN_DIR pointing at this script, so the operator can
# run `sudo rigforge <cmd>` from anywhere instead of `./rigforge.sh`. OPT-IN via `add_to_path` in
# config.json (off by default). Best-effort and idempotent — it never fails the deploy. `uninstall`
# removes it regardless, but only while it's still our symlink.
link_cli() {
    [ "${ADD_TO_PATH:-false}" = "true" ] || return 0
    local target="$SCRIPT_DIR/rigforge.sh" link="$BIN_DIR/rigforge" ok=1
    if [ ! -d "$BIN_DIR" ]; then
        warn "Skipped the 'rigforge' command — $BIN_DIR doesn't exist. Run it as './rigforge.sh' instead."
        return 0
    fi
    if [ -L "$link" ] && [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; then
        return 0 # already our symlink — keep idempotent re-runs quiet
    fi
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        warn "Didn't add the 'rigforge' command — $link already exists and isn't a RigForge symlink."
        return 0
    fi
    # Use sudo only when BIN_DIR isn't writable (it is when setup runs as root on Linux); empty prefix
    # otherwise. shellcheck SC2086: the unquoted prefix is intentional (it must vanish when empty).
    local sudo_pfx=""
    [ -w "$BIN_DIR" ] || sudo_pfx="sudo"
    # shellcheck disable=SC2086
    $sudo_pfx rm -f "$link" 2>/dev/null && $sudo_pfx ln -s "$target" "$link" 2>/dev/null || ok=0
    if [ "$ok" = 1 ]; then
        log "Installed the 'rigforge' command -> $link (try: 'sudo rigforge doctor' from anywhere)."
    else
        warn "Couldn't add the 'rigforge' command at $link (permissions?). Run it as './rigforge.sh' instead."
    fi
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
        if [ "$REBOOT_REQUIRED" = true ]; then
            log "Service enabled — it starts automatically after the reboot above (then: $0 status / logs)."
        else
            log "Service created. xmrig running in background (check: $0 status / logs)."
        fi
    else
        log "Start the miner with:"
        echo "  $0 start          # then: $0 status / logs / stop"
    fi
}

# --- Orchestration: main (setup) ---

# Decide whether the pinned XMRig needs (re)building. Call after parse_config (needs WORKER_ROOT).
decide_rebuild() {
    if xmrig_already_built; then
        XMRIG_REBUILD=false
        log "XMRig $XMRIG_VERSION already built at the pinned commit — recompile will be skipped."
    else
        XMRIG_REBUILD=true
    fi
}

# Re-own everything written as root back to the invoking operator. setup/upgrade/tune/apply/restore write
# files under WORKER_ROOT as root (the XMRig build, the generated config, logs, tune-overrides), and the
# first-run config.json is created as root under `sudo` — leaving a tree the operator can't edit, re-run
# `setup` over without sudo, or `git clean`. Reconcile ownership once at the end of each such command,
# rather than chmod-ing every individual `sudo cp`/`tee`. No-op unless we're root on Linux/macOS.
_reown_worker() {
    [ "$(id -u)" -eq 0 ] || return 0
    local owner
    case "$OS_TYPE" in
    Linux) owner="$REAL_USER:$REAL_USER" ;;
    Darwin) owner="$REAL_USER" ;;
    *) return 0 ;;
    esac
    if [ -n "${WORKER_ROOT:-}" ] && [ -e "$WORKER_ROOT" ]; then sudo chown -R "$owner" "$WORKER_ROOT" 2>/dev/null || true; fi
    if [ -f "$CONFIG_JSON" ]; then sudo chown "$owner" "$CONFIG_JSON" 2>/dev/null || true; fi
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
    CURRENT_STEP="linking the rigforge command"
    link_cli # opt-in (add_to_path): put `rigforge` on PATH so the operator can run it from anywhere
    CURRENT_STEP="reconciling file ownership"
    _reown_worker # hand the build/config/logs back to the operator so they can edit + re-run without sudo
    CURRENT_STEP="finishing up"
    finish_deployment
}

# --- Lifecycle: upgrade & uninstall ---

# Wait until the worker API reports a live (non-zero) hashrate, up to ~90s — used after a restart so a
# freshly-started miner (still allocating the RandomX dataset) is warm before we measure it. True once live.
_wait_miner_live() { # [tries]
    local i hr tries="${1:-30}"
    for i in $(seq 1 "$tries"); do
        hr=$(_read_api_hashrate)
        [ -n "$hr" ] && awk "BEGIN{exit !($hr > 0)}" 2>/dev/null && return 0
        sleep 3
    done
    return 1
}

# After `upgrade` rebuilds XMRig, the fastest knobs can shift between versions — so re-tune the new build
# now if periodic autotune is enabled (the upgrade is the REAL trigger; the monthly timer is just a slow
# safety net). Otherwise point at a manual re-tune, since the carried-over overrides were measured on the
# old build. Extracted from upgrade() so it's unit-testable without the (heavy) rebuild path.
_post_upgrade_retune() {
    if [ "$OS_TYPE" = Linux ] && [ "${AUTOTUNE_MODE:-disabled}" != disabled ] && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log "Re-tuning the new build (autotune: $(_autotune_desc "$AUTOTUNE_MODE")) — knobs can shift between XMRig versions..."
        if _wait_miner_live; then
            autotune || warn "Post-upgrade autotune didn't complete — re-run 'sudo $0 tune --now' once the miner is warm."
        else
            warn "Miner isn't reporting a live hashrate yet — skipping the post-upgrade re-tune. Run 'sudo $0 tune --now' manually, or wait for the scheduled run."
        fi
    elif [ -f "$WORKER_ROOT/tune-overrides.json" ]; then
        warn "Saved tuning (tune-overrides.json) carried over from the previous build. The fastest knobs can shift between XMRig versions — re-run 'sudo $0 tune' (or 'tune --clear' to discard), or enable periodic autotune in config.json."
    fi
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
    _post_upgrade_retune
    _reown_worker
}

# Map a HOME_DIR value to its worker root, validating it first. HOME_DIR becomes a filesystem path we
# mkdir / cd / write / `sudo rm -rf` under, so it must be the sentinel DYNAMIC_HOME (or empty/null) or a
# clean absolute path — no spaces, shell metacharacters, or `..` traversal. Echoes the worker root, or
# returns 1 (invalid) so every consumer fails closed rather than acting on a typo- or attacker-controlled
# path. Shared by parse_config and the privileged uninstall/backup/restore/doctor consumers.
_worker_root_for_home() { # <raw HOME_DIR> -> echoes "<root>", or returns 1 if invalid
    local raw="$1"
    if [ "$raw" = "DYNAMIC_HOME" ] || [ -z "$raw" ] || [ "$raw" = "null" ]; then
        echo "$SCRIPT_DIR/data/worker"
    elif [[ "$raw" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$raw" != *..* ]]; then
        echo "$raw/worker"
    else
        return 1
    fi
}

# Resolve the worker root from config.json the same way parse_config would, but WITHOUT requiring a
# valid/complete config (echoes "" when there's no config). Refuses an invalid HOME_DIR (fails closed)
# so the privileged consumers never act on it. Shared by uninstall/doctor/backup/restore.
_worker_root_from_config() {
    local raw root
    [ -f "$CONFIG_JSON" ] || return 0
    raw=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON" 2>/dev/null)
    if root=$(_worker_root_for_home "$raw"); then
        echo "$root"
    else
        error "Refusing to act on $CONFIG_JSON: HOME_DIR ('$raw') is not a clean absolute path. Fix it first."
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

    # 9. the `rigforge` CLI symlink — only if it's still ours (never touch a file we didn't create)
    if [ -L "$BIN_DIR/rigforge" ] && [ "$(readlink "$BIN_DIR/rigforge" 2>/dev/null)" = "$SCRIPT_DIR/rigforge.sh" ]; then
        sudo rm -f "$BIN_DIR/rigforge"
        log "Removed the 'rigforge' command ($BIN_DIR/rigforge)."
    fi

    log "Uninstall complete. config.json was left in place."
    if [ "$REBOOT_REQUIRED" = true ]; then
        warn "Reboot to fully release the HugePages reserved at boot."
    fi
}

# --- Auto-tuning: memoization, stats & acceptance (#46, #54) ---
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
MEMO_SD_FILE=""       # per-candidate sample stddev, for the variance-aware acceptance gate (#63)
MEMO_THROTTLE_FILE="" # per-candidate throttle flag (1/0), for thermal-throttle rejection (#62)
MEMO_HPW_FILE=""      # per-candidate hashrate-per-watt, for the efficiency optimization target (#79)
RESULTS_FILE=""
TUNE_MODE=""
S_p=""
S_y=""
S_t=""
S_g=""
S_pr=""
S_hj=""             # cpu.huge-pages-jit (off by default; swept only if TUNE_HPJIT lists >1 value)
S_cq=""             # randomx.cache_qos  (off by default; swept only if TUNE_CACHEQOS lists >1 value)
S_wr=""             # randomx.wrmsr      (off by default; swept only if TUNE_WRMSR lists >1 value) (#66)
HILL_BEST=""        # set by _hillclimb (its result is returned via this global, not stdout — see below)
HP_CAP_THREADS=""   # #65: max thread count whose 2MB-page need fits the reservation (empty = check off)
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
# Parallel store for each candidate's sample stddev (kept out of the median memo so its value stays a
# bare number for every existing caller), and the state's memo key (#63).
_memo_sd_get() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$MEMO_SD_FILE" 2>/dev/null; }
_memo_sd_put() { printf '%s\t%s\n' "$1" "$2" >>"$MEMO_SD_FILE"; }
_memo_hpw_get() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$MEMO_HPW_FILE" 2>/dev/null; } # #79
_memo_hpw_put() { printf '%s\t%s\n' "$1" "$2" >>"$MEMO_HPW_FILE"; }
# #79: efficiency mode needs a power source. True if TUNE_POWER_CMD is set or RAPL is readable.
_power_supported() {
    [ -n "${TUNE_POWER_CMD:-}" ] && return 0
    [ -n "$(_rapl_sum energy_uj)" ] && return 0
    return 1
}
_memo_thr_get() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$MEMO_THROTTLE_FILE" 2>/dev/null; } # #62
_memo_thr_put() { printf '%s\t%s\n' "$1" "$2" >>"$MEMO_THROTTLE_FILE"; }
_state_key() { printf '%s|%s|%s|%s|%s|%s|%s|%s' "$S_p" "$S_y" "$S_t" "$S_g" "$S_pr" "$S_hj" "$S_cq" "$S_wr"; }
# Population stddev of the args (0 with fewer than 2).
_stddev() {
    printf '%s\n' "$@" | awk '{ s += $1; ss += $1 * $1; n++ } END { if (n < 2) { print 0; exit } m = s / n; v = ss / n - m * m; if (v < 0) v = 0; printf "%.4f", sqrt(v) }'
}
# Variance-aware acceptance (#63): the candidate wins only if its median beats the best by BOTH the
# TUNE_MIN_DELTA floor AND more than the combined sample-noise band (TUNE_SIGMA × √(sd_cand²+sd_best²)),
# so jitter on noisy hardware can't trigger a phantom adoption. sd is looked up by each combo's memo key.
_accept_better() { # <cand_median> <cand_key> <best_median> <best_key>
    # #62: a throttled candidate's reading is unreliable — never adopt it.
    if [ "$(_memo_thr_get "$2")" = 1 ]; then return 1; fi
    # #79: the efficiency target ranks by hashrate-per-watt instead of raw H/s. The variance band (#63)
    # carries over proportionally — each candidate's relative H/s spread applied to its hs_per_watt. Any
    # pair missing a power reading falls back to the raw-H/s comparison so the search still progresses.
    if [ "${TUNE_TARGET:-perf}" = efficiency ]; then
        local chpw bhpw
        chpw=$(_memo_hpw_get "$2")
        bhpw=$(_memo_hpw_get "$4")
        if [ -n "$chpw" ] && [ -n "$bhpw" ]; then
            awk -v c="$chpw" -v b="$bhpw" -v cm="$1" -v best="$3" -v csd="$(_memo_sd_get "$2")" -v bsd="$(_memo_sd_get "$4")" \
                -v delta="${TUNE_MIN_DELTA:-0.01}" -v sig="${TUNE_SIGMA:-1}" \
                'BEGIN { crel = (cm > 0 ? csd / cm : 0); brel = (best > 0 ? bsd / best : 0); band = sig * sqrt((c * crel) ^ 2 + (b * brel) ^ 2); exit !(c > b * (1 + delta) && (c - b) > band) }'
            return
        fi
    fi
    awk -v cm="$1" -v best="$3" -v csd="$(_memo_sd_get "$2")" -v bsd="$(_memo_sd_get "$4")" \
        -v delta="${TUNE_MIN_DELTA:-0.01}" -v sig="${TUNE_SIGMA:-1}" \
        'BEGIN { band = sig * sqrt(csd * csd + bsd * bsd); exit !(cm > best * (1 + delta) && (cm - best) > band) }'
}

# --- Auto-tuning: power & thermal sensing (#81) ---

# Best-effort temperature (°C) for the hashrate-per-watt view (#54). Defaults to the standard Linux
# thermal zone; TUNE_TEMP_CMD overrides. Read right after the loaded window (the cores are still hot).
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

# Power measurement (#81). hashrate-per-watt only means something if watts are sampled UNDER LOAD and
# averaged across the measurement window — the old code read once AFTER the bench (idle), collapsing the
# metric onto raw H/s. Two sources, both sampled during the load window:
#   - built-in RAPL: the CPU-package energy-counter delta over the window (Linux, root, no config);
#   - TUNE_POWER_CMD: an instantaneous-watts override (IPMI / smart plug / wall AC), polled + averaged.
# hs_per_watt is therefore RELATIVE within one method/machine — RAPL is CPU-package only, a smart plug is
# whole-wall AC — not an absolute or cross-rig figure. See docs/how-it-works.md.

# An instantaneous watts reading from the operator's override (empty if none).
_read_watts_now() {
    [ -n "${TUNE_POWER_CMD:-}" ] && eval "$TUNE_POWER_CMD"
    return 0
}

# Sum a RAPL sysfs metric (energy_uj or max_energy_range_uj) across the PACKAGE domains only — the
# top-level intel-rapl:N zones named "package-*" (AMD Zen + Intel both expose these here). DRAM/core
# subzones (intel-rapl:N:M) and psys are skipped so nothing is double-counted. RAPL_DIR is overridable
# for tests. Empty when RAPL isn't present/readable (needs root) — power then falls back to TUNE_POWER_CMD.
_rapl_sum() { # <energy_uj|max_energy_range_uj>
    [ "$OS_TYPE" = Linux ] || return 0
    local base="${RAPL_DIR:-/sys/class/powercap}" d v sum=0 got=0
    for d in "$base"/intel-rapl:*; do
        [ -r "$d/$1" ] || continue
        case "$(cat "$d/name" 2>/dev/null)" in package-*) ;; *) continue ;; esac
        v=$(cat "$d/$1" 2>/dev/null) || continue
        case "$v" in '' | *[!0-9]*) continue ;; esac
        sum=$((sum + v))
        got=1
    done
    [ "$got" = 1 ] && echo "$sum"
}

# Average watts from a package-energy delta: <e0_uj> <e1_uj> <max_total_uj> <elapsed_s>. Corrects a single
# counter wrap (e1<e0 -> + max). Empty (never errors under set -e) when inputs are missing or elapsed<=0.
# One-line awk so kcov attributes its coverage (a multi-line program in a string reads as uncovered).
_watts_from_energy() {
    awk -v e0="$1" -v e1="$2" -v mx="$3" -v secs="$4" 'BEGIN{if(e0==""||e1==""||secs+0<=0)exit;d=e1-e0;if(d<0&&mx+0>0)d+=mx;if(d<0)exit;printf "%.2f",(d/1e6)/secs}'
}

# Mean of the numeric args (empty if none) — averages instantaneous power samples over the window.
_mean() {
    [ "$#" -gt 0 ] || return 0
    printf '%s\n' "$@" | awk '{ s += $1; n++ } END { if (n > 0) printf "%.2f", s / n }'
}

# Wall-clock seconds with sub-second precision (GNU date) for timing the RAPL energy window (Linux path).
_now_s() { date +%s.%N 2>/dev/null; }

# --- Auto-tuning: config build & H/s measurement ---

# A candidate's knob values as an overrides snippet (the same shape tune writes for the winner).
_tune_knobs_json() { # <prefetch> <yield> <threads> <onegb> <priority> <hpjit> <cacheqos> <wrmsr>
    jq -cn --argjson p "$1" --argjson y "$2" --arg t "$3" --argjson g "$4" --argjson pr "$5" \
        --argjson hj "$6" --argjson cq "$7" --argjson wr "$8" '
        { randomx: { scratchpad_prefetch_mode: $p, "1gb-pages": $g, cache_qos: $cq, wrmsr: $wr },
          cpu: { yield: $y, priority: $pr, "huge-pages-jit": $hj,
                 rx: (if $t == "-1" then -1 else ($t|tonumber) end) } }'
}

# Materialize a full candidate config by merging the knob snippet over the base config.
_tune_config() { # <out> <prefetch> <yield> <threads> <onegb> <priority>
    local out="$1"
    shift
    _tune_knobs_json "$@" | jq -s '.[0] * .[1]' "$TUNE_BASE" - >"$out"
}

# Run `xmrig --bench=<size>` headlessly and echo its full output. XMRig's `--bench` prints the result and
# then waits for Ctrl+C instead of exiting (#75). It block-buffers stdout to a non-TTY, but flushes its
# `--log-file` per line — so we point that at a temp file and poll it for the 'benchmark finished' line
# (which carries the hashrate), then stop xmrig. We also keep stdout (a fake xmrig in the tests writes
# there and exits — process-gone ends the loop too). `http`/`pools`/`log-file`/`background` are stripped
# from the config so xmrig doesn't serve the API, mine, or daemonize. `BENCH_TIMEOUT` bounds a stuck run.
_xmrig_bench() { # <bin> <bench-size> <config|"">
    local bin="$1" size="$2" cfg="${3:-}" bcfg="" tmpcfg="" out logf xpid deadline freqs="" f
    local wsamples="" pe0="" pt0="" pmax="" w # #81: power-window state
    out="$(mktemp 2>/dev/null || echo "/tmp/rf-bo-$$")"
    logf="$(mktemp 2>/dev/null || echo "/tmp/rf-bl-$$")"
    if [ -n "$cfg" ] && [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
        tmpcfg="$(mktemp 2>/dev/null || true)"
        if [ -n "$tmpcfg" ] && jq 'del(.http, .pools, ."log-file", .background)' "$cfg" >"$tmpcfg" 2>/dev/null; then bcfg="$tmpcfg"; fi
    fi
    # shellcheck disable=SC2086 # the :+ expansion is an intentional optional word
    "$bin" --bench="$size" ${bcfg:+--config="$bcfg"} --log-file="$logf" >"$out" 2>&1 &
    xpid=$!
    # #62: when asked, sample the effective CPU clock THROUGHOUT the (sustained) window and keep the min,
    # so the caller can tell a throttled run from a genuinely slow config. One sample up front covers a
    # very short (test) run; the poll loop adds samples across a real ~minutes-long benchmark.
    if [ -n "${BENCH_FREQ_FILE:-}" ]; then
        f=$(_cpu_eff_khz)
        [ -n "$f" ] && freqs="$f"
    fi
    # #81: bracket the same loaded window for power. With TUNE_POWER_CMD we poll instantaneous watts in the
    # loop; otherwise we read the RAPL package energy counter now and at the end and divide by the elapsed
    # time. Averaged into BENCH_WATTS_FILE, so hs_per_watt reflects LOAD power, not the old idle reading.
    if [ -n "${BENCH_WATTS_FILE:-}" ]; then
        if [ -n "${TUNE_POWER_CMD:-}" ]; then
            w=$(_read_watts_now)
            case "$w" in '') ;; *) wsamples="$w" ;; esac
        else
            pe0=$(_rapl_sum energy_uj)
            pt0=$(_now_s)
            pmax=$(_rapl_sum max_energy_range_uj)
        fi
    fi
    deadline=$(($(date +%s) + ${BENCH_TIMEOUT:-1800}))
    while kill -0 "$xpid" 2>/dev/null; do
        grep -qs 'benchmark finished' "$logf" "$out" && break
        [ "$(date +%s)" -ge "$deadline" ] && break
        if [ -n "${BENCH_FREQ_FILE:-}" ]; then
            f=$(_cpu_eff_khz)
            [ -n "$f" ] && freqs="$freqs $f"
        fi
        if [ -n "${BENCH_WATTS_FILE:-}" ] && [ -n "${TUNE_POWER_CMD:-}" ]; then
            w=$(_read_watts_now)
            case "$w" in '') ;; *) wsamples="$wsamples $w" ;; esac
        fi
        sleep 0.2
    done
    # #81: read the end-of-window energy BEFORE killing xmrig (still loaded), then average over the window.
    if [ -n "${BENCH_WATTS_FILE:-}" ]; then
        local pe1="" pt1="" secs="" wout=""
        if [ -n "${TUNE_POWER_CMD:-}" ]; then
            # shellcheck disable=SC2086 # intentional word-split of the sample list
            wout=$(_mean $wsamples)
        elif [ -n "$pe0" ]; then
            pe1=$(_rapl_sum energy_uj)
            pt1=$(_now_s)
            secs=$(awk -v a="$pt0" -v b="$pt1" 'BEGIN { if (a == "" || b == "") exit; printf "%.3f", b - a }')
            wout=$(_watts_from_energy "$pe0" "$pe1" "${pmax:-0}" "$secs")
        fi
        printf '%s' "$wout" >"$BENCH_WATTS_FILE"
    fi
    # `|| true`: xmrig --bench exits ON ITS OWN when the benchmark finishes, so by here it's often already
    # gone — an unguarded kill then returns non-zero and, under set -Eeuo, fires the ERR trap INSIDE this
    # measurement subshell, aborting it before it echoes the result (→ spurious "aborted" spam + a 0 H/s
    # reading). Guarding it keeps the bench result intact whether or not xmrig is still alive.
    kill "$xpid" 2>/dev/null || true
    wait "$xpid" 2>/dev/null || true
    # The MEDIAN clock over the window — robust to the brief low-clock dataset-init phase, which the raw
    # min would mistake for thermal throttling (#62).
    # shellcheck disable=SC2086 # $freqs is an intentional word-split list of samples
    if [ -n "${BENCH_FREQ_FILE:-}" ]; then printf '%s' "$(_median $freqs)" >"$BENCH_FREQ_FILE"; fi
    cat "$logf" "$out" 2>/dev/null
    rm -f "$out" "$logf" "$tmpcfg" 2>/dev/null || true
}

# One offline benchmark of a config file → peak H/s (empty on failure).
_bench_once() {
    local out
    out=$(_xmrig_bench "$TUNE_BIN" "${TUNE_BENCH:-10M}" "$1")
    printf '%s' "$out" | _parse_hashrate
}

# Live measurement (#54): apply a candidate to the RUNNING miner, discard a warmup window, then take a
# few API samples over steady state and return their median. Heavier than --bench (it restarts the
# service per candidate) but reflects real-world conditions. Linux-only; reuses _read_api_hashrate.
_measure_live() { # <prefetch> <yield> <threads> <onegb> <priority> <hpjit> <cacheqos> <wrmsr>
    local tmp
    tmp=$(mktemp)
    _tune_knobs_json "$@" >"$tmp" && sudo cp "$tmp" "$TUNE_OVERRIDES"
    rm -f "$tmp"
    _apply_runtime >/dev/null 2>&1 || true
    sleep "${TUNE_LIVE_WARMUP:-60}"
    local i s samples=() n="${TUNE_LIVE_SAMPLES:-3}"
    # #81: bracket the steady-state window for power — RAPL energy delta over the window, or the mean of
    # instantaneous TUNE_POWER_CMD samples taken alongside the hashrate samples. Written to BENCH_WATTS_FILE.
    local wsamples="" pe0="" pt0="" pmax="" w
    if [ -n "${BENCH_WATTS_FILE:-}" ] && [ -z "${TUNE_POWER_CMD:-}" ]; then
        pe0=$(_rapl_sum energy_uj)
        pt0=$(_now_s)
        pmax=$(_rapl_sum max_energy_range_uj)
    fi
    for i in $(seq 1 "$n"); do
        s=$(_read_api_hashrate)
        [ -n "$s" ] || s=0
        samples+=("$s")
        if [ -n "${BENCH_WATTS_FILE:-}" ] && [ -n "${TUNE_POWER_CMD:-}" ]; then
            w=$(_read_watts_now)
            case "$w" in '') ;; *) wsamples="$wsamples $w" ;; esac
        fi
        [ "$i" -lt "$n" ] && sleep "${TUNE_LIVE_INTERVAL:-30}"
    done
    if [ -n "${BENCH_WATTS_FILE:-}" ]; then
        local pe1="" pt1="" secs="" wout=""
        if [ -n "${TUNE_POWER_CMD:-}" ]; then
            # shellcheck disable=SC2086 # intentional word-split of the sample list
            wout=$(_mean $wsamples)
        elif [ -n "$pe0" ]; then
            pe1=$(_rapl_sum energy_uj)
            pt1=$(_now_s)
            secs=$(awk -v a="$pt0" -v b="$pt1" 'BEGIN { if (a == "" || b == "") exit; printf "%.3f", b - a }')
            wout=$(_watts_from_energy "$pe0" "$pe1" "${pmax:-0}" "$secs")
        fi
        printf '%s' "$wout" >"$BENCH_WATTS_FILE"
    fi
    _median "${samples[@]}"
}

# Measure one candidate (memoized): median over TUNE_ITERS bench runs, or one live window. On a cache
# miss it also records the candidate — samples, median, and any temp/watts — to the results log.
_measure() { # <prefetch> <yield> <threads> <onegb> <priority> <hpjit> <cacheqos> <wrmsr> -> median H/s
    local p="$1" y="$2" t="$3" g="$4" pr="$5" hj="$6" cq="$7" wr="$8" key="$1|$2|$3|$4|$5|$6|$7|$8" cached
    cached=$(_memo_get "$key")
    if [ -n "$cached" ]; then
        printf '%s' "$cached"
        return 0
    fi

    local med samples=() s i cfg minfk="" bf watts="" wsamps=() wv
    if [ "$TUNE_MODE" = live ]; then
        : >"$TUNE_TMP/watts" # #81: _measure_live writes the under-load average watts here
        med=$(BENCH_WATTS_FILE="$TUNE_TMP/watts" _measure_live "$p" "$y" "$t" "$g" "$pr" "$hj" "$cq" "$wr")
        [ -n "$med" ] || med=0
        samples=("$med")
        watts=$(cat "$TUNE_TMP/watts" 2>/dev/null)
    else
        cfg="$TUNE_TMP/cand.json"
        _tune_config "$cfg" "$p" "$y" "$t" "$g" "$pr" "$hj" "$cq" "$wr"
        for i in $(seq 1 "${TUNE_ITERS:-5}"); do
            : >"$TUNE_TMP/freq"  # #62: _xmrig_bench writes the effective clock seen during this run
            : >"$TUNE_TMP/watts" # #81: ... and the average watts under load
            s=$(BENCH_FREQ_FILE="$TUNE_TMP/freq" BENCH_WATTS_FILE="$TUNE_TMP/watts" _bench_once "$cfg")
            [ -n "$s" ] || s=0
            samples+=("$s")
            bf=$(cat "$TUNE_TMP/freq" 2>/dev/null)
            # _median emits a fractional kHz for an even sample count (e.g. 4627500.5); floor it to whole kHz
            # so the integer guard below keeps the reading instead of dropping it — a dropped reading would
            # leave min_freq_mhz null, silently disabling this candidate's #62 throttle check.
            bf=${bf%.*}
            case "$bf" in '' | *[!0-9]*) ;; *) if [ -z "$minfk" ] || [ "$bf" -lt "$minfk" ]; then minfk="$bf"; fi ;; esac
            wv=$(cat "$TUNE_TMP/watts" 2>/dev/null)
            case "$wv" in '' | *[!0-9.]*) ;; *) wsamps+=("$wv") ;; esac
        done
        med=$(_median "${samples[@]}")
        [ -n "$med" ] || med=0
        [ "${#wsamps[@]}" -gt 0 ] && watts=$(_median "${wsamps[@]}") # median load watts across the iters
    fi

    # #62: a candidate whose sustained clock fell below TUNE_MIN_FREQ_MHZ thermally throttled — its number
    # reflects the throttle, not the config, so flag it (logged + memoized) and never adopt it (gate below).
    local throttled=0 minfmhz=""
    if [ -n "$minfk" ] && [ "${TUNE_MIN_FREQ_MHZ:-0}" -gt 0 ] 2>/dev/null; then
        minfmhz=$((minfk / 1000))
        if [ "$minfmhz" -lt "$TUNE_MIN_FREQ_MHZ" ]; then throttled=1; fi
    fi
    if [ "$throttled" = 1 ]; then warn "  tune: candidate throttled to ${minfmhz} MHz (< ${TUNE_MIN_FREQ_MHZ} MHz min) — reading unreliable, skipping it." >&2; fi

    # #65: did this candidate's thread count exceed the HugePages reservation? Recorded per-candidate and
    # summarized at the end of tune. Only meaningful for a concrete count ("-1" lets XMRig auto-size to fit).
    local hpcapped=false
    if [ -n "${HP_CAP_THREADS:-}" ] && [ "$t" != "-1" ] && [ "$t" -gt "$HP_CAP_THREADS" ] 2>/dev/null; then hpcapped=true; fi

    local sd temp
    sd=$(_stddev "${samples[@]}") # sample spread, for the variance-aware acceptance gate (#63)
    # #81: watts is the median UNDER-LOAD reading collected during the window above (no longer a post-bench
    # idle sample), so hs_per_watt below ranks candidates by real load efficiency.
    temp=$(_read_temp)
    jq -cn --argjson p "$p" --argjson y "$y" --arg t "$t" --argjson g "$g" --argjson pr "$pr" \
        --argjson hj "$hj" --argjson cq "$cq" --argjson wr "$wr" --argjson med "$med" --arg samples "${samples[*]}" \
        --arg sd "${sd:-0}" --arg mf "${minfmhz:-}" --argjson thr "$throttled" --arg hpc "$hpcapped" --arg watts "${watts:-}" --arg temp "${temp:-}" '
        { prefetch_mode: $p, yield: $y, threads: ($t|tonumber), "1gb-pages": $g, priority: $pr,
          "huge-pages-jit": $hj, cache_qos: $cq, wrmsr: $wr,
          hashrate: $med, samples: ($samples|split(" ")|map(tonumber)), stddev: ($sd|tonumber),
          min_freq_mhz: (if $mf=="" then null else ($mf|tonumber) end), throttled: ($thr==1),
          hugepages_capped: ($hpc=="true"),
          watts: (if $watts=="" then null else ($watts|tonumber) end),
          temp_c: (if $temp=="" then null else ($temp|tonumber) end),
          hs_per_watt: (if $watts=="" or ($watts|tonumber)==0 then null else ($med/($watts|tonumber)) end) }' \
        >>"$RESULTS_FILE"
    # #79: store hashrate-per-watt for the efficiency-target gate (empty when there's no power reading).
    local hpw
    hpw=$(awk -v m="$med" -v w="${watts:-0}" 'BEGIN{if(w+0>0)printf "%.4f",m/w}')
    _memo_put "$key" "$med"
    _memo_sd_put "$key" "${sd:-0}"
    _memo_thr_put "$key" "$throttled"
    _memo_hpw_put "$key" "$hpw"
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
    wrmsr) echo "$TUNE_WRMSR" ;;
    esac
}
_knob_get() {
    case "$1" in
    prefetch) echo "$S_p" ;; yield) echo "$S_y" ;; threads) echo "$S_t" ;;
    onegb) echo "$S_g" ;; priority) echo "$S_pr" ;;
    hpjit) echo "$S_hj" ;; cacheqos) echo "$S_cq" ;; wrmsr) echo "$S_wr" ;;
    esac
}
_knob_set() {
    case "$1" in
    prefetch) S_p="$2" ;; yield) S_y="$2" ;; threads) S_t="$2" ;;
    onegb) S_g="$2" ;; priority) S_pr="$2" ;;
    hpjit) S_hj="$2" ;; cacheqos) S_cq="$2" ;; wrmsr) S_wr="$2" ;;
    esac
}
_measure_state() { _measure "$S_p" "$S_y" "$S_t" "$S_g" "$S_pr" "$S_hj" "$S_cq" "$S_wr"; }

# #65: HugePages-reservation awareness. A thread candidate that needs more 2MB pages than are reserved
# runs WITHOUT full huge-page backing, so its benchmark is an unfair lower bound. `avail` = the current
# reservation (HugePages_Total); `need` = proposed-grub.sh's page math for a thread count — the SAME
# source of truth `setup` uses, so the two never disagree. Both empty/0 when unavailable (e.g. macOS).
_hugepages_2m_avail() { # echoes the reserved 2MB page count, or nothing (never errors under set -e)
    [ -r "$MEMINFO" ] || return 0
    awk '/^HugePages_Total:/ {print $2; exit}' "$MEMINFO" 2>/dev/null
}
_hugepages_2m_need() { # <threads> -> 2MB pages needed (via proposed-grub.sh), empty if unavailable
    [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ] || return 0
    RX_THREADS="$1" "$SCRIPT_DIR/util/proposed-grub.sh" --runtime 2>/dev/null
}

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
# --- Auto-tuning: search strategies & seeding ---

# beats the running best by TUNE_MIN_DELTA, and repeat rounds until a pass makes no gain (plateau).
# Echoes the best hashrate reached; leaves S_* at the winning combination.
_hillclimb() {
    # Returns its result in the HILL_BEST global and leaves S_* at the winning combination. It must be
    # called DIRECTLY (not via $(...)), because a command-substitution subshell would discard the S_*
    # mutations; the memo and results survive regardless because they are file-backed. Progress is
    # logged to stderr to keep stdout clean.
    local best best_key round=0 improved knob cur best_v best_here best_here_key v cand cand_key
    best=$(_measure_state)
    best_key=$(_state_key) # #63: track each best's memo key so the gate can read its sample spread
    while [ "$round" -lt "${TUNE_MAX_ROUNDS:-3}" ]; do
        round=$((round + 1))
        improved=0
        for knob in $ACTIVE_KNOBS; do
            cur=$(_knob_get "$knob")
            best_v="$cur"
            best_here="$best"
            best_here_key="$best_key"
            for v in $(_knob_values "$knob"); do
                [ "$v" = "$cur" ] && continue
                _knob_set "$knob" "$v"
                cand=$(_measure_state)
                cand_key=$(_state_key) # capture while S_* still holds the candidate
                _knob_set "$knob" "$cur"
                log "    try $knob=$v -> $cand H/s" >&2
                if _accept_better "$cand" "$cand_key" "$best_here" "$best_here_key"; then
                    best_here="$cand"
                    best_v="$v"
                    best_here_key="$cand_key"
                fi
            done
            if [ "$best_v" != "$cur" ]; then
                _knob_set "$knob" "$best_v"
                best="$best_here"
                best_key="$best_here_key"
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
    local vp vy vt vg vpr vhj vcq vwr hr
    for vp in $(_knob_values prefetch); do
        for vy in $(_knob_values yield); do
            for vt in $(_knob_values threads); do
                for vg in $(_knob_values onegb); do
                    for vpr in $(_knob_values priority); do
                        for vhj in $(_knob_values hpjit); do
                            for vcq in $(_knob_values cacheqos); do
                                for vwr in $(_knob_values wrmsr); do
                                    hr=$(_measure "$vp" "$vy" "$vt" "$vg" "$vpr" "$vhj" "$vcq" "$vwr")
                                    log "    grid prefetch=$vp yield=$vy threads=$vt 1gb=$vg prio=$vpr hpjit=$vhj cacheqos=$vcq wrmsr=$vwr -> $hr H/s" >&2
                                    if [ "$G_best" = "-1" ] || _accept_better "$hr" "$vp|$vy|$vt|$vg|$vpr|$vhj|$vcq|$vwr" "$G_best" "$G_best_key"; then
                                        G_best="$hr"
                                        G_best_key="$vp|$vy|$vt|$vg|$vpr|$vhj|$vcq|$vwr"
                                        G_p="$vp"
                                        G_y="$vy"
                                        G_t="$vt"
                                        G_g="$vg"
                                        G_pr="$vpr"
                                        G_hj="$vhj"
                                        G_cq="$vcq"
                                        G_wr="$vwr"
                                    fi
                                done
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
_seed_g() { jq -r '.randomx."1gb-pages" // true' "$TUNE_BASE"; } # base 1gb-pages value (default true)
# wrmsr seed: the base config's value as a single token (true/false/number). An array (advanced custom
# MSRs) isn't a sweepable scalar, so seed from the safe default 'true' and let the operator set TUNE_WRMSR.
_seed_wr() { jq -r '(.randomx.wrmsr // true) | if (type=="boolean" or type=="number") then tostring else "true" end' "$TUNE_BASE"; }

# Seed the state with XMRig's auto baseline (the generated config's own values; threads left to auto).
_seed_auto() {
    S_p=$(jq -r '.randomx.scratchpad_prefetch_mode // 1' "$TUNE_BASE")
    S_y=$(jq -r '.cpu.yield // false' "$TUNE_BASE")
    S_g=$(_seed_g)
    S_pr=$(jq -r '.cpu.priority // 2' "$TUNE_BASE")
    S_t="-1"
    S_hj=$(_seed_hj)
    S_cq=$(_seed_cq)
    S_wr=$(_seed_wr)
}
# Seed the state with an educated guess (a different starting point so the climb can escape a local
# optimum the auto seed lands in): prefetch=2, yield off, threads sized to L3/2 MB.
_seed_guess() {
    S_p="${TUNE_GUESS_PREFETCH:-2}"
    S_y=false
    S_pr=2
    S_g=$(_seed_g)
    S_t="${TUNE_GUESS_THREADS:-${THREAD_CENTER:--1}}"
    [ -n "$S_t" ] || S_t="-1"
    S_hj=$(_seed_hj)
    S_cq=$(_seed_cq)
    S_wr=$(_seed_wr)
}

# --- Auto-tuning: 'tune' command + live confirm / scheduled autotune ---

# User-facing description of a periodic-autotune target, in the SAME vocabulary the operator types in
# config.json ("performance"/"efficiency"/"disabled"). Accepts either the config mode or the internal
# target (perf -> performance), so every autotune surface — setup, apply, tune --history, the run log —
# speaks one consistent language (the offline `tune` command keeps its own "perf"/"--perf" vocabulary).
_autotune_desc() {
    case "$1" in
    efficiency) printf 'efficiency (hashrate-per-watt)' ;;
    disabled) printf 'disabled' ;;
    *) printf 'performance (raw hashrate)' ;;
    esac
}

# `tune --history`: a readable summary of this rig's tuning — what knobs are applied now, the last full
# `tune` run, and (Linux) the periodic autotune timer's recent decisions. Read-only and best-effort:
# every probe is guarded so it never aborts, and it degrades gracefully when nothing's been tuned yet.
_tune_history() { # <overrides_file> <log_file>
    local ovr="$1" logf="$2" when target best n recent sched next tgt has_log=0
    # Read the last full run's summary up front (the best hashrate goes with the winning knobs).
    if [ -s "$logf" ] && jq -e . "$logf" >/dev/null 2>&1; then
        has_log=1
        if [ "$OS_TYPE" = Darwin ]; then when=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$logf" 2>/dev/null || echo "?"); else when=$(date -r "$logf" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?"); fi
        target=$(jq -r '.target // "perf"' "$logf" 2>/dev/null || echo perf)
        best=$(jq -r '.best.hashrate // empty' "$logf" 2>/dev/null || true)
        n=$(jq -r '.results | length' "$logf" 2>/dev/null || echo 0)
    fi
    log "Tuning status for this rig"
    echo ""
    if [ -s "$ovr" ] && jq -e . "$ovr" >/dev/null 2>&1; then
        echo "  Winning tune options (applied — $ovr):"
        jq -r '[(.randomx.scratchpad_prefetch_mode|select(.!=null)|"prefetch_mode=\(.)"),(.cpu.rx|select(.!=null)|"threads=\(.)"),(.cpu.yield|select(.!=null)|"yield=\(.)"),(.randomx."1gb-pages"|select(.!=null)|"1gb-pages=\(.)"),(.cpu.priority|select(.!=null)|"priority=\(.)"),(.cpu."huge-pages-jit"|select(.!=null)|"huge-pages-jit=\(.)"),(.randomx.cache_qos|select(.!=null)|"cache_qos=\(.)"),(.randomx.wrmsr|select(.!=null)|"wrmsr=\(.)")]|.[]|"    • "+.' "$ovr" 2>/dev/null || true
        echo "    -> merged into the generated config; the miner is using these now."
    else
        echo "  Winning tune options: none yet — running XMRig's auto defaults."
        echo "    Run 'sudo $0 tune' to measure the fastest knobs for this CPU."
    fi
    echo ""
    if [ "$has_log" = 1 ]; then
        echo "  Last full tune ($when): target=${target:-perf}, ${n:-0} candidate(s) tried${best:+, best $best H/s}"
        echo "    full search log: $logf"
    else
        echo "  Last full tune: none recorded yet."
    fi
    echo ""
    if [ "$OS_TYPE" = Linux ] && command -v systemctl >/dev/null 2>&1 && systemctl cat rigforge-autotune.timer >/dev/null 2>&1; then
        echo "  Periodic autotune: enabled ($(systemctl is-active rigforge-autotune.timer 2>/dev/null || echo unknown))."
        tgt=$(systemctl cat rigforge-autotune.service 2>/dev/null | sed -nE 's/^Environment=AUTOTUNE_TARGET=//p' | head -1)
        [ -n "$tgt" ] && echo "    optimizing for: $(_autotune_desc "$tgt")"
        sched=$(systemctl cat rigforge-autotune.timer 2>/dev/null | sed -nE 's/^OnCalendar=//p' | head -1)
        next=$(systemctl show rigforge-autotune.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
        [ -n "$sched" ] && echo "    schedule: $sched${next:+ — next run: $next}"
        recent=$(journalctl -u rigforge-autotune.service --no-pager -o cat -n 500 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' | grep -aE 'autotune: (prefetch_mode=|best |no mode|could not)' | sed -E 's/^\[(INFO|WARN)\] autotune: //' | tail -5 || true)
        if [ -n "$recent" ]; then
            echo "    recent decisions:"
            printf '%s\n' "$recent" | sed 's/^/      /'
        else
            echo "    no runs logged yet — it fires on the schedule above."
        fi
        echo "    full log: journalctl -u rigforge-autotune"
    else
        echo "  Periodic autotune: off. Set \"autotune\": \"performance\" (or \"efficiency\") in config.json, then re-run 'sudo $0 setup' to enable it."
    fi
}

# Whether `tune` should re-exec itself under sudo: non-root + interactive (TTY) only, so sudo can actually
# prompt and we never surprise non-interactive callers (tests/cron/pipes). RIGFORGE_FORCE_ELEVATE=1 forces
# it regardless (the coverage test drives this path from a real child process).
_tune_should_elevate() {
    [ "${RIGFORGE_FORCE_ELEVATE:-0}" = 1 ] && return 0
    [ "$(id -u)" -ne 0 ] && [ -t 0 ]
}

tune() {
    # tune mutates system + worker state as root (stops the service, writes tuning as root), so auto-elevate
    # when run without sudo — a plain `rigforge tune` then just works (sudo prompts) instead of failing
    # partway with a cryptic error. Interactive-only (_tune_can_elevate): it keeps non-interactive callers
    # (the test suite, cron, pipes) on their existing path — no surprise elevation, and no re-exec loop if
    # `sudo` is a passthrough stub. `--history` is read-only, so it never needs root.
    local _hist=0 clear=0 target_set=0 now=0
    case " $* " in *" --history "*) _hist=1 ;; esac
    if [ "$_hist" = 0 ] && [ "$OS_TYPE" = Linux ] && _tune_should_elevate; then
        log "tune needs root — re-running with sudo..."
        exec sudo "$0" tune "$@"
    fi
    TUNE_MODE="${TUNE_MODE:-bench}"
    TUNE_CONFIRM="${TUNE_CONFIRM:-0}" # #64: A/B-confirm the winner against the previous config, live
    # #95: the optimization target defaults to the `autotune` config value (resolved by parse_config below);
    # a TUNE_TARGET env override or an explicit --perf/--efficiency flag wins.
    [ -n "${TUNE_TARGET:-}" ] && target_set=1
    while [ $# -gt 0 ]; do
        case "$1" in
        --clear) clear=1 ;;
        --live) TUNE_MODE=live ;;
        --bench) TUNE_MODE=bench ;;
        --confirm) TUNE_CONFIRM=1 ;;
        --efficiency)
            TUNE_TARGET=efficiency
            target_set=1
            ;; # #79: optimize hashrate-per-watt
        --perf)
            TUNE_TARGET=perf
            target_set=1
            ;;
        --now) now=1 ;;              # quick on-demand live re-tune (the 'autotune' engine, under 'tune')
        --history) TUNE_HISTORY=1 ;; # show current tuning + last run + auto-tune decisions, then exit
        *) error "Unknown tune option: $1 (use --now, --live, --bench, --confirm, --efficiency, --perf, --history, or --clear)." ;;
        esac
        shift
    done

    # 'tune --now' is the on-demand live re-tune: a quick convergent pass against the *running* miner
    # (it IS the 'autotune' engine). Exposing it under 'tune' gives one mental model — all manual tuning
    # lives under 'tune' — and reserves the word "autotune" for the scheduled feature (config key + timer).
    # Nothing is lost: the 'autotune' verb still works as an alias, and is the verb the timer runs.
    if [ "$now" = 1 ]; then
        [ "$OS_TYPE" = Linux ] || error "tune --now runs a live re-tune against the systemd service and is Linux-only."
        [ "$target_set" = 1 ] && AUTOTUNE_TARGET="$TUNE_TARGET" # honor --perf/--efficiency for this run
        autotune
        return
    fi

    parse_config # resolves WORKER_ROOT (and validates the config)
    # #95: default the target to what `autotune` is set to in config, unless the user was explicit above.
    [ "$target_set" = 1 ] || TUNE_TARGET="${AUTOTUNE_TARGET:-perf}"
    TUNE_OVERRIDES="$WORKER_ROOT/tune-overrides.json"
    local logf="$WORKER_ROOT/rigforge-tune.json"
    local pre_overrides="" # #64: the overrides in place BEFORE this run, to A/B against and revert to
    [ -f "$TUNE_OVERRIDES" ] && pre_overrides=$(cat "$TUNE_OVERRIDES" 2>/dev/null)

    if [ "${TUNE_HISTORY:-0}" = 1 ]; then
        _tune_history "$TUNE_OVERRIDES" "$logf" # read-only; works without a built worker
        return 0
    fi

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
    TUNE_ITERS="${TUNE_ITERS:-5}"            # median of 5 short benches: steadier than 3 against RandomX jitter (#3)
    TUNE_MIN_DELTA="${TUNE_MIN_DELTA:-0.01}" # minimum relative win (floor)
    TUNE_SIGMA="${TUNE_SIGMA:-1}"            # #63: also require the win to exceed this × the combined sample noise band
    # #79: efficiency mode ranks by hashrate-per-watt, which needs a power source. Without RAPL or
    # TUNE_POWER_CMD, fall back to perf rather than "optimizing" on a metric we can't measure.
    if [ "$TUNE_TARGET" = efficiency ] && ! _power_supported; then
        warn "tune --efficiency needs a power source (built-in RAPL or TUNE_POWER_CMD) — none available; optimizing for raw hashrate (perf) instead."
        TUNE_TARGET=perf
    fi
    local tgt_src=""
    [ "$target_set" = 1 ] || tgt_src=" (from your autotune config; override with --perf/--efficiency)"
    log "Optimization target: $(_autotune_desc "$TUNE_TARGET")${tgt_src}."
    # #62: a candidate whose effective clock dipped below this during its window thermally throttled and is
    # skipped. Default ~80% of max boost (all-core RandomX should hold well above that); 0 disables it.
    if [ -z "${TUNE_MIN_FREQ_MHZ:-}" ]; then
        local _maxk=""
        if [ -r "$CPUFREQ_MAX" ]; then _maxk=$(cat "$CPUFREQ_MAX" 2>/dev/null) || _maxk=""; fi
        if [ -n "$_maxk" ] && [ "$_maxk" -gt 0 ] 2>/dev/null; then TUNE_MIN_FREQ_MHZ=$((_maxk * 80 / 100 / 1000)); fi
    fi
    TUNE_MIN_FREQ_MHZ="${TUNE_MIN_FREQ_MHZ:-0}"
    TUNE_MAX_ROUNDS="${TUNE_MAX_ROUNDS:-3}"
    TUNE_SEARCH="${TUNE_SEARCH:-climb}" # climb = hill-climb (fast); grid = exhaustive (robust, slower) (#6)
    TUNE_SEEDS="${TUNE_SEEDS:-auto guess}"
    TUNE_PREFETCH_MODES="${TUNE_PREFETCH_MODES:-0 1 2 3}"
    TUNE_YIELDS="${TUNE_YIELDS:-true false}"
    TUNE_PRIORITIES="${TUNE_PRIORITIES:-2}" # single value => knob off by default
    # Off-by-default knobs (single value => not searched). huge-pages-jit can help some Ryzen but XMRig
    # warns it makes hashrate unstable; cache_qos is an Intel L3-CAT lever. Sweep with e.g.
    # TUNE_HPJIT="false true" (it then gets pinned only if it actually wins).
    TUNE_HPJIT="${TUNE_HPJIT:-$(_seed_hj)}"
    TUNE_CACHEQOS="${TUNE_CACHEQOS:-$(_seed_cq)}"
    # randomx.wrmsr (#66): off by default (single value = base config's). XMRig auto-picks a per-family MSR
    # preset for `true`; sweep alternatives with e.g. TUNE_WRMSR="true false" or a preset number
    # (TUNE_WRMSR="true 1"). Applied at miner start (no reboot), so it's a fair per-bench candidate.
    TUNE_WRMSR="${TUNE_WRMSR:-$(_seed_wr)}"

    # Thread-count knob: candidates around the L3-derived center (none if L3 can't be read, e.g. macOS).
    THREAD_CENTER=$(_l3_thread_center)
    if [ -n "$THREAD_CENTER" ]; then
        TUNE_THREADS="${TUNE_THREADS:-$(_thread_candidates "$THREAD_CENTER")}"
    else
        TUNE_THREADS="${TUNE_THREADS:--1}"
    fi

    # #65: the largest thread count whose 2MB-page need still fits the current reservation. Candidates
    # above it run without full huge-page backing (flagged per-candidate, summarized at the end). Derived
    # from a single need() probe (the per-thread marginal cost is 1 page). Empty disables the check.
    HP_CAP_THREADS=""
    if [ "$OS_TYPE" = Linux ]; then
        local _hpavail _hpneed1
        _hpavail=$(_hugepages_2m_avail) || _hpavail=""
        _hpneed1=$(_hugepages_2m_need 1) || _hpneed1=""
        if [ -n "$_hpavail" ] && [ "$_hpavail" -gt 0 ] 2>/dev/null && [ -n "$_hpneed1" ] && [ "$_hpneed1" -gt 0 ] 2>/dev/null; then
            HP_CAP_THREADS=$((_hpavail - (_hpneed1 - 1)))
            log "HugePages reservation backs up to $HP_CAP_THREADS threads ($_hpavail × 2MB pages reserved)."
        fi
    fi

    # 1gb-pages is reboot-bound (#54): flipping it only matters if the host actually has 1G HugePages
    # reserved (a GRUB change + reboot, done by `setup`). Sweep it only when they're present; otherwise
    # leave it at the base value and say so, rather than benchmarking a no-op.
    local nr=0
    [ -r "$HUGEPAGES_1G_NR" ] && nr=$(cat "$HUGEPAGES_1G_NR" 2>/dev/null || echo 0)
    if [ "${nr:-0}" -gt 0 ] 2>/dev/null; then
        TUNE_ONEGB="${TUNE_ONEGB:-true false}"
    else
        TUNE_ONEGB="$(_seed_g)"
        log "Note: 1G HugePages not reserved — skipping the 1gb-pages knob (it needs a GRUB change + reboot; run 'setup')."
    fi

    # Active knobs = those with more than one candidate value (the rest are fixed, not searched).
    ACTIVE_KNOBS=""
    local k n
    for k in prefetch yield threads onegb priority hpjit cacheqos wrmsr; do
        n=$(_knob_values "$k" | wc -w | tr -d ' ')
        [ "$n" -gt 1 ] && ACTIVE_KNOBS="$ACTIVE_KNOBS $k"
    done

    TUNE_TMP=$(mktemp -d)
    MEMO_FILE="$TUNE_TMP/memo"
    MEMO_SD_FILE="$TUNE_TMP/memo_sd"
    MEMO_THROTTLE_FILE="$TUNE_TMP/memo_throttle"
    MEMO_HPW_FILE="$TUNE_TMP/memo_hpw"
    RESULTS_FILE="$TUNE_TMP/results.jsonl"
    : >"$MEMO_FILE"
    : >"$MEMO_SD_FILE"
    : >"$MEMO_THROTTLE_FILE"
    : >"$MEMO_HPW_FILE"
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

    local G_best="-1" G_best_key="" G_p="" G_y="" G_t="" G_g="" G_pr="" G_hj="" G_cq="" G_wr="" seed seed_hr
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
            if [ "$G_best" = "-1" ] || _accept_better "$seed_hr" "$(_state_key)" "$G_best" "$G_best_key"; then
                G_best="$seed_hr"
                G_best_key="$(_state_key)"
                G_p="$S_p"
                G_y="$S_y"
                G_t="$S_t"
                G_g="$S_g"
                G_pr="$S_pr"
                G_hj="$S_hj"
                G_cq="$S_cq"
                G_wr="$S_wr"
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
    case " $ACTIVE_KNOBS " in *" wrmsr "*) ovr=$(printf '%s' "$ovr" | jq --argjson wr "$G_wr" '.randomx.wrmsr = $wr') ;; esac
    printf '%s\n' "$ovr" >"$TUNE_TMP/ovr.json" && sudo cp "$TUNE_TMP/ovr.json" "$TUNE_OVERRIDES"

    # Assemble the full search log: the winner, the search parameters, and every measured candidate.
    jq -s --argjson p "$G_p" --argjson y "$G_y" --arg t "$G_t" --argjson g "$G_g" --argjson pr "$G_pr" \
        --argjson hj "$G_hj" --argjson cq "$G_cq" --argjson wr "$G_wr" --arg target "$TUNE_TARGET" \
        --argjson hr "$G_best" --arg mode "$TUNE_MODE" --arg search "$TUNE_SEARCH" --arg seeds "$TUNE_SEEDS" \
        --argjson iters "$TUNE_ITERS" --argjson delta "$TUNE_MIN_DELTA" '
        { best: { scratchpad_prefetch_mode: $p, yield: $y, threads: ($t|tonumber), "1gb-pages": $g,
                  priority: $pr, "huge-pages-jit": $hj, cache_qos: $cq, wrmsr: $wr, hashrate: $hr },
          mode: $mode, target: $target, search: $search, seeds: ($seeds|split(" ")), iterations: $iters, min_delta: $delta,
          results: . }' "$RESULTS_FILE" >"$TUNE_TMP/log.json" && sudo cp "$TUNE_TMP/log.json" "$logf"

    local hpw=""
    hpw=$(jq -r '[.results[].hs_per_watt // empty] | if length>0 then max else empty end' "$logf" 2>/dev/null || true)
    rm -rf "$TUNE_TMP"

    log "Best: prefetch_mode=$G_p yield=$G_y threads=$G_t ($G_best H/s). Saved to $TUNE_OVERRIDES (log: $logf)."
    [ -n "$hpw" ] && log "Best efficiency observed: $hpw H/s per watt."
    if [ "$OS_TYPE" = Linux ]; then
        # #65: be honest about reservation-capped optima — any candidate that needed more 2MB HugePages
        # than reserved ran without full backing, so its number is a floor, not a fair comparison.
        local capped=""
        capped=$(jq -r '[.results[]|select(.hugepages_capped==true)|.threads]|unique|sort|map(tostring)|join(", ")' "$logf" 2>/dev/null) || capped=""
        if [ -n "$capped" ]; then
            warn "HugePages-capped: thread counts {$capped} need more 2MB pages than are reserved, so they ran WITHOUT full backing — their hashrate is a floor, not a fair reading. To explore them properly: 'sudo RIGFORGE_THREADS=<n> $0 setup', reboot, then re-tune."
        fi
        if [ "$G_t" != "-1" ]; then
            log "Note: cpu.rx is pinned to $G_t threads. 'setup' now sizes the HugePages reservation to the tuned thread count automatically — re-run 'sudo $0 setup' (reboot) if 'doctor' ever reports HugePages below 100%."
        fi
    fi
    if [ "$TUNE_CONFIRM" = 1 ] && [ "$OS_TYPE" = Linux ]; then
        _tune_confirm_live "$ovr" "$pre_overrides"
    elif [ "$TUNE_MODE" = live ]; then
        _apply_runtime >/dev/null 2>&1 || true
        log "Applied the winning config to the live miner."
    else
        log "Apply it: sudo $0 apply    (reset anytime with: sudo $0 tune --clear)"
        [ "$OS_TYPE" = Linux ] && log "Or confirm it live first: sudo $0 tune --confirm"
    fi
    _reown_worker # the tune-overrides / log were written via sudo — hand them back to the operator
}

# #64: A/B-confirm the tuned winner against the PREVIOUS config on the live miner. bench/grid measure in
# offline --bench conditions, which differ from production — so optionally apply the winner, measure it
# live over a window, then restore the previous config and measure THAT, and keep the winner only if it
# genuinely wins live (else leave the previous config in place). Reuses _sample_api_median + a margin.
_tune_confirm_live() { # <winner_overrides_json> <previous_overrides_json>
    local win_ovr="$1" pre_ovr="$2"
    local n="${TUNE_LIVE_SAMPLES:-3}" iv="${TUNE_LIVE_INTERVAL:-30}" warm="${TUNE_LIVE_WARMUP:-60}"
    local margin="${TUNE_CONFIRM_MARGIN:-${TUNE_MIN_DELTA:-0.01}}" win_hr base_hr
    log "Confirming the tuned config against the previous one on the live miner (A/B)..."
    _apply_runtime >/dev/null 2>&1 || true # the winner is already in TUNE_OVERRIDES from the search
    sleep "$warm"
    win_hr=$(_sample_api_median "$n" "$iv")
    [ -n "$win_hr" ] || win_hr=0
    if [ -n "$pre_ovr" ]; then printf '%s\n' "$pre_ovr" | sudo tee "$TUNE_OVERRIDES" >/dev/null; else sudo rm -f "$TUNE_OVERRIDES"; fi
    _apply_runtime >/dev/null 2>&1 || true
    sleep "$warm"
    base_hr=$(_sample_api_median "$n" "$iv")
    [ -n "$base_hr" ] || base_hr=0
    if awk "BEGIN{exit !($win_hr > $base_hr * (1 + $margin))}"; then
        printf '%s\n' "$win_ovr" | sudo tee "$TUNE_OVERRIDES" >/dev/null
        _apply_runtime >/dev/null 2>&1 || true
        log "Confirmed: the tuned config wins live ($win_hr vs $base_hr H/s) — kept and applied."
    else
        log "Reverted: the tuned config did NOT beat the previous one live ($win_hr vs $base_hr H/s) — restored the previous config."
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

# Sample the live miner for one candidate: median H/s over the window and, for the efficiency target,
# the average package watts over that SAME window — prints "hr<TAB>watts" (watts empty for perf or when
# no power source). RAPL brackets the sampling window; a TUNE_POWER_CMD override is polled once per
# sample and averaged (parity with tune's _measure_live, #81). Perf skips power entirely (no overhead).
_autotune_sample() { # <n> <interval> <target>
    local n="${1:-3}" iv="${2:-10}" target="${3:-perf}" hr watts="" i s out=() polls=() e0 e1 mx t0 t1
    if [ "$target" != efficiency ]; then
        printf '%s\t' "$(_sample_api_median "$n" "$iv")"
        return 0
    fi
    if [ -n "${TUNE_POWER_CMD:-}" ]; then
        for i in $(seq 1 "$n"); do
            s=$(_read_api_hashrate)
            [ -n "$s" ] || s=0
            out+=("$s")
            s=$(_read_watts_now)
            [ -n "$s" ] && polls+=("$s")
            [ "$i" -lt "$n" ] && [ "$iv" -gt 0 ] 2>/dev/null && sleep "$iv"
        done
        hr=$(_median "${out[@]}")
        [ "${#polls[@]}" -gt 0 ] && watts=$(_mean "${polls[@]}")
    else
        e0=$(_rapl_sum energy_uj || true)
        t0=$(_now_s)
        hr=$(_sample_api_median "$n" "$iv")
        if [ -n "$e0" ]; then
            e1=$(_rapl_sum energy_uj || true)
            mx=$(_rapl_sum max_energy_range_uj || true)
            t1=$(_now_s)
            watts=$(_watts_from_energy "$e0" "$e1" "$mx" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", (b - a)}')")
        fi
    fi
    printf '%s\t%s' "${hr:-0}" "$watts"
}
# Score a sample for the active target: efficiency -> hashrate-per-watt (falls back to raw H/s if watts
# are missing so the sweep still progresses); perf -> raw H/s. Drives both ranking and the margin gate.
_autotune_score() { # <target> <hr> <watts>
    if [ "$1" = efficiency ] && [ -n "$3" ] && awk "BEGIN{exit !($3 > 0)}"; then
        awk -v h="$2" -v w="$3" 'BEGIN{printf "%.4f", h / w}'
    else
        printf '%s' "${2:-0}"
    fi
}
# Human-readable sample for the log line: "10700 H/s" or "10700 H/s, 83.10 W, 128.84 H/s/W".
_autotune_fmt() { # <target> <hr> <watts>
    if [ "$1" = efficiency ] && [ -n "$3" ] && awk "BEGIN{exit !($3 > 0)}"; then
        awk -v h="$2" -v w="$3" 'BEGIN{printf "%s H/s, %.2f W, %.2f H/s/W", h, w, h / w}'
    else
        printf '%s H/s' "${2:-0}"
    fi
}

# autotune (#46, #95): ONE convergent live pass against the running miner. It reads the current hashrate
# from the worker's HTTP API (median of a few samples — live numbers are noisy), then sweeps EVERY
# prefetch mode it isn't already on — applying each (MERGED into the overrides file, preserving any
# offline-`tune` knobs), restarting, and measuring over a warmup window — and adopts the best, but only
# if it beats the baseline by a margin (else it keeps the current mode). The target (#95) decides what
# "best" means: "performance" ranks raw H/s; "efficiency" ranks hashrate-per-watt (falling back to perf
# with a warning when no power source exists, like `tune --efficiency`). So a single run converges the
# prefetch knob (~minutes). Once converged it's stable, so re-tuning is event-driven: `upgrade` runs it
# after a rebuild (the fastest knobs can shift between XMRig versions — the real trigger), and a slow
# safety-net timer catches drift. With `autotune: "performance"|"efficiency"` in config.json, setup
# installs that timer (default monthly; AUTOTUNE_ONCALENDAR) with the target baked into the unit. Median +
# margin keep noisy readings from sticking. For a thorough sweep of ALL knobs, run `tune`.
autotune() {
    if [ "$OS_TYPE" != "Linux" ]; then
        error "autotune drives the live systemd service and is only supported on Linux."
    fi
    # The scheduled run gets AUTOTUNE_TARGET from the systemd unit's env (baked at setup); capture it
    # before parse_config re-derives one from config.json so the unit's choice wins. An interactive run
    # (no unit env) falls through to the config value.
    local target_env="${AUTOTUNE_TARGET:-}"
    parse_config
    local overrides="$WORKER_ROOT/tune-overrides.json"
    local n="${AUTOTUNE_SAMPLES:-3}" iv="${AUTOTUNE_INTERVAL:-10}" warm="${AUTOTUNE_WARMUP:-60}"
    local margin="${AUTOTUNE_MARGIN:-0.01}" modes="${AUTOTUNE_MODES:-0 1 2 3}"
    local target="${target_env:-${AUTOTUNE_TARGET:-perf}}"
    local cur base_hr base_w base_score best_mode best_score m hr w sc last_applied s unit

    # #95: efficiency ranks by hashrate-per-watt, which needs a power source; without one, optimize raw
    # H/s instead (same fallback as `tune --efficiency`).
    if [ "$target" = efficiency ] && ! _power_supported; then
        warn "autotune: efficiency target needs a power source (RAPL or TUNE_POWER_CMD) — none available; falling back to performance (raw hashrate) instead."
        target=perf
    fi
    [ "$target" = efficiency ] && unit="H/s/W" || unit="H/s"
    cur=$(jq -r '.randomx.scratchpad_prefetch_mode // 1' "$overrides" 2>/dev/null || echo 1)

    # Baseline = the mode running right now (no restart needed to measure it).
    s=$(_autotune_sample "$n" "$iv" "$target")
    base_hr=${s%%$'\t'*}
    base_w=${s#*$'\t'}
    [ -n "$base_hr" ] && [ "$base_hr" != 0 ] || {
        warn "autotune: could not read a live hashrate from the API — is the miner running? Skipping."
        return 0
    }
    base_score=$(_autotune_score "$target" "$base_hr" "$base_w")
    best_mode="$cur"
    best_score="$base_score"
    last_applied="$cur"
    log "autotune: optimizing for $(_autotune_desc "$target"); live-sweeping prefetch modes [$modes] against the running miner; baseline mode=$cur at $(_autotune_fmt "$target" "$base_hr" "$base_w") (median of $n)."

    # Try every OTHER mode once, live; track the running best by the target's score.
    for m in $modes; do
        [ "$m" = "$cur" ] && continue
        _autotune_set_prefetch "$overrides" "$m"
        _apply_runtime >/dev/null 2>&1 || true
        last_applied="$m"
        sleep "$warm"
        s=$(_autotune_sample "$n" "$iv" "$target")
        hr=${s%%$'\t'*}
        w=${s#*$'\t'}
        [ -n "$hr" ] || hr=0
        sc=$(_autotune_score "$target" "$hr" "$w")
        log "autotune: prefetch_mode=$m measured $(_autotune_fmt "$target" "$hr" "$w")."
        if awk "BEGIN{exit !($sc > $best_score)}"; then
            best_mode="$m"
            best_score="$sc"
        fi
    done

    # Adopt the winner only if it beats the baseline by the margin (noise guard); else keep the current mode.
    if [ "$best_mode" != "$cur" ] && awk "BEGIN{exit !($best_score > $base_score * (1 + $margin))}"; then
        log "autotune: best is prefetch_mode=$best_mode at $best_score $unit (vs $base_score baseline) — applying it."
    else
        best_mode="$cur"
        log "autotune: no mode beat the baseline by the margin — keeping prefetch_mode=$cur ($base_score $unit)."
    fi
    # Leave the chosen mode running (the sweep may have ended on a different one).
    if [ "$last_applied" != "$best_mode" ]; then
        _autotune_set_prefetch "$overrides" "$best_mode"
        _apply_runtime >/dev/null 2>&1 || true
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

# --- Backup / restore ---
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
    WORKER_ROOT="$wr" _reown_worker # restored config.json + tuning were written as root
}

# --- Commands: macOS & systemd service control (#11) ---

# Service-control verbs. On Linux they wrap the systemd unit; on macOS (no systemd) start/stop/restart/
# status/logs manage XMRig directly, so the same commands work on both. `enable`/`disable` install/remove
# a per-user launchd LaunchAgent (macOS's analogue of boot-start — it runs the miner at login). When the
# agent is installed launchd OWNS the miner, so the run verbs delegate to launchctl; otherwise they
# manage an ad-hoc background process tracked by a PID file. (A headless always-on Mac would instead want
# a /Library/LaunchDaemons unit — out of scope for this dev/light-use target.)

# macOS paths/state. Resolved from config.json (no parse_config needed).
_mac_paths() { # sets MAC_WR / MAC_BIN / MAC_CFG / MAC_PID
    MAC_WR=$(_worker_root_from_config)
    MAC_BIN="$MAC_WR/xmrig/build/xmrig"
    MAC_CFG="$MAC_WR/xmrig/build/config.json"
    MAC_PID="$MAC_WR/xmrig.pid"
}
_mac_pid() { # echo the live ad-hoc miner PID (empty if not running)
    local pid
    [ -f "$MAC_PID" ] || return 0
    pid=$(cat "$MAC_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}
_mac_label() { echo "com.rigforge.$SERVICE_NAME"; }
_mac_plist() { echo "${HOME:-/tmp}/Library/LaunchAgents/$(_mac_label).plist"; }
_mac_enabled() { [ -f "$(_mac_plist)" ]; } # the login agent is installed => launchd owns the miner
_mac_agent_pid() { launchctl list "$(_mac_label)" 2>/dev/null | awk -F'= ' '/"PID"/{gsub(/[^0-9]/,"",$2); print $2; exit}'; }

mac_start() {
    _mac_paths
    [ -x "$MAC_BIN" ] || error "No built worker at $MAC_BIN. Run 'setup' first."
    [ -f "$MAC_CFG" ] || error "No generated config at $MAC_CFG. Run 'setup' first."
    if _mac_enabled; then
        launchctl start "$(_mac_label)" 2>/dev/null || true
        log "Started the miner (login agent)."
        return 0
    fi
    local pid
    pid=$(_mac_pid)
    [ -n "$pid" ] && {
        log "Miner already running (pid $pid)."
        return 0
    }
    # Background it from the build dir (XMRig writes its own log-file per the config); record the PID.
    (cd "$MAC_WR/xmrig/build" && {
        nohup "$MAC_BIN" --config="$MAC_CFG" >/dev/null 2>&1 &
        echo $! >"$MAC_PID"
    })
    log "Started the miner (pid $(cat "$MAC_PID" 2>/dev/null)). Follow it with '$0 logs'; stop with '$0 stop'."
}
mac_stop() {
    _mac_paths
    if _mac_enabled; then
        launchctl stop "$(_mac_label)" 2>/dev/null || true
        log "Stopped the miner (login agent). It starts again at login or '$0 start'; remove it with '$0 disable'."
        return 0
    fi
    local pid
    pid=$(_mac_pid)
    [ -n "$pid" ] || {
        log "Miner is not running."
        rm -f "$MAC_PID" 2>/dev/null
        return 0
    }
    kill "$pid" 2>/dev/null || true
    rm -f "$MAC_PID" 2>/dev/null
    log "Stopped the miner (pid $pid)."
}
mac_status() {
    _mac_paths
    if _mac_enabled; then
        local apid
        apid=$(_mac_agent_pid)
        if [ -n "$apid" ]; then log "Miner is running (login agent, pid $apid)."; else log "Miner is enabled (login agent) but not running."; fi
        return 0
    fi
    local pid
    pid=$(_mac_pid)
    if [ -n "$pid" ]; then log "Miner is running (pid $pid)."; else log "Miner is not running."; fi
}
mac_logs() {
    _mac_paths
    local lf="$MAC_WR/xmrig.log"
    [ -f "$lf" ] || error "No log yet at $lf — start the miner first ('$0 start')."
    tail -f "$lf"
}
mac_enable() {
    _mac_paths
    [ -x "$MAC_BIN" ] || error "No built worker at $MAC_BIN. Run 'setup' first."
    [ -f "$MAC_CFG" ] || error "No generated config at $MAC_CFG. Run 'setup' first."
    # Hand ownership to launchd: stop any ad-hoc miner so there's no competing process.
    local pid
    pid=$(_mac_pid)
    [ -n "$pid" ] && {
        kill "$pid" 2>/dev/null || true
        rm -f "$MAC_PID"
    }
    local plist
    plist=$(_mac_plist)
    mkdir -p "$(dirname "$plist")"
    # KeepAlive=SuccessfulExit:false -> launchd restarts the miner if it crashes, but NOT after a clean
    # `stop` (XMRig exits 0 on SIGTERM); RunAtLoad starts it now and at every login.
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$(_mac_label)</string>
    <key>ProgramArguments</key>
    <array>
        <string>$MAC_BIN</string>
        <string>--config=$MAC_CFG</string>
    </array>
    <key>WorkingDirectory</key><string>$MAC_WR/xmrig/build</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>$MAC_WR/xmrig.launchd.log</string>
    <key>StandardErrorPath</key><string>$MAC_WR/xmrig.launchd.log</string>
</dict>
</plist>
PLIST
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load -w "$plist" 2>/dev/null || error "launchctl could not load $plist."
    log "Enabled: the miner starts at login (and is starting now). Manage it with '$0 start/stop/status'; remove with '$0 disable'."
}
mac_disable() {
    local plist
    plist=$(_mac_plist)
    if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        log "Disabled: removed the login agent (miner stopped; won't start at login)."
    else
        log "No login agent is installed."
    fi
}

svc_status() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_status
        return
    }
    # Read-only: `systemctl status` is world-readable, so no sudo (don't prompt for a password to look).
    systemctl status "$SERVICE_NAME" || true # `status` exits non-zero when stopped; not an error
}
svc_logs() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_logs
        return
    }
    # Read-only: the operator who ran setup is in the `adm` group and can follow the service journal
    # without sudo, so don't prompt for a password just to read logs (use `sudo rigforge logs` if a more
    # locked-down account can't read it).
    journalctl -u "$SERVICE_NAME" -f || true # -f exits 130 on Ctrl-C
}
svc_start() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_start
        return
    }
    sudo systemctl start "$SERVICE_NAME" && log "Started $SERVICE_NAME."
}
svc_stop() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_stop
        return
    }
    sudo systemctl stop "$SERVICE_NAME" && log "Stopped $SERVICE_NAME."
}
svc_restart() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_stop
        mac_start
        return
    }
    sudo systemctl restart "$SERVICE_NAME" && log "Restarted $SERVICE_NAME."
}
svc_enable() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_enable
        return
    }
    sudo systemctl enable "$SERVICE_NAME" && log "Enabled $SERVICE_NAME (starts on boot)."
}
svc_disable() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_disable
        return
    }
    sudo systemctl disable "$SERVICE_NAME" && log "Disabled $SERVICE_NAME (won't start on boot)."
}
# --- Commands: version, apply & bench ---

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

# Surface the periodic-autotune target on a top-level `apply` (#95) so the operator can see what the
# scheduled run optimizes for. Linux-only (the timer is Linux-only); tune/autotune invoke apply with output
# redirected, so this only shows on a direct `apply`. Reflects the `autotune` value apply just parsed.
_autotune_apply_notice() {
    [ "$OS_TYPE" = Linux ] || return 0
    log "Periodic autotune: $(_autotune_desc "${AUTOTUNE_MODE:-disabled}")."
}

# The config-regen + restart core of `apply`, WITHOUT touching the autotune timer. Used directly by
# tune/autotune — which call it in a loop and own the timer themselves — so they don't re-render the unit
# on every prefetch trial.
_apply_runtime() {
    parse_config
    local build="$WORKER_ROOT/xmrig/build"
    [ -d "$build" ] || error "No built worker at $build. Run 'setup' first."
    (cd "$build" && generate_xmrig_config)
    if [ "$OS_TYPE" == "Linux" ]; then
        sudo systemctl restart "$SERVICE_NAME" && log "Applied config and restarted $SERVICE_NAME."
    else
        log "Config regenerated. Restart the miner to apply."
    fi
    _reown_worker
}

# apply (#11): re-read config.json and regenerate the live XMRig config, then restart — WITHOUT
# recompiling. The fast path after editing config.json. As the config-change path it also RECONCILES the
# periodic-autotune timer with config (#95) — so changing the `autotune` target and running `apply`
# actually takes effect (not just shows the new value) — then reports the target. install_autotune is the
# autotune analog of restarting the service; its own log is suppressed in favour of the single status line.
apply() {
    _apply_runtime
    if [ "$OS_TYPE" = Linux ]; then
        install_autotune >/dev/null 2>&1 || true
        _autotune_apply_notice
    fi
}

# bench (#11): run a one-off xmrig --bench and report the hashrate. A quick perf/health check.
bench() {
    parse_config
    local bin="$WORKER_ROOT/xmrig/build/xmrig" cfg="$WORKER_ROOT/xmrig/build/config.json"
    [ -x "$bin" ] || error "No built worker at $bin. Run 'setup' first."
    local b="${BENCH:-1M}" out hr
    log "Running 'xmrig --bench=$b' (this can take a minute or two)..."
    out=$(_xmrig_bench "$bin" "$b" "$cfg")             # strips the API/pool/log-file and stops xmrig once done (#75)
    hr=$(printf '%s' "$out" | _parse_hashrate) || true # empty when nothing hashed; handled below
    # A healthy bench must (a) report a hashrate — proving the build ran, the config parsed and the
    # RandomX dataset initialised — and (b) not have hit a fatal allocation/config error (XMRig's
    # "MEMORY ALLOC FAILED" covers a failed dataset / HugePages / memlock allocation). On failure, echo
    # the raw XMRig output so a broken build/config is diagnosable — this is what the release smoke
    # check (tests/smoke.sh, #61) gates on.
    if printf '%s' "$out" | grep -qiE 'MEMORY ALLOC FAILED|unable to (open|parse) config|error parsing config'; then
        printf '%s\n' "$out" >&2
        error "Benchmark hit a fatal memory/config error — see the XMRig output above."
    fi
    if [ -z "$hr" ]; then
        printf '%s\n' "$out" >&2
        error "Could not read a hashrate from the benchmark output — see the XMRig output above."
    fi
    log "Benchmark hashrate: $hr H/s"
}

# doctor (#45): verify the optimizations actually took effect. Read-only and best-effort — it never
# changes the system, just reports PASS/WARN with actionable hints. Linux-only checks.
_ck_ok() { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
_ck_warn() { echo -e "  ${C_YELLOW}!${C_RESET} $1"; }
_ck_info() { echo -e "  ${C_BLUE}∙${C_RESET} $1"; } # neutral context line (#78), not a pass/fail check
# Read a /sys/class/dmi/id field (board/BIOS identity; world-readable). Empty if missing. #78.
_dmi() {
    [ -r "$DMI_DIR/$1" ] || return 0
    tr -d '\n' <"$DMI_DIR/$1" 2>/dev/null
    return 0
}

# #67/#78 helper. _mem_summary parses `dmidecode -t memory` into "<populated-DIMMs> <channels>
# <min configured MT/s> <max rated MT/s>" — channels from the Bank Locator, the configured speed is the
# RUNNING one, the rated speed is the module's SPD/XMP "Speed". #78 compares the two to spot a memory
# profile that isn't enabled. _cpu_eff_khz averages the per-core scaling_cur_freq (clock under load).
_mem_summary() {
    # One-line awk (kcov can't see coverage of a multi-line program inside a string): per Memory Device,
    # count populated DIMMs + distinct channels, and track the min configured (cf) and max rated (rt) speed.
    # Trailing `|| true`: dmidecode needs root, so a non-root `doctor` makes the pipeline non-zero under
    # `set -o pipefail`; without this the command substitution in doctor would trip errexit and abort the
    # whole health check. Always exit 0 — empty/zeroed output (handled as "run as root") instead.
    "$DMIDECODE" -t memory 2>/dev/null | awk 'function flush(){if(sz~/[0-9]+ *[GMgm][Bb]/){pop++;if(ch!="")chans[ch]=1;if(cf+0>0&&(minc==0||cf+0<minc))minc=cf+0;if(rt+0>maxr)maxr=rt+0};sz="";ch="";cf="";rt=""} /^Memory Device/{flush();next} /^[ \t]*Size:/{v=$0;sub(/^[^:]*:[ \t]*/,"",v);sz=v} /Bank Locator:/{v=$0;sub(/^[^:]*:[ \t]*/,"",v);ch=v} /^[ \t]*Speed:/{if(match($0,/[0-9]+/))rt=substr($0,RSTART,RLENGTH)} /Configured Memory Speed:/{if(match($0,/[0-9]+/))cf=substr($0,RSTART,RLENGTH)} END{flush();nc=0;for(c in chans)nc++;printf "%d %d %d %d",pop+0,nc+0,minc+0,maxr+0}' || true
}
_cpu_eff_khz() {
    local f v sum=0 n=0
    for f in "$CPU_SYSFS"/cpu[0-9]*/cpufreq/scaling_cur_freq; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null)
        case "$v" in '' | *[!0-9]*) continue ;; esac
        sum=$((sum + v))
        n=$((n + 1))
    done
    if [ "$n" -gt 0 ]; then echo $((sum / n)); fi # always exit 0 (empty output when no data)
}

# #66 MSR-verification helpers. doctor confirms the prefetcher MSR mod actually took effect — not just
# that the `msr` module loaded — in two layers: XMRig's own log line (always available) and an rdmsr
# read-back (when msr-tools is installed), which catches a write a hypervisor / kernel-lockdown silently
# dropped even though XMRig reported success.

# Parse the worker's xmrig.log for XMRig's MSR-write confirmation. Per (re)start XMRig logs
# 'msr register values for "<preset>" preset have been set successfully' (or a failure). Echoes
# "<ok|fail|none>\t<preset>" for the LAST msr line. One-line awk so kcov attributes it correctly.
_msr_log_status() { # <logfile>
    if [ ! -f "$1" ]; then
        printf 'none\t'
        return 0
    fi
    awk '/msr +register values for/{p="";if(match($0,/"[^"]+"/))p=substr($0,RSTART+1,RLENGTH-2);if(index($0,"set successfully")>0){st="ok";pr=p}else if(index($0,"FAILED")>0||index($0,"failed")>0||index($0,"cannot")>0){st="fail";pr=p}} END{if(st=="")printf "none\t";else printf "%s\t%s",st,pr}' "$1" 2>/dev/null
}

# The (register, value, mask) triples XMRig writes per MSR preset — verified against XMRig v6.26.0
# (src/crypto/rx/RxConfig.cpp). mask "-" means a whole-register (no-mask) write, so the register equals
# the value exactly regardless of firmware; "~0x20" is encoded as ffffffffffffffdf. Only the presets we
# verify on real hardware are listed — for any other preset, doctor relies on XMRig's log confirmation.
_msr_preset_regs() { # <preset> -> lines "reg value mask"
    case "$1" in
    ryzen_19h_zen4 | ryzen_1Ah_zen5)
        printf '%s\n' '0xc0011020 0004400000000000 -' '0xc0011021 0004000000000040 ffffffffffffffdf' \
            '0xc0011022 8680000401570000 -' '0xc001102b 000000002040cc10 -'
        ;;
    ryzen_19h)
        printf '%s\n' '0xc0011020 0004480000000000 -' '0xc0011021 001c000200000040 ffffffffffffffdf' \
            '0xc0011022 c000000401570000 -' '0xc001102b 000000002000cc10 -'
        ;;
    ryzen_17h)
        printf '%s\n' '0xc0011020 0000000000000000 -' '0xc0011021 0000000000000040 ffffffffffffffdf' \
            '0xc0011022 0000000001510000 -' '0xc001102b 000000002000cc16 -'
        ;;
    intel)
        printf '%s\n' '0x1a4 000000000000000f -'
        ;;
    esac
}

# Read each of a preset's registers via rdmsr and check the bits XMRig controls (value & mask) match.
# Sets _MSR_OK / _MSR_TOTAL / _MSR_BAD. Best-effort: needs rdmsr (msr-tools) + the msr module + root.
_msr_rdmsr_verify() { # <preset> -> sets _MSR_OK / _MSR_TOTAL / _MSR_UNREAD / _MSR_BAD
    _MSR_OK=0
    _MSR_TOTAL=0
    _MSR_UNREAD=0 # registers rdmsr couldn't read (not root / module absent) — distinct from a value mismatch
    _MSR_BAD=""
    local reg val mask actual want got regs
    regs=$(_msr_preset_regs "$1")
    [ -n "$regs" ] || return 0
    while read -r reg val mask; do
        [ -n "$reg" ] || continue
        _MSR_TOTAL=$((_MSR_TOTAL + 1))
        [ "$mask" = "-" ] && mask="ffffffffffffffff"
        actual=$("$RDMSR_BIN" -p0 -0 "$reg" 2>/dev/null || true) # guard INSIDE $(): a failing rdmsr mustn't trip the ERR trap
        case "$actual" in '' | *[!0-9A-Fa-f]*)
            _MSR_UNREAD=$((_MSR_UNREAD + 1))
            continue
            ;;
        esac
        # 64-bit masked compare: these constants set bit 63 (e.g. 0x8680…), so they're negative under bash's
        # signed intmax_t arithmetic — but want/got are masked identically, so the bit patterns compare equal.
        want=$((0x$val & 0x$mask))
        got=$((0x$actual & 0x$mask))
        if [ "$got" = "$want" ]; then _MSR_OK=$((_MSR_OK + 1)); else _MSR_BAD="$_MSR_BAD $reg"; fi
    done <<EOF
$regs
EOF
}

# --- Doctor: one-stop health check ---

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

    # Resolve the worker's xmrig.log once — the MSR-applied (#66) and HUGE PAGES checks both read it.
    local wr="" log_file=""
    if [ -f "$CONFIG_JSON" ]; then
        wr=$(_worker_root_from_config)
        log_file="$wr/xmrig.log"
    fi

    # MSR mod applied? (#66) The ~10-15% RandomX gain needs three things, checked in order: the msr
    # module loadable, XMRig's own log line confirming it WROTE the prefetcher preset, and — when rdmsr
    # (msr-tools) is present — a register read-back that catches a write a hypervisor/lockdown dropped.
    if [ -d "$MSR_MODULE_DIR" ]; then
        _ck_ok "msr kernel module loaded"
    else
        _ck_warn "msr module not loaded — the MSR mod won't apply; if it persists, disable Secure Boot"
        issues=$((issues + 1))
    fi
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        local msrstat="" preset=""
        IFS="$(printf '\t')" read -r msrstat preset <<EOF
$(_msr_log_status "$log_file")
EOF
        case "$msrstat" in
        ok)
            _ck_ok "MSR mod applied — XMRig set the '${preset:-?}' preset (per its log)"
            # Register-level read-back (rdmsr) needs root + the msr device; it's the strong check that
            # catches a write a hypervisor/lockdown silently dropped. Degrade gracefully otherwise — the
            # log line above already confirms XMRig wrote the preset, so missing rdmsr is advisory, never
            # an issue. Mirrors the #67 RAM check, which also asks for root rather than crying wolf.
            if [ "$(id -u)" -ne 0 ]; then
                _ck_warn "run 'doctor' as root (sudo) to verify the MSRs at the register level (advisory; XMRig's log already confirms the write)"
            elif ! command -v "$RDMSR_BIN" >/dev/null 2>&1; then
                _ck_warn "rdmsr not found — install msr-tools to verify the MSRs at the register level (advisory; XMRig's log already confirms the write)"
            elif [ -n "$(_msr_preset_regs "$preset")" ]; then
                _msr_rdmsr_verify "$preset"
                if [ "${_MSR_OK:-0}" -gt 0 ] && [ "${_MSR_OK:-0}" -eq "${_MSR_TOTAL:-0}" ]; then
                    _ck_ok "MSR registers verified via rdmsr ($_MSR_OK/$_MSR_TOTAL match the $preset preset)"
                elif [ -n "$_MSR_BAD" ]; then
                    # A genuine value mismatch — the write didn't take. This is the real failure (#66).
                    _ck_warn "MSR registers don't match the $preset preset ($_MSR_OK/$_MSR_TOTAL ok;${_MSR_BAD}) — a hypervisor/lockdown may have dropped the write, or XMRig changed its preset"
                    issues=$((issues + 1))
                else
                    # No mismatch, but some/all registers were unreadable (e.g. msr module not loaded). Advisory.
                    _ck_warn "couldn't read $_MSR_UNREAD/$_MSR_TOTAL MSR(s) via rdmsr (is the 'msr' module loaded?) — relying on XMRig's log confirmation"
                fi
            fi
            ;;
        fail)
            _ck_warn "XMRig reports the MSR preset FAILED to set — check Secure Boot / msr.allow_writes=on"
            issues=$((issues + 1))
            ;;
        *) : ;; # no msr line yet (the miner may not have started a RandomX job) — stay quiet
        esac
    fi

    # CPU governor
    local gov
    gov=$(cat "$GOVERNOR_FILE" 2>/dev/null || echo "")
    if [ "$gov" = "performance" ]; then
        _ck_ok "CPU governor = performance"
    else
        _ck_warn "CPU governor is '${gov:-unknown}' (expected 'performance')"
    fi

    # Hashrate-capping HARDWARE (advisory; #67). RandomX fast-mode is dataset-latency bound, so a
    # single memory channel, slow RAM, or a power/boost cap silently leaves performance on the table.
    # doctor can't change these — it only flags them. Best-effort, gated on tool/data availability.
    if command -v "$DMIDECODE" >/dev/null 2>&1; then
        local mem pop nch spd rated
        mem=$(_mem_summary)
        read -r pop nch spd rated <<<"${mem:-0 0 0 0}" # rated (4th field) feeds the #78 XMP/EXPO check
        if [ "${pop:-0}" -eq 0 ] 2>/dev/null; then
            _ck_warn "RAM layout not readable — run 'doctor' as root so dmidecode can check channels/speed"
        else
            if [ "${nch:-0}" -le 1 ]; then
                _ck_warn "RAM is single-channel ($pop module(s), 1 channel) — RandomX wants ≥2 channels; move a stick to the other channel for a large gain"
            else
                _ck_ok "RAM: $pop modules across $nch channels (dual+ channel)"
            fi
            if [ "${spd:-0}" -gt 0 ] 2>/dev/null && [ "$spd" -lt "$MIN_RAM_MTS" ]; then
                _ck_warn "RAM speed ${spd} MT/s is low — enable XMP/EXPO or fit faster RAM (RandomX is memory-latency bound)"
            elif [ "${spd:-0}" -gt 0 ] 2>/dev/null; then
                _ck_ok "RAM speed: ${spd} MT/s"
            fi
        fi
    else
        _ck_warn "dmidecode not found — install it for the RAM channels/speed check (advisory only)"
    fi

    # Effective CPU clock under load — only meaningful while the miner is running (else the cores idle).
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        local maxk effk pct
        maxk=$(cat "$CPUFREQ_MAX" 2>/dev/null || true) # guard INSIDE $(): missing cpufreq sysfs (a VM) mustn't trip the ERR trap
        effk=$(_cpu_eff_khz)
        if [ -n "$effk" ] && [ "${maxk:-0}" -gt 0 ] 2>/dev/null; then
            pct=$((effk * 100 / maxk))
            if [ "$pct" -lt "$MIN_CLOCK_PCT" ]; then
                _ck_warn "CPU at $((effk / 1000)) MHz — only ${pct}% of the $((maxk / 1000)) MHz max boost; check PBO/cTDP power limits + cooling (likely throttling)"
            else
                _ck_ok "CPU clock under load: $((effk / 1000)) MHz (${pct}% of max boost)"
            fi
        fi
    fi

    # BIOS / firmware advisory (#78). RigForge can't read or change BIOS setup variables from a booted OS,
    # so this is detect-and-recommend only: it reads what the OS DOES expose (board/BIOS identity, the
    # memory profile, SMT) and turns it into concrete manual recommendations. Advisory — never an issue.
    local bvendor board bios bdate cpu smt xmp_rec="" smt_rec=""
    bvendor=$(_dmi board_vendor)
    board=$(_dmi board_name)
    bios=$(_dmi bios_version)
    bdate=$(_dmi bios_date)
    cpu=$(lscpu 2>/dev/null | awk -F: '/^Model name:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' || true) # ^anchored: skip "BIOS Model name:"; guard INSIDE $()
    # Work out the recommendations FIRST, so the context line only points "below" when there ARE any
    # (otherwise it'd promise items that never come — e.g. RAM already at its rated speed and SMT on).
    # XMP/EXPO/DOCP: RAM running below its rated SPD speed means the memory profile isn't enabled. Sharper
    # than the #67 fixed-threshold check (it compares rated vs configured for THIS kit).
    if [ "${rated:-0}" -gt 0 ] 2>/dev/null && [ "${spd:-0}" -gt 0 ] 2>/dev/null && [ "$spd" -lt "$rated" ] 2>/dev/null; then
        xmp_rec="RAM is running at ${spd} MT/s but the modules are rated for ${rated} MT/s — enable the memory profile (XMP / EXPO / DOCP) in BIOS for a sizable RandomX gain."
    fi
    # SMT / Hyper-Threading off on a capable CPU leaves logical cores unused for RandomX.
    smt=$(cat "$SMT_CONTROL" 2>/dev/null || true) # guard INSIDE $(): missing SMT sysfs mustn't trip the ERR trap
    case "$smt" in
    off | forceoff) smt_rec="SMT/Hyper-Threading is disabled — enable it in BIOS (SMT / Hyper-Threading) so RandomX can use every logical core." ;;
    esac
    if [ -n "$bvendor$board$bios" ]; then
        if [ -n "$xmp_rec$smt_rec" ]; then
            _ck_info "Firmware: ${bvendor:-?} ${board:-?}, BIOS ${bios:-?} (${bdate:-?})${cpu:+, $cpu} — apply the BIOS/UEFI item(s) below (RigForge can't change them from the OS)."
        else
            _ck_info "Firmware: ${bvendor:-?} ${board:-?}, BIOS ${bios:-?} (${bdate:-?})${cpu:+, $cpu} — no BIOS changes recommended."
        fi
    fi
    if [ -n "$xmp_rec" ]; then _ck_warn "$xmp_rec"; fi
    if [ -n "$smt_rec" ]; then _ck_warn "$smt_rec"; fi

    # XMRig's own startup report (HUGE PAGES 100% means the dataset is fully backed). Reuses the
    # log_file resolved above for the MSR-applied check.
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        if grep -qiE 'huge pages.*100%' "$log_file"; then
            _ck_ok "XMRig log reports HUGE PAGES 100%"
        elif grep -qi 'huge pages' "$log_file"; then
            _ck_warn "XMRig log shows HUGE PAGES below 100% — not all threads are backed"
        fi
    fi

    echo ""
    if [ "$issues" -eq 0 ]; then
        log "doctor: all critical checks passed."
    else
        warn "doctor: $issues issue(s) found — see the hints above."
    fi
}

# --- Usage & command dispatch ---

usage() {
    cat <<USAGE
RigForge — provision and maintain an XMRig mining worker.

Usage: $0 [command]

Most days you only need the first group; the rest are grouped below. Full guide: docs/operations.md

Day to day:
  apply      re-read config.json, regenerate the XMRig config, and restart (no rebuild)
  upgrade    redeploy after a 'git pull': rebuild + restart if the pinned XMRig changed
  doctor     check that HugePages, the MSR mod, the governor and the service are all healthy
  logs       follow the live miner logs
  status     show whether the miner is running
  start      start the miner (systemd on Linux, a background process on macOS) [alias: up]
  stop       stop the miner [alias: down]
  restart    restart the miner

Tuning:
  tune       measure the fastest XMRig knobs and keep them. Live re-tunes: '--now' a quick pass vs the
             running miner (run a live tune now — keeps the best prefetch mode), '--live' a full live
             search, '--confirm' A/B-checks the winner live before keeping it. '--efficiency' optimizes
             hashrate-per-watt (default '--perf' = raw H/s), '--history' shows the current tuning +
             recent runs, '--clear' resets
  bench      run a one-off 'xmrig --bench' and report the hashrate
  autotune   alias of 'tune --now' (and the verb the scheduled timer runs); turn on the schedule with
             autotune:"performance"|"efficiency" in config.json

Provision & lifecycle:
  setup      (default) provision the worker: dependencies, build, kernel tuning, service
  uninstall  remove the service and revert all system changes (add --yes/-y to skip the prompt)
  enable     start the miner automatically (boot on Linux, login on macOS)
  disable    don't start the miner automatically

Backup:
  backup     save config.json + tuning to a timestamped archive in ./backups
  restore    restore config.json + tuning from a backup archive: restore [-y] <archive>

Info:
  version    print the RigForge version  (-v, --version)
  help       show this help              (-h, --help)

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
