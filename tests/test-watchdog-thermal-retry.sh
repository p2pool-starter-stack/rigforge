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
_read_api_hashrate() { printf '100\n'; }
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
        [ ! -f "$STATE/stop-fail" ] || return 1
        printf 'inactive\n' >"$STATE/active"
        ;;
    start)
        increment "$STATE/start-count"
        [ ! -f "$STATE/start-fail" ] || return 1
        printf 'active\n' >"$STATE/active"
        ;;
    restart)
        printf 'active\n' >"$STATE/active"
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
assert_failure_warning() {
    local action="$1" log="$2"
    grep -q '^\[WARN\] watchdog:' "$log" || bad "$action failure was not warned"
    grep -Eqi "$action.*(failed|could not)|(failed|could not).*$action" "$log" || bad "$action failure was not reported"
    grep -qi 'retry' "$log" || bad "$action failure did not promise a retry"
}
tick() {
    local name="$1"
    (watchdog) >"$STATE/$name.log" 2>&1
}
new_state() {
    STATE="$TEST_DIR/$1"
    mkdir -p "$STATE/worker"
}

new_state stop-retry
printf 'active\n' >"$STATE/active"
printf '90\n' >"$STATE/cutoff"
printf '96\n' >"$STATE/temp"
: >"$STATE/stop-fail"
tick stop-failed-1
assert_count stop-count 1
assert_active active
[ ! -e "$STATE/worker/watchdog.thermal-hold" ] || bad 'failed stop created a thermal hold'
assert_failure_warning stop "$STATE/stop-failed-1.log"
! grep -q 'miner stopped' "$STATE/stop-failed-1.log" || bad 'failed stop reported success'
tick stop-failed-2
assert_count stop-count 2
assert_active active
[ ! -e "$STATE/worker/watchdog.thermal-hold" ] || bad 'repeated failed stop created a thermal hold'
assert_failure_warning stop "$STATE/stop-failed-2.log"
rm "$STATE/stop-fail"
tick stop-recovered
assert_count stop-count 3
assert_active inactive
[ -f "$STATE/worker/watchdog.thermal-hold" ] || bad 'successful retry did not create a thermal hold'
grep -q 'miner stopped' "$STATE/stop-recovered.log" || bad 'successful stop was not reported'

for mode in cooled removed; do
    new_state "start-$mode"
    printf 'inactive\n' >"$STATE/active"
    printf '80\n' >"$STATE/temp"
    [ "$mode" = removed ] || printf '90\n' >"$STATE/cutoff"
    : >"$STATE/worker/watchdog.thermal-hold"
    : >"$STATE/start-fail"
    tick start-failed
    assert_count start-count 1
    assert_active inactive
    [ -f "$STATE/worker/watchdog.thermal-hold" ] || bad "$mode failed start removed the thermal hold"
    assert_failure_warning start "$STATE/start-failed.log"
    ! grep -q 'hold lifted, miner started' "$STATE/start-failed.log" || bad "$mode failed start reported success"
    tick start-failed-2
    assert_count start-count 2
    assert_active inactive
    [ -f "$STATE/worker/watchdog.thermal-hold" ] || bad "$mode repeated failed start removed the thermal hold"
    assert_failure_warning start "$STATE/start-failed-2.log"
    rm "$STATE/start-fail"
    tick start-recovered
    assert_count start-count 3
    assert_active active
    [ ! -e "$STATE/worker/watchdog.thermal-hold" ] || bad "$mode successful retry kept the thermal hold"
    grep -q 'hold lifted, miner started' "$STATE/start-recovered.log" || bad "$mode successful retry was not reported"
done

new_state roundtrip
printf 'active\n' >"$STATE/active"
printf '90\n' >"$STATE/cutoff"
printf '96\n' >"$STATE/temp"
tick stopped
assert_count stop-count 1
assert_active inactive
[ -f "$STATE/worker/watchdog.thermal-hold" ] || bad 'successful stop did not create a thermal hold'
: >"$STATE/temp"
tick unreadable
assert_count start-count 0
assert_active inactive
grep -q 'thermal hold active (temp unreadable' "$STATE/unreadable.log" || bad 'unreadable temperature did not preserve the hold'
printf '85\n' >"$STATE/temp"
tick boundary
assert_count start-count 0
assert_active inactive
printf '84\n' >"$STATE/temp"
tick cooled
assert_count start-count 1
assert_active active
[ ! -e "$STATE/worker/watchdog.thermal-hold" ] || bad 'successful roundtrip kept the thermal hold'

[ "$FAIL" = 0 ] || exit 1
printf 'watchdog thermal command retries: PASS\n'
