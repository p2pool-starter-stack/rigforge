#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${1:-$ROOT/tests/e2e-pithead.sh}"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
HERE="$SANDBOX/checkout" CFG="$SANDBOX/checkout/config.json"
RIGFORGE="$ROOT/rigforge.sh" PITHEAD_URL=fixture.invalid:3333
mkdir -p "$HERE/old-worker/xmrig/build" "$SANDBOX/external/worker/xmrig/build" "$HERE/data/worker/xmrig/build"
printf 'new job from stale\naccepted (1/0)\n' >"$HERE/old-worker/xmrig.log"
printf '{"pools":[{"user":"stale-worker"}]}' >"$HERE/old-worker/xmrig/build/config.json"
cp "$HERE/old-worker/xmrig.log" "$SANDBOX/decoy-log"
cp "$HERE/old-worker/xmrig/build/config.json" "$SANDBOX/decoy-config"
eval "$(sed -n '/^require_preflight()/,/^}/p; /^phase_connect()/,/^}/p; /^wait_for_job()/,/^}/p; /^die()/,/^}/p' "$HARNESS")"
uname() { printf 'Linux\n'; }
id() { printf '0\n'; }
phase() { :; }
ok() { printf '%s\n' "$1"; }
bad() {
    printf '%s\n' "$1" >&2
    return 1
}
_connect_bad() { bad "$1"; }
systemctl() { [ "$*" = 'is-active --quiet xmrig' ]; }
set_cfg() { :; }
sleep() { :; }
fixture_restart() {
    [ "$1" = restart ] || return 1
    [ ! -s "$EXPECTED_LOG" ] || {
        printf 'stale evidence survived truncation\n' >&2
        return 1
    }
    case "$WORK" in
    complete) printf 'new job from fixture\naccepted (1/0)\n' >"$EXPECTED_LOG" ;;
    no-share) printf 'new job from fixture\n' >"$EXPECTED_LOG" ;;
    no-job) : ;;
    esac
}
export -f require_preflight die phase_connect wait_for_job uname id phase ok bad _connect_bad systemctl set_cfg sleep fixture_restart
export HERE CFG RIGFORGE PITHEAD_URL
printf '%s\n' 'set -Eeuo pipefail' 'require_preflight connect' '[ "$WORK" != clear-failed ] || set -o noclobber' 'RIGFORGE=fixture_restart E2E_SHARE_TIMEOUT=1' 'phase_connect' >"$SANDBOX/connect-case.sh"
write_generated() {
    jq -n --arg log "$1/xmrig.log" '{"log-file":$log,pools:[{user:"configured-worker"}]}' >"$1/xmrig/build/config.json"
    printf 'new job from previous\naccepted (1/0)\n' >"$1/xmrig.log"
}
write_generated "$SANDBOX/external/worker"
write_generated "$HERE/data/worker"
check_paths() {
    (
        require_preflight connect
        [ "$WLOG" = "$1/xmrig.log" ] || {
            printf "harness selected another worker log\n" >&2
            exit 1
        }
        [ "$GEN_CFG" = "$1/xmrig/build/config.json" ] || {
            printf "harness selected another generated config\n" >&2
            exit 1
        }
    )
}
expect_refusal() {
    local result=0
    (require_preflight "$1") >"$SANDBOX/refusal" 2>&1 || result=$?
    [ "$result" -eq 2 ] || {
        printf '%s preflight returned %s instead of refusal\n' "$1" "$result" >&2
        exit 1
    }
    grep -q "$2" "$SANDBOX/refusal"
}
for home in omitted null empty dynamic; do
    case "$home" in
    omitted) printf '{}' >"$CFG" ;;
    null) printf '{"HOME_DIR":null}' >"$CFG" ;;
    empty) printf '{"HOME_DIR":""}' >"$CFG" ;;
    dynamic) printf '{"HOME_DIR":"DYNAMIC_HOME"}' >"$CFG" ;;
    esac
    check_paths "$HERE/data/worker"
done
for home in "$SANDBOX/external" "$SANDBOX/external/"; do
    jq -n --arg home "$home" '{HOME_DIR:$home}' >"$CFG"
    write_generated "$home/worker"
    check_paths "$home/worker"
done
jq -n --arg home "$SANDBOX/external" '{HOME_DIR:$home}' >"$CFG"
EXPECTED_LOG="$SANDBOX/external/worker/xmrig.log"
export EXPECTED_LOG WORK
for WORK in complete no-job no-share; do
    write_generated "$SANDBOX/external/worker"
    result=0
    bash "$SANDBOX/connect-case.sh" >"$SANDBOX/$WORK.log" 2>&1 || result=$?
    if [ "$WORK" = complete ]; then
        [ "$result" -eq 0 ]
        grep -q 'share accepted by the stack' "$SANDBOX/$WORK.log"
        grep -q "stratum user label set ('configured-worker')" "$SANDBOX/$WORK.log"
    else
        [ "$result" -ne 0 ]
        case "$WORK" in
        no-job) grep -q 'no stratum job' "$SANDBOX/$WORK.log" ;;
        no-share) grep -q 'no accepted share' "$SANDBOX/$WORK.log" ;;
        esac
    fi
done
write_generated "$SANDBOX/external/worker"
result=0
WORK=clear-failed bash "$SANDBOX/connect-case.sh" >"$SANDBOX/clear-failed.log" 2>&1 || result=$?
[ "$result" -eq 2 ]
grep -q 'could not clear worker log for fresh mining evidence' "$SANDBOX/clear-failed.log"
mv "$SANDBOX/external/worker/xmrig/build/config.json" "$SANDBOX/generated"
expect_refusal connect 'no generated config at the configured worker root'
mv "$SANDBOX/generated" "$SANDBOX/external/worker/xmrig/build/config.json"
rm -f "$EXPECTED_LOG"
expect_refusal connect 'required persistent worker log is unavailable'
for persistent in absent stale; do
    [ "$persistent" != stale ] || cp "$SANDBOX/decoy-log" "$EXPECTED_LOG"
    printf '{"pools":[{"user":"appliance"}]}' >"$SANDBOX/external/worker/xmrig/build/config.json"
    for selected in connect stratum-auth network-sequence all; do
        expect_refusal "$selected" 'harness limitation:.*journal-only appliance mining is unsupported'
    done
    (require_preflight worker-api)
    if [ "$persistent" = absent ]; then
        [ ! -e "$EXPECTED_LOG" ]
    else
        cmp "$EXPECTED_LOG" "$SANDBOX/decoy-log"
    fi
done
for home in relative / /etc '/unsafe/../path'; do
    jq -n --arg home "$home" '{HOME_DIR:$home}' >"$CFG"
    expect_refusal connect 'could not resolve configured worker root'
done
printf '{invalid' >"$CFG"
expect_refusal connect 'invalid worker configuration'
cmp "$HERE/old-worker/xmrig.log" "$SANDBOX/decoy-log"
cmp "$HERE/old-worker/xmrig/build/config.json" "$SANDBOX/decoy-config"
printf 'configured worker-root harness regressions: PASS\n'
