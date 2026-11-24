#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
eq() {
    if [ "$2" = "$3" ]; then printf '  PASS: %s\n' "$1"; else
        printf '  FAIL: %s — expected [%s], got [%s]\n' "$1" "$3" "$2" >&2
        FAIL=$((FAIL + 1))
    fi
}

BASE='{"cpu":{"yield":false,"priority":2,"huge-pages-jit":false},"randomx":{"scratchpad_prefetch_mode":1,"cache_qos":false,"wrmsr":true}}'
fresh() {
    D="$TMP/$1"
    OVR="$D/tune-overrides.json"
    mkdir -p "$D/xmrig/build"
    printf '#!/usr/bin/env bash\nexit 99\n' >"$D/xmrig/build/xmrig"
    chmod +x "$D/xmrig/build/xmrig"
    printf '%s\n' "$BASE" >"$D/xmrig/build/config.json"
    : >"$D/measured"
}
apply_ovr() {
    printf '%s\n' "$BASE" >"$D/base.json"
    (
        source "$SCRIPT"
        _shared_host_merge "$D/base.json" "$OVR"
    ) >"$D/xmrig/build/config.json"
}
run_tune() {
    (
        cd "$D" || exit 1
        source "$SCRIPT"
        parse_config() {
            WORKER_ROOT="$D"
            XMRIG_OVERLAY="${OVERLAY:-}"
            [ -n "$XMRIG_OVERLAY" ] || XMRIG_OVERLAY='{}'
            AUTOTUNE_TARGET=perf
        }
        _l3_thread_center() { :; }
        _accept_better() { awk -v a="$1" -v b="$3" 'BEGIN{exit !(a > b)}'; }
        _apply_runtime() { :; }
        _power_supported() { return 1; }
        sudo() { "$@"; }
        _measure() {
            echo "$*" >>"$D/measured"
            if [ "$6" = "${BEST_HJ:-true}" ]; then echo 1100; else echo 1000; fi
        }
        OS_TYPE=Darwin
        export TUNE_ITERS=1 TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false
        local a
        for a in "$@"; do export "${a?}"; done
        tune </dev/null >>"$D/tune.out" 2>&1
    )
}
pinned() { jq -c '[(.cpu, .randomx) | objects | keys[]] | sort' "$OVR"; }

echo "== a plain tune keeps a knob an earlier tune pinned (#815) =="
fresh a
run_tune TUNE_HPJIT="false true"
eq "run one pins huge-pages-jit" "$(jq -r '.cpu."huge-pages-jit"' "$OVR")" true
apply_ovr
eq "the applied config carries the pin" "$(jq -r '.cpu."huge-pages-jit"' "$D/xmrig/build/config.json")" true
: >"$D/measured"
run_tune
eq "a plain tune exits 0" "$?" 0
eq "every run-two candidate ran with huge-pages-jit true" "$(awk '{print $6}' "$D/measured" | sort -u)" true
eq "a plain tune keeps the huge-pages-jit pin" "$(jq -r '.cpu."huge-pages-jit"' "$OVR")" true
eq "a plain tune writes only its own winner plus the kept pin" "$(pinned)" '["huge-pages-jit","scratchpad_prefetch_mode","yield"]'

echo "== an old pin on a knob this run sweeps takes the new winner (#815) =="
fresh b
printf '{"cpu":{"huge-pages-jit":true}}\n' >"$OVR"
apply_ovr
run_tune TUNE_HPJIT="false true" BEST_HJ=false
eq "the swept knob takes run two's winner" "$(jq -r '.cpu."huge-pages-jit"' "$OVR")" false

echo "== an old threads pin does not survive an auto-threads winner (#815) =="
fresh c
printf '{"cpu":{"rx":{"mode":0,"threads":4,"max_threads_cnt":4,"intensity":1,"affinity":-1}}}\n' >"$OVR"
apply_ovr
run_tune
eq "auto threads won" "$(jq -r '.best.threads' "$D/rigforge-tune.json")" -1
eq "no cpu.rx is written" "$(jq -r '.cpu | has("rx")' "$OVR")" false

echo "== a knob never pinned and not swept stays absent (#815) =="
fresh d
run_tune
eq "only prefetch and yield are written" "$(pinned)" '["scratchpad_prefetch_mode","yield"]'

echo "== an invalid old overrides file acts like none (#815) =="
fresh e
printf 'not json{\n' >"$OVR"
run_tune
eq "tune exits 0" "$?" 0
eq "only prefetch and yield are written" "$(pinned)" '["scratchpad_prefetch_mode","yield"]'
eq "no jq error is printed" "$(grep -c 'jq:' "$D/tune.out")" 0

echo "== a knob the xmrig overlay pins is not written from the old file (#815) =="
fresh f
printf '{"cpu":{"huge-pages-jit":true,"priority":3}}\n' >"$OVR"
apply_ovr
run_tune OVERLAY='{"cpu":{"huge-pages-jit":true}}'
eq "the overlay-pinned knob is dropped" "$(jq -r '.cpu | has("huge-pages-jit")' "$OVR")" false
eq "the other old pin is kept" "$(jq -r '.cpu.priority' "$OVR")" 3

echo "== without an apply in between, the next tune writes the value it measured (#815) =="
fresh g
run_tune TUNE_HPJIT="false true"
eq "run one pins huge-pages-jit" "$(jq -r '.cpu."huge-pages-jit"' "$OVR")" true
: >"$D/measured"
run_tune
eq "run two measured with the built config's value" "$(awk '{print $6}' "$D/measured" | sort -u)" false
eq "run two writes the value it measured" "$(jq -r '.cpu."huge-pages-jit"' "$OVR")" false

echo "== applied cache_qos, 1gb-pages and wrmsr pins survive a plain tune (#815) =="
fresh h
printf '{"randomx":{"cache_qos":true,"1gb-pages":false,"wrmsr":false}}\n' >"$OVR"
apply_ovr
run_tune HUGEPAGES_1G_NR="$D/none"
eq "the three pins are kept" "$(jq -c '.randomx | {cache_qos, "1gb-pages", wrmsr}' "$OVR")" '{"cache_qos":true,"1gb-pages":false,"wrmsr":false}'

echo "== an applied priority pin is measured and kept when the guess seed wins (#815) =="
fresh i
printf '{"cpu":{"priority":3}}\n' >"$OVR"
apply_ovr
run_tune TUNE_SEEDS=guess
eq "every candidate ran with priority 3" "$(awk '{print $5}' "$D/measured" | sort -u)" 3
eq "priority 3 is kept" "$(jq -r '.cpu.priority' "$OVR")" 3

n=0
for shape in '[1]' '"s"' null; do
    echo "== an old overrides file holding $shape acts like none (#815) =="
    n=$((n + 1))
    fresh "j$n"
    printf '%s\n' "$shape" >"$OVR"
    run_tune
    eq "tune exits 0" "$?" 0
    eq "only prefetch and yield are written" "$(pinned)" '["scratchpad_prefetch_mode","yield"]'
    eq "candidates ran with the built huge-pages-jit" "$(awk '{print $6}' "$D/measured" | sort -u)" false
    eq "no jq error is printed" "$(grep -c 'jq:' "$D/tune.out")" 0
done

echo "== a key in the wrong section or with a space is not a pin (#815) =="
fresh k1
printf '{"cpu":{"wrmsr":false}}\n' >"$OVR"
run_tune
eq "cpu.wrmsr creates no pin" "$(pinned)" '["scratchpad_prefetch_mode","yield"]'
fresh k2
printf '{"randomx":{"a wrmsr":1,"b randomx.wrmsr":1},"cpu":{"c cpu.priority":1}}\n' >"$OVR"
run_tune
eq "keys with a space create no pin" "$(pinned)" '["scratchpad_prefetch_mode","yield"]'
exit "$FAIL"
