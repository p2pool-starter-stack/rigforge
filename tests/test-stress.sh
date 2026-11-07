#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-$ROOT/rigforge.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
source "$SCRIPT"

declare -F stress >/dev/null || {
    printf 'FAIL: stress command is not loaded\n' >&2
    exit 1
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_case() {
    CASE_DIR="$TMP/$1"
    mkdir -p "$CASE_DIR/worker/xmrig/build"
    printf '%s\n' '{"pools":[],"http":{"enabled":true},"background":true,"autosave":true,"watch":true,"pause-on-active":true,"pause-on-battery":true,"stress":"other","benchmark":true}' >"$CASE_DIR/worker/xmrig/build/config.json"
    CALLS="$CASE_DIR/calls"
    : >"$CALLS"
    CLOCK=0
    TEMP_INDEX=0
    printf 0 >"$CASE_DIR/temp-index"
    SERVICE_ACTIVE=${2:-1}
    AUTOTUNE_TIMER_ACTIVE=1
    WATCHDOG_TIMER_ACTIVE=1
    AUTOTUNE_SERVICE_STATE=inactive
    WATCHDOG_SERVICE_STATE=inactive
    XMRIG_MODE=hashing
    TEMP_VALUES='50'
    MAX_TEMP_C=80
    SAMPLE_STEP=2
    FAIL_START=''
    HOLD_WRITE_FAIL=0
    OS_TYPE=Linux
}

parse_config() { WORKER_ROOT="$CASE_DIR/worker"; }
_tune_should_elevate() { return 1; }
_stress_now() { printf '%s' "$CLOCK"; }
_stress_sleep() {
    local n
    CLOCK=$((CLOCK + SAMPLE_STEP))
    /bin/sleep 0.01
    if [ "$XMRIG_MODE" = latefail ]; then
        for n in 1 2 3 4 5 6 7 8 9 10; do
            [ -f "$CASE_DIR/exited" ] && break
            /bin/sleep 0.01
        done
    fi
}
touch() {
    if [ "$HOLD_WRITE_FAIL" = 1 ]; then return 1; fi
    command touch "$@"
}
_read_temp() {
    local value
    TEMP_INDEX=$(cat "$CASE_DIR/temp-index")
    TEMP_INDEX=$((TEMP_INDEX + 1))
    printf '%s' "$TEMP_INDEX" >"$CASE_DIR/temp-index"
    value=$(printf '%s\n' $TEMP_VALUES | sed -n "${TEMP_INDEX}p")
    [ -n "$value" ] || value=$(printf '%s\n' $TEMP_VALUES | tail -1)
    printf '%s' "$value"
}
systemctl() {
    local quiet=0 state
    [ "$1" = is-active ] || return 1
    shift
    if [ "${1:-}" = --quiet ]; then
        quiet=1
        shift
    fi
    if [ "$1" = rigforge-autotune.service ] || [ "$1" = rigforge-watchdog.service ]; then
        if [ "$1" = rigforge-autotune.service ]; then state=$AUTOTUNE_SERVICE_STATE; else state=$WATCHDOG_SERVICE_STATE; fi
        [ "$quiet" = 1 ] || printf '%s\n' "$state"
        [ "$state" = active ] && return 0
        return 3
    fi
    case "$1" in
    xmrig) [ "$SERVICE_ACTIVE" = 1 ] ;;
    rigforge-autotune.timer) [ "$AUTOTUNE_TIMER_ACTIVE" = 1 ] ;;
    rigforge-watchdog.timer) [ "$WATCHDOG_TIMER_ACTIVE" = 1 ] ;;
    *) return 1 ;;
    esac
}
sudo() {
    [ "$1" = systemctl ] || return 1
    shift
    printf '%s\n' "$*" >>"$CALLS"
    if [ "$1" = start ] && [ "${FAIL_START:-}" = "$2" ]; then return 1; fi
    case "$1:$2" in
    stop:xmrig) SERVICE_ACTIVE=0 ;;
    start:xmrig) SERVICE_ACTIVE=1 ;;
    stop:rigforge-autotune.timer) AUTOTUNE_TIMER_ACTIVE=0 ;;
    start:rigforge-autotune.timer) AUTOTUNE_TIMER_ACTIVE=1 ;;
    stop:rigforge-watchdog.timer) WATCHDOG_TIMER_ACTIVE=0 ;;
    start:rigforge-watchdog.timer) WATCHDOG_TIMER_ACTIVE=1 ;;
    esac
}

make_xmrig() {
    local bin="$CASE_DIR/worker/xmrig/build/xmrig"
    cat >"$bin" <<'EOF'
#!/usr/bin/env bash
log=''
config=''
for arg in "$@"; do
    case "$arg" in
    --log-file=*) log=${arg#*=} ;;
    --config=*) config=${arg#*=} ;;
    esac
done
printf '%s\n' "$*" >"$CASE_DIR/argv"
printf '%s' "$$" >"$CASE_DIR/xmrig-pid"
cp "$config" "$CASE_DIR/stress-config"
case "$XMRIG_MODE" in
hashing) printf 'miner speed 10s/60s/15m 1234.5 n/a n/a H/s max 1234.5 H/s\n' >"$log" ;;
ready) printf 'READY\n' >"$log" ;;
zero) printf '%s\n' 'miner speed 10s/60s/15m 1234.5 n/a n/a H/s' 'miner speed 10s/60s/15m 0.0 n/a n/a H/s' >"$log" ;;
currentzero) printf 'miner speed 10s/60s/15m 0.0 1234.5 1234.5 H/s\n' >"$log" ;;
fatal) printf '%s\n' 'miner speed 10s/60s/15m 1234.5 n/a n/a H/s' 'MEMORY ALLOC FAILED' >"$log" ;;
latefail)
    printf 'miner speed 10s/60s/15m 1234.5 n/a n/a H/s\n' >"$log"
    sleep 0.005
    : >"$CASE_DIR/exited"
    exit 0
    ;;
fail) exit 7 ;;
esac
child=''
trap '[ -z "$child" ] || kill "$child" 2>/dev/null; exit 0' TERM INT HUP
while :; do
    sleep 30 &
    child=$!
    wait "$child" 2>/dev/null || true
done
EOF
    chmod +x "$bin"
    export CASE_DIR XMRIG_MODE
}

run_case() {
    local rc=0
    stress --minutes 1 >"$CASE_DIR/output" 2>&1 || rc=$?
    printf '%s' "$rc"
}

make_case success 1
make_xmrig
[ "$(run_case)" = 0 ] || fail 'hashing stress run failed'
grep -q '^stop xmrig$' "$CALLS" || fail 'active miner was not stopped'
grep -q '^start xmrig$' "$CALLS" || fail 'active miner was not restored'
for timer in rigforge-autotune.timer rigforge-watchdog.timer; do
    grep -q "^stop $timer$" "$CALLS" || fail "$timer was not paused"
    grep -q "^start $timer$" "$CALLS" || fail "$timer was not restored"
done
grep -q -- '--stress' "$CASE_DIR/argv" || fail 'XMRig stress mode was not used'
safe_cfg=$(sed -n 's/.*--config=\([^ ]*\).*/\1/p' "$CASE_DIR/argv")
if [ -e "$safe_cfg" ]; then fail 'temporary stress config was not removed'; fi
jq -e 'has("pools") == false and has("http") == false and has("stress") == false and has("benchmark") == false and .background == false and .autosave == false and .watch == false and ."pause-on-active" == false and ."pause-on-battery" == false' "$CASE_DIR/stress-config" >/dev/null || fail 'stress config was not sanitized'
grep -q 'Stress PASS:.*peak temperature 50°C' "$CASE_DIR/output" || fail 'success report lacks peak temperature'
printf 'PASS: hashing run stops and restores the active miner\n'

for busy_unit in autotune watchdog; do
    make_case "activating-$busy_unit" 1
    if [ "$busy_unit" = autotune ]; then AUTOTUNE_SERVICE_STATE=activating; else WATCHDOG_SERVICE_STATE=activating; fi
    make_xmrig
    busy_rc=0
    (stress --minutes 1 >"$CASE_DIR/output" 2>&1) || busy_rc=$?
    [ "$busy_rc" -ne 0 ] || fail "activating $busy_unit unit did not block stress"
    if grep -q '^stop xmrig$' "$CALLS"; then fail "miner stopped while $busy_unit was activating"; fi
    [ ! -e "$CASE_DIR/argv" ] || fail "XMRig launched while $busy_unit was activating"
    grep -q '^start rigforge-autotune.timer$' "$CALLS" || fail "autotune timer was not restored after $busy_unit refusal"
    grep -q '^start rigforge-watchdog.timer$' "$CALLS" || fail "watchdog timer was not restored after $busy_unit refusal"
done
printf 'PASS: activating scheduled units refuse stress before miner changes\n'

make_case default 0
make_xmrig
SAMPLE_STEP=60
default_rc=0
stress >"$CASE_DIR/output" 2>&1 || default_rc=$?
[ "$default_rc" = 0 ] || fail 'default stress run failed'
grep -q 'for 30 minute(s)' "$CASE_DIR/output" || fail 'default duration is not 30 minutes'
for invalid in 0 1441 1.5; do
    invalid_rc=0
    (stress --minutes "$invalid" >/dev/null 2>&1) || invalid_rc=$?
    [ "$invalid_rc" -ne 0 ] || fail "invalid duration $invalid passed"
done
leading_rc=0
stress --minutes 08 >"$CASE_DIR/output" 2>&1 || leading_rc=$?
[ "$leading_rc" = 0 ] || fail 'leading-zero duration failed'
grep -q 'for 8 minute(s)' "$CASE_DIR/output" || fail 'leading-zero duration was not normalized'
printf 'PASS: duration defaults to 30 minutes and stays bounded\n'

make_case inactive 0
make_xmrig
[ "$(run_case)" = 0 ] || fail 'inactive-miner stress run failed'
if grep -q ' xmrig$' "$CALLS"; then fail 'originally inactive miner was changed'; fi
printf 'PASS: originally inactive miner stays inactive\n'

make_case stale-hold-active 1
command touch "$CASE_DIR/worker/watchdog.thermal-hold"
make_xmrig
[ "$(run_case)" = 0 ] || fail 'active miner with a stale hold failed stress'
grep -q '^start xmrig$' "$CALLS" || fail 'stale hold blocked restoration of an originally active miner'
[ -f "$CASE_DIR/worker/watchdog.thermal-hold" ] || fail 'preexisting active thermal hold was removed'
printf 'PASS: active state is restored without changing its preexisting hold\n'

make_case held-inactive 0
command touch "$CASE_DIR/worker/watchdog.thermal-hold"
make_xmrig
[ "$(run_case)" = 0 ] || fail 'inactive held miner failed stress'
if grep -q '^start xmrig$' "$CALLS"; then fail 'originally inactive held miner was started'; fi
[ -f "$CASE_DIR/worker/watchdog.thermal-hold" ] || fail 'preexisting inactive thermal hold was removed'
printf 'PASS: inactive thermal hold remains stopped and unchanged\n'

make_case failed 1
XMRIG_MODE=fail
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'early XMRig exit passed'
grep -q '^start xmrig$' "$CALLS" || fail 'miner was not restored after XMRig failure'
grep -q 'Stress FAIL: XMRig exited.*peak temperature 50°C' "$CASE_DIR/output" || fail 'process failure lacks peak temperature'
printf 'PASS: process failure restores the miner and fails\n'

make_case nohash 1
XMRIG_MODE=ready
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'READY without hashing passed'
grep -q 'latest speed report was not a positive hashrate' "$CASE_DIR/output" || fail 'missing hashrate was not reported'
printf 'PASS: readiness without hashing fails\n'

make_case zero 1
XMRIG_MODE=zero
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'latest zero hashrate passed after an earlier positive sample'
grep -q 'latest speed report was not a positive hashrate' "$CASE_DIR/output" || fail 'latest zero hashrate was not reported'
printf 'PASS: latest zero speed fails despite an earlier positive speed\n'

make_case current-zero 1
XMRIG_MODE=currentzero
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'zero current hashrate passed on positive historical averages'
grep -q 'latest speed report was not a positive hashrate' "$CASE_DIR/output" || fail 'zero current hashrate was not reported'
printf 'PASS: zero current speed fails despite positive historical averages\n'

make_case fatal 1
XMRIG_MODE=fatal
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'fatal XMRig output passed'
grep -q 'fatal memory or config error' "$CASE_DIR/output" || fail 'fatal XMRig output was not reported'
printf 'PASS: fatal memory or config output fails\n'

make_case late 1
XMRIG_MODE=latefail
SAMPLE_STEP=60
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'process exit at the deadline passed'
grep -q 'XMRig exited before' "$CASE_DIR/output" || fail 'deadline process exit was not reported'
printf 'PASS: process liveness is checked before deadline success\n'

make_case thermal 1
TEMP_VALUES='70 81'
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'thermal cutoff passed'
[ -f "$CASE_DIR/worker/watchdog.thermal-hold" ] || fail 'thermal hold was not recorded'
if grep -q '^start xmrig$' "$CALLS"; then fail 'hot miner was restarted'; fi
grep -q 'Stress FAIL: temperature 81.*peak temperature 81°C' "$CASE_DIR/output" || fail 'thermal failure lacks peak temperature'
printf 'PASS: thermal cutoff leaves recovery to watchdog\n'

make_case hold-failure 1
TEMP_VALUES='81'
HOLD_WRITE_FAIL=1
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'thermal hold write failure passed'
if grep -q '^start xmrig$' "$CALLS"; then fail 'hold write failure restarted the hot miner'; fi
grep -q 'recover it manually after it cools' "$CASE_DIR/output" || fail 'hold write failure lacks manual recovery guidance'
printf 'PASS: failed hold write still leaves the hot miner stopped\n'

make_case restore-failure 1
FAIL_START=xmrig
make_xmrig
[ "$(run_case)" -ne 0 ] || fail 'miner restoration failure passed'
grep -q 'could not restore xmrig' "$CASE_DIR/output" || fail 'restoration failure was not reported'
if grep -q 'Stress PASS' "$CASE_DIR/output"; then fail 'PASS was printed before failed restoration'; fi
printf 'PASS: restoration failure changes the final verdict\n'

for timer in autotune watchdog; do
    make_case "restore-$timer-timer" 1
    FAIL_START="rigforge-$timer.timer"
    make_xmrig
    [ "$(run_case)" -ne 0 ] || fail "$timer timer restoration failure passed"
    grep -q "could not restore rigforge-$timer.timer" "$CASE_DIR/output" || fail "$timer timer restoration failure was not reported"
done
printf 'PASS: timer restoration failures change the final verdict\n'

make_case signal 1
make_xmrig
_stress_sleep() {
    local n
    for n in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$CASE_DIR/xmrig-pid" ] && break
        /bin/sleep 0.01
    done
    kill -TERM "$BASHPID"
}
/bin/sleep 30 &
sentinel_pid=$!
signal_rc=0
(stress --minutes 1 >"$CASE_DIR/output" 2>&1) || signal_rc=$?
[ "$signal_rc" = 143 ] || fail "signal exit was $signal_rc instead of 143"
xmrig_pid=$(cat "$CASE_DIR/xmrig-pid")
if kill -0 "$xmrig_pid" 2>/dev/null; then fail 'owned XMRig process survived signal cleanup'; fi
kill -0 "$sentinel_pid" 2>/dev/null || fail 'signal cleanup stopped an unrelated process'
kill "$sentinel_pid"
wait "$sentinel_pid" 2>/dev/null || true
grep -q '^start xmrig$' "$CALLS" || fail 'signal cleanup did not restore miner'
printf 'PASS: signal cleanup stops only the owned process and restores state\n'

make_case argument-errors 1
for bad in '--bogus' '--minutes'; do
    if (stress "$bad" >/dev/null 2>&1); then fail "stress accepted $bad"; fi
done
if (OS_TYPE=Darwin stress --minutes 1 >/dev/null 2>&1); then fail 'stress ran on a non-Linux host'; fi
for sig in HUP:129 INT:130 TERM:143; do
    sig_rc=0
    (_stress_signal "${sig%:*}") || sig_rc=$?
    [ "$sig_rc" = "${sig#*:}" ] || fail "_stress_signal ${sig%:*} exited $sig_rc"
done
if bash "$SCRIPT" stress --bogus >/dev/null 2>&1; then fail 'the stress subcommand accepted an unknown option'; fi
printf 'PASS: stress rejects bad arguments and maps signals to exit codes\n'

printf 'stress tests: PASS\n'
