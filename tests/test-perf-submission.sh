#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-$ROOT/tests/e2e-real.sh}
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
sed -n '/^ok() {$/,/^}/p; /^bad() {$/,/^}/p; /^summary() {$/,/^}/p; /^_perf_[a-z]*()/,/^}/p; /^perf()/,/^}/p' "$SCRIPT" >"$D/functions.sh"
cat >"$D/rigforge" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
if [ "$1" = bench ]; then
    echo 'Benchmark hashrate: 1000.0 H/s'
    if [ "${2:-}" = --submit ] && [ "${OMIT_ID:-0}" = 0 ]; then
        echo 'Benchmark submission ID: AbC123'
    fi
fi
exit 0
STUB
chmod +x "$D/rigforge"
hostname() { printf ''; }
lscpu() { echo 'Model name: test CPU'; }
phase() { :; }
die() {
    printf 'e2e-real: %s\n' "$1" >&2
    exit 2
}
HERE="$D" RIGFORGE="$D/rigforge"
export CALLS="$D/calls"
source "$D/functions.sh"
run_perf() (
    PASS=0 FAIL=0
    E2E_PERF_RECORD=1 E2E_PERF_TAG=test
    E2E_PERF_SUBMIT=$1
    perf
)
run_perf 0 >"$D/output" 2>&1
jq -e 'has("benchmark_id") | not' "$D/tests/perf-baselines/.json" >/dev/null
if grep -q -- --submit "$CALLS"; then
    echo 'FAIL: offline perf submitted'
    exit 1
fi
run_perf 1 >"$D/output" 2>&1
grep -q '^bench --submit$' "$CALLS" || {
    echo 'FAIL: perf did not submit'
    exit 1
}
jq -e '.benchmark_id == "AbC123"' "$D/tests/perf-baselines/.json" >/dev/null
tail -1 "$D/tests/perf-baselines/.history.jsonl" | jq -e '.benchmark_id == "AbC123"' >/dev/null
cp "$D/tests/perf-baselines/.json" "$D/before"
if OMIT_ID=1 run_perf 1 >"$D/output" 2>&1; then
    echo 'FAIL: missing submission ID passed'
    exit 1
fi
cmp -s "$D/before" "$D/tests/perf-baselines/.json"
lscpu() { echo 'Model name: AMD Ryzen 7 7800X3D 8-Core Processor'; }
class=amd-ryzen-7-7800x3d-8-core-processor
rm -rf "$D/tests"
run_report() (
    PASS=0 FAIL=0
    perf
)
out=$(run_report 2>&1)
printf '%s\n' "$out" | grep '^{' | jq -e --arg c "$class" '.[$c].bench_1m_hs == 1000' >/dev/null || {
    echo 'FAIL: perf did not emit class-keyed JSON'
    exit 1
}
[ ! -e "$D/tests/perf-baselines" ] || {
    echo 'FAIL: report mode wrote into the checkout'
    exit 1
}
H="$D/history.jsonl"
printf '{"%s":{"bench_1m_hs":2000}}\n{"other":{"bench_1m_hs":9}}\n' "$class" >"$H"
out=$(E2E_PERF_HISTORY=$H run_report 2>&1) || {
    echo 'FAIL: report mode failed on regression'
    exit 1
}
grep -q 'REGRESSION (report only)' <<<"$out" || {
    echo 'FAIL: report mode hid the regression'
    exit 1
}
if E2E_PERF_HISTORY=$D/missing E2E_PERF_GATE=1 run_report >/dev/null 2>&1; then
    echo 'FAIL: gate mode passed with no history file'
    exit 1
fi
printf 'not json\n{"%s":{"bench_1m_hs":null}}\n' "$class" >"$H"
out=$(E2E_PERF_HISTORY=$H run_report 2>&1) || {
    echo 'FAIL: malformed history aborted the phase'
    exit 1
}
grep -q 'no history for class' <<<"$out" || {
    echo 'FAIL: malformed history was not reported as no history'
    exit 1
}
printf '{"%s":{"bench_1m_hs":1000}}\n{"%s":{"bench_1m_hs":1010}}\n{"%s":{"bench_1m_hs":995}}\n{"%s":{"bench_1m_hs":1005}}\n{"%s":{"bench_1m_hs":1000}}\n' "$class" "$class" "$class" "$class" "$class" >"$H"
out=$(E2E_PERF_HISTORY=$H E2E_PERF_MODE=gate run_report 2>&1) || {
    echo 'FAIL: gate mode failed a healthy result'
    exit 1
}
grep -q 'matches the class history band' <<<"$out" || {
    echo 'FAIL: healthy gate result not reported'
    exit 1
}
printf '{"%s":{"bench_1m_hs":5000}}\n{"%s":{"bench_1m_hs":5100}}\n{"%s":{"bench_1m_hs":4900}}\n{"%s":{"bench_1m_hs":5050}}\n{"%s":{"bench_1m_hs":4950}}\n' "$class" "$class" "$class" "$class" "$class" >"$H"
if out=$(E2E_PERF_HISTORY=$H E2E_PERF_MODE=gate run_report 2>&1); then
    echo 'FAIL: gate mode passed a regression'
    exit 1
fi
grep -q 'perf REGRESSION' <<<"$out" || {
    echo 'FAIL: gate regression not named REGRESSION'
    exit 1
}
out=$(E2E_PERF_HISTORY=$H run_report 2>&1) || {
    echo 'FAIL: report mode failed on a regression with full history'
    exit 1
}
grep -q 'REGRESSION (report only)' <<<"$out" || {
    echo 'FAIL: report mode hid the regression with full history'
    exit 1
}
printf '{"%s":{"bench_1m_hs":95}}\n{"%s":{"bench_1m_hs":100}}\n{"%s":{"bench_1m_hs":105}}\n{"%s":{"bench_1m_hs":98}}\n{"%s":{"bench_1m_hs":102}}\n' "$class" "$class" "$class" "$class" "$class" >"$H"
if out=$(E2E_PERF_HISTORY=$H E2E_PERF_MODE=gate run_report 2>&1); then
    echo 'FAIL: gate mode passed an unexplained spike'
    exit 1
fi
grep -q 'perf SPIKE' <<<"$out" || {
    echo 'FAIL: gate spike not named SPIKE'
    exit 1
}
printf '{"%s":{"bench_1m_hs":1000}}\n{"%s":{"bench_1m_hs":1010}}\n{"%s":{"bench_1m_hs":995}}\n{"%s":{"bench_1m_hs":1005}}\n' "$class" "$class" "$class" "$class" >"$H"
out=$(E2E_PERF_HISTORY=$H E2E_PERF_MODE=gate run_report 2>&1) || {
    echo 'FAIL: gate mode failed on insufficient history'
    exit 1
}
grep -q 'insufficient history (4/5)' <<<"$out" || {
    echo 'FAIL: insufficient history not reported'
    exit 1
}
printf '{"other":{"bench_1m_hs":9}}\n' >"$H"
out=$(E2E_PERF_HISTORY=$H E2E_PERF_MODE=gate run_report 2>&1) || {
    echo 'FAIL: gate mode failed a box whose class has no history'
    exit 1
}
grep -q 'insufficient history (0/5)' <<<"$out" || {
    echo 'FAIL: missing class history not reported'
    exit 1
}
printf '{"%s":{"bench_1m_hs":5000}}\n{"%s":{"bench_1m_hs":5100}}\n{"%s":{"bench_1m_hs":4900}}\n{"%s":{"bench_1m_hs":5050}}\n{"%s":{"bench_1m_hs":4950}}\n' "$class" "$class" "$class" "$class" "$class" >"$H"
if out=$(E2E_PERF_HISTORY=$H E2E_PERF_GATE=1 run_report 2>&1); then
    echo 'FAIL: legacy E2E_PERF_GATE=1 no longer activates gate mode'
    exit 1
fi
grep -q 'perf REGRESSION' <<<"$out" || {
    echo 'FAIL: legacy gate alias did not judge'
    exit 1
}
if out=$(E2E_PERF_MODE=maybe run_report 2>&1); then
    echo 'FAIL: unknown mode passed'
    exit 1
fi
grep -q 'E2E_PERF_MODE must be report or gate' <<<"$out" || {
    echo 'FAIL: unknown mode not rejected'
    exit 1
}
mkdir -p "$D/tests/perf-baselines"
printf '{"bench_1m_hs":2000}\n' >"$D/tests/perf-baselines/.json"
run_report >/dev/null 2>&1 || {
    echo 'FAIL: legacy baseline failed report mode'
    exit 1
}
if E2E_PERF_GATE=1 run_report >/dev/null 2>&1; then
    echo 'FAIL: legacy baseline passed the gate without E2E_PERF_HISTORY'
    exit 1
fi
printf 'garbage\n' >"$D/tests/perf-baselines/.json"
if E2E_PERF_RECORD=1 run_report >/dev/null 2>&1; then
    echo 'FAIL: record overwrote an unreadable baseline'
    exit 1
fi
grep -qx garbage "$D/tests/perf-baselines/.json" || {
    echo 'FAIL: unreadable baseline was modified'
    exit 1
}
rm -rf "$D/tests"
out=$(E2E_PERF_SUBMIT=1 run_report 2>&1)
printf '%s\n' "$out" | grep '^{' | jq -e --arg c "$class" '.[$c].benchmark_id == "AbC123"' >/dev/null || {
    echo 'FAIL: emitted JSON dropped the submission ID'
    exit 1
}
printf 'perf submission: PASS\n'
