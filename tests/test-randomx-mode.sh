#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317,SC2329
set -euo pipefail

ROOT="${RIGFORGE_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
has() { case "$1" in *"$2"*) ;; *) fail "[$1] missing [$2]" ;; esac }
absent() { case "$1" in *"$2"*) fail "[$1] unexpectedly contains [$2]" ;; esac }

source "$SCRIPT"
warn() { printf 'WARN:%s\n' "$*"; }
log() { :; }
sudo() { "$@"; }
hostname() { jq -r '.. | objects | .url? // empty' "$ROOT/tests/contract/v1/feed.json" | sed 's/:[0-9]*$//' | head -n1; }
lscpu() { printf 'Model name: Generic CPU\nL3 cache: 20 MiB\nSocket(s): 1\nNUMA node(s): 2\n'; }

write_config() {
    CONFIG_JSON="$D/config.json"
    local pool_url
    pool_url=$(jq -r '.. | objects | .url? // empty' "$ROOT/tests/contract/v1/feed.json" | head -n1)
    jq --arg pool_url "$pool_url" '.pools = [{url:$pool_url}]' <<<"$1" >"$CONFIG_JSON"
}

parse_ok() {
    write_config "$1"
    parse_config >/dev/null
}

parse_fails() {
    write_config "$1"
    if (parse_config >/dev/null 2>&1); then
        fail "invalid RandomX config was accepted: $1"
    fi
}

generate() {
    local name=$1 overlay=${2:-}
    WORKER_ROOT="$D/$name/worker"
    local build="$WORKER_ROOT/xmrig/build"
    mkdir -p "$build"
    if [ -n "$overlay" ]; then
        printf '%s\n' "$overlay" >"$WORKER_ROOT/tune-overrides.json"
    fi
    POOLS_JSON='[]'
    (
        cd "$build"
        OS_TYPE=Linux RIGFORGE_APPLIANCE=1 LOG_FILE_PATH="" generate_xmrig_config >/dev/null
    )
    printf '%s\n' "$build/config.json"
}

parse_ok '{}'
default_config=$(generate defaults)
eq "$(jq -c '.randomx | {mode,init,"init-avx2":."init-avx2"}' "$default_config")" '{"mode":"fast","init":-1,"init-avx2":-1}'

parse_ok '{"xmrig":{"randomx":{"mode":"light","init":7,"init-avx2":0}}}'
eq "$(bash -c 'printf %s "${RX_MODE:-}"')" light
overlay='{"randomx":{"mode":"fast","init":19,"init-avx2":1,"1gb-pages":true}}'
light_config=$(generate light "$overlay")
eq "$(jq -c '.randomx | {mode,init,"init-avx2":."init-avx2","1gb-pages":."1gb-pages"}' "$light_config")" '{"mode":"light","init":7,"init-avx2":0,"1gb-pages":false}'
TUNE_BASE="$light_config"
RX_MODE=light
_tune_config "$D/light-candidate.json" 2 false 4 true 2 false false true
eq "$(jq -c '.randomx | {mode,init,"init-avx2":."init-avx2","1gb-pages":."1gb-pages"}' "$D/light-candidate.json")" '{"mode":"light","init":7,"init-avx2":0,"1gb-pages":false}'
eq "$(_seed_g)" false
if RANDOMX_JSON='[]' _tune_config "$D/bad-candidate.json" 2 false 4 true 2 false false true 2>/dev/null; then fail 'a failed xmrig.randomx overlay still produced a tune candidate'; fi
TUNE_TMP="$D/tune-tmp"
MEMO_FILE="$D/tune-memo"
TUNE_MODE=bench
mkdir -p "$TUNE_TMP"
_bench_once() { printf 'benched\n' >"$D/benched"; }
eq "$(RANDOMX_JSON='[]' _measure 2 false 4 true 2 false false true 2>/dev/null)" 0
[ ! -e "$D/benched" ] || fail 'tune benchmarked a candidate whose config failed to render'

parse_ok '{}'
WORKER_ROOT="$D/null-randomx/worker"
mkdir -p "$WORKER_ROOT/xmrig/build"
printf '{"randomx":null}\n' >"$WORKER_ROOT/tune-overrides.json"
printf '{"previous":true}\n' >"$WORKER_ROOT/xmrig/build/config.json"
POOLS_JSON='[]'
if out=$(cd "$WORKER_ROOT/xmrig/build" && OS_TYPE=Linux RIGFORGE_APPLIANCE=1 LOG_FILE_PATH="" generate_xmrig_config 2>&1); then fail 'a failed xmrig.randomx overlay still rendered a config'; fi
has "$out" 'Applying the xmrig.randomx settings failed'
eq "$(cat "$WORKER_ROOT/xmrig/build/config.json")" '{"previous":true}'
eq "$(find "$WORKER_ROOT/xmrig/build" -type f | wc -l | tr -d ' ')" 1

for value in auto fast light; do
    parse_ok "{\"xmrig\":{\"randomx\":{\"mode\":\"$value\",\"init\":2147483647,\"init-avx2\":1}}}"
    mode_config=$(generate "mode-$value")
    eq "$(jq -c '.randomx | {mode,init,"init-avx2":."init-avx2"}' "$mode_config")" "{\"mode\":\"$value\",\"init\":2147483647,\"init-avx2\":1}"
done
for invalid in \
    '{"xmrig":null}' \
    '{"xmrig":[]}' \
    '{"xmrig":{"randomx":null}}' \
    '{"xmrig":{"randomx":[]}}' \
    '{"xmrig":{"randomx":"fast"}}' \
    '{"xmrig":{"randomx":{"mode":null}}}' \
    '{"xmrig":{"randomx":{"mode":"slow"}}}' \
    '{"xmrig":{"randomx":{"mode":1}}}' \
    '{"xmrig":{"randomx":{"init":null}}}' \
    '{"xmrig":{"randomx":{"init":"1"}}}' \
    '{"xmrig":{"randomx":{"init":true}}}' \
    '{"xmrig":{"randomx":{"init":0}}}' \
    '{"xmrig":{"randomx":{"init":-2}}}' \
    '{"xmrig":{"randomx":{"init":1.5}}}' \
    '{"xmrig":{"randomx":{"init":2147483648}}}' \
    '{"xmrig":{"randomx":{"init-avx2":null}}}' \
    '{"xmrig":{"randomx":{"init-avx2":"0"}}}' \
    '{"xmrig":{"randomx":{"init-avx2":false}}}' \
    '{"xmrig":{"randomx":{"init-avx2":2}}}'; do
    parse_fails "$invalid"
done
parse_ok '{"xmrig":{"randomx":{"init":1,"init-avx2":-1}}}'
parse_ok '{"xmrig":{"cpu":{"yield":false},"randomx":{"mode":"light","numa":false}}}'
eq "$RX_MODE" light
overlay_config=$(generate overlay-randomx '{"randomx":{"numa":true,"1gb-pages":true}}')
eq "$(jq -c '{yield:.cpu.yield,mode:.randomx.mode,numa:.randomx.numa,"1gb-pages":.randomx."1gb-pages"}' "$overlay_config")" '{"yield":false,"mode":"light","numa":false,"1gb-pages":false}'

PROPOSED="$ROOT/util/proposed-grub.sh"
PSTUB="$D/proposed-stubs"
mkdir -p "$PSTUB"
cat >"$PSTUB/lscpu" <<'EOF'
#!/usr/bin/env bash
printf 'L3 cache: 20 MiB\nSocket(s): 1\nNUMA node(s): %s\n' "${STUB_NUMA_NODES:-2}"
EOF
cat >"$PSTUB/find" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PSTUB"/*
printf 'flags pdpe1gb\n' >"$D/cpuinfo"
printf '4\n' >"$D/one-gb-pages"

proposed() {
    local args=(-q)
    [ -n "${2:-}" ] && args=("$2" -q)
    env PATH="$PSTUB:$PATH" CPUINFO="$D/cpuinfo" HUGEPAGES_1G_NR="$D/one-gb-pages" \
        RX_THREADS=10 RX_MODE="$1" RESERVE_EXTRA_MB="${3:-0}" POOL_CEILING_MB="${4:-0}" \
        bash "$PROPOSED" "${args[@]}"
}

fast_line=$(proposed fast)
auto_line=$(proposed auto)
eq "$auto_line" "$fast_line"
eq "$(proposed '')" "$fast_line"
has "$fast_line" 'hugepagesz=1G hugepages=6'
has "$fast_line" 'hugepagesz=2M hugepages=148'
light_line=$(proposed light)
absent "$light_line" 'hugepagesz=1G'
has "$light_line" 'default_hugepagesz=2M hugepages=148'
eq "$(STUB_NUMA_NODES=8 proposed light)" "$light_line"
eq "$(proposed light --runtime)" 148
eq "$(proposed light --runtime 5)" 151
eq "$(proposed fast --runtime)" 148
printf '0\n' >"$D/one-gb-pages"
eq "$(proposed fast --runtime)" 2396
eq "$(proposed auto --runtime)" 2396
printf '4\n' >"$D/one-gb-pages"
has "$(proposed light '' 0 200 2>/dev/null)" 'hugepages=100'
has "$(proposed fast '' 0 200 2>/dev/null)" 'hugepagesz=2M hugepages=100'

CALL_ROOT="$D/caller-root"
mkdir -p "$CALL_ROOT/util"
cat >"$CALL_ROOT/util/proposed-grub.sh" <<'EOF'
#!/usr/bin/env bash
printf 'RX_MODE=[%s] args=[%s]\n' "${RX_MODE:-}" "$*" >>"$RANDOMX_CALL_LOG"
case " $* " in *' --runtime '*) printf '148\n' ;; *) printf 'quiet splash default_hugepagesz=2M hugepages=148 msr.allow_writes=on\n' ;; esac
EOF
chmod +x "$CALL_ROOT/util/proposed-grub.sh"
export RANDOMX_CALL_LOG="$D/calls"
SCRIPT_DIR="$CALL_ROOT"
RX_MODE=light
RX_SETUP_THREADS=10
HUGEPAGES_RESERVE_EXTRA_MB=0
HUGEPAGES_POOL_CEILING_MB=0
THREADS_CAP=""
GRUB_DEFAULT="$D/grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' >"$GRUB_DEFAULT"
_grub_proposed
_hugepages_2m_need 7 >/dev/null
_ensure_hugepages() { :; }
RIGFORGE_APPLIANCE=1
OS_TYPE=Linux
MODULES_LOAD_DIR="$D/modules"
MODULES_FILE="$D/modules-file"
mkdir -p "$MODULES_LOAD_DIR"
WORKER_ROOT="$D/caller-worker"
mkdir -p "$WORKER_ROOT"
RIGFORGE_THREADS=10
tune_kernel >/dev/null
write_config '{"xmrig":{"randomx":{"mode":"light"}}}'
RIGFORGE_APPLIANCE=0
MEMINFO="$D/no-meminfo"
FSTAB="$D/fstab"
LIMITS_CONF="$D/limits"
SYSTEMD_DIR="$D/systemd"
_detect_pkg_manager() { return 1; }
plan=$(_setup_plan)
has "$plan" '148 2MB HugePages'
calls=$(cat "$RANDOMX_CALL_LOG")
eq "$(printf '%s\n' "$calls" | wc -l | tr -d ' ')" 5
absent "$calls" 'RX_MODE=[]'
mkdir -p "$D/no-proposed"
_ensure_hugepages() { printf 'called\n' >"$D/unsafe-allocation"; }
if (SCRIPT_DIR="$D/no-proposed" RX_MODE=light tune_kernel >/dev/null 2>&1); then
    fail 'light mode accepted the generic HugePages fallback'
fi
[ ! -e "$D/unsafe-allocation" ] || fail 'light mode allocated the generic HugePages fallback'
has "$(SCRIPT_DIR="$D/no-proposed" RX_MODE=light _setup_plan 2>&1)" 'RandomX light mode requires util/proposed-grub.sh'
if RX_MODE=bogus bash "$PROPOSED" -q >/dev/null 2>&1; then fail 'proposed-grub accepted an invalid RandomX mode'; fi

_ck_info() { printf 'INFO:%s\n' "$*"; }
_ck_warn() { printf 'WARN:%s\n' "$*"; }
mkdir -p "$D/hugepages-1g"
HUGEPAGES_1G_NR="$D/hugepages-1g/nr_hugepages"
printf '0\n' >"$D/hugepages-1g/free_hugepages"
memory_check() {
    write_config "$1"
    MEMINFO="$2" _check_randomx_memory "${3:-n}"
}
printf 'MemAvailable: 2129920 kB\nHugePages_Free: 0\nHugepagesize: 2048 kB\n' >"$D/mem-exact"
out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-exact")
has "$out" 'RandomX mode: fast'
absent "$out" 'WARN:'
printf 'MemAvailable: 2129919 kB\nHugePages_Free: 0\nHugepagesize: 2048 kB\n' >"$D/mem-low"
out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-low" || true)
has "$out" 'RandomX mode: fast'
has "$out" 'WARN:'
out=$(memory_check '{}' "$D/mem-low" || true)
has "$out" 'RandomX mode: fast'
has "$out" 'WARN:'
if memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-low" >/dev/null; then
    fail 'low-memory fast mode returned success'
fi
printf 'MemFree: 1 kB\nHugePages_Free: 1040\nHugepagesize: 2048 kB\n' >"$D/mem-free-pages"
out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-free-pages")
absent "$out" 'WARN:'
printf 'MemAvailable: 2117631 kB\nHugePages_Free: 10\nHugePages_Rsvd: 4\nHugepagesize: 2048 kB\n' >"$D/mem-reserved-pages"
out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-reserved-pages" || true)
has "$out" 'WARN:'
printf 'MemAvailable: 1081344 kB\nHugePages_Free: 0\nHugepagesize: 2048 kB\n' >"$D/mem-free-1g"
printf '2\n' >"$D/hugepages-1g/free_hugepages"
printf '1\n' >"$D/hugepages-1g/resv_hugepages"
out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-free-1g")
absent "$out" 'WARN:'
printf '0\n' >"$D/hugepages-1g/free_hugepages"
printf '0\n' >"$D/hugepages-1g/resv_hugepages"
printf 'MemAvailable: 32768 kB\nHugePages_Free: 1\nHugepagesize: 1048576 kB\n' >"$D/mem-default-1g"
printf '1\n' >"$D/hugepages-1g/free_hugepages"
if out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-default-1g"); then fail 'default 1G pages counted twice'; fi
has "$out" 'WARN:'
printf '0\n' >"$D/hugepages-1g/free_hugepages"
for mode in auto light; do
    out=$(memory_check "{\"xmrig\":{\"randomx\":{\"mode\":\"$mode\"}}}" "$D/mem-low")
    has "$out" "RandomX mode: $mode"
    absent "$out" 'WARN:'
done
out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-low" y)
has "$out" 'RandomX mode: fast'
absent "$out" 'WARN:'
printf 'HugePages_Free: 0\n' >"$D/mem-unknown"
out=$(memory_check '{"xmrig":{"randomx":{"mode":"fast"}}}' "$D/mem-unknown")
has "$out" 'Available memory unknown'
absent "$out" 'WARN:'
if out=$(memory_check '{"xmrig":{"randomx":{"mode":"bogus"}}}' "$D/mem-low"); then fail 'invalid RandomX settings passed the memory check'; fi
has "$out" 'Invalid xmrig.randomx settings'

cmd_version() { :; }
systemctl() { return 1; }
_worker_root_from_config() { :; }
_dmi() { :; }
_lockdown_state() { printf 'none\n'; }
_cpu_missing_isa() { :; }
_nps_suspect() { :; }
mkdir -p "$D/doctor-msr"
MSR_MODULE_DIR="$D/doctor-msr"
GOVERNOR_FILE="$D/no-governor"
CPUFREQ_MAX="$D/no-cpufreq"
CPUINFO="$D/no-cpuinfo"
DMI_DIR="$D/no-dmi"
SMT_CONTROL="$D/no-smt"
NODE_SYSFS="$D/no-node"
LOCKDOWN_FILE="$D/no-lockdown"
DMIDECODE="$D/no-dmidecode"
MEMINFO="$D/doctor-meminfo"
printf 'MemAvailable: 1 kB\nHugePages_Total: 1\nHugePages_Free: 0\nHugepagesize: 2048 kB\n' >"$MEMINFO"
doctor_config() {
    jq -n --arg mode "$1" '{pools:[],xmrig:{randomx:{mode:$mode}}}' >"$CONFIG_JSON"
}
doctor_config light
if light_doctor=$(doctor 2>&1); then fail 'light doctor unexpectedly passed the inactive-service baseline'; fi
has "$light_doctor" 'RandomX mode: light'
absent "$light_doctor" 'RandomX fast needs'
has "$light_doctor" '1GB HugePages disabled in RandomX light mode'
has "$light_doctor" 'doctor: 1 issue(s) found'
doctor_config fast
if fast_doctor=$(doctor 2>&1); then fail 'fast doctor unexpectedly passed low memory'; fi
has "$fast_doctor" 'RandomX mode: fast'
has "$fast_doctor" 'RandomX fast needs'
absent "$fast_doctor" '1GB HugePages disabled'
has "$fast_doctor" 'doctor: 2 issue(s) found'

out=$(CONFIG_JSON="$D/missing-config" _check_randomx_memory)
has "$out" 'RandomX mode unavailable'
absent "$out" 'WARN:'
RX_MODE=light
CONFIG_JSON="$D/missing-config" _check_randomx_memory >/dev/null
eq "$RX_MODE" ''

printf 'randomx config, sizing, callers, and doctor: PASS\n'
