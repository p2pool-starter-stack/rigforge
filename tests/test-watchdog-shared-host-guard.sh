#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export RIGFORGE_HOME="$TEST_DIR/rigforge"
export RIGFORGE_APPLIANCE=0
export NO_COLOR=1
mkdir -p "$RIGFORGE_HOME"
source "$SCRIPT"
OS_TYPE=Linux

STATE=""
FAIL=0
parse_config() {
    WORKER_ROOT="$STATE/worker"
    SERVICE_NAME=xmrig
    OS_TYPE=Linux
    MAX_TEMP_C=""
    [ ! -f "$STATE/cutoff" ] || MAX_TEMP_C=$(cat "$STATE/cutoff")
    mkdir -p "$WORKER_ROOT"
}
_read_temp() { cat "$STATE/temp"; }
_read_api_hashrate() { [ ! -f "$STATE/hashrate" ] || cat "$STATE/hashrate"; }
increment() {
    local file="$1" count
    count=$(cat "$file" 2>/dev/null || printf 0)
    printf '%s\n' "$((count + 1))" >"$file"
}
systemctl() {
    local action="$1"
    shift
    case "$action" in
    is-active)
        [ "$(cat "$STATE/active")" = active ]
        ;;
    stop)
        increment "$STATE/stop-count"
        printf 'inactive\n' >"$STATE/active"
        ;;
    start)
        increment "$STATE/start-count"
        printf 'active\n' >"$STATE/active"
        ;;
    restart)
        increment "$STATE/restart-count"
        printf 'active\n' >"$STATE/active"
        ;;
    show)
        case "$*" in
        'xmrig -p Slice --value')
            [ -f "$STATE/loaded_slice" ] && cat "$STATE/loaded_slice" && return 0
            return 1
            ;;
        'xmrig -p ExecStartPre --value')
            [ -f "$STATE/loaded_pre" ] && cat "$STATE/loaded_pre" && return 0
            return 1
            ;;
        *) return 1 ;;
        esac
        ;;
    *) return 1 ;;
    esac
}
sudo() {
    [ "$1" = systemctl ]
    shift
    systemctl "$@"
}
bad() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL=1
}
assert_count() {
    local file="$1" expected="$2" actual
    actual=$(cat "$STATE/$file" 2>/dev/null || printf 0)
    [ "$actual" = "$expected" ] || bad "$file was $actual, expected $expected"
}
assert_active() {
    [ "$(cat "$STATE/active")" = "$1" ] || bad "service was not $1"
}
assert_hold_kept() {
    [ -f "$STATE/worker/watchdog.thermal-hold" ] || bad 'guard refusal removed the thermal hold'
}
assert_guard_message() {
    local pattern="$1" file="$2"
    grep -q "$pattern" "$file" || bad "refusal did not carry the guard message: $pattern"
    grep -q 'run apply' "$file" || bad 'refusal did not tell the operator to run apply'
}
assert_no_error() {
    ! grep -q '\[ERROR\]' "$1" || bad "tick that starts nothing reported an error: $1"
}
tick_ok() {
    local name="$1"
    (watchdog) >"$STATE/$name.log" 2>&1 || bad "$name: watchdog tick failed unexpectedly"
}
tick_refused() {
    local name="$1"
    if (watchdog) >"$STATE/$name.log" 2>&1; then bad "$name: start proceeded despite the failing guard"; fi
}
new_state() {
    STATE="$TEST_DIR/$1"
    mkdir -p "$STATE/worker" "$STATE/systemd"
    printf '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":4096}}\n' >"$STATE/config.json"
    CONFIG_JSON="$STATE/config.json"
    SYSTEMD_DIR="$STATE/systemd"
    printf 'active\n' >"$STATE/active"
}
in_profile() {
    printf '# RigForge shared-host profile\n' >"$SYSTEMD_DIR/xmrig.service"
    printf 'rigforge.slice\n' >"$STATE/loaded_slice"
    printf '/usr/bin/env rigforge.sh shared-host-check\n' >"$STATE/loaded_pre"
}

new_state hot-out-of-profile
printf '90\n' >"$STATE/cutoff"
printf '96\n' >"$STATE/temp"
tick_ok hot-stop
assert_count stop-count 1
assert_active inactive
[ -f "$STATE/worker/watchdog.thermal-hold" ] || bad 'failing guard blocked the thermal stop'
grep -q 'miner stopped' "$STATE/hot-stop.log" || bad 'thermal stop was not reported'
assert_no_error "$STATE/hot-stop.log"

new_state lift-out-of-profile
printf 'inactive\n' >"$STATE/active"
printf '90\n' >"$STATE/cutoff"
printf '80\n' >"$STATE/temp"
: >"$STATE/worker/watchdog.thermal-hold"
tick_refused lift-refused
assert_count start-count 0
assert_active inactive
assert_hold_kept
assert_guard_message 'not bounded' "$STATE/lift-refused.log"

new_state lift-removed-out-of-profile
printf 'inactive\n' >"$STATE/active"
printf '70\n' >"$STATE/temp"
: >"$STATE/worker/watchdog.thermal-hold"
tick_refused lift-removed-refused
assert_count start-count 0
assert_active inactive
assert_hold_kept
assert_guard_message 'not bounded' "$STATE/lift-removed-refused.log"

new_state hold-active-out-of-profile
printf 'inactive\n' >"$STATE/active"
printf '90\n' >"$STATE/cutoff"
printf '96\n' >"$STATE/temp"
: >"$STATE/worker/watchdog.thermal-hold"
tick_ok hold-active
assert_count start-count 0
assert_active inactive
[ -f "$STATE/worker/watchdog.thermal-hold" ] || bad 'hold-retaining tick removed the hold'
grep -q 'thermal hold active' "$STATE/hold-active.log" || bad 'hold-retaining tick did not report the hold'
assert_no_error "$STATE/hold-active.log"

new_state wedge-show-fails
printf '# RigForge shared-host profile\n' >"$SYSTEMD_DIR/xmrig.service"
tick_ok wedge-strike-1
assert_count restart-count 0
[ "$(cat "$STATE/worker/watchdog.fails")" = 1 ] || bad 'first wedge strike was not recorded'
assert_no_error "$STATE/wedge-strike-1.log"
tick_refused wedge-restart-refused
assert_count restart-count 0
assert_active active
[ ! -e "$STATE/worker/watchdog.fails" ] || bad 'refused wedge restart left the strike counter'
assert_guard_message 'Cannot inspect the loaded miner service' "$STATE/wedge-restart-refused.log"

new_state in-profile
in_profile
printf '90\n' >"$STATE/cutoff"
printf '96\n' >"$STATE/temp"
tick_ok in-profile-hot-stop
assert_count stop-count 1
assert_active inactive
[ -f "$STATE/worker/watchdog.thermal-hold" ] || bad 'in-profile stop did not record the thermal hold'
printf '80\n' >"$STATE/temp"
tick_ok in-profile-lift
assert_count start-count 1
assert_active active
[ ! -e "$STATE/worker/watchdog.thermal-hold" ] || bad 'in-profile lift kept the thermal hold'
grep -q 'hold lifted, miner started' "$STATE/in-profile-lift.log" || bad 'in-profile lift was not reported'

new_state in-profile-wedge
in_profile
tick_ok in-profile-wedge-strike-1
tick_ok in-profile-wedge-restart
assert_count restart-count 1
grep -q 'miner wedged' "$STATE/in-profile-wedge-restart.log" || bad 'in-profile wedge restart was not reported'

[ "$FAIL" = 0 ] || exit 1
printf 'watchdog shared-host start guard ordering: PASS\n'
