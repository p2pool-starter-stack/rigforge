#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317,SC2329
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-"$ROOT/rigforge.sh"}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing: $2)" ;; esac }
absent() { case "$1" in *"$2"*) fail "$3 (unexpected: $2)" ;; *) ;; esac }

source "$SCRIPT"
CONFIG_JSON="$TEST_TMP/config.json"
WORKER_ROOT="$TEST_TMP/worker"
BUILD_DIR="$WORKER_ROOT/xmrig/build"
CONFIG_META_FILE="$TEST_TMP/config-meta.json"
mkdir -p "$BUILD_DIR"
jq 'del(.HOME_DIR)' "$ROOT/config.minimal.json" >"$CONFIG_JSON"

_worker_root_for_home() { printf '%s\n' "$WORKER_ROOT"; }
_validate_host_port() { :; }
_reown_worker() { :; }
_apply_pool_check() { :; }
sysctl() {
    case "$*" in
    *hw.ncpu) printf '2\n' ;;
    *) printf '\n' ;;
    esac
}
hostname() {
    if [ "${MUTATE_SOURCE:-0}" = 1 ]; then
        MUTATE_SOURCE=0
        rewrite_config '.DONATION = ((.DONATION // 0) + 1)'
    fi
    printf '\n'
}
systemctl() { return 0; }
mac_status() { :; }
mac_logs() { :; }
_status_api_summary() { :; }
OS_TYPE=Darwin

check_state() {
    CHECK_RC=0
    CHECK_OUT=$(_config_apply_check) || CHECK_RC=$?
}
rewrite_config() {
    jq "$1" "$CONFIG_JSON" >"$TEST_TMP/config.next"
    mv "$TEST_TMP/config.next" "$CONFIG_JSON"
}
bounded_check() {
    local output="$TEST_TMP/bounded.out" pid i rc=0
    (_config_apply_check >"$output") &
    pid=$!
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || rc=$?
            [ "$rc" -eq 0 ] || fail "bounded apply-state check returned $rc"
            BOUNDED_OUT=$(cat "$output")
            return
        fi
        sleep 0.1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail 'apply-state check hung on a FIFO'
}
apply_now() { apply >/dev/null; }
expect_stale() {
    check_state
    contains "$CHECK_OUT" "$1 changed since the last apply" "$1 drift is reported"
    contains "$CHECK_OUT" 'run: sudo ./rigforge.sh apply' "$1 drift gives the apply remedy"
}
expect_current() {
    check_state
    [ "$CHECK_RC" -eq 0 ] || fail "matching apply state returned $CHECK_RC"
    contains "$CHECK_OUT" '✓' "matching apply state is ok: $CHECK_OUT"
    contains "$CHECK_OUT" 'Generated configuration matches' 'matching apply state names the generated configuration'
}

apply_now
STAMP="$BUILD_DIR/.rigforge-apply.json"
jq -e '.config_hash | type == "string" and length > 0' "$STAMP" >/dev/null || fail 'apply stamp has config_hash'
jq -e 'has("tune_hash")' "$STAMP" >/dev/null || fail 'apply stamp has tune_hash'
jq -e '.generated_at | type == "string" and length > 0' "$STAMP" >/dev/null || fail 'apply stamp has generated_at'
expect_current

rewrite_config '.DONATION = 1'
expect_stale config.json
apply_now
expect_current

rewrite_config '.threads = 1'
expect_stale config.json
apply_now
expect_current

parse_config >/dev/null
API_HASH=$(_writable_config_hash)
jq -n '{cpu: {yield: true}}' >"$WORKER_ROOT/tune-overrides.json"
parse_config >/dev/null
[ "$(_writable_config_hash)" = "$API_HASH" ] || fail 'tune overlay changed the writable API revision contract'
expect_stale tune-overrides.json
apply_now
expect_current
jq '.cpu.yield = false' "$WORKER_ROOT/tune-overrides.json" >"$TEST_TMP/tune.next"
mv "$TEST_TMP/tune.next" "$WORKER_ROOT/tune-overrides.json"
expect_stale tune-overrides.json
apply_now
expect_current
rm "$WORKER_ROOT/tune-overrides.json"
expect_stale tune-overrides.json
apply_now
expect_current

rewrite_config '.watchdog = "enabled"'
expect_stale config.json
absent "$CHECK_OUT" 'running' 'source-only drift does not claim the miner is running stale config'
apply_now
expect_current

jq '.autosave = false' "$BUILD_DIR/config.json" >"$TEST_TMP/generated.next"
mv "$TEST_TMP/generated.next" "$BUILD_DIR/config.json"
expect_current

rewrite_config '.DONATION = 2'
OS_TYPE=Darwin
status_out=$(svc_status)
contains "$status_out" 'config.json changed since the last apply' 'Darwin status uses the apply-state row'
OS_TYPE=Linux
status_out=$(svc_status)
contains "$status_out" 'config.json changed since the last apply' 'Linux status uses the apply-state row'
doctor_prefix=$(declare -f doctor | awk 'NR == 1 {sub(/^doctor /, "doctor_apply_row ")} {print} /_config_apply_check/ {print "}"; exit}')
eval "$doctor_prefix"
doctor_out=$(doctor_apply_row)
contains "$doctor_out" 'config.json changed since the last apply' 'doctor uses the apply-state row'
OS_TYPE=Darwin
apply_now

MUTATE_SOURCE=1
apply_now
MUTATE_SOURCE=0
[ ! -e "$STAMP" ] || fail 'generation source race invalidates the old apply stamp'
check_state
contains "$CHECK_OUT" '∙' 'generation source race is informational'
contains "$CHECK_OUT" 'no apply stamp' 'generation source race cannot leave a current stamp'
apply_now
expect_current

race_rc=0
race_out=$(
    jq() {
        local rc=0 last="${!#}"
        command jq "$@" || rc=$?
        if [ "$rc" -eq 0 ] && [ "$last" = "$STAMP" ]; then rm "$STAMP"; fi
        return "$rc"
    }
    _config_apply_check
) || race_rc=$?
[ "$race_rc" -eq 0 ] || fail "stamp snapshot read race returned $race_rc"
contains "$race_out" '✓' 'stamp removed after its read still uses the captured snapshot'
contains "$race_out" 'Generated configuration matches' 'stamp snapshot remains internally consistent'
[ ! -e "$STAMP" ] || fail 'stamp read race did not remove the known stamp'

apply_now
race_rc=0
race_out=$(
    jq() {
        local rc=0 last="${!#}"
        if [ "$last" = "$STAMP" ]; then rm "$STAMP"; fi
        command jq "$@" || rc=$?
        return "$rc"
    }
    _config_apply_check
) || race_rc=$?
[ "$race_rc" -eq 0 ] || fail "stamp removal before open returned $race_rc"
contains "$race_out" '∙' 'stamp removed before open is informational'
contains "$race_out" 'unreadable or invalid' 'stamp removed before open explains the state'
absent "$race_out" '✓' 'stamp removed before open is not current'

apply_now
mkfifo "$WORKER_ROOT/tune-overrides.json"
bounded_check
contains "$BOUNDED_OUT" '∙' 'FIFO tune overlay is informational'
contains "$BOUNDED_OUT" 'unreadable or invalid' 'FIFO tune overlay is refused without opening it'
rm "$WORKER_ROOT/tune-overrides.json"
rm "$STAMP"
mkfifo "$STAMP"
bounded_check
contains "$BOUNDED_OUT" '∙' 'FIFO apply stamp is informational'
contains "$BOUNDED_OUT" 'unreadable or invalid' 'FIFO apply stamp is refused without opening it'
rm "$STAMP"

apply_now
rm "$STAMP"
check_state
contains "$CHECK_OUT" '∙' 'missing stamp is informational'
contains "$CHECK_OUT" 'no apply stamp' 'missing stamp explains the state'
printf '{broken\n' >"$STAMP"
check_state
contains "$CHECK_OUT" '∙' 'malformed stamp is informational'
contains "$CHECK_OUT" 'invalid' 'malformed stamp explains the state'

apply_now
printf '{broken\n' >"$WORKER_ROOT/tune-overrides.json"
expect_stale tune-overrides.json
apply_now
[ ! -e "$STAMP" ] || fail 'invalid tune overlay invalidates the old apply stamp'
check_state
contains "$CHECK_OUT" 'no apply stamp' 'invalid tune overlay cannot leave a current stamp'

printf 'config apply state: PASS\n'
