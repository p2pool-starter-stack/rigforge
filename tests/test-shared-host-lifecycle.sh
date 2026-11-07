#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2218,SC2329
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D" RIGFORGE_APPLIANCE=1
source "$SCRIPT"

fail() {
    printf 'shared host lifecycle regression: %s\n' "$1" >&2
    exit 1
}
assert_fails() {
    local label="$1"
    shift
    if ("$@") >"$D/result" 2>&1; then fail "$label unexpectedly passed"; fi
}
sudo() { "$@"; }
hostname() { :; }
lscpu() { printf 'Model name: Fixture CPU\nFlags: aes avx2\n'; }

OS_TYPE=Linux
SCRIPT_DIR="$ROOT"
WORKER_ROOT="$D/worker"
SYSTEMD_DIR="$D/systemd"
CONFIG_JSON="$D/config.json"
POOLS_JSON='[]'
ACCESS_TOKEN=''
DONATION=3
THREADS_CAP=2
MINER_USER=rigforge-miner
SHARED_HOST=true
mkdir -p "$WORKER_ROOT/xmrig/build" "$SYSTEMD_DIR"
printf '{"cpu":{"yield":false,"priority":2,"rx":99,"rx/wow":[0,1],"huge-pages":true,"memory-pool":true},"randomx":{"wrmsr":true,"rdmsr":true,"cache_qos":true,"1gb-pages":true,"numa":true},"pools":[{"user":"fixture"}],"http":{"access-token":"sentinel"},"donate-level":99,"autosave":true}\n' >"$WORKER_ROOT/tune-overrides.json"
(
    cd "$WORKER_ROOT/xmrig/build"
    generate_xmrig_config >/dev/null
)
cfg="$WORKER_ROOT/xmrig/build/config.json"
jq -e '
  .autosave == false and .cpu.yield == true and .cpu.priority == 1 and
  .cpu.rx == [-1,-1] and .cpu."*" == .cpu.rx and (.cpu | has("rx/wow") | not) and
  .cpu."huge-pages" == false and .cpu."memory-pool" == false and
  .randomx.wrmsr == false and .randomx.rdmsr == false and .randomx.cache_qos == false and
  .randomx."1gb-pages" == false and .randomx.numa == false and .randomx.init == 2 and
  ."donate-level" == 3 and .pools == [] and .http."access-token" == null
' "$cfg" >/dev/null || fail 'hostile tune overrides escaped shared safeguards'
cp "$cfg" "$D/first.json"
(
    cd "$WORKER_ROOT/xmrig/build"
    generate_xmrig_config >/dev/null
)
cmp -s "$D/first.json" "$cfg" || fail 'repeated generation changed shared safeguards'

BUILD_DIR="$WORKER_ROOT/xmrig/build"
CPUPOWER_PATH=cpupower
NFT_PATH=nft
_render_xmrig_unit
unit="$SYSTEMD_DIR/$SERVICE_NAME.service"
grep -qFx '# RigForge shared-host profile' "$unit" || fail 'shared unit lacks ownership marker'
grep -qFx 'Slice=rigforge.slice' "$unit" || fail 'miner not placed in budgeted slice'
! grep -q 'frequency-set -g performance' "$unit" || fail 'shared unit retunes governor'
! grep -q '^ExecStartPre=.*msr-apply' "$unit" || fail 'shared unit writes MSRs'
SHARED_HOST=false
_render_xmrig_unit
grep -q 'frequency-set -g performance' "$unit" || fail 'dedicated governor changed'
grep -q '^ExecStartPre=.*msr-apply' "$unit" || fail 'dedicated MSR behavior changed'
! grep -qFx 'Slice=rigforge.slice' "$unit" || fail 'dedicated miner retained shared slice'

printf '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":4096}}\n' >"$CONFIG_JSON"
assert_fails 'starting an unbounded unit' svc_start
assert_fails 'restarting an unbounded unit' svc_restart
SHARED_HOST=true
_render_xmrig_unit
LOADED_SLICE=rigforge.slice
LOADED_PRECHECK='rigforge.sh shared-host-check'
systemctl() {
    case "$*" in
    "show $SERVICE_NAME -p Slice --value") printf '%s\n' "$LOADED_SLICE" ;;
    "show $SERVICE_NAME -p ExecStartPre --value") printf '%s\n' "$LOADED_PRECHECK" ;;
    *) printf '%s\n' "$*" >>"$D/systemctl-calls" ;;
    esac
}
LOADED_SLICE=system.slice
assert_fails 'marked unit with stale loaded slice' svc_start
[ ! -e "$D/systemctl-calls" ] || fail 'stale loaded slice reached systemctl start'
LOADED_SLICE=rigforge.slice
LOADED_PRECHECK=''
assert_fails 'marked unit without loaded startup check' svc_restart
[ ! -e "$D/systemctl-calls" ] || fail 'missing loaded startup check reached systemctl restart'
LOADED_PRECHECK='rigforge.sh shared-host-check'
svc_start >/dev/null
svc_restart >/dev/null
grep -qFx "start $SERVICE_NAME" "$D/systemctl-calls" || fail 'bounded start not passed to systemd'
grep -qFx "restart $SERVICE_NAME" "$D/systemctl-calls" || fail 'bounded restart not passed to systemd'

assert_fails 'direct offline benchmark' _xmrig_bench unused 1M ''
parse_config() { SHARED_HOST=true; }
assert_fails 'full live tuning' tune --live

systemd-run() {
    printf '%s\n' "$@" >"$D/scope-args"
    IFS= read -r -d '' power_command || fail 'helper power command frame is missing'
    printf '%s' "$power_command" >"$D/helper-power-command"
}
AUTOTUNE_TARGET=efficiency TUNE_POWER_CMD='printf 42' AUTOTUNE_SAMPLES=2 AUTOTUNE_INTERVAL=3 \
    AUTOTUNE_WARMUP=4 AUTOTUNE_MARGIN=0.05 AUTOTUNE_MODES='0 2' _shared_host_run true
grep -q -- '--slice=rigforge.slice' "$D/scope-args" || fail 'helper did not enter budgeted slice'
grep -q -- '--property=Nice=19' "$D/scope-args" || fail 'helper scheduling was not conservative'
grep -qFx 'printf 42' "$D/helper-power-command" || fail 'helper power command did not reach stdin'
! grep -qF 'printf 42' "$D/scope-args" || fail 'helper power command leaked into systemd arguments'
for setting in 'AUTOTUNE_TARGET=efficiency' 'AUTOTUNE_SAMPLES=2' \
    'AUTOTUNE_INTERVAL=3' 'AUTOTUNE_WARMUP=4' 'AUTOTUNE_MARGIN=0.05' 'AUTOTUNE_MODES=0 2'; do
    grep -qFx -- "--setenv=$setting" "$D/scope-args" || fail "helper lost $setting"
done
_shared_host_check() { [ "$1" = helper ] || fail 'helper used the wrong guard'; }
printf '%s\0' 'printf 42' | (_shared_host_exec bash -c '[ "$TUNE_POWER_CMD" = "printf 42" ]') ||
    fail 'valid helper power command frame was not exported'
assert_fails 'missing helper power command frame' _shared_host_exec true </dev/null
_shared_host_in_slice() { return 1; }
_shared_host_run() {
    printf '%s\n' "$*" >"$D/autotune-scope"
    printf '%s\n' "$AUTOTUNE_TARGET" >"$D/autotune-target"
}
autotune >/dev/null
grep -q 'rigforge.sh autotune' "$D/autotune-scope" || fail 'autotune bypassed budgeted helper scope'
parse_config() {
    SHARED_HOST=true
    AUTOTUNE_TARGET="$CONFIG_AUTOTUNE_TARGET"
}
CONFIG_AUTOTUNE_TARGET=efficiency
AUTOTUNE_TARGET='' tune --now --perf >/dev/null
grep -qFx perf "$D/autotune-target" || fail 'explicit performance target lost before helper hop'
CONFIG_AUTOTUNE_TARGET=perf
AUTOTUNE_TARGET='' tune --now --efficiency >/dev/null
grep -qFx efficiency "$D/autotune-target" || fail 'explicit efficiency target lost before helper hop'
autotune() { printf 'bounded live trial\n' >"$D/live-trial"; }
tune --now >/dev/null
[ -f "$D/live-trial" ] || fail 'bounded quick tune did not use autotune'

printf 'MemTotal: 16777216 kB\n' >"$D/meminfo16"
[ "$(SHARED_HOST=false MEMINFO="$D/meminfo16" compute_build_jobs 8)" = 8 ] || fail 'dedicated build parallelism changed'
[ "$(SHARED_HOST=true SHARED_MEMORY_MAX_MB=3072 MEMINFO="$D/meminfo16" compute_build_jobs 8)" = 1 ] || fail 'shared build sized from host RAM'
[ "$(SHARED_HOST=true SHARED_MEMORY_MAX_MB=8192 MEMINFO="$D/meminfo16" compute_build_jobs 8)" = 4 ] || fail 'shared build ignored its ceiling'
(
    git() {
        case "$1" in
        clone)
            mkdir -p xmrig.new/src
            printf 'constexpr const int kDefaultDonateLevel = 1;\nconstexpr const int kMinimumDonateLevel = 1;\n' >xmrig.new/src/donate.h
            ;;
        -C) printf '%s\n' "$XMRIG_COMMIT" ;;
        esac
    }
    nproc() { printf '8\n'; }
    systemctl() {
        case "$1" in
        is-active) return 0 ;;
        stop) printf 'stop %s\n' "$2" >>"$D/compile-calls" ;;
        esac
    }
    _shared_host_run() { printf '%s\n' "$*" >>"$D/compile-calls"; }
    generate_xmrig_config() { :; }
    _activate_xmrig_build() { :; }
    MEMINFO="$D/meminfo16" SHARED_HOST=true SHARED_MEMORY_MAX_MB=3072 XMRIG_REBUILD=true XMRIG_VERSION=v0 XMRIG_COMMIT=fixture DONATION=3
    compile_xmrig >/dev/null
)
[ "$(head -n1 "$D/compile-calls")" = "stop $SERVICE_NAME.service" ] || fail 'shared build started beside a running miner'
grep -qFx 'make -j1' "$D/compile-calls" || fail 'shared build parallelism exceeded the memory ceiling'

printf 'external slice\n' >"$SYSTEMD_DIR/rigforge.slice"
_shared_host_remove
[ -f "$SYSTEMD_DIR/rigforge.slice" ] || fail 'unowned slice was removed'
printf 'Description=RigForge shared-host resource budget\n' >"$SYSTEMD_DIR/rigforge.slice"
_shared_host_remove
[ ! -e "$SYSTEMD_DIR/rigforge.slice" ] || fail 'owned slice survived removal'

trace() { printf '%s\n' "$1" >>"$D/trace"; }
assert_order() {
    awk -v first="$1" -v second="$2" '
        $0 == first { a = NR }
        $0 == second { b = NR }
        END { exit !(a > 0 && b > a) }
    ' "$D/trace" || fail "$1 was not before $2"
}
_persist_appliance_mode() { :; }
check_prerequisites() { :; }
ensure_config_exists() { :; }
parse_config() {
    SHARED_HOST=true
    trace parse
}
_shared_host_prepare() { trace prepare; }
decide_rebuild() { XMRIG_REBUILD=false; }
prepare_workspace() { :; }
install_dependencies() { :; }
compile_xmrig() { trace compile; }
generate_xmrig_config() { trace generate; }
tune_kernel() { :; }
configure_limits() { :; }
install_service() { trace service; }
install_autotune() { :; }
install_watchdog() { :; }
install_api() { :; }
install_control() { :; }
install_api_firewall() { :; }
link_cli() { :; }
_reown_worker() { :; }
finish_deployment() { :; }
_upgrade_restart() { trace restart; }
_post_upgrade_retune() { :; }
_ensure_miner_user() { :; }
_render_xmrig_unit() { :; }
_apply_runtime() { trace runtime; }
_autotune_apply_notice() { :; }
_stamp_config_meta() { :; }
_apply_pool_check() { :; }

: >"$D/trace"
main >/dev/null
assert_order prepare compile
assert_order prepare service
: >"$D/trace"
upgrade >/dev/null
assert_order prepare compile
assert_order prepare restart
: >"$D/trace"
apply >/dev/null
assert_order prepare runtime

printf 'shared host generation, service and helper lifecycle regressions: PASS\n'
