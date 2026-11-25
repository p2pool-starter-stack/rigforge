#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317,SC2034
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
run_config() {
    printf '%s' "$1" >"$D/config.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$D/config.json" SCRIPT_DIR="$ROOT"
        parse_config 2>&1
    )
    echo "rc=$?"
}
POOL='"pools": [{"url": "h:3333"}]'
PLANT='Zq7planted~tok'
out=$(run_config "{ $POOL, \"ACCESS_TOKEN\": \"$PLANT\" }")
check "ACCESS_TOKEN error leaves the value out" absent "$(grep -qF "$PLANT" <<<"$out" && echo present || echo absent)"
check "ACCESS_TOKEN error leaves out the value's other parts" absent "$(grep -qF "planted" <<<"$out" && echo present || echo absent)"
check "ACCESS_TOKEN error names the key and the allowed characters" 1 "$(grep -cF 'ACCESS_TOKEN has invalid characters (allowed: letters, digits, . _ - : @ +).' <<<"$out")"
check "ACCESS_TOKEN error still refuses the config" 1 "$(grep -cF 'rc=1' <<<"$out")"
out=$(run_config "{ $POOL, \"ACCESS_TOKENS\": {\"bench\": \"$PLANT\"} }")
check "ACCESS_TOKENS error leaves the value out" absent "$(grep -qF "planted" <<<"$out" && echo present || echo absent)"
check "ACCESS_TOKENS error names the entry and the allowed characters" 1 "$(grep -cF 'ACCESS_TOKENS."bench" has invalid characters (allowed: letters, digits, . _ - : @ +).' <<<"$out")"
check "ACCESS_TOKENS error still refuses the config" 1 "$(grep -cF 'rc=1' <<<"$out")"
out=$(run_config "{ $POOL, \"ACCESS_TOKEN\": \"ok.tok:1@x+y-z_\", \"ACCESS_TOKENS\": {\"bench\": \"ok-tok-2\"} }")
check "valid tokens are still accepted" "rc=0" "$(grep -F 'rc=' <<<"$out")"
exit "$fail"
