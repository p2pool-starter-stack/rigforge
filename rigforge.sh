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
# Color only when stdout is a terminal and NO_COLOR (https://no-color.org) is unset/empty (#144) —
# pipes, captures, CI logs, and the journal entries timer units write all get plain text. The
# ${_tty:+...} shape (instead of an if/else around the assignments) keeps every line executing on
# every run, so the no-pty CI coverage gate sees the whole block.
_tty=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then _tty=y; fi
C_RESET="${_tty:+\033[0m}"
C_GREEN="${_tty:+\033[1;32m}"
C_YELLOW="${_tty:+\033[1;33m}"
C_RED="${_tty:+\033[1;31m}"
C_BLUE="${_tty:+\033[1;34m}"
readonly C_RESET C_GREEN C_YELLOW C_RED C_BLUE
unset _tty

log() { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1" >&2; }
error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
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
# #254: config-change provenance marker (revision/source/last_change_id/changed_at), a sidecar next to
# config.json. Env-overridable so tests can sandbox it.
CONFIG_META_FILE="${RIGFORGE_CONFIG_META:-$SCRIPT_DIR/.rigforge-config-meta.json}"
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
# SHA-256 of a file, portable (Linux sha256sum / macOS shasum).
_sha256() { # <file>
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

xmrig_already_built() {
    local marker="$WORKER_ROOT/xmrig/.rigforge-commit" sums="$WORKER_ROOT/xmrig/.rigforge-sha256"
    [ -x "$WORKER_ROOT/xmrig/build/xmrig" ] && [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$XMRIG_COMMIT" ] || return 1
    # Tamper evidence (#141): a binary that no longer matches its build-time SHA-256 is NOT "already
    # built" — the next setup/upgrade rebuilds it (self-healing). A missing record is a build from an
    # older RigForge: still built (don't force a 10-minute recompile fleet-wide on first upgrade).
    [ ! -f "$sums" ] || [ "$(cat "$sums" 2>/dev/null)" = "$(_sha256 "$WORKER_ROOT/xmrig/build/xmrig")" ]
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

# Escape a value for use as the REPLACEMENT text of a `sed "s|pat|repl|"` command: backslash-prefix
# `\`, `&` (whole-match backreference) and the `|` delimiter. Without this, a pre-existing kernel
# param containing one of them (e.g. memmap=4G&2M) would silently corrupt /etc/default/grub (#134).
# Implemented with sed, not ${var//}, because bash 5.2's patsub_replacement changed `&` semantics
# in expansion replacements while our floor is bash 3.2.
_sed_escape_replacement() { # <value> -> escaped value on stdout
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
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
            # config.reference.json for the full list). The URL is host:port (Pithead's proxy
            # listens on 3333).
            read -r -p "Enter your pool URL (host:port, e.g. your-stack:3333): " IN_URL || true

            if [ -z "$IN_URL" ]; then
                error "A pool URL is required."
            fi
            if ! [[ "$IN_URL" =~ :[0-9]+$ ]]; then
                error "Pool URL must include a port, e.g. $IN_URL:3333."
            fi
            # Validate the host now, the same way parse_config will in a moment — otherwise a host-less URL
            # like ":3333" passes the port check, gets written, and then parse_config hard-errors on it,
            # leaving a broken config.json on disk that suppresses this prompt on the re-run (the file now
            # exists). Failing before the write keeps the user re-promptable.
            _host="${IN_URL%:*}"
            case "$_host" in
            \[*\]) [[ "$_host" =~ ^\[[0-9A-Fa-f:]+\]$ ]] || error "Pool URL '$IN_URL' has an invalid IPv6 literal (use [addr]:port)." ;;
            *) [[ "$_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || error "Pool URL host '$_host' is not a valid hostname or IP." ;;
            esac

            # Pithead stratum auth (#113): if the stack sets p2pool.stratum_password, every rig's pool
            # `pass` must match or the proxy rejects the login. The secret is shown by `pithead status`.
            # Enter skips it (open stack / non-Pithead pool) — parse_config then defaults pass to "x".
            # Pre-validate with parse_config's exact pass rule (same reasoning as the host check above:
            # fail before the write so a bad value doesn't leave a prompt-suppressing config on disk).
            IN_PASS=""
            read -r -p "Stratum password, if your stack requires one (shown by 'pithead status'; Enter for none): " IN_PASS || true
            if [ -n "$IN_PASS" ] && ! [[ "$IN_PASS" =~ ^[[:graph:]]+$ ]]; then
                error "Stratum password must have no spaces or control characters."
            fi

            # Minimal config: just the native pools array. jq writes it so the URL (and pass, when
            # given) are safely quoted; an empty pass writes no key at all, keeping the no-auth
            # minimal config byte-identical to before.
            jq -n --arg url "$IN_URL" --arg pass "$IN_PASS" \
                '{pools: [({url: $url} + (if $pass == "" then {} else {pass: $pass} end))]}' >"$CONFIG_JSON"
            # The operator is told (below) to hand-edit this file to add a wallet / ACCESS_TOKEN, and the
            # first `apply` may be a long way off — chmod now so those secrets are never world-readable
            # in the interim (generate_xmrig_config's chmod 600 only runs on setup/apply). (#131)
            chmod 600 "$CONFIG_JSON"
            _reown_worker # hand the freshly-created config.json to the operator, even if setup later fails
            log "Created $CONFIG_JSON successfully."
            # New-user safety net: the minimal config has no wallet, so a PUBLIC-pool miner who stops here
            # would credit hashes to the hostname, not themselves — and nothing later (doctor included)
            # flags it, since it's a pool-side auth detail. Pithead users correctly need no wallet.
            warn "Mining to a PUBLIC pool (SupportXMR, etc.)? Add your Monero wallet as the pool \"user\" in"
            warn "$CONFIG_JSON and run 'sudo $0 apply', or your hashes credit '$(hostname)', not you."
            warn "Connecting to a Pithead stack instead? You're all set — no wallet needed."
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

    # tls-fingerprint (#115): re-attach the pin from the raw config, emitted ONLY when set — adding
    # it unconditionally (null) would change the generated config shape for every existing rig on
    # its next apply. A second single-line pass rather than lines inside the map above: kcov can't
    # attribute in-string program lines, and the patch-coverage gate needs every new line hittable.
    POOLS_JSON=$(jq -c --argjson base "$POOLS_JSON" '[$base, [.pools[] | ."tls-fingerprint"]] | transpose | map(.[0] + (if (.[1] // null) != null then {"tls-fingerprint": .[1]} else {} end))' "$CONFIG_JSON") || error "Could not parse 'pools' in $CONFIG_JSON."

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
        # TLS fingerprint pin (#115): xmrig does NO cert verification for stratum without a pin
        # (v6.26.0 Tls.cpp verifyFingerprint returns true when unset), so the fingerprint is the
        # ONLY server authentication stratum-TLS has. 64 hex chars, either case (xmrig compares
        # case-insensitively); passed verbatim, never normalized. A pin without tls:true is a hard
        # error — a silently-ignored pin would leave the operator believing they're protected.
        _fp=$(jq -r '."tls-fingerprint" // empty' <<<"$_pool")
        if [ -n "$_fp" ]; then
            if ! [[ "$_fp" =~ ^[0-9A-Fa-f]{64}$ ]]; then
                error "Pool tls-fingerprint must be the cert's SHA-256 as 64 hex chars (no colons). Get it with: echo | openssl s_client -connect $_u 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':'"
            fi
            if [ "$(jq -r '.tls' <<<"$_pool")" != "true" ]; then
                error "Pool '$_u' sets tls-fingerprint but not \"tls\": true — the pin only applies to a TLS connection; set both or remove the fingerprint."
            fi
        fi
        for _f in keepalive tls enabled; do
            _bv=$(jq -r --arg f "$_f" '.[$f]' <<<"$_pool")
            case "$_bv" in true | false) ;; *) error "Pool $_f must be true or false (got: $_bv)." ;; esac
        done
    done < <(jq -c '.[]' <<<"$POOLS_JSON")

    # HTTP API token (OPTIONAL). By default the rig's read-only xmrig API is left OPEN — no token.
    # Pithead's stock contract is a no-auth probe of GET http://<rig>:8080/1/summary, so an
    # untokened, `restricted` (read-only) API works out of the box. Set ACCESS_TOKEN to require a
    # Bearer token instead — then match it on the dashboard side (Pithead `workers.api_auth: token`
    # + `workers.api_token`; or `name` if you set ACCESS_TOKEN to the rig name). See
    # docs/pithead-integration.md.
    ACCESS_TOKEN=$(jq -r '.ACCESS_TOKEN // empty' "$CONFIG_JSON")

    # Opt-in firewall scoping (#142): restrict the read-only API port(s) to one source + loopback.
    # Empty (default) = RigForge manages no firewall. Accepts IPv4 or IPv6 address/CIDR (#243): the
    # strict per-family charset is the injection guard (the value reaches an nft file), and
    # API_ALLOW_FAMILY (ip|ip6) picks the nft match keyword.
    API_ALLOW_FROM=$(jq -r '.api_allow_from // empty' "$CONFIG_JSON")
    API_ALLOW_FAMILY=ip
    if [ -n "$API_ALLOW_FROM" ]; then
        if [[ "$API_ALLOW_FROM" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            local _a _b _c _d _p
            IFS='./' read -r _a _b _c _d _p <<<"$API_ALLOW_FROM"
            if [ "$_a" -gt 255 ] || [ "$_b" -gt 255 ] || [ "$_c" -gt 255 ] || [ "$_d" -gt 255 ] || [ "${_p:-0}" -gt 32 ]; then
                error "api_allow_from must be a valid IPv4/IPv6 address or CIDR (e.g. 192.168.1.0/24 or fd00::/64); got: '$API_ALLOW_FROM'."
            fi
            API_ALLOW_FAMILY=ip
        elif [[ "$API_ALLOW_FROM" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] && [[ "$API_ALLOW_FROM" == *:*:* ]]; then
            # IPv6/CIDR: hex-and-colons charset (the injection guard) + >=2 colons + a 0-128 prefix.
            # nft rejects a truly malformed address at load, so this is the guard, not a full RFC
            # validator — same posture as the IPv4 octet check above.
            local _pfx=""
            case "$API_ALLOW_FROM" in */*) _pfx="${API_ALLOW_FROM##*/}" ;; esac
            if [ -n "$_pfx" ] && { ! [[ "$_pfx" =~ ^[0-9]+$ ]] || [ "$_pfx" -gt 128 ]; }; then
                error "api_allow_from IPv6 prefix must be 0-128 (got: '$API_ALLOW_FROM')."
            fi
            API_ALLOW_FAMILY=ip6
        else
            error "api_allow_from must be an IPv4/IPv6 address or CIDR (e.g. 192.168.1.0/24 or fd00::/64); got: '$API_ALLOW_FROM'."
        fi
    fi
    # When set, the token is sent as an HTTP Authorization header, so keep it to safe, header-clean
    # characters. Empty is allowed and means "open API" (the default).
    if [ -n "$ACCESS_TOKEN" ] && ! [[ "$ACCESS_TOKEN" =~ ^[A-Za-z0-9._:@+-]+$ ]]; then
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

    # Opt-in miner watchdog (#139): a periodic health check (same timer machinery as autotune) that
    # restarts a WEDGED miner — process alive, 0 H/s or API dead, the case systemd's Restart= can't
    # see — and, when max_temp_c is set, stops the miner above that temperature (restarting 5°C
    # below). A typo hard-errors: a recovery mechanism must not be silently disabled.
    _wd=$(jq -r '.watchdog // "disabled"' "$CONFIG_JSON")
    case "$_wd" in
    disabled | false | off | none | null | "") WATCHDOG_MODE=disabled ;;
    enabled | true | on) WATCHDOG_MODE=enabled ;;
    *) error "Invalid \"watchdog\" value '$_wd' in config.json — use \"disabled\" or \"enabled\"." ;;
    esac
    WATCHDOG_INTERVAL_MIN=$(jq -r '.watchdog_interval_min // 5' "$CONFIG_JSON")
    if ! [[ "$WATCHDOG_INTERVAL_MIN" =~ ^[0-9]+$ ]] || [ "$WATCHDOG_INTERVAL_MIN" -lt 1 ] || [ "$WATCHDOG_INTERVAL_MIN" -gt 1440 ]; then
        error "watchdog_interval_min must be a whole number of minutes, 1-1440 (got: $WATCHDOG_INTERVAL_MIN)."
    fi
    # Empty (the default) = no thermal cutoff. Opt-in because thermal_zone0's meaning varies by
    # board — a wrong cutoff on an unchecked sensor is worse than none. 40-110: below 40 a loaded
    # rig would never restart, above 110 is past any CPU's limit.
    MAX_TEMP_C=$(jq -r '.max_temp_c // empty' "$CONFIG_JSON")
    if [ -n "$MAX_TEMP_C" ]; then
        if ! [[ "$MAX_TEMP_C" =~ ^[0-9]+$ ]] || [ "$MAX_TEMP_C" -lt 40 ] || [ "$MAX_TEMP_C" -gt 110 ]; then
            error "max_temp_c must be empty (no thermal cutoff) or a whole number 40-110 °C (got: $MAX_TEMP_C)."
        fi
    fi

    # Opt-in: install a `rigforge` command on PATH (a symlink in BIN_DIR). Off by default — setup makes
    # no system-wide convenience change you didn't ask for.
    ADD_TO_PATH=$(jq -r '.add_to_path // false' "$CONFIG_JSON")

    # Opt-in read-only sister API (#99): serves XMRig's /2/summary enriched with RigForge state
    # (tune/power/health/provenance) on its own port. Same posture as :8080 — read-only, LAN-bound,
    # gated by the SAME ACCESS_TOKEN (a second token would re-open the Pithead token-coordination
    # problem for no gain).
    _api=$(jq -r '.api // "disabled"' "$CONFIG_JSON")
    case "$_api" in
    disabled | false | off | none | null | "") API_MODE=disabled ;;
    enabled | true | on) API_MODE=enabled ;;
    *) error "Invalid \"api\" value '$_api' in config.json — use \"disabled\" or \"enabled\"." ;;
    esac
    API_PORT=$(jq -r '.api_port // 8081' "$CONFIG_JSON")
    if ! [[ "$API_PORT" =~ ^[0-9]+$ ]] || [ "$API_PORT" -lt 1 ] || [ "$API_PORT" -gt 65535 ]; then error "api_port must be a port number 1-65535 (got: $API_PORT)."; fi
    if [ "$API_PORT" = 8080 ]; then error "api_port 8080 collides with XMRig's own API — pick another port."; fi
    API_BIND=$(jq -r '.api_bind // "0.0.0.0"' "$CONFIG_JSON")
    [[ "$API_BIND" =~ ^[0-9A-Fa-f.:]+$ ]] || error "api_bind must be an IP address (got: $API_BIND)."

    # Opt-in WRITABLE control path (#236): a SEPARATE authenticated endpoint that lets the stack
    # (pithead #185) apply validated config changes THROUGH RigForge, so config.json stays the
    # source of truth. Distinct from the read-only sister API — its own port, its own units, an
    # unprivileged receiver decoupled from the privileged applier (see docs/adr/0001). Default off.
    _control=$(jq -r '.control // "disabled"' "$CONFIG_JSON")
    case "$_control" in
    disabled | false | off | none | null | "") CONTROL_MODE=disabled ;;
    enabled | true | on) CONTROL_MODE=enabled ;;
    *) error "Invalid \"control\" value '$_control' in config.json — use \"disabled\" or \"enabled\"." ;;
    esac
    CONTROL_PORT=$(jq -r '.control_port // 8082' "$CONFIG_JSON")
    if ! [[ "$CONTROL_PORT" =~ ^[0-9]+$ ]] || [ "$CONTROL_PORT" -lt 1 ] || [ "$CONTROL_PORT" -gt 65535 ]; then error "control_port must be a port number 1-65535 (got: $CONTROL_PORT)."; fi
    if [ "$CONTROL_PORT" = 8080 ]; then error "control_port 8080 collides with XMRig's own API — pick another port."; fi
    CONTROL_BIND=$(jq -r '.control_bind // "0.0.0.0"' "$CONFIG_JSON")
    [[ "$CONTROL_BIND" =~ ^[0-9A-Fa-f.:]+$ ]] || error "control_bind must be an IP address (got: $CONTROL_BIND)."
    if [ "$CONTROL_MODE" = enabled ]; then
        if [ "${API_MODE:-disabled}" = enabled ] && [ "$CONTROL_PORT" = "$API_PORT" ]; then
            error "control_port ($CONTROL_PORT) collides with the sister API port — pick another port."
        fi
        # Fail-closed dual auth: the writable path demands BOTH a Bearer token AND a pinned source.
        # Missing either would expose an unauthenticated remote config write, so this is a hard
        # error, not a warning — a writable control surface must never come up open by omission.
        [ -n "${ACCESS_TOKEN:-}" ] || error "control: \"enabled\" requires ACCESS_TOKEN — a writable API with no token is an open remote config write. Set ACCESS_TOKEN in config.json."
        [ -n "${API_ALLOW_FROM:-}" ] || error "control: \"enabled\" requires api_allow_from — the writable path must be pinned to the stack host. Set api_allow_from in config.json."
    fi
    # #243/scan: an IPv6 api_allow_from only scopes traffic the APIs actually receive over IPv6, but
    # api_bind/control_bind default to IPv4 (0.0.0.0). Warn on the silent no-op — it fails safe (no
    # reachable v6 to scope), but the operator's intent isn't met until they bind "::".
    if [ "${API_ALLOW_FAMILY:-ip}" = ip6 ] && [[ "$API_BIND" != *:* ]] && [[ "$CONTROL_BIND" != *:* ]]; then
        warn "api_allow_from is IPv6 but api_bind/control_bind are IPv4 (0.0.0.0) — the APIs aren't reachable over IPv6, so the v6 scope takes no effect. Set api_bind/control_bind to \"::\" to serve + scope IPv6."
    fi

    # Privilege separation (#140): run the miner as this dedicated non-root system user. Empty
    # (default) keeps today's root behavior exactly. `root` is rejected — it would silently mean
    # "no separation". useradd-portable names only.
    MINER_USER=$(jq -r '.miner_user // empty' "$CONFIG_JSON")
    if [ -n "$MINER_USER" ]; then
        if [ "$MINER_USER" = "root" ]; then
            error "miner_user must be a non-root system username (empty = run as root, the default)."
        fi
        [[ "$MINER_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || error "miner_user '$MINER_USER' is not a valid system username (lowercase, digits, _ -; max 32 chars)."
    fi

    _warn_unknown_config_keys
}

# Typo lint (#138): a key parse_config doesn't read is silently ignored — worst case a security key
# ("ACESS_TOKEN") that the operator believes is protecting them. Warn (never error: an unknown key
# is at worst a no-op, and erroring would brick fleet applies on any future rename), name each
# unknown key with a case-insensitive did-you-mean, and point at the reference. Keys starting with
# `_` are the comment convention (config.reference.json's own _docs); RIG_NAME is reserved for the
# #1 image seed. Warn NAMES only, never values — a fat-fingered token must not land in a log.
_warn_unknown_config_keys() {
    local known="pools ACCESS_TOKEN DONATION autotune add_to_path HOME_DIR api api_port api_bind api_allow_from miner_user RIG_NAME watchdog watchdog_interval_min max_temp_c control control_port control_bind"
    local known_pool="url user pass keepalive tls enabled tls-fingerprint"
    local k lk m lm hit hint unknown_seen=0
    while IFS= read -r k; do
        case "$k" in _*) continue ;; esac
        hit=""
        hint=""
        lk=$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')
        for m in $known; do
            if [ "$k" = "$m" ]; then
                hit=1
                break
            fi
            lm=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
            if [ "$lk" = "$lm" ]; then hint="$m"; fi
        done
        if [ -n "$hit" ]; then continue; fi
        if [ -n "$hint" ]; then warn "config.json: unknown key \"$k\" is ignored — did you mean \"$hint\"?"; else warn "config.json: unknown key \"$k\" is ignored."; fi
        unknown_seen=1
    done < <(jq -r 'keys[]' "$CONFIG_JSON" 2>/dev/null || true)
    while IFS= read -r k; do
        case "$k" in _*) continue ;; esac
        hit=""
        hint=""
        lk=$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')
        for m in $known_pool; do
            if [ "$k" = "$m" ]; then
                hit=1
                break
            fi
            lm=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
            if [ "$lk" = "$lm" ]; then hint="$m"; fi
        done
        if [ -n "$hit" ]; then continue; fi
        if [ -n "$hint" ]; then warn "config.json: unknown pool field \"$k\" is ignored — did you mean \"$hint\"?"; else warn "config.json: unknown pool field \"$k\" is ignored."; fi
        unknown_seen=1
    done < <(jq -r '(.pools // []) | map(keys[]) | unique | .[]' "$CONFIG_JSON" 2>/dev/null || true)
    if [ "$unknown_seen" = 1 ]; then warn "See config.reference.json for every supported key."; fi
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

# Package-manager detection (read-only) — sets DEP_LIST / DEP_CHECK / DEP_INSTALL, rc 1 when no
# manager is found. Split from install_dependencies so the setup --dry-run plan (#146) reuses the
# EXACT list and check — never a second copy to drift.
_detect_pkg_manager() {
    DEP_LIST=""
    DEP_CHECK=""
    DEP_INSTALL=""
    if command -v apt-get &>/dev/null; then
        DEP_LIST="git build-essential cmake libuv1-dev libssl-dev libhwloc-dev gettext-base python3"
        if [ "$OS_TYPE" == "Linux" ]; then
            # msr-tools (rdmsr): lets `doctor` verify the prefetcher MSR mod actually applied (#66).
            DEP_LIST="$DEP_LIST linux-tools-common msr-tools"
            if apt-cache show "linux-tools-$(uname -r)" &>/dev/null; then
                DEP_LIST="$DEP_LIST linux-tools-$(uname -r)"
            fi
        fi
        # DPkg::Lock::Timeout waits for the apt/dpkg lock instead of failing — fresh boots often have
        # unattended-upgrades holding it for a minute or two (#74).
        DEP_INSTALL="sudo apt-get update -qq -o DPkg::Lock::Timeout=300 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=300 -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
        DEP_CHECK="dpkg -s"
    elif command -v dnf &>/dev/null; then
        DEP_LIST="git cmake libuv-devel openssl-devel hwloc-devel gettext gcc gcc-c++ make automake kernel-devel msr-tools"
        DEP_INSTALL="sudo dnf install -y"
        DEP_CHECK="rpm -q"
    elif command -v pacman &>/dev/null; then
        DEP_LIST="git cmake libuv openssl hwloc gettext base-devel"
        DEP_INSTALL="sudo pacman -Sy --noconfirm --needed"
        DEP_CHECK="pacman -Qi"
    else
        return 1
    fi
}

# Echo the packages from DEP_LIST that aren't installed (read-only, no root). $DEP_LIST are PACKAGE
# names (build-essential, libuv1-dev — most have no same-named binary), so the package manager is
# the authority for "is it installed", not `command -v` (which would both miss header-only -dev
# packages and let an unrelated PATH binary mask a genuinely-absent package).
_missing_deps() {
    local dep missing=""
    for dep in $DEP_LIST; do
        if ! $DEP_CHECK "$dep" &>/dev/null; then
            missing="$missing $dep"
        fi
    done
    printf '%s' "$missing"
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
        if ! _detect_pkg_manager; then
            warn "No supported package manager found. Please install dependencies manually."
            return
        fi
        local missing_deps
        missing_deps="$(_missing_deps)"

        if [ -n "$missing_deps" ]; then
            # `setup` is an automated provisioner (often run headless / over the release e2e), so install
            # the build dependencies non-interactively rather than prompting — an interactive `read` here
            # hit EOF and aborted the whole run under `set -e` on a non-tty stdin (#74).
            log "Installing required system dependencies:"
            echo -e "  ${C_YELLOW}$missing_deps${C_RESET}"
            eval "$DEP_INSTALL $missing_deps"
        else
            log "All system dependencies are already installed."
        fi
    fi
}

# --- Setup: build XMRig from source ---

compile_xmrig() {
    if [ "$XMRIG_REBUILD" != true ]; then
        log "XMRig $XMRIG_VERSION (commit ${XMRIG_COMMIT:0:12}) already built — skipping clone/compile."
        # Enter the build dir the rebuild path also ends in, so generate_xmrig_config (which writes a
        # relative config.json) emits it where the service actually reads it: --config=$BUILD_DIR/config.json
        # with BUILD_DIR=$WORKER_ROOT/xmrig/build. Without this, a no-rebuild setup re-run would drop the
        # regenerated config.json in $WORKER_ROOT and the miner would keep loading the stale build/config.json
        # — config edits would silently never take effect. The dir is guaranteed to exist here (a no-rebuild
        # decision requires the built binary under it). `apply` and the rebuild path already cd here.
        cd "$WORKER_ROOT/xmrig/build"
        return 0
    fi
    log "Cloning and patching XMRig source code ($XMRIG_VERSION)..."
    # Remove any partial/stale clone an interrupted or commit-mismatched prior run left behind — otherwise
    # `git clone` aborts with "destination path 'xmrig' already exists and is not empty".
    rm -rf xmrig
    git clone --quiet --branch "$XMRIG_VERSION" --depth 1 https://github.com/xmrig/xmrig.git

    # Verify we built the exact commit we pinned (supply-chain hardening). On a mismatch, drop the clone so
    # the next run starts clean rather than tripping the not-empty error above.
    local actual
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
    # And the binary's SHA-256 (#141): tamper EVIDENCE, not proofing — root can rewrite this too,
    # but it reliably catches the accidental and unsophisticated cases, same honest posture as
    # `restricted:true`. Guarded if: the stubbed-make tests produce no binary, and a trailing
    # false `&&` would abort the function under set -e.
    if [ -f "$WORKER_ROOT/xmrig/build/xmrig" ]; then
        _sha256 "$WORKER_ROOT/xmrig/build/xmrig" >"$WORKER_ROOT/xmrig/.rigforge-sha256"
    fi
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
    # stack host via GET http://<rig>:8080/1/summary (read-only; OPEN by default — see ACCESS_TOKEN
    # above). Binding localhost would break that integration — see issue #24. Workers are expected to
    # live on a trusted LAN, which is why a read-only API with no token is a safe default there.
    HTTP_RESTRICTED="true"
    HTTP_HOST="0.0.0.0"

    # Privilege separation (#140): an unprivileged miner cannot write /dev/cpu/*/msr — RigForge
    # applies the MSR preset root-side (msr-apply, ExecStartPre) and xmrig must not try itself.
    if [ -n "${MINER_USER:-}" ]; then
        WRMSR="false"
        RDMSR="false"
    fi

    # macOS Specific Overrides (only the values that differ from the shared defaults above)
    if [ "$OS_TYPE" == "Darwin" ]; then
        ASM="true"
        WRMSR="false"
        RDMSR="false"
        HUGE_PAGES="false"
        MEMORY_POOL="false"
        ONE_GB_PAGES="false"
        HTTP_HOST="::"

        # Generate rx array [-1, -1, ...] based on core count
        CORES=$(sysctl -n hw.ncpu)
        THREADS="["
        for ((i = 0; i < CORES; i++)); do
            THREADS="${THREADS}-1"
            if [ "$i" -lt $((CORES - 1)) ]; then THREADS="${THREADS},"; fi
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

    # The live config holds the pool/wallet and the API token, so keep it owner-only (a root `jq`
    # redirect would otherwise leave it world-readable). _reown_worker hands ownership to the operator
    # later; chmod here is preserved across that chown, and root (the service) reads it regardless.
    chmod 600 config.json

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
        create 0644 ${MINER_USER:-$REAL_USER} ${MINER_USER:-$REAL_USER}
    }
EOF
    fi
}

# --- Setup: service, kernel tuning & deployment ---

# Render the miner unit from its template (#140 made this shared: `apply` must re-render when
# miner_user changes, without install_service's enable/start side effects).
# Privilege separation (#140): create the dedicated system user on first use. Never deleted by
# uninstall (we can't prove we created it; an inert nologin user is safer than userdel). Called
# from BOTH install paths — setup (install_service) and apply's unit re-render — because apply is
# the documented config-change path for toggling miner_user; a unit saying User=<absent user>
# fails with status=217/USER (caught live on miner-0 during the v1.4.0 gate).
_ensure_miner_user() {
    if [ -n "${MINER_USER:-}" ] && ! id -u "$MINER_USER" >/dev/null 2>&1; then
        log "Creating system user '$MINER_USER' for the miner..."
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$MINER_USER"
    fi
}

_render_xmrig_unit() {
    local msr_line=""
    # Root-side MSR application for an unprivileged miner: no `-` prefix — on an opted-in rig a
    # failed MSR write should be VISIBLE, and msr-apply itself exits 0 on the known-benign cases
    # (unknown CPU family, module missing) so it never wedges the Restart=always loop.
    if [ -n "${MINER_USER:-}" ]; then msr_line="ExecStartPre=+$SCRIPT_DIR/rigforge.sh msr-apply"; fi
    WORKER_ROOT="$WORKER_ROOT" MINER_USER_EFFECTIVE="${MINER_USER:-root}" MSR_APPLY_LINE="$msr_line" \
        envsubst '$BUILD_DIR $CPUPOWER_PATH $WORKER_ROOT $NFT_PATH $MINER_USER_EFFECTIVE $MSR_APPLY_LINE' \
        <"$SCRIPT_DIR/systemd/xmrig.service.template" | sudo tee "$SYSTEMD_DIR/$SERVICE_NAME.service" >/dev/null
}

install_service() {
    if [ "$OS_TYPE" == "Linux" ]; then
        log "Installing systemd service..."
        export BUILD_DIR="$WORKER_ROOT/xmrig/build"
        CPUPOWER_PATH=$(command -v cpupower || echo "/usr/bin/cpupower")
        export CPUPOWER_PATH
        NFT_PATH=$(command -v nft || echo "/usr/sbin/nft")
        export NFT_PATH

        _ensure_miner_user
        _render_xmrig_unit

        # Reload systemd daemon
        sudo systemctl daemon-reload

        # Enable service to start on boot
        sudo systemctl enable "$SERVICE_NAME.service"

        if [ "$REBOOT_REQUIRED" = true ]; then
            # HugePages aren't reserved until the GRUB change takes effect on reboot — starting the miner
            # now would run it DEGRADED (no huge-page backing, Restart=always churn) until then. So only
            # enable it; it starts automatically after the reboot. (#audit A2)
            log "Service enabled — it will start automatically after you reboot."
        elif [ "$XMRIG_REBUILD" = true ]; then
            # Restart only when the binary was rebuilt; otherwise just ensure it's running (a running
            # service is left undisturbed on a no-op re-run).
            log "Restarting XMRig service..."
            sudo systemctl restart "$SERVICE_NAME.service"
        else
            log "No rebuild — ensuring the service is running (no restart)."
            sudo systemctl start "$SERVICE_NAME.service"
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

# Install (or remove) the systemd timer that runs the miner watchdog periodically, based on the
# `watchdog` config flag (#139). Same shape as install_autotune above; idempotent both ways.
install_watchdog() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    local svc="$SYSTEMD_DIR/rigforge-watchdog.service" tmr="$SYSTEMD_DIR/rigforge-watchdog.timer"
    if [ "${WATCHDOG_MODE:-disabled}" = "disabled" ]; then
        if [ -f "$tmr" ]; then
            sudo systemctl disable --now rigforge-watchdog.timer 2>/dev/null || true
            sudo rm -f "$svc" "$tmr"
            sudo systemctl daemon-reload 2>/dev/null || true
            log "Miner watchdog disabled."
        fi
        return 0
    fi
    log "Enabling the miner watchdog: a health check every ${WATCHDOG_INTERVAL_MIN:-5} min${MAX_TEMP_C:+, thermal cutoff ${MAX_TEMP_C}°C}..."
    # Only the cadence is baked into the units — the verb re-reads config.json every run, so an
    # `apply` after a max_temp_c or ACCESS_TOKEN edit needs no unit rewrite (and no token on disk).
    SERVICE_NAME="$SERVICE_NAME" RIGFORGE_OPERATOR="$REAL_USER" SCRIPT_DIR="$SCRIPT_DIR" \
        envsubst '$SERVICE_NAME $RIGFORGE_OPERATOR $SCRIPT_DIR' \
        <"$SCRIPT_DIR/systemd/rigforge-watchdog.service.template" | sudo tee "$svc" >/dev/null
    WATCHDOG_INTERVAL_MIN="${WATCHDOG_INTERVAL_MIN:-5}" \
        envsubst '$WATCHDOG_INTERVAL_MIN' \
        <"$SCRIPT_DIR/systemd/rigforge-watchdog.timer.template" | sudo tee "$tmr" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable --now rigforge-watchdog.timer 2>/dev/null || true
}

# Sister API (#99/#164, xmrig-model): one tiny persistent python3-stdlib server ships pre-computed
# JSON from /run/rigforge-api; a systemd timer (`rigforge.sh api-refresh`) recomputes the files every
# 15 s. Requests never touch the miner. Toggle shape mirrors install_autotune above.
# Opt-in API firewall (#142): an own `inet rigforge` nft table scoping the read-only API port(s)
# to `api_allow_from` + loopback. nftables only (Ubuntu 24.04's native firewall — a ufw fallback
# would double the surface); own table so teardown is a single `destroy`. Matches only the API
# dports, so SSH and the outbound stratum connection are untouchable by construction. Applied now
# AND re-applied on boot via xmrig.service (the always-present anchor); removed with the table.
install_api_firewall() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    [ -n "${WORKER_ROOT:-}" ] || return 0 # nowhere to stage the rule file yet
    local nft_file="$WORKER_ROOT/api-firewall.nft"
    if [ -z "${API_ALLOW_FROM:-}" ]; then
        if [ -f "$nft_file" ]; then
            command -v nft >/dev/null 2>&1 && sudo nft destroy table inet rigforge 2>/dev/null || true
            sudo rm -f "$nft_file"
            log "API firewall removed."
        fi
        return 0
    fi
    command -v nft >/dev/null 2>&1 || error "api_allow_from is set but 'nft' is missing — install nftables (sudo apt-get install nftables) or clear the key."
    # Port set: :8080 (XMRig's API) always, plus :8081 (the sister API) when it's enabled.
    local ports="8080"
    [ "${API_MODE:-disabled}" = enabled ] && ports="$ports, ${API_PORT:-8081}"
    [ "${CONTROL_MODE:-disabled}" = enabled ] && ports="$ports, ${CONTROL_PORT:-8082}"
    sudo tee "$nft_file" >/dev/null <<NFT
destroy table inet rigforge
table inet rigforge {
    chain api {
        type filter hook input priority filter; policy accept;
        tcp dport { $ports } iifname "lo" accept
        tcp dport { $ports } ${API_ALLOW_FAMILY:-ip} saddr $API_ALLOW_FROM accept
        tcp dport { $ports } drop
    }
}
NFT
    # Fail CLOSED: if nft rejects the ruleset (e.g. a charset-valid but structurally-invalid IPv6
    # slipped past parse_config's guard), the API ports are NOT scoped — never log success. This is
    # a security control, so a load failure is a hard error, not a warning swallowed by apply's
    # `install_api_firewall || true`.
    if ! sudo nft -f "$nft_file"; then
        error "API firewall FAILED to load — nft rejected the ruleset for api_allow_from='$API_ALLOW_FROM'. The API ports are NOT restricted. Fix api_allow_from and re-run."
    fi
    log "API firewall active — port(s) $ports reachable only from $API_ALLOW_FROM and loopback."
}

install_api() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    local svc="$SYSTEMD_DIR/rigforge-api.service" rsvc="$SYSTEMD_DIR/rigforge-api-refresh.service" rtmr="$SYSTEMD_DIR/rigforge-api-refresh.timer"
    # v1.2.x shipped a per-connection socket pair (Accept=yes) — remove it on sight so upgrades converge.
    if [ -f "$SYSTEMD_DIR/rigforge-api.socket" ]; then
        sudo systemctl disable --now rigforge-api.socket 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/rigforge-api.socket" "$SYSTEMD_DIR/rigforge-api@.service"
        sudo systemctl daemon-reload 2>/dev/null || true
    fi
    if [ "${API_MODE:-disabled}" = "disabled" ]; then
        if [ -f "$svc" ] || [ -f "$rtmr" ]; then
            sudo systemctl disable --now rigforge-api.service rigforge-api-refresh.timer 2>/dev/null || true
            sudo rm -f "$svc" "$rsvc" "$rtmr"
            sudo systemctl daemon-reload 2>/dev/null || true
            log "Sister API disabled."
        fi
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || error "The sister API server needs python3 (stock on Ubuntu 24.04). Install it or set \"api\": \"disabled\"."
    # Never echo the token itself — only whether one is required.
    log "Enabling the sister API on $API_BIND:$API_PORT (read-only; token: $([ -n "${ACCESS_TOKEN:-}" ] && echo required || echo open); state refreshes every 15s)..."
    API_BIND="$API_BIND" API_PORT="$API_PORT" SCRIPT_DIR="$SCRIPT_DIR" envsubst '$API_BIND $API_PORT $SCRIPT_DIR' <"$SCRIPT_DIR/systemd/rigforge-api.service.template" | sudo tee "$svc" >/dev/null
    RIGFORGE_OPERATOR="$REAL_USER" SCRIPT_DIR="$SCRIPT_DIR" envsubst '$RIGFORGE_OPERATOR $SCRIPT_DIR' <"$SCRIPT_DIR/systemd/rigforge-api-refresh.service.template" | sudo tee "$rsvc" >/dev/null
    sudo tee "$rtmr" <"$SCRIPT_DIR/systemd/rigforge-api-refresh.timer.template" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable --now rigforge-api-refresh.timer 2>/dev/null || true
    sudo systemctl enable rigforge-api.service 2>/dev/null || true
    # restart, not just enable --now: a bind/port/token change must be re-read (restart also starts).
    sudo systemctl restart rigforge-api.service 2>/dev/null || true
    # Prime the state files so the first poll isn't a 503 for a whole timer period.
    sudo systemctl start rigforge-api-refresh.service 2>/dev/null || true
}

# Writable control path (#236): the unprivileged receiver server plus the path-triggered privileged
# applier. Same opt-in/teardown shape as install_api; its own units so it enables independently.
# parse_config has already refused to reach here without a token + api_allow_from (fail-closed).
install_control() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    local svc="$SYSTEMD_DIR/rigforge-control.service" asvc="$SYSTEMD_DIR/rigforge-control-apply.service" apath="$SYSTEMD_DIR/rigforge-control-apply.path"
    if [ "${CONTROL_MODE:-disabled}" = "disabled" ]; then
        if [ -f "$svc" ] || [ -f "$apath" ]; then
            sudo systemctl disable --now rigforge-control.service rigforge-control-apply.path 2>/dev/null || true
            sudo rm -f "$svc" "$asvc" "$apath"
            sudo systemctl daemon-reload 2>/dev/null || true
            log "Writable control path disabled."
        fi
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || error "The control server needs python3 (stock on Ubuntu 24.04). Install it or set \"control\": \"disabled\"."
    log "Enabling the writable control path on $CONTROL_BIND:$CONTROL_PORT (token required, pinned to $API_ALLOW_FROM; changes staged and applied off the request path)..."
    CONTROL_BIND="$CONTROL_BIND" CONTROL_PORT="$CONTROL_PORT" SCRIPT_DIR="$SCRIPT_DIR" API_PORT="${API_PORT:-8081}" \
        envsubst '$CONTROL_BIND $CONTROL_PORT $SCRIPT_DIR $API_PORT' \
        <"$SCRIPT_DIR/systemd/rigforge-control.service.template" | sudo tee "$svc" >/dev/null
    RIGFORGE_OPERATOR="$REAL_USER" SCRIPT_DIR="$SCRIPT_DIR" \
        envsubst '$RIGFORGE_OPERATOR $SCRIPT_DIR' \
        <"$SCRIPT_DIR/systemd/rigforge-control-apply.service.template" | sudo tee "$asvc" >/dev/null
    sudo tee "$apath" <"$SCRIPT_DIR/systemd/rigforge-control-apply.path.template" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable --now rigforge-control-apply.path 2>/dev/null || true
    sudo systemctl enable rigforge-control.service 2>/dev/null || true
    # restart, not just enable --now: a bind/port/token change must be re-read (restart also starts).
    sudo systemctl restart rigforge-control.service 2>/dev/null || true
}

# #65 (read-only): the thread count the HugePages reservation is sized for — the tuned cpu.rx if
# `tune` pinned one (so setup + tune stay consistent), or an explicit RIGFORGE_THREADS override (the
# documented resize-then-re-tune path). Empty => proposed-grub.sh falls back to its L3 estimate.
_rx_setup_threads() {
    RX_SETUP_THREADS=""
    if [ -n "${RIGFORGE_THREADS:-}" ]; then
        RX_SETUP_THREADS="$RIGFORGE_THREADS"
    elif [ -f "$WORKER_ROOT/tune-overrides.json" ]; then
        RX_SETUP_THREADS=$(jq -r '.cpu.rx // empty' "$WORKER_ROOT/tune-overrides.json" 2>/dev/null) || RX_SETUP_THREADS=""
    fi
    case "$RX_SETUP_THREADS" in -1 | '' | *[!0-9]*) RX_SETUP_THREADS="" ;; esac
}

# Read-only GRUB computation shared by tune_kernel (the mutation half) and the setup --dry-run plan
# (#146): sets MANAGED (params we manage), CURRENT (the live cmdline), MERGED (#19 merge — never
# clobbers params the user/distro set). Callers guard on proposed-grub.sh + $GRUB_DEFAULT existing.
_grub_proposed() {
    MANAGED=$(RX_THREADS="$RX_SETUP_THREADS" "$SCRIPT_DIR/util/proposed-grub.sh" -q)
    MANAGED="${MANAGED#quiet splash }"
    CURRENT=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_DEFAULT" | head -n1)
    MERGED=$(grub_merge_cmdline "$MANAGED" "$CURRENT")
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

    _rx_setup_threads
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
        _grub_proposed

        if [ "$CURRENT" = "$MERGED" ]; then
            log "GRUB is already configured with optimal HugePages settings."
        else
            sudo cp "$GRUB_DEFAULT" "$GRUB_DEFAULT.bak"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$(_sed_escape_replacement "$MERGED")\"|" "$GRUB_DEFAULT"
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
    local target="$SCRIPT_DIR/rigforge.sh" link="$BIN_DIR/rigforge"
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
    if $sudo_pfx rm -f "$link" 2>/dev/null && $sudo_pfx ln -s "$target" "$link" 2>/dev/null; then
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
        warn "Please run 'sudo reboot' now."
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
    # Privilege separation (#140): the unprivileged miner must keep write access to its autosaved
    # config and its log after the blanket re-own above. Every re-owning verb routes through here.
    if [ -n "${MINER_USER:-}" ] && [ "$OS_TYPE" = Linux ]; then
        sudo chown "$MINER_USER:$MINER_USER" "$WORKER_ROOT/xmrig/build/config.json" "$WORKER_ROOT/xmrig.log" 2>/dev/null || true
    fi
}

# setup --dry-run (#146): a numbered plan of exactly what setup WOULD do on this machine with this
# config, computed from read-only probes only — no sudo, no writes, no modprobe. A dedicated printer
# (not a DRY_RUN flag threaded through the mutating functions) because a printer can't mutate by
# construction; the drift risk is covered by a test asserting every CURRENT_STEP phrase in main()
# appears here. Step lines reuse those exact phrases — they're load-bearing for that test.
_setup_plan() {
    local n=0
    _p() {
        n=$((n + 1))
        printf '%2d. %s: %s\n' "$n" "$1" "$2"
    }
    echo "setup --dry-run — the plan for this machine ($(hostname), $OS_TYPE):"
    if command -v jq >/dev/null 2>&1; then
        _p "verifying prerequisites" "jq found; nothing to install"
    else
        _p "verifying prerequisites" "install jq (config-dependent details below unavailable until it exists)"
        echo "Dry run — nothing was changed. Run 'sudo $0 setup' to apply."
        return 0
    fi
    if [ ! -f "$CONFIG_JSON" ]; then
        _p "ensuring config exists" "would create $CONFIG_JSON interactively (pool URL prompt) — the rest of the plan depends on it"
        echo "Dry run — nothing was changed. Run 'sudo $0 setup' to apply."
        return 0
    fi
    _p "ensuring config exists" "use the existing $CONFIG_JSON"
    parse_config >/dev/null
    _p "parsing config" "pools: $(printf '%s' "$POOLS_JSON" | jq -r '[.[].url] | join(", ")' 2>/dev/null)"
    decide_rebuild >/dev/null 2>&1 || true
    if [ "$XMRIG_REBUILD" = true ]; then
        _p "checking the build" "build XMRig $XMRIG_VERSION (commit ${XMRIG_COMMIT:0:12}) — clone + compile"
    else
        _p "checking the build" "skip the build — XMRig $XMRIG_VERSION already built at the pinned commit"
    fi
    _p "preparing workspace" "workspace at $WORKER_ROOT (an existing prior install would be archived first)"
    if [ "$OS_TYPE" = "Darwin" ]; then
        _p "installing dependencies" "install/verify via brew: cmake libuv openssl hwloc"
    elif _detect_pkg_manager; then
        local _md
        _md="$(_missing_deps)"
        if [ -n "$_md" ]; then
            _p "installing dependencies" "install packages:$_md"
        else
            _p "installing dependencies" "all dependencies already installed"
        fi
    else
        _p "installing dependencies" "no supported package manager found — manual install"
    fi
    if [ "$XMRIG_REBUILD" = true ]; then
        _p "compiling XMRig" "compile in $WORKER_ROOT/xmrig/build and record the binary SHA-256"
    else
        _p "compiling XMRig" "skipped (already built; SHA-256 record kept)"
    fi
    _p "generating XMRig config" "write $WORKER_ROOT/xmrig/build/config.json$([ -f "$WORKER_ROOT/tune-overrides.json" ] && echo ' + overlay tune-overrides.json')"
    if [ "$OS_TYPE" != "Linux" ]; then
        _p "tuning the kernel" "skipped (not supported on $OS_TYPE — no HugePages/MSR here)"
        _p "configuring limits" "skipped (Linux-only)"
        _p "installing the service" "none on macOS — run via '$0 start' (nohup) or the launchd login agent"
    else
        local _msr _pages="(proposed-grub.sh missing — fallback 3072)" _grubline="GRUB: will check at run time" _reboot=""
        _msr="write msr to $MODULES_LOAD_DIR/msr.conf (module autoload)"
        [ -e "$MODULES_LOAD_DIR/msr.conf" ] && _msr="msr module already configured"
        if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ]; then
            _rx_setup_threads
            _pages=$(RX_THREADS="$RX_SETUP_THREADS" "$SCRIPT_DIR/util/proposed-grub.sh" --runtime 2>/dev/null) || _pages="?"
            if [ -f "$GRUB_DEFAULT" ]; then
                _grub_proposed
                if [ "$CURRENT" = "$MERGED" ]; then
                    _grubline="GRUB already configured (no reboot needed for it)"
                else
                    _grubline="GRUB cmdline: '$CURRENT' -> '$MERGED'"
                    _reboot=" — a reboot WILL be required"
                fi
            fi
        fi
        _p "tuning the kernel" "$_msr; reserve $_pages 2MB HugePages (runtime sysctl); $_grubline$_reboot"
        local _f1="hugetlbfs /dev/hugepages hugetlbfs defaults 0 0" _f2="hugetlbfs_1g $HUGEPAGES_1G_DIR hugetlbfs pagesize=1G 0 0" _add=""
        grep -qxF "$_f1" "$FSTAB" 2>/dev/null || _add=" '$_f1'"
        grep -qxF "$_f2" "$FSTAB" 2>/dev/null || _add="$_add '$_f2'"
        if [ -n "$_add" ]; then
            _p "configuring limits" "append to $FSTAB:$_add; memlock unlimited for $REAL_USER in $LIMITS_CONF"
        else
            _p "configuring limits" "fstab already configured; memlock unlimited for $REAL_USER in $LIMITS_CONF"
        fi
        _p "installing the service" "render systemd/xmrig.service.template -> $SYSTEMD_DIR/$SERVICE_NAME.service (User=${MINER_USER:-root}), daemon-reload, enable --now"
    fi
    case "$AUTOTUNE_MODE" in
    disabled) _p "configuring autotune" "no periodic timer (autotune disabled) — an installed one would be removed" ;;
    *) _p "configuring autotune" "install rigforge-autotune.timer (monthly re-tune, target: $AUTOTUNE_MODE)" ;;
    esac
    case "$WATCHDOG_MODE" in
    disabled) _p "configuring the watchdog" "no watchdog timer (watchdog disabled) — an installed one would be removed" ;;
    *) _p "configuring the watchdog" "install rigforge-watchdog.timer (health check every ${WATCHDOG_INTERVAL_MIN}min${MAX_TEMP_C:+, thermal cutoff ${MAX_TEMP_C}°C})" ;;
    esac
    if [ "$API_MODE" = enabled ]; then
        _p "configuring the sister API" "install rigforge-api.service (:$API_PORT) + the 15s refresh timer"
    else
        _p "configuring the sister API" "disabled — installed units would be removed"
    fi
    if [ "$CONTROL_MODE" = enabled ]; then
        _p "configuring the control path" "install rigforge-control.service (:$CONTROL_PORT, writable, token+source pinned) + the staged applier"
    else
        _p "configuring the control path" "disabled — installed units would be removed"
    fi
    if [ -n "${API_ALLOW_FROM:-}" ]; then
        _p "configuring the API firewall" "nftables 'inet rigforge' table scoping the API port(s) to $API_ALLOW_FROM + loopback"
    else
        _p "configuring the API firewall" "no api_allow_from — no firewall scoping (an installed table would be removed)"
    fi
    if [ "$ADD_TO_PATH" = true ]; then
        _p "linking the rigforge command" "symlink $BIN_DIR/rigforge -> $SCRIPT_DIR/rigforge.sh"
    else
        _p "linking the rigforge command" "add_to_path is off — no symlink"
    fi
    _p "reconciling file ownership" "chown the worker tree back to $REAL_USER${MINER_USER:+ (config+log to $MINER_USER)}"
    _p "finishing up" "print the summary$([ "$OS_TYPE" = Linux ] && echo ' (and the reboot notice when HugePages changed)')"
    echo "Dry run — nothing was changed. Run 'sudo $0 setup' to apply."
}

main() {
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
        --dry-run)
            _setup_plan
            return 0
            ;;
        *) error "Unknown option for setup: '$_arg'. Run '$0 help'." ;;
        esac
    done
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
    CURRENT_STEP="configuring the watchdog"
    install_watchdog
    CURRENT_STEP="configuring the sister API"
    install_api
    CURRENT_STEP="configuring the control path"
    install_control
    CURRENT_STEP="configuring the API firewall"
    install_api_firewall
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
        [ -n "$hr" ] && awk -v hr="$hr" 'BEGIN{exit !(hr > 0)}' 2>/dev/null && return 0
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

# upgrade --check: compare the local VERSION against GitHub's latest release tag, on demand only.
# This is the one place RigForge talks to GitHub's API, and it runs exactly when the operator types
# it — never scheduled, never piggybacked on another verb (SECURITY.md's "no version ping" promise
# stands because the check is explicit). Always returns 0: an update *hint* must never break a
# script that calls it. Reads one file and one URL; no parse_config, no root, no other side effects.
_upgrade_check() {
    local local_v remote_v url body highest
    local_v=$(tr -d '[:space:]' <"$SCRIPT_DIR/VERSION" 2>/dev/null || true) # guard inside the $() (#210)
    if [ -z "$local_v" ]; then
        warn "No VERSION file at $SCRIPT_DIR/VERSION — can't compare against the latest release."
        return 0
    fi
    body=$(curl -fsS --max-time 5 "https://api.github.com/repos/p2pool-starter-stack/rigforge/releases/latest" 2>/dev/null || true)
    if [ -z "$body" ]; then
        warn "Couldn't reach GitHub to check for a newer release — try again later."
        return 0
    fi
    remote_v=$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null || true)
    url=$(printf '%s' "$body" | jq -r '.html_url // empty' 2>/dev/null || true)
    remote_v="${remote_v#v}"
    if [ -z "$remote_v" ]; then
        warn "Couldn't reach GitHub to check for a newer release — try again later."
        return 0
    fi
    if [ "$local_v" = "$remote_v" ]; then
        log "RigForge $local_v is the latest release."
        return 0
    fi
    highest=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -n1)
    if [ "$highest" = "$remote_v" ]; then
        log "A newer RigForge is available: $remote_v (you have $local_v)."
        if [ -n "$url" ]; then
            log "Release notes: $url"
        fi
        log "Update: cd $SCRIPT_DIR && git pull && sudo $0 upgrade  (tag-pinned fleets: git fetch --tags && git checkout v$remote_v)"
    else
        log "RigForge $local_v is ahead of the latest release ($remote_v) — development build."
    fi
    return 0
}

# Upgrade flow: rebuild + restart ONLY if the pinned XMRig version/commit changed. Skips the
# setup-only steps (dependency install, kernel tuning) — those don't change on a version bump.
upgrade() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        --check)
            _upgrade_check
            return 0
            ;;
        *) error "Unknown option for upgrade: '$arg'. Run '$0 help'." ;;
        esac
    done
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
    local raw="$1" trimmed
    if [ "$raw" = "DYNAMIC_HOME" ] || [ -z "$raw" ] || [ "$raw" = "null" ]; then
        echo "$SCRIPT_DIR/data/worker"
    elif [[ "$raw" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$raw" != *..* ]]; then
        # Syntactically valid is not enough: HOME_DIR feeds mkdir/cd/`sudo rm -rf`, so the
        # filesystem's own top levels ("/", "/etc", bare "/home", ...) must fail closed too. (#135)
        # ponytail: strips one trailing slash; the charset regex above already blocks anything
        # hostile — this is a fat-finger guard, not a security boundary.
        trimmed="${raw%/}"
        case "${trimmed:-/}" in
        / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var | /Applications | /Library | /System | /Users | /Volumes | /private)
            return 1
            ;;
        esac
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
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for uninstall: '$arg'. Run '$0 help'." ;;
        esac
    done
    if [ "$assume_yes" -eq 0 ]; then
        warn "This removes the xmrig service and reverts RigForge's system changes (fstab, limits, modules, GRUB)."
        # `|| true`: EOF on a piped/non-interactive stdin leaves ANS empty, so the default-No abort
        # below runs instead of the ERR trap (same guard as the setup prompts).
        read -r -p "Proceed with uninstall? (y/N): " ANS || true
        [[ "$ANS" =~ ^[Yy] ]] || {
            log "Aborted."
            return 0
        }
    fi

    # Work out the worker root the same way parse_config would, without requiring a valid config.
    local worker_root
    worker_root=$(_worker_root_from_config)

    # 1. systemd service (+ the optional autotune timer, #46)
    local _mu
    _mu=$(jq -r '.miner_user // empty' "$CONFIG_JSON" 2>/dev/null || true)
    if [ -n "$_mu" ] && id -u "$_mu" >/dev/null 2>&1; then
        # Exact-removal discipline: we only delete what we provably created, and we can't prove
        # that for a user. An inert nologin user is safer than a wrong userdel.
        log "Left system user '$_mu' in place — remove it yourself with: sudo userdel $_mu"
    fi
    if [ -f "$SYSTEMD_DIR/rigforge-api.socket" ] || [ -f "$SYSTEMD_DIR/rigforge-api.service" ]; then
        sudo systemctl disable --now rigforge-api.socket rigforge-api.service rigforge-api-refresh.timer 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/rigforge-api.socket" "$SYSTEMD_DIR/rigforge-api@.service" \
            "$SYSTEMD_DIR/rigforge-api.service" "$SYSTEMD_DIR/rigforge-api-refresh.service" "$SYSTEMD_DIR/rigforge-api-refresh.timer"
    fi
    if [ -f "$SYSTEMD_DIR/rigforge-control.service" ] || [ -f "$SYSTEMD_DIR/rigforge-control-apply.path" ]; then
        sudo systemctl disable --now rigforge-control.service rigforge-control-apply.path 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/rigforge-control.service" "$SYSTEMD_DIR/rigforge-control-apply.service" "$SYSTEMD_DIR/rigforge-control-apply.path"
    fi
    command -v nft >/dev/null 2>&1 && sudo nft destroy table inet rigforge 2>/dev/null || true
    if [ -f "$SYSTEMD_DIR/rigforge-autotune.timer" ]; then
        sudo systemctl disable --now rigforge-autotune.timer 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/rigforge-autotune.timer" "$SYSTEMD_DIR/rigforge-autotune.service"
    fi
    if [ -f "$SYSTEMD_DIR/rigforge-watchdog.timer" ]; then
        sudo systemctl disable --now rigforge-watchdog.timer 2>/dev/null || true
        sudo rm -f "$SYSTEMD_DIR/rigforge-watchdog.timer" "$SYSTEMD_DIR/rigforge-watchdog.service"
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
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$(_sed_escape_replacement "$stripped")\"|" "$GRUB_DEFAULT"
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
    local z="${THERMAL_ZONE:-/sys/class/thermal/thermal_zone0/temp}" h n
    if [ -r "$z" ]; then
        awk '{printf "%.1f", $1/1000}' "$z" 2>/dev/null
        return 0
    fi
    # No thermal zone: fall back to the CPU hwmon — k10temp (AMD) / coretemp (Intel), same
    # millidegree format (#208). None of the production boards exposes a thermal_zone, so without
    # this the watchdog's max_temp_c and tune's temperature sampling are blind on the real fleet.
    # Still best-effort: nothing readable -> empty, and every thermal consumer skips (a missing
    # sensor must never stop a healthy miner). NOTE k10temp reports Tctl — a control temperature
    # that runs high by design; check the live reading before choosing a cutoff.
    for h in "${HWMON_DIR:-/sys/class/hwmon}"/hwmon*; do
        n=$(cat "$h/name" 2>/dev/null || true)
        case "$n" in
        k10temp | coretemp)
            [ -r "$h/temp1_input" ] && awk '{printf "%.1f", $1/1000}' "$h/temp1_input" 2>/dev/null
            return 0
            ;;
        esac
    done
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
    local _hist=0 clear=0 target_set=0 now=0 now_long=0
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
        --now) now=1 ;;                      # quick on-demand live re-tune (= --short); the 'autotune' engine
        --short) now=1 ;;                    # explicit quick pass — the default depth for --now
        --long) TUNE_MODE=live now_long=1 ;; # full all-knob LIVE sweep (= --live), the thorough re-tune
        --history) TUNE_HISTORY=1 ;;         # show current tuning + last run + auto-tune decisions, then exit
        *) error "Unknown option for tune: '$1' (use --now, --short, --long, --live, --bench, --confirm, --efficiency, --perf, --history, or --clear)." ;;
        esac
        shift
    done

    # 'tune --now' (a.k.a. --short) is the on-demand live re-tune: a quick convergent pass against the
    # *running* miner (it IS the 'autotune' engine). 'tune --now --long' instead runs the FULL all-knob
    # live sweep — --long set TUNE_MODE=live and now_long above, so we fall through to the full tune below
    # rather than the quick engine. Exposing all of this under 'tune' gives one mental model — every manual
    # tune lives under 'tune' — and reserves "autotune" for the scheduled feature (config key + timer). The
    # 'autotune' verb still works as an alias for the quick pass, and is the verb the timer runs.
    if [ "$now" = 1 ] && [ "$now_long" != 1 ]; then
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
    # Cleanup is armed the moment the temp dir exists — an ERR-abort anywhere below (live mode
    # included) must not leak it. _tune_bench_cleanup is idempotent and only restarts the service
    # when _TUNE_SVC_STOPPED says the bench path stopped it. (#135)
    trap '_tune_bench_cleanup' EXIT
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

    if [ -z "$G_p" ] || awk -v hr="$G_best" 'BEGIN{exit !(hr <= 0)}'; then
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
    if awk -v w="$win_hr" -v b="$base_hr" -v m="$margin" 'BEGIN{exit !(w > b * (1 + m))}'; then
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
    if [ "$1" = efficiency ] && [ -n "$3" ] && awk -v w="$3" 'BEGIN{exit !(w > 0)}'; then
        awk -v h="$2" -v w="$3" 'BEGIN{printf "%.4f", h / w}'
    else
        printf '%s' "${2:-0}"
    fi
}
# Human-readable sample for the log line: "10700 H/s" or "10700 H/s, 83.10 W, 128.84 H/s/W".
_autotune_fmt() { # <target> <hr> <watts>
    if [ "$1" = efficiency ] && [ -n "$3" ] && awk -v w="$3" 'BEGIN{exit !(w > 0)}'; then
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
        if awk -v sc="$sc" -v b="$best_score" 'BEGIN{exit !(sc > b)}'; then
            best_mode="$m"
            best_score="$sc"
        fi
    done

    # Adopt the winner only if it beats the baseline by the margin (noise guard); else keep the current mode.
    if [ "$best_mode" != "$cur" ] && awk -v b="$best_score" -v base="$base_score" -v m="$margin" 'BEGIN{exit !(b > base * (1 + m))}'; then
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
# Raw /2/summary JSON from the worker API, or nothing when curl is missing/unreachable (#143).
_read_api_summary() {
    local url="http://127.0.0.1:8080/2/summary"
    command -v curl >/dev/null 2>&1 || return 0
    # The API is open (read-only) with no token by default; only send a Bearer when ACCESS_TOKEN is set.
    # XMRig 401s a token it never asked for, and curl -f (exit 22) would then abort the caller under set -e.
    # Branch rather than an empty-array curl arg, which also trips set -u on bash 3.2 (macOS).
    if [ -n "${ACCESS_TOKEN:-}" ]; then
        curl -fsS --max-time 5 -H "Authorization: Bearer $ACCESS_TOKEN" "$url" 2>/dev/null
    else
        curl -fsS --max-time 5 "$url" 2>/dev/null
    fi
}

_read_api_hashrate() {
    if [ -n "${API_CMD:-}" ]; then
        eval "$API_CMD"
        return
    fi
    _read_api_summary | jq -r '.hashrate.total[0] // empty' 2>/dev/null
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
        *) error "Unknown option for backup: '$arg'. Run '$0 help'." ;;
        esac
    done
    [ -f "$CONFIG_JSON" ] || error "No config.json to back up. Run 'setup' first."

    local wr stage included="config.json" f
    wr=$(_worker_root_from_config)
    stage=$(mktemp -d)
    cp "$CONFIG_JSON" "$stage/config.json"
    # The tuning files live under the worker root; include whichever exist (a fresh worker has none yet).
    for f in tune-overrides.json rigforge-tune.json rigforge-bios.json; do
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
    log "Restore with: $0 restore $archive"
}

# restore [-y|--yes] <archive>: put config.json + tuning back from a backup archive.
restore() {
    local assume_yes=0 archive="" arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        -*) error "Unknown option for restore: '$arg'. Run '$0 help'." ;;
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
    _stamp_config_meta restore # #254: attribute this config to a restore (bumps revision if it differs)
    local restored="config.json" wr f
    wr=$(_worker_root_from_config)
    for f in tune-overrides.json rigforge-tune.json rigforge-bios.json; do
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

# Structural secret redaction for the support bundle (#147): jq path operations only — NEVER sed
# over secret values (a regex that misses one quoting variant leaks; deleting/replacing a JSON path
# can't). Tokens and pool passwords go entirely; the pool user (usually a wallet — pseudonymous but
# it publicly links every rig and payout to one identity) keeps first-4…last-4 so a maintainer can
# still tell rigs apart and spot the same-wallet-wrong-field misconfig.
_redact_config() {
    jq 'def mask: if length > 12 then .[0:4] + "…" + .[-4:] else "<redacted>" end; (if (.ACCESS_TOKEN // "") != "" then .ACCESS_TOKEN = "<redacted>" else . end) | (if .http?."access-token" != null then .http."access-token" = "<redacted>" else . end) | (if .pools then .pools = (.pools | map((if (.pass // "") != "" then .pass = "<redacted>" else . end) | (if (.user // "") != "" then .user = (.user | mask) else . end))) else . end)'
}

# support-bundle (#147): everything a maintainer needs to debug a miner, nothing secret, one local
# tarball (never uploaded anywhere — the no-phone-home posture in SECURITY.md). No root required;
# root-only probes inside doctor degrade to their own warn lines, which is itself useful signal.
support_bundle() {
    local arg
    for arg in "$@"; do
        error "Unknown option for support-bundle: '$arg'. Run '$0 help'."
    done
    [ -f "$CONFIG_JSON" ] || error "No config.json to collect. Run 'setup' first."

    local wr stage collected="" skipped="" f
    wr=$(_worker_root_from_config)
    stage=$(mktemp -d)
    _take() { collected="$collected $1"; }
    _skip() { skipped="$skipped $1"; }

    cmd_version >"$stage/version.txt" && _take version.txt
    # Subprocess, not a function call: doctor's error-exits can't kill the bundle. Strip ANSI codes.
    ("$0" doctor </dev/null 2>&1 || true) | sed -e $'s/\x1b\[[0-9;]*m//g' >"$stage/doctor.txt" && _take doctor.txt
    # Fail closed: if jq can't redact a file, the file stays OUT of the bundle — never the original.
    if _redact_config <"$CONFIG_JSON" >"$stage/config.redacted.json" 2>/dev/null; then
        _take config.redacted.json
    else
        rm -f "$stage/config.redacted.json"
        _skip "config.redacted.json(unparseable)"
    fi
    if [ -n "$wr" ] && [ -f "$wr/xmrig/build/config.json" ]; then
        if _redact_config <"$wr/xmrig/build/config.json" >"$stage/xmrig-config.redacted.json" 2>/dev/null; then
            _take xmrig-config.redacted.json
        else
            rm -f "$stage/xmrig-config.redacted.json"
            _skip "xmrig-config.redacted.json(unparseable)"
        fi
    fi
    if [ -n "$wr" ] && [ -f "$wr/xmrig.log" ]; then
        tail -n 500 "$wr/xmrig.log" >"$stage/xmrig.log.tail" 2>/dev/null && _take xmrig.log.tail
    fi
    for f in tune-overrides.json rigforge-tune.json; do
        [ -n "$wr" ] && [ -f "$wr/$f" ] && cp "$wr/$f" "$stage/$f" && _take "$f"
    done
    for f in "$SERVICE_NAME.service" rigforge-autotune.service rigforge-autotune.timer; do
        [ -f "$SYSTEMD_DIR/$f" ] && cp "$SYSTEMD_DIR/$f" "$stage/$f" 2>/dev/null && _take "$f"
    done
    {
        uname -a
        if [ "$OS_TYPE" = Linux ]; then
            lscpu 2>/dev/null || true
            free -h 2>/dev/null || true
        else
            sysctl -n machdep.cpu.brand_string 2>/dev/null || true
            sysctl -n hw.memsize 2>/dev/null || true
        fi
    } >"$stage/system.txt" 2>/dev/null && _take system.txt
    jq -n --arg v "$(cmd_version)" --arg host "$(hostname 2>/dev/null)" --arg files "${collected# }" --arg skipped "${skipped# }" \
        '{rigforge: $v, source_host: $host, files: ($files | split(" ")), not_collected: (["journalctl (system-wide)", "shell history", "unredacted configs", "backups/"] + (if $skipped != "" then ($skipped | split(" ")) else [] end))}' \
        >"$stage/manifest.json" 2>/dev/null || true

    local stamp archive
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$SCRIPT_DIR/rigforge-support-$(hostname 2>/dev/null)-$stamp.tar.gz"
    (umask 077 && tar -czf "$archive" -C "$stage" .)
    rm -rf "$stage"
    chmod 600 "$archive" 2>/dev/null || true

    log "Collected:${collected}"
    log "NOT collected: journalctl, shell history, unredacted configs, ./backups (tokens and pool passwords are redacted; pool user/wallet is masked to first-4…last-4)."
    log "Bundle: $archive"
    log "Review the extracted contents before attaching it to a public issue."
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

# One-glance live summary from a single /2/summary fetch (#143). Facts only, no ✓/! judgment
# markers (that's doctor's job); plain aligned lines stay grep-friendly. Never sudo, never prompts.
_status_api_summary() {
    local body hs pool up acc rej hp
    body=$(_read_api_summary)
    if [ -z "$body" ]; then
        echo "RigForge: worker API not reachable at 127.0.0.1:8080 (miner stopped or still starting)."
        return 0
    fi
    # One jq fork for every field, tab-separated (bash-3.2-safe read into locals).
    IFS=$(printf '\t') read -r hs pool up acc rej hp < <(printf '%s' "$body" |
        jq -r '[(.hashrate.total[0] // 0), (.connection.pool // "?"), (.uptime // 0),
                (.connection.accepted // 0), (.connection.rejected // 0), (.hugepages // "")] | @tsv' 2>/dev/null) || true
    [ -n "${hs:-}" ] || return 0 # half-up API / unparseable body: stay quiet, platform block follows
    printf '  %-10s %s H/s\n' "Hashrate:" "$hs"
    printf '  %-10s %s\n' "Pool:" "$pool"
    printf '  %-10s %s\n' "Uptime:" "$(_render_duration "$up")"
    printf '  %-10s %s accepted / %s rejected\n' "Shares:" "$acc" "$rej"
    [ -n "$hp" ] && printf '  %-10s %s\n' "HugePages:" "$hp"
    echo
}

# Seconds -> "Nd Nh Nm" (integer math only; no bc).
_render_duration() {
    local s="${1:-0}" d h m
    case "$s" in *[!0-9]*) s=0 ;; esac
    d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
    if [ "$d" -gt 0 ]; then printf '%dd %dh %dm' "$d" "$h" "$m"; elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

svc_status() {
    [ "$OS_TYPE" = "Linux" ] || {
        mac_status
        # parse_config in a subshell: it error-exits on a bad config, and ACCESS_TOKEN only exists
        # after it — a bad/missing config must degrade to the platform block, never crash status.
        (parse_config >/dev/null 2>&1 && _status_api_summary) || true
        return
    }
    (parse_config >/dev/null 2>&1 && _status_api_summary) || true
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

# Tab completion (#145): PRINT a completion script, install nothing — the operator opts in with
# `source <(rigforge completion bash)` or by writing it to the completions dir. Static on purpose
# (zero deps, no callback into rigforge at tab-time); the suite diffs _rigforge_verbs against the
# dispatch case, so adding a verb without updating this list fails CI. The internal hyphenated
# verbs (api-refresh, msr-apply, control-apply) and the -v/-h flag spellings are deliberately not completed.
_completion_bash() {
    cat <<'RIGFORGE_COMPLETION'
_rigforge_verbs="setup upgrade uninstall tune autotune watchdog doctor bios status logs start up stop down restart enable disable apply bench backup restore support-bundle version help completion"
_rigforge() {
    local cur verb
    cur="${COMP_WORDS[COMP_CWORD]}"
    verb="${COMP_WORDS[1]:-}"
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "$_rigforge_verbs" -- "$cur"))
        return
    fi
    case "$verb" in
    tune) COMPREPLY=($(compgen -W "--now --short --long --live --bench --confirm --efficiency --perf --history --clear" -- "$cur")) ;;
    setup | apply) COMPREPLY=($(compgen -W "--dry-run" -- "$cur")) ;;
    upgrade) COMPREPLY=($(compgen -W "--check" -- "$cur")) ;;
    bios) COMPREPLY=($(compgen -W "--perf --efficiency" -- "$cur")) ;;
    uninstall | backup) COMPREPLY=($(compgen -W "-y --yes" -- "$cur")) ;;
    restore) COMPREPLY=($(compgen -W "-y --yes" -- "$cur") $(compgen -f -- "$cur")) ;;
    completion) COMPREPLY=($(compgen -W "bash zsh" -- "$cur")) ;;
    esac
}
complete -F _rigforge rigforge rigforge.sh ./rigforge.sh
RIGFORGE_COMPLETION
}

cmd_completion() {
    case "${1:-}" in
    bash) _completion_bash ;;
    zsh)
        # bashcompinit runs the same script under zsh — one verb list, not two to drift apart.
        echo "autoload -U +X bashcompinit && bashcompinit"
        _completion_bash
        ;;
    *) error "Usage: $0 completion bash|zsh" ;;
    esac
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
# apply --dry-run (#146): the three-line plan — symmetric with setup --dry-run.
_apply_plan() {
    parse_config >/dev/null
    echo "apply --dry-run — the plan:"
    echo " 1. regenerate $WORKER_ROOT/xmrig/build/config.json$([ -f "$WORKER_ROOT/tune-overrides.json" ] && echo ' (+ overlay tune-overrides.json)')"
    if [ "$OS_TYPE" = Linux ]; then
        echo " 2. re-render the unit (User=${MINER_USER:-root}) and restart $SERVICE_NAME"
    else
        echo " 2. restart the miner manually ('$0 restart') — no service on $OS_TYPE"
    fi
    echo " 3. reconcile the autotune timer + sister API + firewall to config (autotune: $AUTOTUNE_MODE, api: $API_MODE)"
    echo "Dry run — nothing was changed. Run 'sudo $0 apply' to apply."
}

apply() {
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
        --dry-run)
            _apply_plan
            return 0
            ;;
        *) error "Unknown option for apply: '$_arg'. Run '$0 help'." ;;
        esac
    done
    if [ "$OS_TYPE" = Linux ] && [ -f "$SYSTEMD_DIR/$SERVICE_NAME.service" ]; then
        # A miner_user change only lands in the unit file — re-render + daemon-reload so the
        # _apply_runtime restart below picks it up (#140).
        parse_config
        _ensure_miner_user
        NFT_PATH=$(command -v nft || echo "/usr/sbin/nft")
        export NFT_PATH
        export BUILD_DIR="$WORKER_ROOT/xmrig/build"
        CPUPOWER_PATH=$(command -v cpupower || echo "/usr/bin/cpupower")
        export CPUPOWER_PATH
        _render_xmrig_unit
        sudo systemctl daemon-reload 2>/dev/null || true
    fi
    _apply_runtime
    if [ "$OS_TYPE" = Linux ]; then
        install_autotune >/dev/null 2>&1 || true
        install_watchdog >/dev/null 2>&1 || true
        install_api >/dev/null 2>&1 || true
        install_control >/dev/null 2>&1 || true
        install_api_firewall || true
        _autotune_apply_notice
    fi
    # #254: record who put this config into effect. Default source "local" (a bare `apply` after a
    # hand-edit); control-apply and restore set RIGFORGE_CONFIG_SOURCE first. No-op unless the writable
    # config actually changed (so tune/autotune restarts, which reuse _apply_runtime not apply(), and
    # a re-apply of the same config, never bump the revision).
    _stamp_config_meta "${RIGFORGE_CONFIG_SOURCE:-local}" "${RIGFORGE_CONFIG_CHANGE_ID:-}"
}

# --- Writable control path applier (#236) ---

# Merge a staged control change into config.json — the security-critical core, isolated so it is
# testable without systemd or a live miner. Only allowlisted keys are applied; the merged result
# must pass parse_config BEFORE anything touches disk, so an invalid change never lands; only then
# is the old config snapshotted to config-backups/ (history + recovery) and the new one written
# atomically + fsynced. Echoes "committed <backup>" or "rejected <reason>"; returns 0 / 1.
_control_commit() { # <staged.json> <backups-dir>
    local staged="$1" backups="$2"
    local CONTROL_WRITABLE_KEYS="pools DONATION autotune watchdog watchdog_interval_min max_temp_c"
    local change allow badkeys stamp backup cand msg
    change=$(cat "$staged" 2>/dev/null) || {
        echo "rejected unreadable-staged-file"
        return 1
    }
    # Structural re-validation (never trust the spool blindly): a non-empty JSON object, keys ⊆ allowlist.
    printf '%s' "$change" | jq -e 'type == "object" and length > 0' >/dev/null 2>&1 || {
        echo "rejected not-a-config-object"
        return 1
    }
    allow=$(jq -n --arg s "$CONTROL_WRITABLE_KEYS" '$s | split(" ")')
    badkeys=$(printf '%s' "$change" | jq -r --argjson a "$allow" '[keys[] | select(. as $k | $a | index($k) | not)] | join(",")')
    if [ -n "$badkeys" ]; then
        echo "rejected non-writable-keys:$badkeys"
        return 1
    fi
    # #257: safety — the control path is for TUNING, not removing thermal protection. Refuse a staged
    # change that disables the watchdog or unsets/out-of-bands max_temp_c. A local `rigforge.sh apply`
    # still can (the operator is physically present); only the remote/spool path is constrained. The
    # remote entry (util/control-server.py unsafe_reasons()) already rejects these with a 400 before
    # staging — this is the applier-side backstop for anything staged out-of-band (drift-tested).
    local wd_new mt_new
    wd_new=$(printf '%s' "$change" | jq -r 'if has("watchdog") then (.watchdog | tostring | ascii_downcase) else "-" end')
    case "$wd_new" in disabled | false | off | none | "" | null)
        echo "rejected safety-watchdog-cannot-be-disabled"
        return 1
        ;;
    esac
    if printf '%s' "$change" | jq -e 'has("max_temp_c")' >/dev/null 2>&1; then
        mt_new=$(printf '%s' "$change" | jq -r '.max_temp_c // ""')
        if [ -z "$mt_new" ] || ! [[ "$mt_new" =~ ^[0-9]+$ ]] || [ "$mt_new" -lt 40 ] || [ "$mt_new" -gt 110 ]; then
            echo "rejected safety-max_temp_c-out-of-band"
            return 1
        fi
    fi
    # Build the candidate: current config with ONLY the allowlisted staged keys overlaid (pools and
    # other arrays replace, scalars replace). Filter again so a stray key can never ride in.
    cand="$CONFIG_JSON.control.$$"
    if ! jq -n --slurpfile base "$CONFIG_JSON" --argjson chg "$change" --argjson a "$allow" '$base[0] * ($chg | with_entries(select(.key as $k | $a | index($k))))' >"$cand" 2>/dev/null; then
        rm -f "$cand"
        echo "rejected merge-failed"
        return 1
    fi
    # The merged config must be valid RigForge config BEFORE it lands — parse_config is the
    # authoritative semantic gate (pool shapes, ranges, the dual-auth rule). Run it isolated so a
    # failure can't corrupt the caller's globals, and so a bad change can never reach config.json.
    if ! msg=$( (CONFIG_JSON="$cand" && parse_config) 2>&1); then
        rm -f "$cand"
        echo "rejected invalid-config:$(printf '%s' "$msg" | grep -o '\[ERROR\][^\"]*' | head -1 | sed "s/'.*//")"
        return 1
    fi
    # Only now, with a valid candidate, snapshot the old config and commit. A backup is a HARD
    # precondition (ADR): never commit a change without first snapshotting the config it replaces —
    # if the snapshot can't be written, reject the whole change and leave config.json untouched.
    stamp=$(date -u +%Y%m%d-%H%M%S)
    backup="$backups/config-$stamp.json"
    if ! mkdir -p "$backups" || ! (umask 077 && cp "$CONFIG_JSON" "$backup"); then
        rm -f "$cand"
        echo "rejected backup-failed"
        return 1
    fi
    # config.json is secret-bearing (ACCESS_TOKEN, pool creds) and 0600 by contract; mv inherits the
    # candidate's mode, so pin it to 0600 BEFORE the rename or the live config goes world-readable.
    chmod 600 "$cand"
    # Durable: flush the candidate's data and the backup to disk, then atomically rename over
    # config.json (a crash leaves either the old file or the whole new one, never a torn config).
    sync
    mv -f "$cand" "$CONFIG_JSON"
    sync
    echo "committed $backup"
    return 0
}

# Prune config-backups/ to the retention cap and hand it to the operator so they can inspect or
# restore old configs without sudo (recovery = `cp config-backups/config-<stamp>.json config.json`
# then `sudo rigforge apply`). Override the cap with KEEP_CONFIG_BACKUPS.
_reown_config_backups() { # <backups-dir>
    local dir="$1" keep="${KEEP_CONFIG_BACKUPS:-20}" old
    # shellcheck disable=SC2012  # names are controlled (config-YYYYmmdd-HHMMSS.json); ls -t orders by recency
    old=$(ls -t "$dir"/config-*.json 2>/dev/null | tail -n +"$((keep + 1))" || true)
    if [ -n "$old" ]; then
        printf '%s\n' "$old" | while IFS= read -r f; do [ -n "$f" ] && rm -f "$f"; done
    fi
    if [ "$(id -u)" -eq 0 ] && [ -n "${REAL_USER:-}" ]; then sudo chown -R "$REAL_USER" "$dir" 2>/dev/null || true; fi
}

# The apply + liveness check control-apply gates its rollback on. Split out so tests can stub it.
_control_do_apply() {
    apply >/dev/null 2>&1
    _wait_miner_live "${CONTROL_LIVE_TRIES:-20}"
}

# Record the outcome for the receiver's GET /status (mode 644 so the DynamicUser server reads it back).
_control_status() { # <status-file> <status> <cid> <keys-csv> <reason> <backup>
    local f="$1" cid="$3" body cdir
    mkdir -p "$(dirname "$f")"
    # #257: warnings[] flags a safety-relevant change (watchdog / max_temp_c = thermal protection) even
    # when it was allowed, so the operator and the dashboard see it and can require an extra confirm.
    # Additive to the /status shape (a new warnings[] is a backward-compatible extension of the contract).
    body=$(jq -n --arg s "$2" --arg c "$3" --arg k "$4" --arg r "$5" --arg b "$6" --arg src control --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status: $s, change_id: $c, source: $src, applied_at: $when, changed_keys: ($k | split(",") | map(select(length > 0))), reason: (if $r == "" then null else $r end), backup: (if $b == "" then null else $b end), warnings: ($k | split(",") | map(select(. == "watchdog" or . == "max_temp_c")) | map("thermal protection changed: " + .))}')
    printf '%s' "$body" >"$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" && chmod 644 "$f" 2>/dev/null || true
    # #255: also index this outcome by change_id so a caller can GET /status?change_id=<cid> even after
    # a concurrent change overwrote the most-recent status.json. cid is server-generated 16-hex; guard it
    # anyway (it becomes a filename). Keep only the last ~20 outcomes.
    if [[ "$cid" =~ ^[0-9a-f]{16}$ ]]; then
        cdir="$(dirname "$f")/changes"
        mkdir -p "$cdir"
        printf '%s' "$body" >"$cdir/$cid.json.tmp.$$" 2>/dev/null && mv -f "$cdir/$cid.json.tmp.$$" "$cdir/$cid.json" && chmod 644 "$cdir/$cid.json" 2>/dev/null || true
        # shellcheck disable=SC2012  # names are controlled 16-hex; ls -t orders by recency
        ls -t "$cdir"/*.json 2>/dev/null | tail -n +21 | while IFS= read -r old; do [ -n "$old" ] && rm -f "$old"; done
    fi
}

# control-apply (#236): the privileged half of the writable control path, run by the
# rigforge-control-apply.path unit when the receiver stages a change. Applies the NEWEST staged
# change (older staged ones are superseded, so we never restart twice), reconciles the live miner,
# and rolls back to the pre-change snapshot if it doesn't come back live. Every failure path
# returns 0 with a recorded status — a bad request must not wedge the oneshot.
control_apply() {
    [ "$OS_TYPE" != "Linux" ] && error "control-apply is driven by the rigforge-control-apply.path unit and is Linux-only."
    parse_config
    local state="${RIGFORGE_CONTROL_STATE:-/var/lib/rigforge-control}" spool status backups
    spool="$state/spool"
    status="$state/status.json"
    backups="$SCRIPT_DIR/config-backups"
    local newest older cid change_keys result rc backup
    newest=$(ls -t "$spool"/pending-*.json 2>/dev/null | head -1) || true
    if [ -z "$newest" ]; then
        log "control-apply: nothing staged."
        return 0
    fi
    older=$(ls -t "$spool"/pending-*.json 2>/dev/null | tail -n +2) || true
    if [ -n "$older" ]; then
        printf '%s\n' "$older" | while IFS= read -r f; do [ -n "$f" ] && rm -f "$f"; done
    fi
    cid=$(basename "$newest" .json)
    cid="${cid#pending-}"
    change_keys=$(jq -r 'keys | join(",")' "$newest" 2>/dev/null || echo "?")
    result=$(_control_commit "$newest" "$backups")
    rc=$?
    rm -f "$newest"
    if [ "$rc" -ne 0 ]; then
        _control_status "$status" rejected "$cid" "$change_keys" "$result" ""
        warn "control-apply: change $cid rejected (${result#rejected }) — config.json untouched."
        return 0
    fi
    backup="${result#committed }"
    _reown_config_backups "$backups"
    log "control-apply: committed change $cid (keys: $change_keys); applying..."
    # #254: attribute this (and the rollback re-apply) to the control path with its change_id — the
    # nested apply()'s _stamp_config_meta reads these via dynamic scope.
    local RIGFORGE_CONFIG_SOURCE=control RIGFORGE_CONFIG_CHANGE_ID="$cid"
    if _control_do_apply; then
        _control_status "$status" applied "$cid" "$change_keys" "" "$backup"
        log "control-apply: change $cid applied."
    else
        warn "control-apply: change $cid did not come back live — rolling back to $backup."
        cp "$backup" "$CONFIG_JSON"
        _control_do_apply || true
        _control_status "$status" rolled_back "$cid" "$change_keys" "miner did not return to a live hashrate" "$backup"
    fi
    return 0
}

# Miner watchdog (#139): ONE health check per invocation — rigforge-watchdog.timer provides the
# cadence. Two jobs systemd's Restart= can't do: restart a WEDGED miner (process alive, 0 H/s or
# API dead — two consecutive strikes, so one restart-in-progress or dataset-init blip never
# triggers it), and an opt-in thermal cutoff (stop above max_temp_c, start again 5°C below — the
# hysteresis is fixed: big enough to outlast the post-restart heat-up on the rigs we run, small
# enough not to strand the miner, and one less knob to typo). State lives in $WORKER_ROOT (which
# _reown_worker already re-owns): a bare-integer strike counter and a thermal-hold marker file.
# The health probe reuses _read_api_hashrate (ACCESS_TOKEN Bearer handled there, token never
# logged) and _read_temp (THERMAL_ZONE/TUNE_TEMP_CMD overrides handled there).
watchdog() {
    if [ "$OS_TYPE" != "Linux" ]; then
        error "watchdog drives the live systemd service and is only supported on Linux."
    fi
    parse_config
    local fails_f="$WORKER_ROOT/watchdog.fails" hold_f="$WORKER_ROOT/watchdog.thermal-hold" t hr f
    t=$(_read_temp)
    # Thermal hold first: WE stopped the miner, so the not-active check below must not short-circuit
    # the recovery. Start again only once we're 5°C under the cutoff (or the cutoff was removed).
    if [ -f "$hold_f" ]; then
        if [ -z "$MAX_TEMP_C" ]; then
            rm -f "$hold_f"
            sudo systemctl start "$SERVICE_NAME" 2>/dev/null || true
            log "watchdog: max_temp_c is no longer set — thermal hold lifted, miner started."
        elif [ -n "$t" ] && awk -v t="$t" -v m="$MAX_TEMP_C" 'BEGIN { exit !(t < m - 5) }'; then
            rm -f "$hold_f"
            sudo systemctl start "$SERVICE_NAME" 2>/dev/null || true
            log "watchdog: temp ${t}°C is below $((MAX_TEMP_C - 5))°C — thermal hold lifted, miner started."
        else
            log "watchdog: thermal hold active (temp ${t:-unreadable}°C, resumes below $((MAX_TEMP_C - 5))°C) — miner stays stopped."
        fi
        return 0
    fi
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        rm -f "$fails_f"
        log "watchdog: $SERVICE_NAME is not active — dead-process recovery is systemd's (Restart=). Nothing to do."
        return 0
    fi
    # Thermal cutoff (opt-in). An unreadable temp skips this — a missing sensor must not stop a
    # healthy miner.
    if [ -n "$MAX_TEMP_C" ] && [ -n "$t" ] && awk -v t="$t" -v m="$MAX_TEMP_C" 'BEGIN { exit !(t > m) }'; then
        sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        touch "$hold_f"
        warn "watchdog: temp ${t}°C is above max_temp_c=${MAX_TEMP_C}°C — miner stopped (starts again below $((MAX_TEMP_C - 5))°C)."
        return 0
    fi
    # Wedge check: the API probe returns empty (unreachable) or the live hashrate (a float).
    # `|| true` INSIDE the substitution (#210): curl's nonzero exit (refused/timeout) rides the
    # pipeline out of the probe via pipefail; unguarded, the assignment errexits the whole check,
    # and a guard OUTSIDE the $() still lets the ERR trap fire in the subshell and spam "aborted
    # while" into the journal every tick. An unreachable API is a STRIKE, not a crash.
    hr=$(_read_api_hashrate || true)
    if [ -z "$hr" ] || awk -v h="$hr" 'BEGIN { exit !(h == 0) }'; then
        f=$(cat "$fails_f" 2>/dev/null || true) # guard inside the $() — see the probe above (#210)
        [[ "$f" =~ ^[0-9]+$ ]] || f=0
        f=$((f + 1))
        if [ "$f" -ge 2 ]; then
            rm -f "$fails_f"
            sudo systemctl restart "$SERVICE_NAME" 2>/dev/null || true
            warn "watchdog: miner wedged ($f consecutive checks with 0 H/s or an unreachable API) — restarted."
        else
            printf '%s\n' "$f" >"$fails_f"
            log "watchdog: unhealthy check ($f/2: 0 H/s or API unreachable) — restarting at 2 in a row."
        fi
        return 0
    fi
    rm -f "$fails_f"
    log "watchdog: healthy ($hr H/s)."
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
# <min configured MT/s> <max rated MT/s>" — channels from BOTH the Locator and Bank Locator (whichever
# yields more), the configured speed is the RUNNING one, the rated speed is the module's SPD/XMP "Speed".
# #78 compares the two speeds to spot a memory profile that isn't enabled. _cpu_eff_khz averages the
# per-core scaling_cur_freq (clock under load).
_mem_summary() {
    # One-line awk (kcov can't see coverage of a multi-line program inside a string): per Memory Device,
    # count populated DIMMs + distinct channels, and track the min configured (cf) and max rated (rt) speed.
    # Channels: desktop boards encode the channel in Bank Locator (`BANK 0`/`P0 CHANNEL A`); server boards
    # (EPYC/Threadripper) repeat one Bank Locator (`BANK 0`) for every DIMM and instead carry the channel in
    # the Locator's letter group (`DIMM_P0_A0`..`DIMM_P0_H0` = channels A..H). Count distinct channels in
    # EACH field and take whichever is larger, so server boards aren't mis-flagged as single-channel (#108).
    # Trailing `|| true`: dmidecode needs root, so a non-root `doctor` makes the pipeline non-zero under
    # `set -o pipefail`; without this the command substitution in doctor would trip errexit and abort the
    # whole health check. Always exit 0 — empty/zeroed output (handled as "run as root") instead.
    "$DMIDECODE" -t memory 2>/dev/null | awk 'function flush(){if(sz~/[0-9]+ *[GMgm][Bb]/){pop++;if(ch!="")chans[ch]=1;if(lc!="")lchans[lc]=1;if(cf+0>0&&(minc==0||cf+0<minc))minc=cf+0;if(rt+0>maxr)maxr=rt+0};sz="";ch="";lc="";cf="";rt=""} /^Memory Device/{flush();next} /^[ \t]*Size:/{v=$0;sub(/^[^:]*:[ \t]*/,"",v);sz=v} /Bank Locator:/{v=$0;sub(/^[^:]*:[ \t]*/,"",v);ch=v} /^[ \t]*Locator:/{v=$0;sub(/^[^:]*:[ \t]*/,"",v);if(match(v,/[A-Za-z][0-9]+$/))lc=toupper(substr(v,RSTART,1))} /^[ \t]*Speed:/{if(match($0,/[0-9]+/))rt=substr($0,RSTART,RLENGTH)} /Configured Memory Speed:/{if(match($0,/[0-9]+/))cf=substr($0,RSTART,RLENGTH)} END{flush();nc=0;for(c in chans)nc++;nl=0;for(c in lchans)nl++;if(nl>nc)nc=nl;printf "%d %d %d %d",pop+0,nc+0,minc+0,maxr+0}' || true
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
# Detect which MSR preset fits this CPU — the same family/model mapping XMRig's RxConfig uses,
# limited to the presets _msr_preset_regs carries (verified on real hardware).
_msr_detect_preset() { # -> preset name, or "" for unknown
    local vendor family model
    vendor=$(lscpu 2>/dev/null | sed -nE 's/^Vendor ID:[ \t]+//p' | head -1)
    family=$(lscpu 2>/dev/null | sed -nE 's/^CPU family:[ \t]+//p' | head -1)
    model=$(lscpu 2>/dev/null | sed -nE 's/^Model:[ \t]+//p' | head -1)
    case "$vendor" in
    AuthenticAMD)
        case "$family" in
        23) printf 'ryzen_17h' ;;
        25)
            # Zen4 lives in family 25 models 0x60-0x7f (96-127); the rest of family 25 is Zen3.
            if [ "${model:-0}" -ge 96 ] 2>/dev/null && [ "${model:-0}" -le 127 ] 2>/dev/null; then printf 'ryzen_19h_zen4'; else printf 'ryzen_19h'; fi
            ;;
        26) printf 'ryzen_1Ah_zen5' ;;
        esac
        ;;
    GenuineIntel) printf 'intel' ;;
    esac
}

# Apply the MSR preset root-side (#140): the unprivileged miner can't write /dev/cpu/*/msr, so the
# unit's ExecStartPre=+ runs this as root before xmrig starts. Exits 0 on the known-benign cases
# (unknown family, no msr module) so Restart=always never wedges; a real write failure is fatal
# and visible — an opted-in operator must know the ~10-15% MSR boost didn't apply.
msr_apply() {
    [ "$OS_TYPE" = Linux ] || error "msr-apply writes Linux MSRs and is only supported on Linux."
    [ "$(id -u)" -eq 0 ] || error "msr-apply needs root (it writes /dev/cpu/*/msr) — it is normally run by the systemd unit."
    parse_config >/dev/null
    local preset regs reg val mask cpu old new
    preset=$(_msr_detect_preset)
    if [ -z "$preset" ]; then
        warn "no MSR preset for this CPU family — mining continues without the MSR boost."
        return 0
    fi
    modprobe msr 2>/dev/null || true
    if ! command -v wrmsr >/dev/null 2>&1; then
        warn "wrmsr (msr-tools) not found — mining continues without the MSR boost."
        return 0
    fi
    regs=$(_msr_preset_regs "$preset")
    while read -r reg val mask; do
        if [ -z "$reg" ]; then continue; fi
        if [ "$mask" = "-" ]; then
            wrmsr -a "$reg" "0x$val"
        else
            # Masked register: read-modify-write per CPU — the unmasked bits differ per core's prior
            # state, so -a would clobber them. Same masked-compare semantics as _msr_rdmsr_verify.
            for cpu in "${CPU_SYSFS:-/sys/devices/system/cpu}"/cpu[0-9]*; do
                cpu="${cpu##*cpu}"
                old=$("${RDMSR_BIN:-rdmsr}" -p"$cpu" -0 "$reg" 2>/dev/null || true)
                case "$old" in '' | *[!0-9A-Fa-f]*) continue ;; esac
                new=$(printf '%016x' $(((0x$old & ~0x$mask) | (0x$val & 0x$mask))))
                wrmsr -p"$cpu" "$reg" "0x$new"
            done
        fi
    done <<EOF
$regs
EOF
    printf '%s' "$preset" >"$WORKER_ROOT/.rigforge-msr-preset"
    log "MSR preset '$preset' applied root-side (miner runs unprivileged)."
}

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

# --- Sister API (#99): read-only stats superset on its own port ---

# Full /2/summary body from the local worker API (empty when unreachable). Sibling of
# _read_api_hashrate with the same API_CMD test hook and Bearer branch (see the comment there).
_xmrig_summary_json() {
    local url="http://127.0.0.1:8080/2/summary"
    if [ -n "${API_CMD:-}" ]; then
        eval "$API_CMD"
        return
    fi
    command -v curl >/dev/null 2>&1 || return 0
    if [ -n "${ACCESS_TOKEN:-}" ]; then
        curl -fsS --max-time 5 -H "Authorization: Bearer $ACCESS_TOKEN" "$url" 2>/dev/null || true
    else
        curl -fsS --max-time 5 "$url" 2>/dev/null || true
    fi
}

# {watts, hs_per_watt} over a 1-second RAPL energy window; nulls when unmeasurable (no RAPL /
# non-root). RAPL only — TUNE_POWER_CMD is an operator-session env var whose value is eval'd, and
# config-derived text must never reach eval inside a network-facing handler.
_api_power_json() { # <hashrate|"">
    local hr="${1:-}" e0 e1 t0 t1 mx w=""
    e0=$(_rapl_sum energy_uj || true)
    t0=$(_now_s)
    if [ -n "$e0" ]; then
        sleep 1
        e1=$(_rapl_sum energy_uj || true)
        t1=$(_now_s)
        mx=$(_rapl_sum max_energy_range_uj || true)
        w=$(_watts_from_energy "$e0" "$e1" "${mx:-0}" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b - a}')")
    fi
    jq -n --arg w "$w" --arg hr "$hr" '{watts: (if $w == "" then null else ($w | tonumber) end), hs_per_watt: (if $w == "" or $hr == "" or ($w | tonumber) == 0 then null else (($hr | tonumber) / ($w | tonumber)) end)}'
}

# Tune/autotune state as JSON — the machine-readable sibling of _tune_history (same sources, same
# systemctl reads). Every jq program here is single-line: kcov cannot attribute in-string lines.
_api_tune_json() {
    local ovr="$WORKER_ROOT/tune-overrides.json" logf="$WORKER_ROOT/rigforge-tune.json"
    local applied=null target=null best=null n=null aten=false atgt="" asched="" anext=""
    if [ -s "$ovr" ] && jq -e . "$ovr" >/dev/null 2>&1; then applied=$(cat "$ovr"); fi
    if [ -s "$logf" ] && jq -e . "$logf" >/dev/null 2>&1; then
        target=$(jq -c '.target // null' "$logf" 2>/dev/null || echo null)
        best=$(jq -c '.best.hashrate // null' "$logf" 2>/dev/null || echo null)
        n=$(jq -c '.results | length' "$logf" 2>/dev/null || echo null)
    fi
    if [ "$OS_TYPE" = Linux ] && command -v systemctl >/dev/null 2>&1 && systemctl cat rigforge-autotune.timer >/dev/null 2>&1; then
        aten=true
        atgt=$(systemctl cat rigforge-autotune.service 2>/dev/null | sed -nE 's/^Environment=AUTOTUNE_TARGET=//p' | head -1)
        asched=$(systemctl cat rigforge-autotune.timer 2>/dev/null | sed -nE 's/^OnCalendar=//p' | head -1)
        anext=$(systemctl show rigforge-autotune.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
    fi
    jq -n --argjson applied "$applied" --argjson target "$target" --argjson best "$best" --argjson n "$n" --argjson aten "$aten" --arg atgt "$atgt" --arg asched "$asched" --arg anext "$anext" '{applied: $applied, target: $target, last_best_hs: $best, candidates_tried: $n, autotune: {enabled: $aten, target: (if $atgt == "" then null else $atgt end), schedule: (if $asched == "" then null else $asched end), next: (if $anext == "" then null else $anext end)}}'
}

# Health probes as JSON — reuses doctor's probe helpers and comparison expressions verbatim so the
# wire and the human report can never disagree; doctor stays the judgmental formatter.
_health_json() {
    local sa=false hp_total="" hp1g="" gov="" msr_st="" wr="" logf="" mem pop nch spd rated smt="" bv="" bn="" pct="" thr=null xmp=null effk maxk
    if [ "$OS_TYPE" = Linux ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then sa=true; fi
    hp_total=$(awk '/^HugePages_Total:/ {print $2}' "$MEMINFO" 2>/dev/null || true)
    hp1g=$(cat "$HUGEPAGES_1G_NR" 2>/dev/null || true)
    gov=$(cat "$GOVERNOR_FILE" 2>/dev/null || true)
    wr=$(_worker_root_from_config)
    [ -n "$wr" ] && logf="$wr/xmrig.log"
    msr_st=$(_msr_log_status "${logf:-/nonexistent}" | cut -f1)
    mem=$(_mem_summary)
    read -r pop nch spd rated <<<"${mem:-0 0 0 0}"
    if [ "${rated:-0}" -gt 0 ] 2>/dev/null && [ "${spd:-0}" -gt 0 ] 2>/dev/null; then
        if [ "$spd" -lt "$rated" ]; then xmp=false; else xmp=true; fi
    fi
    smt=$(cat "$SMT_CONTROL" 2>/dev/null || true)
    bv=$(_dmi board_vendor)
    bn=$(_dmi board_name)
    if [ "$sa" = true ]; then
        maxk=$(cat "$CPUFREQ_MAX" 2>/dev/null || true)
        effk=$(_cpu_eff_khz)
        if [ -n "$effk" ] && [ "${maxk:-0}" -gt 0 ] 2>/dev/null; then
            pct=$((effk * 100 / maxk))
            if [ "$pct" -lt "$MIN_CLOCK_PCT" ]; then thr=true; else thr=false; fi
        fi
    fi
    jq -n --argjson sa "$sa" --arg hpt "${hp_total:-}" --arg hp1g "${hp1g:-}" --arg gov "$gov" --arg msr "${msr_st:-none}" --arg pop "${pop:-0}" --arg nch "${nch:-0}" --arg spd "${spd:-0}" --arg rated "${rated:-0}" --argjson xmp "$xmp" --arg smt "$smt" --arg bv "$bv" --arg bn "$bn" --arg pct "${pct:-}" --argjson thr "$thr" '{service_active: $sa, hugepages_total: (if $hpt == "" then null else ($hpt | tonumber) end), hugepages_1g: (if $hp1g == "" then null else ($hp1g | tonumber) end), governor: (if $gov == "" then null else $gov end), msr: $msr, ram: {modules: ($pop | tonumber), channels: ($nch | tonumber), mts: ($spd | tonumber), rated_mts: ($rated | tonumber)}, xmp: $xmp, smt: (if $smt == "" then null else $smt end), firmware: {vendor: (if $bv == "" then null else $bv end), board: (if $bn == "" then null else $bn end)}, clock_pct_of_boost: (if $pct == "" then null else ($pct | tonumber) end), throttling: $thr}'
}

# Watchdog state as JSON (#212): when the watchdog stops the miner, the sister API is the one
# component still alive — a thermally-held rig must say "held, resumes below N" on the wire, not
# look mystery-dead. Reads the same state files watchdog() writes; absent or garbled files
# degrade to defaults and never fail the refresh.
_watchdog_json() {
    local wr hold=false strikes t=""
    if [ "${WATCHDOG_MODE:-disabled}" = disabled ]; then
        jq -n '{mode: "disabled"}'
        return 0
    fi
    wr=$(_worker_root_from_config)
    [ -n "$wr" ] && [ -f "$wr/watchdog.thermal-hold" ] && hold=true
    strikes=$(cat "$wr/watchdog.fails" 2>/dev/null || true)
    [[ "$strikes" =~ ^[0-9]+$ ]] || strikes=0
    t=$(_read_temp 2>/dev/null || true)
    jq -n --argjson hold "$hold" --arg mt "${MAX_TEMP_C:-}" --arg t "$t" --arg s "$strikes" '{mode: "enabled", thermal_hold: $hold, max_temp_c: (if $mt == "" then null else ($mt | tonumber) end), resumes_below_c: (if $mt == "" then null else (($mt | tonumber) - 5) end), temp_c: (if $t == "" then null else ($t | tonumber) end), strikes: ($s | tonumber)}'
}

# Provenance + tune + power + health, namespaced under one `rigforge` key. Runs in the refresh
# timer, never on a request path, so it can afford the full probe pass every time.
# #253/#254: the effective WRITABLE config in CANONICAL form — exactly the control-path allowlist,
# read the same way parse_config does (canonical strings perf->performance, on/true->enabled), keys
# sorted. Single source of truth for the masked feed view (#253) AND the revision hash (#254), so what
# a consumer reads, hashes, and can POST back all agree. UNMASKED here (pool pass included): the hash
# is one-way so it never leaks, and the revision must bump on ANY writable change incl. a pool password.
_writable_config_canonical() {
    local pools
    pools=$(jq -c '.pools // []' "$CONFIG_JSON" 2>/dev/null || echo '[]')
    [ -n "$pools" ] || pools='[]'
    jq -Sn --argjson pools "$pools" --argjson don "${DONATION:-1}" --arg at "${AUTOTUNE_MODE:-disabled}" --arg wd "${WATCHDOG_MODE:-disabled}" --argjson wi "${WATCHDOG_INTERVAL_MIN:-5}" --arg mt "${MAX_TEMP_C:-}" '{pools: $pools, DONATION: $don, autotune: $at, watchdog: $wd, watchdog_interval_min: $wi, max_temp_c: (if $mt == "" then null else ($mt | tonumber) end)}'
}

# #254: a short content hash of the canonical writable config — the load-bearing "did it change"
# signal a polling consumer compares against. Changes iff the effective writable config changes.
_writable_config_hash() { _sha256 <(_writable_config_canonical) | cut -c1-16; }

# #253: the MASKED view for the open feed — pool pass + tls-fingerprint dropped so no credential is
# ever served on the token-optional read.
_api_config_json() {
    _writable_config_canonical | jq -c '.pools = [.pools[]? | del(.pass, ."tls-fingerprint")]'
}

# #254: config-change provenance marker. Stamped by every path that rewrites the writable config
# (local apply, control-apply, restore) via _stamp_config_meta; updated ONLY when the writable hash
# actually changes, so a no-op apply never false-bumps it. (autotune tunes runtime params — threads,
# MSR — not the writable config, so it is never a source here.)
_stamp_config_meta() { # <source> [change_id] — record provenance IFF the writable config changed
    local src="$1" cid="${2:-}" newrev oldrev
    # Self-sufficient + error-isolated: parse the current config.json in a subshell, so this is safe to
    # call from restore/apply/control regardless of whether the caller has parsed (and a bad config
    # can't abort the caller).
    newrev=$( (parse_config >/dev/null 2>&1 && _writable_config_hash) 2>/dev/null) || newrev=""
    [ -n "$newrev" ] || return 0
    oldrev=$(jq -r '.revision // ""' "$CONFIG_META_FILE" 2>/dev/null || echo "")
    [ "$newrev" = "$oldrev" ] && return 0
    jq -n --arg r "$newrev" --arg s "$src" --arg c "$cid" --arg w "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{revision: $r, source: $s, last_change_id: (if $c == "" then null else $c end), changed_at: $w}' >"$CONFIG_META_FILE.tmp.$$" 2>/dev/null && mv -f "$CONFIG_META_FILE.tmp.$$" "$CONFIG_META_FILE" && chmod 644 "$CONFIG_META_FILE" 2>/dev/null || true
}

# #254: the config_meta block for the feed. revision is recomputed here (authoritative — catches even
# a raw hand-edit that never ran apply); source/changed_at/last_change_id come from the marker
# (best-effort attribution, null on a fresh rig that hasn't changed its config yet).
_api_config_meta_json() {
    local rev
    rev=$(_writable_config_hash)
    if [ -f "$CONFIG_META_FILE" ]; then
        jq --arg rev "$rev" '{revision: $rev, changed_at: .changed_at, source: .source, last_change_id: .last_change_id}' "$CONFIG_META_FILE" 2>/dev/null || jq -n --arg rev "$rev" '{revision: $rev, changed_at: null, source: null, last_change_id: null}'
    else
        jq -n --arg rev "$rev" '{revision: $rev, changed_at: null, source: null, last_change_id: null}'
    fi
}

_api_rigforge_block() { # <hashrate|"">
    jq -n --arg v "$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo unknown)" --arg xv "$XMRIG_VERSION" --arg xc "$XMRIG_COMMIT" --argjson tune "$(_api_tune_json)" --argjson power "$(_api_power_json "$1")" --argjson health "$(_health_json)" --argjson watchdog "$(_watchdog_json)" --argjson config "$(_api_config_json)" --argjson config_meta "$(_api_config_meta_json)" '{version: $v, xmrig_version: $xv, xmrig_commit: $xc, tune: $tune, power: $power, health: $health, watchdog: $watchdog, config: $config, config_meta: $config_meta}'
}

# Produce the sister API's response bodies: compute once, write atomically (tmp + rename, the
# node_exporter textfile pattern), and let the persistent server ship bytes. Driven by
# rigforge-api-refresh.timer every 15s at idle priority — the REQUEST path never runs a probe,
# which is how xmrig's own API costs nothing (#164; four gate iterations proved every
# per-request-process design shaves hashrate one way or another).
api_refresh() {
    [ "$OS_TYPE" = Linux ] || error "api-refresh is driven by the rigforge-api-refresh systemd timer and is Linux-only."
    parse_config >/dev/null
    local dir="${RIGFORGE_API_DATA:-/run/rigforge-api}" sum hr rf body
    mkdir -p "$dir"
    sum=$(_xmrig_summary_json || true)
    printf '%s' "$sum" | jq -e . >/dev/null 2>&1 || sum=""
    hr=$(printf '%s' "$sum" | jq -r '.hashrate.total[0] // empty' 2>/dev/null || true)
    rf=$(_api_rigforge_block "$hr")
    # Superset rule: every XMRig field passes through unchanged, plus one namespaced key. When the
    # miner is down the RigForge data still serves — that is when health matters most.
    if [ -n "$sum" ]; then body=$(jq -n --argjson x "$sum" --argjson r "$rf" '$x + {rigforge: $r}'); else body=$(jq -n --argjson r "$rf" '{rigforge: ($r + {xmrig_api: "unreachable"})}'); fi
    printf '%s' "$body" >"$dir/summary.json.tmp.$$" && mv -f "$dir/summary.json.tmp.$$" "$dir/summary.json"
    printf '%s' "$rf" | jq -c '.health + {watchdog: .watchdog}' >"$dir/health.json.tmp.$$" && mv -f "$dir/health.json.tmp.$$" "$dir/health.json"
    printf '%s' "$rf" | jq -c '.tune' >"$dir/tune.json.tmp.$$" && mv -f "$dir/tune.json.tmp.$$" "$dir/tune.json"
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

    # Privilege separation (#140): when the config asks for an unprivileged miner, the unit must
    # actually say so (a stale unit from before the change would still run root). Quiet when
    # systemctl can't answer (non-systemd test envs).
    local cfg_mu=""
    [ -f "$CONFIG_JSON" ] && cfg_mu=$(jq -r '.miner_user // empty' "$CONFIG_JSON" 2>/dev/null || true)
    if [ -n "$cfg_mu" ]; then
        local svc_user
        svc_user=$(systemctl show -p User --value "$SERVICE_NAME" 2>/dev/null || true)
        if [ "$svc_user" = "$cfg_mu" ]; then
            _ck_ok "miner runs unprivileged as '$cfg_mu' (miner_user)"
        elif [ -n "$svc_user" ]; then
            _ck_warn "config sets miner_user='$cfg_mu' but the unit runs as '$svc_user' — re-run 'sudo $0 apply'"
            issues=$((issues + 1))
        fi
        if [ -n "$wr" ] && [ -f "$wr/.rigforge-msr-preset" ]; then
            local _mp
            _mp=$(cat "$wr/.rigforge-msr-preset" 2>/dev/null || true)
            _msr_rdmsr_verify "$_mp"
            if [ "$_MSR_TOTAL" -gt 0 ] && [ "$_MSR_OK" = "$_MSR_TOTAL" ]; then
                _ck_ok "root-side MSR preset '$_mp' verified by register read-back ($_MSR_OK/$_MSR_TOTAL)"
            elif [ "$_MSR_UNREAD" = "$_MSR_TOTAL" ]; then
                _ck_info "root-side MSR preset '$_mp' recorded — run doctor as root for the register read-back"
            else
                _ck_warn "root-side MSR preset '$_mp': only $_MSR_OK/$_MSR_TOTAL registers match (bad:$_MSR_BAD)"
                issues=$((issues + 1))
            fi
        fi
    fi

    # Binary tamper evidence (#141): the artifact that runs 24/7 as root should still be the one we
    # built. Recompute and compare against the build-time record; a missing record (older build) is
    # advisory only — the next rebuild writes one.
    local bin="$wr/xmrig/build/xmrig" sums="$wr/xmrig/.rigforge-sha256"
    if [ -n "$wr" ] && [ -f "$bin" ]; then
        if [ ! -f "$sums" ]; then
            _ck_info "no build-time checksum recorded (older build) — the next setup/upgrade rebuild records one"
        elif [ "$(cat "$sums" 2>/dev/null)" = "$(_sha256 "$bin")" ]; then
            _ck_ok "xmrig binary matches its build-time SHA-256 (unchanged since compile)"
        else
            _ck_warn "xmrig binary CHANGED since it was built — re-run 'sudo $0 setup' to rebuild, or investigate how it changed"
            issues=$((issues + 1))
        fi
    fi

    # Read-only API posture (#135): exposing the HTTP API on 0.0.0.0:8080 is safe ONLY because the
    # generated config pins http.restricted=true — assert the live file still does, so a hand-edit
    # or a bad merge can't silently turn the read-only API into a control plane. Quiet when there is
    # no built config yet (setup hasn't run); the service check above already covers that state.
    local live_cfg="" restricted=""
    [ -n "$wr" ] && live_cfg="$wr/xmrig/build/config.json"
    if [ -n "$live_cfg" ] && [ -f "$live_cfg" ]; then
        restricted=$(jq -r '.http.restricted' "$live_cfg" 2>/dev/null || true)
        if [ "$restricted" = "true" ]; then
            _ck_ok "HTTP API is read-only (http.restricted=true in the live config)"
        else
            _ck_warn "HTTP API is NOT read-only (http.restricted=${restricted:-unreadable}) — regenerate it with: sudo $0 apply"
            issues=$((issues + 1))
        fi
    fi

    # Combined exposure posture: open (tokenless) AND unscoped (no api_allow_from firewall) is the
    # designed default for a trusted LAN — but it deserves one loud advisory line, because it's
    # exactly the combination that must not leave the LAN. Advisory, not a counted issue: on the
    # designed topology it is correct.
    if [ -f "$CONFIG_JSON" ]; then
        local cfg_tok cfg_scope
        cfg_tok=$(jq -r '.ACCESS_TOKEN // empty' "$CONFIG_JSON" 2>/dev/null || true)
        cfg_scope=$(jq -r '.api_allow_from // empty' "$CONFIG_JSON" 2>/dev/null || true)
        if [ -z "$cfg_tok" ] && [ -z "$cfg_scope" ]; then
            _ck_info "API is open (no ACCESS_TOKEN) and unscoped (no api_allow_from) — fine on a trusted LAN; set one of them before this rig faces anything else"
        else
            _ck_ok "API exposure is limited (${cfg_tok:+token}${cfg_tok:+${cfg_scope:+ + }}${cfg_scope:+firewall scope})"
        fi
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
    # NPS on EPYC (#201): a BIOS update or CMOS reset silently drops NPS4 to NPS1 and costs
    # RandomX its per-node datasets — detectable, so say so. Advisory only; NPS1 mines, just slower.
    local nps_rec=""
    if [ -n "$(_nps_suspect "$cpu")" ]; then
        nps_rec="EPYC reports a single NUMA node (NPS1) — set NUMA nodes per socket to NPS4 in BIOS ($(_bios_menu "$bvendor" numa_nps perf)) so RandomX gets quadrant-local memory."
    fi
    if [ -n "$bvendor$board$bios" ]; then
        if [ -n "$xmp_rec$smt_rec$nps_rec" ]; then
            _ck_info "Firmware: ${bvendor:-?} ${board:-?}, BIOS ${bios:-?} (${bdate:-?})${cpu:+, $cpu} — apply the BIOS/UEFI item(s) below (RigForge can't change them from the OS)."
        else
            _ck_info "Firmware: ${bvendor:-?} ${board:-?}, BIOS ${bios:-?} (${bdate:-?})${cpu:+, $cpu} — no BIOS changes recommended."
        fi
    fi
    if [ -n "$xmp_rec" ]; then _ck_warn "$xmp_rec"; fi
    if [ -n "$smt_rec" ]; then _ck_warn "$smt_rec"; fi
    if [ -n "$nps_rec" ]; then _ck_warn "$nps_rec"; fi

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
        log "Check for a newer RigForge any time: '$0 upgrade --check'."
    else
        warn "doctor: $issues issue(s) found — see the hints above."
        # Non-zero on unhealthy (#149): doctor is the verb operators cron/gate on, and Pithead's
        # health verb already exits non-zero — one stack's habits must transfer to the other.
        return 1
    fi
}

# --- Usage & command dispatch ---

# --- Guided BIOS tuning (#80): detect -> guide -> reboot -> re-verify ---

# One probe pass; results in globals (the S_* style tune uses). Detection expressions are byte-for-
# byte doctor's (#78: memory 2998-form, SMT, boost) so `bios` and `doctor` can never disagree about
# the same rig. Each item: B_<X>_STATUS = ok|pending|unknown, B_<X>_BEFORE = short human value.
# NPS regression detection (#201): a multi-CCD EPYC at NPS1 (one NUMA node) leaves quadrant-local
# memory on the table — XMRig allocates one RandomX dataset per NUMA node. Echoes "1" when the
# topology looks wrong (EPYC model + exactly one node dir), else nothing. Desktop parts correctly
# report one node and are never flagged; missing sysfs (n=0) is unverifiable, not suspect.
# Shared by doctor's #78 advisory and _bios_detect (the #80 rule: they can never disagree).
_nps_suspect() { # <cpu_model> -> echoes the node count when suspect, else nothing
    case "$1" in *EPYC*) ;; *) return 0 ;; esac
    local n=0 d
    for d in "${NODE_SYSFS:-/sys/devices/system/node}"/node[0-9]*; do
        [ -d "$d" ] && n=$((n + 1))
    done
    [ "$n" -eq 1 ] && echo "$n"
    return 0
}

_bios_detect() {
    local mem pop nch spd rated smt effk maxk pct cpu_m
    B_MEM_STATUS=unknown B_MEM_BEFORE="" B_SMT_STATUS=unknown B_SMT_BEFORE="" B_BOOST_STATUS=unknown B_BOOST_BEFORE=""
    B_NPS_STATUS=unknown B_NPS_BEFORE=""
    cpu_m=$(lscpu 2>/dev/null | awk -F: '/^Model name:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' || true)
    case "$cpu_m" in
    *EPYC*)
        if [ -n "$(_nps_suspect "$cpu_m")" ]; then
            B_NPS_STATUS=pending
            B_NPS_BEFORE="1 NUMA node (NPS1)"
        else
            B_NPS_STATUS=ok
            B_NPS_BEFORE="multiple NUMA nodes"
        fi
        ;;
    esac
    mem=$(_mem_summary)
    read -r pop nch spd rated <<<"${mem:-0 0 0 0}"
    if [ "${rated:-0}" -gt 0 ] 2>/dev/null && [ "${spd:-0}" -gt 0 ] 2>/dev/null; then
        if [ "$spd" -lt "$rated" ]; then B_MEM_STATUS=pending; else B_MEM_STATUS=ok; fi
        B_MEM_BEFORE="${spd} of ${rated} MT/s"
    fi
    smt=$(cat "$SMT_CONTROL" 2>/dev/null || true)
    case "$smt" in
    off | forceoff)
        B_SMT_STATUS=pending
        B_SMT_BEFORE="$smt"
        ;;
    "") : ;; # no SMT sysfs -> unknown (can't verify)
    *)
        B_SMT_STATUS=ok
        B_SMT_BEFORE="$smt"
        ;;
    esac
    # Boost is only measurable under load (idle cores read low) — same gate as doctor's check.
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        maxk=$(cat "$CPUFREQ_MAX" 2>/dev/null || true)
        effk=$(_cpu_eff_khz)
        if [ -n "$effk" ] && [ "${maxk:-0}" -gt 0 ] 2>/dev/null; then
            pct=$((effk * 100 / maxk))
            if [ "$pct" -lt "$MIN_CLOCK_PCT" ]; then B_BOOST_STATUS=pending; else B_BOOST_STATUS=ok; fi
            B_BOOST_BEFORE="${pct}% of max boost"
        fi
    fi
}

# The exact BIOS menu path(s) for an item on a detected board vendor. A case statement is the
# smallest thing that holds four vendors + a generic fallback — no data file. (#80)
_bios_menu() { # <board_vendor> <item_id> <target> -> menu-path line(s) on stdout
    local v
    v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$v" in
    asus*) v=asus ;; # asustek matches too
    asrock*) v=asrock ;;
    giga*) v=gigabyte ;;
    micro-star* | msi*) v=msi ;;
    *) v=generic ;;
    esac
    case "$2:$v" in
    memory_profile:asus) echo "Ai Tweaker ▸ Ai Overclock Tuner ▸ EXPO I (Intel boards: XMP I)" ;;
    memory_profile:asrock) echo "OC Tweaker ▸ DRAM Profile ▸ EXPO/XMP Profile 1" ;;
    memory_profile:gigabyte) echo "Tweaker ▸ Extreme Memory Profile (X.M.P.) / EXPO ▸ Profile 1" ;;
    memory_profile:msi) echo "OC ▸ A-XMP / EXPO ▸ Profile 1" ;;
    memory_profile:*) echo "look for the memory profile setting (XMP / EXPO / DOCP) and enable profile 1" ;;
    smt:*) echo "Advanced ▸ CPU Configuration ▸ SMT / Hyper-Threading ▸ Enabled" ;;
    numa_nps:*) echo "Advanced ▸ AMD CBS ▸ DF Common Options ▸ Memory Addressing ▸ NUMA nodes per socket ▸ NPS4" ;;
    power_boost:*)
        if [ "$3" = efficiency ]; then
            printf '%s\n' "PBO ▸ Eco Mode (65 W TDP)" "Curve Optimizer ▸ All Cores ▸ Negative ▸ 20" "Server boards (EPYC): AMD CBS ▸ NBIO ▸ cTDP — set the lower cTDP the SKU supports"
        else
            printf '%s\n' "Advanced ▸ AMD Overclocking ▸ Precision Boost Overdrive ▸ Enabled (Advanced) (Intel: lift the PL1/PL2 power limits)" "Server boards (EPYC): AMD CBS ▸ NBIO ▸ cTDP / Package Power Limit at the SKU maximum, Determinism Control ▸ Performance"
        fi
        ;;
    esac
}

# Persist ONLY the still-pending items — done items are not state. jq -n --arg for every value:
# DMI strings carry spaces/quotes, and the menu strings carry UTF-8 markers.
_bios_state_write() { # <state_file>; reads the B_* globals + TUNE_TARGET
    local f="$1" items="[]" vendor
    vendor=$(_dmi board_vendor)
    if [ "$B_MEM_STATUS" = pending ]; then items=$(jq -c --argjson a "$items" --arg b "$B_MEM_BEFORE" --arg m "$(_bios_menu "$vendor" memory_profile "$TUNE_TARGET")" -n '$a + [{id: "memory_profile", status: "pending", before: $b, menu: $m}]'); fi
    if [ "$B_SMT_STATUS" = pending ]; then items=$(jq -c --argjson a "$items" --arg b "$B_SMT_BEFORE" --arg m "$(_bios_menu "$vendor" smt "$TUNE_TARGET")" -n '$a + [{id: "smt", status: "pending", before: $b, menu: $m}]'); fi
    if [ "$B_BOOST_STATUS" = pending ]; then items=$(jq -c --argjson a "$items" --arg b "$B_BOOST_BEFORE" --arg m "$(_bios_menu "$vendor" power_boost "$TUNE_TARGET")" -n '$a + [{id: "power_boost", status: "pending", before: $b, menu: $m}]'); fi
    if [ "$B_NPS_STATUS" = pending ]; then items=$(jq -c --argjson a "$items" --arg b "$B_NPS_BEFORE" --arg m "$(_bios_menu "$vendor" numa_nps "$TUNE_TARGET")" -n '$a + [{id: "numa_nps", status: "pending", before: $b, menu: $m}]'); fi
    jq -n --arg t "$TUNE_TARGET" --arg when "$(date '+%Y-%m-%d %H:%M')" --argjson items "$items" '{target: $t, saved: $when, items: $items}' >"$f"
    log "Saved $(jq -r '.items | length' "$f") pending item(s) to $f."
}

_bios_item_label() { # <id> -> human label
    case "$1" in
    memory_profile) printf 'Memory profile' ;;
    smt) printf 'SMT / Hyper-Threading' ;;
    power_boost) printf 'CPU boost / power' ;;
    numa_nps) printf 'NUMA per socket (NPS)' ;;
    esac
}

# Run 1: detect, print the firmware context, walk the pending items one at a time with the exact
# BIOS menu path for this board, save the resumable state, and hand the operator the checklist.
# RigForge never writes BIOS (#78 feasibility) — this is detect-and-recommend with a verify loop.
_bios_guide() { # <state_file>
    local state="$1" pending="" id
    _bios_detect
    echo ""
    log "Reading current firmware state (RigForge can't change these from the OS — it only reads them):"
    _ck_info "Firmware: $(_dmi board_vendor) $(_dmi board_name), BIOS $(_dmi bios_version) ($(_dmi bios_date))"
    if [ "$B_SMT_STATUS" = ok ]; then _ck_ok "SMT / Hyper-Threading: enabled"; fi
    if [ "$B_SMT_STATUS" = pending ]; then _ck_warn "SMT / Hyper-Threading: $B_SMT_BEFORE"; fi
    if [ "$B_MEM_STATUS" = ok ]; then _ck_ok "Memory profile: running at rated speed ($B_MEM_BEFORE)"; fi
    if [ "$B_MEM_STATUS" = pending ]; then _ck_warn "Memory profile: running at $B_MEM_BEFORE — EXPO/XMP not enabled"; fi
    if [ "$B_MEM_STATUS" = unknown ]; then _ck_info "Memory profile: can't verify — run as root so dmidecode can read the RAM state"; fi
    if [ "$B_BOOST_STATUS" = ok ]; then _ck_ok "CPU boost under load: $B_BOOST_BEFORE"; fi
    if [ "$B_BOOST_STATUS" = pending ]; then _ck_warn "CPU boost under load: $B_BOOST_BEFORE — likely power-capped"; fi
    if [ "$B_BOOST_STATUS" = unknown ]; then _ck_info "CPU boost not checked — the miner isn't running (start it and re-run bios to include the power/boost item)"; fi
    for id in memory_profile smt power_boost; do
        case "$id" in
        memory_profile) if [ "$B_MEM_STATUS" = pending ]; then pending="$pending $id"; fi ;;
        smt) if [ "$B_SMT_STATUS" = pending ]; then pending="$pending $id"; fi ;;
        power_boost) if [ "$B_BOOST_STATUS" = pending ]; then pending="$pending $id"; fi ;;
        esac
    done
    if [ -z "$pending" ]; then
        echo ""
        _ck_ok "Everything's already set for $(_autotune_desc "$TUNE_TARGET") — no BIOS changes needed."
        return 0
    fi
    echo ""
    log "BIOS/UEFI changes for this board, one at a time (highest RandomX impact first):"
    local n=0 vendor
    vendor=$(_dmi board_vendor)
    for id in $pending; do
        n=$((n + 1))
        echo ""
        printf '  %d. %s\n' "$n" "$(_bios_item_label "$id")"
        _bios_menu "$vendor" "$id" "$TUNE_TARGET" | sed 's/^/     -> /'
        read -r -p "  Press Enter when you've noted it (nothing is applied now) ... " _ || true
    done
    _bios_state_write "$state"
    echo ""
    log "Next: reboot into BIOS/UEFI (usually Del/F2 at power-on), apply the item(s) above, Save & Exit."
    log "Back in Linux, run 'sudo $0 bios' again — it re-reads the same probes and reports what took."
    _reown_worker
}

# Run 2+: re-read the saved pending items against fresh probes. An item flips to done only when its
# OS-visible fingerprint says so — `unknown` NEVER passes (honesty rule from the issue spec).
_bios_verify() { # <state_file>
    local state="$1" target saved id before menu fresh_status fresh_before kept="" applied=0 total=0
    target=$(jq -r '.target // "perf"' "$state")
    saved=$(jq -r '.saved // "?"' "$state")
    TUNE_TARGET="$target" # the checklist was built for the saved target; it governs the re-verify wording
    total=$(jq -r '.items | length' "$state")
    log "Resuming — $total item(s) were pending from $saved."
    local rows
    rows=$(jq -r '.items[] | [.id, .before, .menu] | @tsv' "$state")
    _bios_detect
    echo ""
    log "Re-checking the items you went in to change:"
    while IFS=$'\t' read -r id before menu; do
        case "$id" in
        memory_profile)
            fresh_status="$B_MEM_STATUS"
            fresh_before="$B_MEM_BEFORE"
            ;;
        smt)
            fresh_status="$B_SMT_STATUS"
            fresh_before="$B_SMT_BEFORE"
            ;;
        power_boost)
            fresh_status="$B_BOOST_STATUS"
            fresh_before="$B_BOOST_BEFORE"
            ;;
        *) continue ;;
        esac
        if [ "$fresh_status" = ok ]; then
            _ck_ok "$(_bios_item_label "$id") — now $fresh_before (was $before). Took."
            applied=$((applied + 1))
        elif [ "$fresh_status" = pending ]; then
            _ck_warn "$(_bios_item_label "$id") — still $fresh_before. Didn't take; re-check: $menu"
            kept="$kept $id"
        elif [ "$id" = power_boost ]; then
            _ck_warn "CPU boost — can't verify with the miner stopped; run 'sudo $0 start', let it warm up, then re-run bios."
            kept="$kept $id"
        else
            _ck_warn "$(_bios_item_label "$id") — can't verify (run as root so dmidecode can read the RAM state)."
            kept="$kept $id"
        fi
    done <<<"$rows"
    echo ""
    if [ -z "$kept" ]; then
        rm -f "$state"
        log "All BIOS items applied. Firmware is tuned for: $(_autotune_desc "$target")."
        log "Next: 'sudo $0 tune --live' — the hardware envelope changed, so re-tune XMRig against it."
    else
        # Rewrite the state with only the still-pending items: re-detect filled the B_* globals, so
        # neutralize the ones that took and let the writer keep the rest.
        case " $kept " in *" memory_profile "*) : ;; *) B_MEM_STATUS="done" ;; esac
        case " $kept " in *" smt "*) : ;; *) B_SMT_STATUS="done" ;; esac
        case " $kept " in *" power_boost "*) : ;; *) B_BOOST_STATUS="done" ;; esac
        if [ "$B_BOOST_STATUS" = unknown ]; then B_BOOST_STATUS=pending; fi # keep it resumable
        if [ "$B_MEM_STATUS" = unknown ]; then B_MEM_STATUS=pending; fi
        _bios_state_write "$state"
        log "$applied of $total applied, $(jq -r '.items | length' "$state") still pending. Reboot into BIOS to finish, then run 'sudo $0 bios' again."
    fi
    _reown_worker
}

# The guided, resumable BIOS walk-through (#80): a sibling of tune/doctor. Interactive by design —
# this is the one flow that needs console access for the reboot-into-BIOS step.
bios() {
    [ "$OS_TYPE" = Linux ] || error "bios reads Linux firmware interfaces (dmidecode, /sys/class/dmi) and is only supported on Linux."
    # dmidecode (the memory-profile probe) needs root — auto-elevate exactly like tune.
    if _tune_should_elevate; then
        log "bios needs root for the firmware probes — re-running with sudo..."
        exec sudo "$0" bios "$@"
    fi
    local target_set=0
    if [ -n "${TUNE_TARGET:-}" ]; then target_set=1; fi
    while [ $# -gt 0 ]; do
        case "$1" in
        --efficiency)
            TUNE_TARGET=efficiency
            target_set=1
            ;;
        --perf)
            TUNE_TARGET=perf
            target_set=1
            ;;
        *) error "Unknown option for bios: '$1' (use --perf or --efficiency)." ;;
        esac
        shift
    done
    parse_config
    if [ "$target_set" != 1 ]; then TUNE_TARGET="${AUTOTUNE_TARGET:-perf}"; fi
    local state="$WORKER_ROOT/rigforge-bios.json"
    log "RigForge guided BIOS tuning — target: $(_autotune_desc "$TUNE_TARGET")"
    if [ -s "$state" ] && jq -e '.items | length > 0' "$state" >/dev/null 2>&1; then
        _bios_verify "$state"
        return 0
    fi
    _bios_guide "$state"
}

usage() {
    cat <<USAGE
RigForge — provision and maintain an XMRig mining worker.

Usage: $0 [command]

Most days you only need the first group; the rest are grouped below. Full guide: docs/operations.md

Day to day:
  apply      re-read config.json, regenerate the XMRig config, and restart (no rebuild; --dry-run: preview)
  upgrade    redeploy after a 'git pull': rebuild + restart if the pinned XMRig changed ('--check' just reports whether a newer RigForge release exists)
  doctor     check that HugePages, the MSR mod, the governor and the service are all healthy
  logs       follow the live miner logs
  status     live summary (hashrate, pool, uptime, shares) + whether the miner is running
  start      start the miner (systemd on Linux, a background process on macOS) [alias: up]
  stop       stop the miner [alias: down]
  restart    restart the miner

Tuning:
  tune       measure the fastest XMRig knobs and keep them. Live re-tunes against the running miner:
             '--now' (= '--short') a quick pass that keeps the best prefetch mode, '--now --long' a full
             all-knob live sweep (= '--live'). Offline: plain 'tune' (or '--bench') sweeps every knob on
             the whole machine — fastest/cleanest, but rx/0 only. '--confirm' A/B-checks the winner live
             before keeping it. '--efficiency' optimizes hashrate-per-watt (default '--perf' = raw H/s),
             '--history' shows the current tuning + recent runs, '--clear' resets
  bench      run a one-off 'xmrig --bench' and report the hashrate
  autotune   alias of 'tune --now' (and the verb the scheduled timer runs); turn on the schedule with
             autotune:"performance"|"efficiency" in config.json
  watchdog   one health check: restart a wedged miner (alive but 0 H/s, two strikes), enforce
             max_temp_c (stop above it, start 5°C below). Schedule it with watchdog:"enabled"
             in config.json — the timer runs it every watchdog_interval_min minutes
  bios       guided, resumable walk-through of the BIOS/UEFI changes for your hardware (XMP/EXPO,
             SMT, PBO/Eco-Mode; '--efficiency' picks the low-power set). Detects state, hands you a
             board-specific checklist, and re-verifies what took after the reboot. RigForge never
             writes BIOS itself

Provision & lifecycle:
  setup      (default) provision the worker: dependencies, build, kernel tuning, service (--dry-run: preview the plan, no sudo)
  uninstall  remove the service and revert all system changes (add -y|--yes to skip the prompt)
  enable     start the miner automatically (boot on Linux, login on macOS)
  disable    don't start the miner automatically

Backup:
  backup     save config.json + tuning to a timestamped archive in ./backups
  restore    restore config.json + tuning from a backup archive: restore [-y|--yes] <archive>

Info:
  msr-apply  (internal) apply the CPU's MSR preset as root — run by the miner unit's
             ExecStartPre when miner_user is set (the unprivileged miner can't write MSRs)
  api-refresh (internal) recompute the sister API's response files — driven every 15s by the
             rigforge-api-refresh systemd timer ("api": "enabled" in config.json)
  control-apply (internal) persist + apply a config change staged by the control server — run by
             the rigforge-control-apply.path unit ("control": "enabled" in config.json)
  support-bundle  collect doctor/version/configs/log-tail into a redacted tarball for bug reports
  completion print a bash/zsh tab-completion script: completion bash|zsh
  version    print the RigForge version  (-v, --version)
  help       show this help              (-h, --help)

Re-running 'setup' is idempotent: it skips the recompile when the pinned XMRig is already built.
USAGE
}

if [ "$_RIGFORGE_SOURCED" = "0" ]; then
    # Honesty check: these verbs take no arguments, so reject extras (Pithead's `setup --skip-deps`
    # muscle memory, a typo'd `apply --now`) instead of silently running as if nothing was passed.
    # Verbs with their own flags (setup/upgrade/tune/apply/backup/restore/...) validate in their loops.
    case "${1:-setup}" in
    autotune | watchdog | doctor | api-refresh | msr-apply | control-apply | status | logs | start | up | stop | down | restart | enable | disable | bench | version | --version | -v | help | -h | --help)
        [ -z "${2:-}" ] || error "Unexpected argument for $1: '$2'. Run '$0 help'."
        ;;
    esac
    case "${1:-setup}" in
    setup)
        # if-form, not `[ $# -gt 0 ] && shift`: a false && list at top level trips set -e on the
        # zero-arg default path (bare ./rigforge.sh dispatches here with $# = 0).
        if [ $# -gt 0 ]; then shift; fi
        main "$@"
        ;;
    upgrade)
        shift
        upgrade "$@"
        ;;
    uninstall)
        shift
        uninstall "$@"
        ;;
    tune)
        shift
        tune "$@"
        ;;
    autotune) autotune ;;
    watchdog) watchdog ;;
    doctor) doctor || exit 1 ;; # `||`: a mere unhealthy report must not fire the ERR trap's "aborted while" line
    bios)
        shift
        bios "$@"
        ;;
    api-refresh) api_refresh ;;
    msr-apply) msr_apply ;;
    control-apply) control_apply ;;
    status) svc_status ;;
    logs) svc_logs ;;
    start | up) svc_start ;;
    stop | down) svc_stop ;;
    restart) svc_restart ;;
    enable) svc_enable ;;
    disable) svc_disable ;;
    apply)
        shift
        apply "$@"
        ;;
    bench) bench ;;
    backup)
        shift
        backup "$@"
        ;;
    restore)
        shift
        restore "$@"
        ;;
    support-bundle)
        shift
        support_bundle "$@"
        ;;
    completion)
        shift
        cmd_completion "$@"
        ;;
    version | --version | -v) cmd_version ;;
    help | -h | --help) usage ;;
    *) error "Unknown command: $1. Try: setup, upgrade, apply, uninstall, doctor, bench, tune, autotune, backup, restore, status, logs, start, stop, restart, enable, disable, bios, api-refresh, msr-apply, support-bundle, completion, version, help." ;;
    esac
fi
