#!/usr/bin/env bash
# #540: queued replay input, sequence, transport and publication checks, without hardware.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" = 0 ]; then
    REPLAY_TEST_DIR=$(mktemp -d)
    export REPLAY_TEST_DIR
    replay_test_cleanup() {
        local rc=$?
        if [ "$rc" != 0 ]; then tail -n 20 "$REPLAY_TEST_DIR"/*.log >&2 || true; fi
        rm -rf "$REPLAY_TEST_DIR"
        exit "$rc"
    }
    trap replay_test_cleanup EXIT
    for kind in thermal pools; do
        for success in fresh history; do
            bash "$0" "$kind" "$success" >"$REPLAY_TEST_DIR/$kind-$success.log" 2>&1
            grep -q "replay $kind published within 90s" "$REPLAY_TEST_DIR/$kind-$success.log"
            grep -q 'finish-profile' "$REPLAY_TEST_DIR/$kind-$success.log"
        done
        for mode in stale late wrong-id; do
            if bash "$0" "$kind" "$mode" >"$REPLAY_TEST_DIR/$kind-$mode.log" 2>&1; then
                echo "replay $kind $mode unexpectedly passed" >&2
                exit 1
            fi
            grep -q "feed stale after 90s" "$REPLAY_TEST_DIR/$kind-$mode.log"
        done
    done
    for mode in missing inactive context probe other bad-id mining curl-failed status-missing status-malformed; do
        if bash "$0" thermal "$mode" >"$REPLAY_TEST_DIR/$mode.log" 2>&1; then
            echo "replay $mode unexpectedly passed" >&2
            exit 1
        fi
    done
    for mode in status-missing status-malformed; do
        grep -q 'replay-settle: elapsed_s=.* status=unknown' "$REPLAY_TEST_DIR/$mode.log"
        ! grep -q 'PRIVATE\|never-execute' "$REPLAY_TEST_DIR/$mode.log"
    done
    (
        source "$ROOT/tests/e2e-refresh-window.sh"
        systemctl() { [ "$1" = show ]; }
        if refresh_profile_state >"$REPLAY_TEST_DIR/inactive-state"; then exit 1; fi
        refresh_profile_state allow-inactive >>"$REPLAY_TEST_DIR/inactive-state"
        grep -q 'xmrig_active=0' "$REPLAY_TEST_DIR/inactive-state"
    )
    (
        source "$ROOT/tests/e2e-control-replay.sh"
        WLOG="$REPLAY_TEST_DIR/xmrig.log"
        printf '%s\n' 'nEw JoB fRoM fixture' 'AcCePtEd (1/0)' 'DnS ErRoR' 'CoNnEcT ErRoR' 'TlS ErRoR' 'LoGiN ErRoR' 'CoNfIg ErRoR' 'FaIlEd for another reason' >"$WLOG"
        systemctl() { printf '%s\n' 'ActiveState=active' 'SubState=running' 'Result=success' 'ExecMainStatus=0'; }
        _xmrig_diagnostics >"$REPLAY_TEST_DIR/xmrig-diagnostic"
        grep -qx 'xmrig-diagnostic: active_state=active sub_state=running result=success exec_main_status=0 log_state=present jobs=1 accepted=1 dns_errors=1 network_errors=1 tls_errors=1 auth_errors=1 config_errors=1 other_errors=1' "$REPLAY_TEST_DIR/xmrig-diagnostic"
        WLOG="$REPLAY_TEST_DIR/absent-xmrig.log"
        _xmrig_diagnostics | grep -q 'log_state=missing jobs=0 accepted=0'
        systemctl() { printf '%s\n' 'ActiveState=active' 'SubState=running' 'Result=success'; }
        ! _xmrig_diagnostics
        systemctl() { printf '%s\n' 'ActiveState=PRIVATE' 'SubState=running' 'Result=success' 'ExecMainStatus=0'; }
        ! _xmrig_diagnostics
        systemctl() { printf '%s\n' 'ActiveState=active' 'SubState=running' 'Result=success' 'ExecMainStatus=0'; }
        WLOG="$REPLAY_TEST_DIR/xmrig.log"
        awk() {
            printf 'PRIVATE PATH' >&2
            return 1
        }
        ! _xmrig_diagnostics 2>"$REPLAY_TEST_DIR/xmrig-diagnostic-error"
        [ ! -s "$REPLAY_TEST_DIR/xmrig-diagnostic-error" ]
    )
    (
        source "$ROOT/tests/e2e-control-replay.sh"
        eval "$(sed -n '/^phase_connect()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
        phase() { :; }
        set_cfg() { :; }
        find() { :; }
        bad() {
            printf 'bad:%s\n' "$1"
            exit 1
        }
        systemctl() {
            [ "$1" = show ] && printf '%s\n' 'ActiveState=active' 'SubState=running' 'Result=success' 'ExecMainStatus=0'
        }
        # shellcheck disable=SC2034 # consumed by the extracted phase_connect function
        HERE="$REPLAY_TEST_DIR" RIGFORGE=true WLOG='' GEN_CFG='' PITHEAD_URL='fixture.invalid:3333'
        if (phase_connect) >"$REPLAY_TEST_DIR/connect-diagnostic" 2>&1; then exit 1; fi
        grep -q 'xmrig-diagnostic: .* log_state=missing jobs=0 accepted=0' "$REPLAY_TEST_DIR/connect-diagnostic"
        grep -q "bad:could not find the worker's xmrig.log" "$REPLAY_TEST_DIR/connect-diagnostic"
    )
    printf 'control replay regressions: PASS\n'
    exit 0
fi
kind="$1" mode="$2"
source "$ROOT/tests/e2e-pithead-control.sh"
source "$ROOT/tests/e2e-control-replay.sh"
CFG="$REPLAY_TEST_DIR/$kind-$mode.json"
CALLS="$REPLAY_TEST_DIR/$kind-$mode.calls"
PITHEAD_URL='fixture.invalid:3333'
RIGFORGE=true # Bash's builtin fixture does not depend on a container's external true path.
printf '{"control_port":8082,"api_port":8081,"pools":[{"url":"original.invalid:3333","user":"synthetic-user","pass":"SOURCE-SECRET"},{"url":"fixture.invalid:3333","user":"synthetic-user","pass":"BENCH-SECRET"}]}' >"$CFG"
E2E_PITHEAD_CONTROL_FIXTURE=pithead-control
E2E_RIG_LOCK_UNIT=bench-ci-riglock-synthetic-123
E2E_PITHEAD_CONTROL_CONTEXT='{"version":1,"fixture":"pithead-control","thermal":{"feed_deadline_s":90,"starting_scalars":{"max_temp_c":100,"DONATION":0,"watchdog_interval_min":5}},"unknown":["historical timing"]}'
IT_RIG_POOLS_PROBE='[{"url":"fixture.invalid:3333","user":"synthetic-user","pass":"SECRET $(never-execute) `never-execute`"}]'
case "$mode" in
missing) E2E_PITHEAD_CONTROL_FIXTURE='' ;;
context) E2E_PITHEAD_CONTROL_CONTEXT='{}' ;;
probe) IT_RIG_POOLS_PROBE='[]' ;;
esac
die() {
    echo "$1" >&2
    exit 2
}
bad() {
    echo "$1" >&2
    exit 1
}
ok() { echo "$1"; }
phase() { :; }
rig_lock() { die 'fixture tried to compete for the rig lock'; }
systemctl() { [ "$mode" != inactive ]; }
jq() {
    [[ "$*" != *synthetic-token* && "$*" != *SECRET* ]] || die 'credential-bearing jq argument'
    command jq "$@"
}
export http_proxy='http://127.0.0.1:9' ALL_PROXY='http://127.0.0.1:9' NO_PROXY=''
phase_connect() {
    [ "$mode" != mining ] && [ "$1" = preserve-pools ] &&
        [ "$(jq -r '.pools[0].url' "$CFG")" = "$PITHEAD_URL" ] &&
        [ "$(jq -r '.pools[1].url' "$CFG")" = original.invalid:3333 ] &&
        [ "$(jq -r '.pools[1].pass' "$CFG")" = SOURCE-SECRET ]
}
refresh_profile_start() { :; }
refresh_profile_state() { :; }
refresh_profile_finish() { echo finish-profile; }
head() { printf 'synthetic-token'; }
xxd() { cat; }
sleep() { SECONDS=$((SECONDS + $1)); }
date() { printf '2026-09-30T00:00:00Z\n'; }
curl() {
    [ "$1 $2 $3 $4 $5" = '-q --noproxy * --config -' ] || return 1
    [[ "$*" != *SECRET* && "$*" != *synthetic-token* ]] || return 1
    grep -q '^header = "Authorization: Bearer synthetic-token"$' || return 1
    local output='' data='' url='' target=100 id stamp='2026-09-30T00:00:00Z' published_id
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -o)
            output="$2"
            shift
            ;;
        --data-binary)
            data="$2"
            shift
            ;;
        http://*) url="$1" ;;
        esac
        shift
    done
    if [ -n "$output" ]; then
        [ "$(LC_ALL=C ls -ld "${data#@}" | cut -c1-10)" = '-rw-------' ] || return 1
        jq -c 'if has("pools") then {pools:"PRIVATE"} else . end' "${data#@}" >>"$CALLS"
        id=$(printf '%016x' "$(wc -l <"$CALLS")")
        [ "$mode" != bad-id ] || id='bad-id'
        printf '{"change_id":"%s"}' "$id" >"$output"
        printf 202
        [ "$mode" != curl-failed ] || return 7
    elif [[ "$url" == */status* ]]; then
        case "$mode" in
        status-missing) printf '{}' ;;
        status-malformed) printf '{"status":"PRIVATE $(never-execute)"}' ;;
        *) printf '{"status":"applied"}' ;;
        esac
    else
        id=$(printf '%016x' "$(wc -l <"$CALLS")")
        published_id="$id"
        [ "$mode" != wrong-id ] || published_id='ffffffffffffffff'
        if [ "$mode" != stale ] && { [ "$mode" != late ] || [ "$((SECONDS - started))" -ge 95 ]; }; then
            stamp='2026-09-30T00:00:01Z'
            target=102
        fi
        if [ "$mode" = history ]; then
            printf '{"generated_at":"%s","rigforge":{"watchdog":{"max_temp_c":%s},"control":null,"control_history":[{"change_id":"%s","status":"applied"}]}}' "$stamp" "$target" "$published_id"
        else
            printf '{"generated_at":"%s","rigforge":{"watchdog":{"max_temp_c":%s},"control":{"change_id":"%s","status":"applied"},"control_history":[]}}' "$stamp" "$target" "$published_id"
        fi
    fi
}
phase_name="control-replay-$kind"
[ "$mode" != other ] || phase_name=control
replay_lock "$phase_name"
[ "$REPLAY_RUNNER_LOCK" = 1 ] || die 'reservation bypass not tracked'
phase_control_replay "$kind"
expected='{"max_temp_c":101}
{"max_temp_c":100}
{"DONATION":1}
{"DONATION":0}
{"watchdog_interval_min":6}
{"watchdog_interval_min":5}
{"pools":"PRIVATE"}'
[ "$kind" != thermal ] || expected="$expected
{\"max_temp_c\":102}"
[ "$(cat "$CALLS")" = "$expected" ] || die 'recorded apply order differs'
! grep -q 'SECRET' "$CALLS" || die 'pool credentials escaped into log'
# Exercise the real cleanup function: the runner marker survives, the ordinary marker does not.
eval "$(sed -n '/^_cleanup()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
_restore_xmrig() { return 0; }
# shellcheck disable=SC2034 # consumed by the extracted cleanup function
RIGFORGE=true HAMMER_PIDS=''
RIG_LOCK_HOLDER="$REPLAY_TEST_DIR/holder"
SAVED_CFG=$(mktemp)
cp "$CFG" "$SAVED_CFG"
printf 'runner owns release\n' >"$RIG_LOCK_HOLDER"
_cleanup
[ "$(cat "$RIG_LOCK_HOLDER")" = 'runner owns release' ] || die 'cleanup removed runner marker'
REPLAY_RUNNER_LOCK=0
SAVED_CFG=$(mktemp)
cp "$CFG" "$SAVED_CFG"
_cleanup
[ ! -e "$RIG_LOCK_HOLDER" ] || die 'ordinary cleanup stopped removing its marker'
