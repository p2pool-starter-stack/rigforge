#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export SCRIPT RF_TEST_ROOT="$D" STUB_MODE=ok
mkdir -p "$D/xmrig/build"
printf '%s\n' '{"colors":false,"background":true,"benchmark":{"submit":true},"randomx":{"scratchpad_prefetch_mode":1,"1gb-pages":false},"cpu":{"yield":false,"priority":2}}' >"$D/xmrig/build/config.json"
cat >"$D/xmrig/build/xmrig" <<'STUB'
#!/usr/bin/env bash
cfg='' mode=offline
[ "$STUB_MODE" != pipe ] || [ -p /dev/stdout ] || { echo 'capture is not a pipe'; exit 9; }
for a in "$@"; do
    case "$a" in
    --config=*) cfg=${a#*=} ;;
    --submit) mode=submit ;;
    --verify=*) mode=verify ;;
    esac
done
printf '%s\n' "$mode" >>"$RF_TEST_ROOT/calls"
[ -z "$cfg" ] || cp "$cfg" "$RF_TEST_ROOT/captured.json"
color=32 rate=1000.0 hash=898B6E0431C28A6B
case "$STUB_MODE" in
mismatch) color=31 ;;
missing) echo 'speed 9000.0 H/s'; exit 0 ;;
plain) color='' ;;
fatal) echo 'MEMORY ALLOC FAILED' ;;
zero_final) echo 'speed 9000.0 H/s'; rate=0.0 ;;
bad_submit_verify) [ "$mode" != verify ] || color=31 ;;
tune_bad | tune_mixed)
    p=$(jq -r .randomx.scratchpad_prefetch_mode "$cfg")
    if [ "$p" = 2 ]; then
        rate=9000.0 color=31
        if [ "$STUB_MODE" = tune_mixed ]; then
            n=$(cat "$RF_TEST_ROOT/mixed-count" 2>/dev/null || echo 0)
            n=$((n + 1)); printf '%s' "$n" >"$RF_TEST_ROOT/mixed-count"
            [ "$n" = 1 ] || color=32
        fi
    fi
    ;;
esac
if [ "$mode" = submit ] || [ "$mode" = verify ]; then
    printf '\033[0;36mbench\033[0m  \033[1;37mseed \033[1;30mAABBCCDD\033[0m\n'
fi
[ "$mode" != submit ] || color=30
if [ -n "$color" ]; then
    printf 'bench benchmark finished in 1.000 seconds (%s h/s) hash sum = \033[1;%sm%s\033[0m\n' "$rate" "$color" "$hash"
else
    printf 'bench benchmark finished in 1.000 seconds (%s h/s) hash sum = %s\n' "$rate" "$hash"
fi
if [ "$mode" = submit ]; then
    sleep 0.3
    echo 'bench benchmark submitted /benchmark/AbC123'
fi
if [ "$STUB_MODE" = failed_exit ]; then exit 7; fi
STUB
chmod +x "$D/xmrig/build/xmrig"
PASS=0 FAIL=0
check() {
    if "$@"; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n' "$*"
        printf '%s\n' "${OUT:-}" | tail -n 15
    fi
}
contains() { [[ "$OUT" == *"$1"* ]]; }
file_mode() {
    case "$(uname -s)" in
    Darwin) stat -f %Lp "$1" ;;
    *) stat -c %a "$1" ;;
    esac
}
run_bench() {
    RC=0
    OUT=$(bash -c '
        source "$SCRIPT"
        parse_config() { WORKER_ROOT="$RF_TEST_ROOT"; }
        _reown_worker() { :; }
        bench "$@"
    ' benchmark-test "$@" 2>&1) || RC=$?
}
run_bench
check test "$RC" = 0
check contains '1000.0 H/s'
check test "$(jq -r '.colors' "$D/captured.json")" = true
check test "$(jq -r '.background' "$D/captured.json")" = false
check test "$(jq -r '.benchmark // "absent"' "$D/captured.json")" = absent
check test "$(cat "$D/calls")" = offline
check test "$(jq -r '.verdict' "$D/rigforge-bench.json" 2>/dev/null)" = verified
check test "$(jq -r '.hash' "$D/rigforge-bench.json" 2>/dev/null)" = 898B6E0431C28A6B
check test -n "$(jq -r '.seed // empty' "$D/rigforge-bench.json" 2>/dev/null)"
check test "$(file_mode "$D/rigforge-bench.json")" = 644
OUT=$(bash -c '
    source "$SCRIPT"
    WORKER_ROOT="$RF_TEST_ROOT"
    mktemp() { return 1; }
    _bench_record "benchmark output unavailable"
' 2>&1)
check contains 'Could not record the latest benchmark result'
export STUB_MODE=pipe
run_bench
check test "$RC" = 0
for STUB_MODE in mismatch missing plain fatal failed_exit zero_final; do
    export STUB_MODE
    run_bench
    check test "$RC" != 0
    if [ "$STUB_MODE" = mismatch ]; then check contains correctness; fi
done
export STUB_MODE=ok
: >"$D/calls"
run_bench --submit
check test "$RC" = 0
check contains AbC123
check test "$(cat "$D/calls")" = "$(printf 'submit\nverify')"
check test "$(jq -r '.id' "$D/rigforge-bench.json" 2>/dev/null)" = AbC123
check test "$(jq -r '.verdict' "$D/rigforge-bench.json" 2>/dev/null)" = verified
check test "$(jq -r '.seed' "$D/rigforge-bench.json" 2>/dev/null)" = AABBCCDD
export STUB_MODE=bad_submit_verify
run_bench --submit
check test "$RC" != 0
export STUB_MODE=ok
run_bench --verify AbC123
check test "$RC" = 0
check test "$(jq -r '.id' "$D/rigforge-bench.json" 2>/dev/null)" = AbC123
for args in '--verify' '--submit --verify AbC123' '--minutes 1' '--verify ../bad'; do
    # shellcheck disable=SC2086
    run_bench $args
    check test "$RC" != 0
done
for STUB_MODE in tune_bad tune_mixed; do
    export STUB_MODE
    rm -f "$D/tune-overrides.json" "$D/mixed-count"
    RC=0
    OUT=$(bash -c '
        source "$SCRIPT"
        OS_TYPE=test
        parse_config() { WORKER_ROOT="$RF_TEST_ROOT"; }
        _tune_should_elevate() { return 1; }
        _reown_worker() { :; }
        _l3_thread_center() { echo 2; }
        _cpu_eff_khz() { :; }
        _read_temp() { echo 50; }
        sudo() { "$@"; }
        HUGEPAGES_1G_NR="$RF_TEST_ROOT/absent"
        RAPL_DIR="$RF_TEST_ROOT/absent"
        TUNE_SEARCH=grid TUNE_SEEDS=auto TUNE_PREFETCH_MODES="1 2" TUNE_YIELDS=false
        TUNE_THREADS=2 TUNE_PRIORITIES=2 TUNE_HPJIT=false TUNE_CACHEQOS=false TUNE_WRMSR=true
        TUNE_MIN_FREQ_MHZ=0 TUNE_ITERS=3 TUNE_TARGET=perf
        tune
    ' 2>&1) || RC=$?
    check test "$RC" = 0
    check test "$(jq -r '.randomx.scratchpad_prefetch_mode' "$D/tune-overrides.json" 2>/dev/null)" = 1
    check contains correctness
done
printf 'benchmark verification: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
