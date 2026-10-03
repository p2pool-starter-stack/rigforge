#!/usr/bin/env bash
# Hardware-free argv, authentication and restoration regression for #559.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" = 0 ]; then
    TEST_CREDENTIAL_DIR=$(mktemp -d)
    export TEST_CREDENTIAL_DIR
    trap 'rm -rf "$TEST_CREDENTIAL_DIR"' EXIT
    for mode in tokens stratum edit-failed apply-failed tokens-failed stratum-failed; do
        if bash "$0" "$mode" >"$TEST_CREDENTIAL_DIR/$mode.log" 2>&1; then
            case "$mode" in *-failed)
                echo "$mode unexpectedly succeeded"
                exit 1
                ;;
            esac
        else
            case "$mode" in *-failed) ;; *)
                cat "$TEST_CREDENTIAL_DIR/$mode.log"
                exit 1
                ;;
            esac
        fi
        case "$mode" in
        edit-failed | apply-failed)
            grep -q 'could not enable api+control' "$TEST_CREDENTIAL_DIR/$mode.log"
            [ ! -s "$TEST_CREDENTIAL_DIR/$mode.requests" ]
            ;;
        esac
        case "$mode" in
        tokens-failed)
            grep -q '^access-token-diagnostic: control_transport_rc=7 control_active=1$' "$TEST_CREDENTIAL_DIR/$mode.log"
            grep -q 'revoked entry still answered 000' "$TEST_CREDENTIAL_DIR/$mode.log"
            ;;
        stratum-failed)
            grep -q '^xmrig-diagnostic: .*network_errors=1 .*auth_errors=0 ' "$TEST_CREDENTIAL_DIR/$mode.log"
            grep -q 'wrong pass: no rejection within 60s' "$TEST_CREDENTIAL_DIR/$mode.log"
            ;;
        esac
        cmp "$TEST_CREDENTIAL_DIR/$mode.json" "$TEST_CREDENTIAL_DIR/$mode.original"
    done
    ! grep -qE 'a{64}|b{64}|stratum-secret' "$TEST_CREDENTIAL_DIR"/*.log
    printf 'contract credential regressions: PASS\n'
    exit 0
fi
mode="$1"
CFG="$TEST_CREDENTIAL_DIR/$mode.json"
WLOG="$TEST_CREDENTIAL_DIR/worker.log"
# shellcheck disable=SC2034 # consumed by extracted editor/cleanup functions
RIGFORGE=fixture_rigforge
# shellcheck disable=SC2034 # consumed by extracted cleanup function
HAMMER_PIDS='' RIG_LOCK_HOLDER="$TEST_CREDENTIAL_DIR/holder"
E2E_STRATUM_PASS=$'stratum-secret"\\\nsecond line'
master_fixture=$(printf 'a%.0s' {1..64})
bench_fixture=$(printf 'b%.0s' {1..64})
read_fixture=5ce653a2e6f6e9ece58f79eedbfcaf87ab80b78b0b0019dd340a758f0badded9
printf '{"DONATION":1,"pools":[{"pass":"original"}],"keep":true}\n' >"$CFG"
cp "$CFG" "$TEST_CREDENTIAL_DIR/$mode.original"
: >"$WLOG"
: >"$TEST_CREDENTIAL_DIR/$mode.requests"
: >"$TEST_CREDENTIAL_DIR/$mode.edits"
phase() { :; }
ok() { printf 'ok\n' >>"$TEST_CREDENTIAL_DIR/$mode.ok"; }
bad() {
    echo "$1" >&2
    exit 1
}
die() {
    echo "$1" >&2
    exit 2
}
skip() { bad 'unexpected skip'; }
sleep() { :; }
refresh_profile_finish() { :; }
_restore_xmrig() { :; }
systemctl() {
    case "$1" in
    is-active) return 0 ;;
    show) printf 'ActiveState=active\nSubState=running\nResult=success\nExecMainStatus=0\n' ;;
    *) return 1 ;;
    esac
}
# Run the actual editor, phases and EXIT restoration without preflight or hardware.
eval "$(sed -n '/^set_cfg()/,/^}/p; /^_cleanup()/,/^}/p; /^snapshot_config()/,/^}/p; /^phase_stratum_auth()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
eval "$(sed -n '/^_xmrig_diagnostics()/,/^}/p; /^_connect_bad()/,/^}/p' "$ROOT/tests/e2e-control-replay.sh")"
source "$ROOT/tests/e2e-pithead-control.sh"
source "$ROOT/tests/e2e-pithead-tokens.sh"
check_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        *"$master_fixture"* | *"$bench_fixture"* | *"$read_fixture"* | *stratum-secret*) bad 'credential appeared in process arguments' ;;
        esac
    done
}
jq() {
    check_args "$@"
    [ "$mode" != edit-failed ] || [ "${1:-}" != --slurpfile ] || return 1
    command jq "$@"
}
python3() {
    check_args "$@"
    command python3 "$@"
}
openssl() {
    check_args "$@"
    bad 'unexpected openssl invocation'
}
xxd() {
    cat >/dev/null
    # xxd runs in command substitutions: persist the count outside the subshell.
    if [ -e "$TEST_CREDENTIAL_DIR/$mode.generated" ]; then
        printf '%s\n' "$bench_fixture"
    else
        : >"$TEST_CREDENTIAL_DIR/$mode.generated"
        printf '%s\n' "$master_fixture"
    fi
}
fixture_rigforge() {
    if [ "$1" = restart ]; then
        if command jq -e '.pools[0].pass == "wrong-114"' "$CFG" >/dev/null; then
            if [ "$mode" = stratum-failed ]; then
                printf 'connect error: stratum-secret\n' >"$WLOG"
            else
                printf 'login error\n' >"$WLOG"
            fi
        else
            printf 'new job from fixture\n' >"$WLOG"
        fi
        return
    fi
    [ "$1" = apply ]
    cmp -s "$CFG" "$SAVED_CFG" && return 0 # restoration
    [ "$mode" != apply-failed ] || return 1
    if [[ "$mode" = stratum* ]]; then
        # Compare private stdin to the edited password, including quotes, slash and newline.
        if ! command jq -e '.pools[0].pass == "wrong-114"' "$CFG" >/dev/null; then
            printf '%s' "$E2E_STRATUM_PASS" | command jq -e --rawfile pass /dev/stdin '.pools[0].pass == $pass and .keep' "$CFG" >/dev/null
        fi
    else
        command jq -e '.ACCESS_TOKEN == ("a" * 64) and .api == "enabled" and .control == "enabled" and .api_allow_from == "127.0.0.1/32" and .keep and (.ACCESS_TOKENS == {"bench":("b" * 64)} or .ACCESS_TOKENS == {})' "$CFG" >/dev/null
    fi
    echo edit >>"$TEST_CREDENTIAL_DIR/$mode.edits"
}
wait_for_job() { grep -q 'new job from' "$WLOG"; }
curl() {
    check_args "$@"
    local config arg url='' response='' count expected
    config=$(cat)
    count=$(wc -l <"$TEST_CREDENTIAL_DIR/$mode.requests" | tr -d ' ')
    echo request >>"$TEST_CREDENTIAL_DIR/$mode.requests"
    expected="$bench_fixture"
    [ "$count" != 2 ] || expected="$read_fixture"
    [ "$config" = "header = \"Authorization: Bearer $expected\"" ] || bad 'wrong bearer transport or derivation'
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in -o)
            response="$1"
            shift
            ;;
        http://*) url="$arg" ;; esac
    done
    case "$count:$url" in
    0:*/2/summary) printf 401 ;;
    1:*/health | 2:*/health) printf '{}' ;;
    3:*/apply)
        printf '{"change_id":"fixture"}' >"$response"
        printf 202
        ;;
    4:*/status?change_id=fixture) printf '{"status":"applied"}' ;;
    5:*/health | 6:*/apply)
        command jq -e '.ACCESS_TOKENS == {}' "$CFG" >/dev/null
        if [ "$mode:$count" = tokens-failed:6 ]; then
            printf 000
            return 7
        fi
        printf 401
        ;;
    *) bad 'unexpected request sequence' ;;
    esac
}
snapshot_config
if [[ "$mode" = stratum* ]]; then
    phase_stratum_auth
    [ "$(wc -l <"$TEST_CREDENTIAL_DIR/$mode.edits" | tr -d ' ')" = 3 ]
    [ "$(wc -l <"$TEST_CREDENTIAL_DIR/$mode.ok" | tr -d ' ')" = 4 ]
else
    phase_access_tokens
    [ "$(wc -l <"$TEST_CREDENTIAL_DIR/$mode.requests" | tr -d ' ')" = 7 ]
    [ "$(wc -l <"$TEST_CREDENTIAL_DIR/$mode.ok" | tr -d ' ')" = 7 ]
fi
_cleanup
trap - EXIT
