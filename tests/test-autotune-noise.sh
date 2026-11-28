#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2317,SC2329
set -euo pipefail
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
mkdir -p "$D/worker"
OVF="$D/worker/tune-overrides.json"
export OVF D
POW_BASE_ONLY='[ "$(jq -r .randomx.scratchpad_prefetch_mode "$OVF")" = 1 ] || echo 100'
POW_CAND_ONLY='[ "$(jq -r .randomx.scratchpad_prefetch_mode "$OVF")" = 1 ] && echo 100 || :'
run_autotune() {
    printf '{"randomx":{"scratchpad_prefetch_mode":0}}\n' >"$OVF"
    : >"$D/reads"
    (
        OS_TYPE=Linux
        WORKER_ROOT="$D/worker"
        AUTOTUNE_TARGET="$1"
        AUTOTUNE_MODES="0 1"
        AUTOTUNE_SAMPLES=1
        AUTOTUNE_INTERVAL=0
        AUTOTUNE_WARMUP=0
        API_CMD="$2"
        TUNE_POWER_CMD="${3:-$POW_BASE_ONLY}"
        parse_config() { :; }
        _shared_host_start_guard() { :; }
        _xmrig_knob_pinned() { return 1; }
        _apply_runtime() { :; }
        sudo() { "$@"; }
        autotune >"$D/autotune.out" 2>&1
        echo "$?" >"$D/rc"
    )
    jq -r '.randomx.scratchpad_prefetch_mode' "$OVF"
}
mode1_reads() { printf '[ "$(jq -r .randomx.scratchpad_prefetch_mode "$OVF")" = 1 ] && { echo x >>"$D/reads"; [ "$(wc -l <"$D/reads")" -le 1 ] && echo %s || echo %s; } || echo 1000' "$1" "$2"; }

echo "== unit: autotune scores a candidate without a power reading on raw H/s (#814) =="
check "efficiency: a watt-less candidate 0.5% faster does not beat the baseline" 0 "$(run_autotune efficiency "$(mode1_reads 1005 1005)")"
check "efficiency: a watt-less candidate 10% faster still wins on raw H/s (#79)" 1 "$(run_autotune efficiency "$(mode1_reads 1100 1100)")"
check "the winner line shows the measured candidate figure" 1 "$(grep -c 'best is prefetch_mode=1 at 1100 H/s (vs 1000 H/s, 100.00 W' "$D/autotune.out")"
check "the winner line does not label the watt-less candidate as H/s/W" 0 "$(grep 'best is' "$D/autotune.out" | sed 's/ (vs.*//' | grep -c 'H/s/W')"
check "efficiency: against a watt-less baseline a candidate 10% faster wins on raw H/s" 1 "$(run_autotune efficiency "$(mode1_reads 1100 1100)" "$POW_CAND_ONLY")"
check "efficiency: against a watt-less baseline a candidate 10% slower loses on raw H/s" 0 "$(run_autotune efficiency "$(mode1_reads 900 900)" "$POW_CAND_ONLY")"

echo "== unit: autotune skips a baseline that reads 0.0 (#814) =="
check "a 0.0 baseline keeps the current mode" 0 "$(run_autotune efficiency 'echo 0.0')"
check "a 0.0 baseline exits 0" 0 "$(cat "$D/rc")"
check "a 0.0 baseline gets the no-hashrate warning" 1 "$(grep -c 'could not read a live hashrate' "$D/autotune.out")"
check "a 0.0 baseline raises no awk error" 0 "$(grep -c 'awk' "$D/autotune.out")"

echo "== unit: autotune re-measures the winner before adopting it (#814) =="
check "a lucky first reading that does not repeat is not adopted" 0 "$(run_autotune perf "$(mode1_reads 1100 1000)")"
check "the re-measure is logged" 1 "$(grep -c 're-measured prefetch_mode=1' "$D/autotune.out")"
check "a winner that holds on re-measure is adopted" 1 "$(run_autotune perf "$(mode1_reads 1100 1100)")"

echo "== unit: live tune keeps the raw samples, so the stddev is real (#814) =="
TUNE_MODE=live
TUNE_TMP="$D/tmp"
mkdir -p "$TUNE_TMP"
MEMO_FILE="$D/memo" MEMO_SD_FILE="$D/memo-sd" MEMO_HPW_FILE="$D/memo-hpw" MEMO_THROTTLE_FILE="$D/memo-thr"
RESULTS_FILE="$D/results.jsonl" TUNE_OVERRIDES="$D/live-overrides.json"
TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=3 TUNE_TEMP_CMD=':' RAPL_DIR="$D/no-rapl"
_apply_runtime() { :; }
sudo() { "$@"; }
: >"$D/reads"
API_CMD='echo x >>"$D/reads"; echo $((900 + 100 * $(wc -l <"$D/reads")))'
check "the median is still the reported hashrate" 1100 "$(_measure 1 false -1 false 2 true false true)"
check "every live sample is recorded" "[1000,1100,1200]" "$(jq -c .samples "$RESULTS_FILE")"
check "the recorded stddev is nonzero" true "$(jq '.stddev > 0' "$RESULTS_FILE")"
check "the acceptance gate sees the same stddev" "$(jq -r .stddev "$RESULTS_FILE")" "$(_memo_get "$MEMO_SD_FILE" "1|false|-1|false|2|true|false|true")"
check "the median memo keeps its tab-separated row" "$(printf '1|false|-1|false|2|true|false|true\t1100')" "$(cat "$MEMO_FILE")"
check "the throttle memo keeps its tab-separated row" "$(printf '1|false|-1|false|2|true|false|true\t0')" "$(cat "$MEMO_THROTTLE_FILE")"
check "the hashrate-per-watt memo keeps its row, empty without a power reading" "$(printf '1|false|-1|false|2|true|false|true\t')" "$(cat "$MEMO_HPW_FILE")"
printf 'sd-only\t7\n' >>"$MEMO_SD_FILE"
check "a key in the stddev memo is found there" 7 "$(_memo_get "$MEMO_SD_FILE" sd-only)"
check "a key in the stddev memo is not found through the median memo" "" "$(_memo_get "$MEMO_FILE" sd-only)"
check "a cached median is served from the median memo without new reads" "1100 3" "$(_measure 1 false -1 false 2 true false true) $(wc -l <"$D/reads" | tr -d ' ')"
printf 'hot\t1\n' >>"$MEMO_THROTTLE_FILE"
printf 'noisy\t300\njumpy\t400\n' >>"$MEMO_SD_FILE"
printf 'lean\t10\nhungry\t8\n' >>"$MEMO_HPW_FILE"
check "a throttled candidate is refused through the throttle memo" reject "$(_accept_better 2000 hot 1000 cool && echo accept || echo reject)"
check "the same gain without a throttle flag is accepted" accept "$(_accept_better 2000 calm 1000 cool && echo accept || echo reject)"
check "a gain inside the combined noise band of both candidates is refused" reject "$(_accept_better 1450 noisy 1000 jumpy && echo accept || echo reject)"
check "efficiency: a slower candidate with more hashrate per watt wins through the hpw memo" accept "$(TUNE_TARGET=efficiency _accept_better 900 lean 1000 hungry && echo accept || echo reject)"
printf 'lean\t135\nhungry\t187.5\n' >>"$MEMO_SD_FILE"
check "efficiency: the same win inside the combined noise band is refused" reject "$(TUNE_TARGET=efficiency _accept_better 900 lean 1000 hungry && echo accept || echo reject)"
bash "$(dirname "${BASH_SOURCE[0]}")/test-tune-gate.sh" "$SCRIPT" || fail=1
exit "$fail"
