#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
FAILURES=0
ORIGINAL_PATH=$PATH

check() {
    if "$@"; then
        return
    fi
    printf 'FAIL: %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
}

check grep -Fq 'e2e-pithead-allowlist.sh' "$ROOT/tests/e2e-pithead.sh"
check grep -q phase_api_allowlist < <(sed -n '/^phase_network()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")
check grep -q 'counter drop' < <(sed -n '/^install_api_firewall()/,/^}/p' "$ROOT/rigforge.sh")

HELPER="$ROOT/tests/e2e-pithead-allowlist.sh"
if [ ! -f "$HELPER" ]; then
    printf 'FAIL: missing %s\n' "$HELPER" >&2
    exit 1
fi
# shellcheck source=tests/e2e-pithead-allowlist.sh
source "$HELPER"

FAKE_BIN="$TASK_TMP/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$IP_LOG"
if [ "$1" = netns ] && [ "$2" = exec ]; then
    case "$*" in
    *http_code*)
        printf '%s' "${HOST_CODE:-200}"
        exit 0
        ;;
    esac
    exit "${NS_CURL_RC:-28}"
fi
if [ "$1" = netns ] && [ "$2" = del ] && [ "${NS_REMOVES_LINK:-0}" = 1 ]; then
    : >"$CLEANUP_STATE"
fi
if [ "$1" = link ] && [ "$2" = del ] && [ -e "$CLEANUP_STATE" ]; then
    exit 1
fi
if [ "$2" = del ]; then exit "${CLEANUP_RC:-0}"; fi
[ "$1" != link ] || [ "$2" != show ]
EOF
cat >"$FAKE_BIN/nft" <<'EOF'
#!/bin/sh
count=$(cat "$NFT_CALLS")
if [ "$count" -eq 0 ]; then packets=$DROP_BEFORE; else packets=$DROP_AFTER; fi
printf '%s' "$((count + 1))" >"$NFT_CALLS"
printf '{"nftables":[{"rule":{"family":"inet","table":"rigforge","chain":"api","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[%s]}}},{"counter":{"packets":%s,"bytes":0}},{"drop":null}]}}]}\n' "$FAKE_PORT" "$packets"
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$IP_LOG.host-curl"
exit 1
EOF
chmod +x "$FAKE_BIN/ip" "$FAKE_BIN/nft" "$FAKE_BIN/curl"

allow_hook() {
    printf '%s\n' "$1" >"$HOOK_OUT"
    return "${HOOK_RC:-0}"
}

run_case() {
    local scenario=$1 expected=$2 rc
    export IP_LOG="$TASK_TMP/$scenario.ip" NFT_CALLS="$TASK_TMP/$scenario.nft" CLEANUP_STATE="$TASK_TMP/$scenario.cleanup"
    : >"$IP_LOG"
    printf 0 >"$NFT_CALLS"
    export HOOK_OUT="$TASK_TMP/$scenario.hook" HOOK_RC=0 FAKE_PORT=$((10000 + RANDOM % 50000)) DROP_BEFORE=4 DROP_AFTER=5 NS_CURL_RC=28 HOST_CODE=200 HASH_VALUE=1 HASH_WARMUP=0 CLEANUP_RC=0 NS_REMOVES_LINK=0 E2E_ALLOWLIST_HASH_WAIT=3 E2E_ALLOWLIST_HASH_INTERVAL=1
    HASH_CALLS="$TASK_TMP/$scenario.hash"
    printf 0 >"$HASH_CALLS"
    case "$scenario" in
    admitted) NS_CURL_RC=0 ;;
    cleanup-race) NS_REMOVES_LINK=1 ;;
    no-counter-move) DROP_AFTER=$DROP_BEFORE ;;
    host-refused) HOST_CODE=403 ;;
    stopped-miner) HASH_VALUE=0 ;;
    malformed-hashrate) HASH_VALUE=unknown ;;
    warmup) HASH_WARMUP=2 ;;
    cleanup-failed) CLEANUP_RC=1 ;;
    hook-failed) HOOK_RC=1 ;;
    esac
    export DROP_BEFORE DROP_AFTER NS_CURL_RC HOST_CODE HASH_WARMUP HASH_CALLS E2E_ALLOWLIST_HASH_WAIT E2E_ALLOWLIST_HASH_INTERVAL
    PATH="$FAKE_BIN:$ORIGINAL_PATH" api_allowlist_probe "$FAKE_PORT" token allow_hook >"$TASK_TMP/$scenario.out" 2>&1
    rc=$?
    check test "$rc" -eq "$expected"
    check test ! -e "$IP_LOG.host-curl"
    check grep -q '^netns del ' "$IP_LOG"
    check grep -q '^link del ' "$IP_LOG"
}

live_hashrate() {
    local calls
    calls=$(cat "$HASH_CALLS")
    printf '%s' "$((calls + 1))" >"$HASH_CALLS"
    [ "$calls" -lt "$HASH_WARMUP" ] || printf '%s' "$HASH_VALUE"
}
run_case success 0
run_case cleanup-race 0
run_case warmup 0
run_case admitted 1
run_case no-counter-move 1
run_case host-refused 1
run_case stopped-miner 2
run_case malformed-hashrate 2
run_case cleanup-failed 2
run_case hook-failed 2

check grep -q 'allowed source got HTTP 403' "$TASK_TMP/host-refused.out"
check grep -q 'second source was not refused' "$TASK_TMP/admitted.out"
check grep -q 'drop counter did not move' "$TASK_TMP/no-counter-move.out"
check grep -q 'no live hashrate within 3s' "$TASK_TMP/stopped-miner.out"
check grep -q 'allow hook failed' "$TASK_TMP/hook-failed.out"
check test "$(cat "$TASK_TMP/warmup.hash")" -eq 3
check test "$(cat "$TASK_TMP/warmup.nft")" -ge 1

check grep -Eq '^netns exec rfapi-[0-9]+ curl .*-w %\{http_code\} .*--interface 169\.254\.[0-9]+\.[0-9]+ ' "$TASK_TMP/success.ip"
check grep -Eq '^169\.254\.' "$TASK_TMP/success.hook"
check grep -Fq -- "--interface $(cat "$TASK_TMP/success.hook") " "$TASK_TMP/success.ip"
check grep -Fq -- "address add $(cat "$TASK_TMP/success.hook")/" "$TASK_TMP/success.ip"

(
    hash -r
    PATH="$FAKE_BIN" api_allowlist_probe "$FAKE_PORT" token
) >"$TASK_TMP/missing-tool.out" 2>&1
check test "$?" -eq 2
check grep -q 'missing required tool' "$TASK_TMP/missing-tool.out"

if [ "$FAILURES" -ne 0 ]; then
    printf '%d api allowlist probe test(s) failed\n' "$FAILURES" >&2
    exit 1
fi
printf 'api allowlist probe tests passed\n'
