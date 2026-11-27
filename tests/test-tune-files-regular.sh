#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
[ "$(uname -s)" = Linux ] || {
    echo "  skip Linux-only"
    exit 0
}
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
source "$SCRIPT"
set +e
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
OS_TYPE=Darwin
WORKER_ROOT="$D/worker"
mkdir -p "$WORKER_ROOT"
OVR="$WORKER_ROOT/tune-overrides.json"
LOG="$WORKER_ROOT/rigforge-tune.json"
OTHER="$D/other.json"
printf '{"marker":"outside","best":{"hashrate":9},"target":"x","results":[1,2,3]}\n' >"$OTHER"
EMPTY='{"applied":null,"target":null,"last_best_hs":null,"candidates_tried":null}'
real_jq=$(command -v jq)
feed() { _api_tune_json 2>"$D/err" | "$real_jq" -c '{applied, target, last_best_hs, candidates_tried}'; }
reset() { rm -rf "$OVR" "$LOG"; }

reset
printf '{"randomx":{"scratchpad_prefetch_mode":2}}\n' >"$OVR"
printf '{"target":"perf","best":{"hashrate":1234},"results":[1,2]}\n' >"$LOG"
check "regular files give the feed" '{"applied":{"randomx":{"scratchpad_prefetch_mode":2}},"target":"perf","last_best_hs":1234,"candidates_tried":2}' "$(feed)"
check "regular files write nothing to stderr" "0" "$(wc -c <"$D/err" | tr -d ' ')"

reset
check "missing files read as absent" "$EMPTY" "$(feed)"
check "missing files create nothing" "none" "$([ -e "$OVR" ] || [ -e "$LOG" ] && echo some || echo none)"
jq() {
    echo start >>"$D/jq-starts"
    "$real_jq" "$@"
}
: >"$D/jq-starts"
feed >/dev/null
unset -f jq
check "missing files start one jq, as before" "1" "$(wc -l <"$D/jq-starts" | tr -d ' ')"

reset
: >"$OVR"
: >"$LOG"
check "empty files read as absent" "$EMPTY" "$(feed)"

reset
ln -s "$OTHER" "$OVR"
ln -s "$OTHER" "$LOG"
check "a link at either path reads as absent" "$EMPTY" "$(feed)"
check "a link at either path writes nothing to stderr" "0" "$(wc -c <"$D/err" | tr -d ' ')"
check "a link at tune-overrides.json leaves the feed without the target content" "no" "$(_api_tune_json 2>/dev/null | grep -q outside && echo yes || echo no)"

reset
ln -s "$D/nowhere.json" "$OVR"
check "a dangling link reads as absent" "$EMPTY" "$(feed)"

reset
mkdir "$OVR" "$LOG"
check "a directory at either path reads as absent" "$EMPTY" "$(feed)"

reset
mkfifo "$OVR" "$LOG"
feed >"$D/fifo.out" &
pid=$!
for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null && sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo hang >"$D/fifo.out"
fi
wait "$pid" 2>/dev/null
check "a fifo at either path reads as absent without waiting" "$EMPTY" "$(cat "$D/fifo.out")"

reset
printf '{"randomx":{"scratchpad_prefetch_mode":1}}\n' >"$OVR"
printf '{"target":"perf","best":{"hashrate":5},"results":[1]}\n' >"$LOG"
swap() {
    if [ -e "$D/swap-armed" ]; then
        rm -f "$D/swap-armed" "$OVR" "$LOG"
        ln -s "$OTHER" "$OVR"
        ln -s "$OTHER" "$LOG"
    fi
}
jq() {
    swap
    "$real_jq" "$@"
}
read() {
    swap
    builtin read "$@"
}
: >"$D/swap-armed"
out=$(feed)
check "a swap to a link after the check keeps the file that was checked" "no" "$(printf '%s' "$out" | grep -q outside && echo yes || echo no)"
check "a swap to a link after the check keeps the original applied content" "1" "$(printf '%s' "$out" | "$real_jq" -r '.applied.randomx.scratchpad_prefetch_mode')"
unset -f jq read

reset
printf '{"randomx":{"scratchpad_prefetch_mode":1}}\n' >"$OVR"
printf '{"target":"perf","best":{"hashrate":5},"results":[1]}\n' >"$LOG"
printf '{"marker":"replacement"}\n' >"$D/replacement.json"
eval '[() {
    if builtin [ -e "$D/swap-armed" ] && builtin [ "$2" = -ef ]; then
        rm -f "$D/swap-armed" "$OVR"
        cp "$D/replacement.json" "$OVR"
    fi
    builtin [ "$@"
}'
: >"$D/swap-armed"
out=$(feed)
unset -f [
check "a swap to another file between open and check reads as absent" "null" "$(printf '%s' "$out" | "$real_jq" -c '.applied')"

exit "$fail"
