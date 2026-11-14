#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-$ROOT/tests/e2e-real.sh}
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
sed -n '/^ok() {$/,/^}/p; /^bad() {$/,/^}/p; /^summary() {$/,/^}/p; /^_perf_judge()/,/^}/p; /^perf()/,/^}/p' "$SCRIPT" >"$D/functions.sh"
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
printf 'perf submission: PASS\n'
