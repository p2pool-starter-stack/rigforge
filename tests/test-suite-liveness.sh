#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
export FIXTURE_ROOT="$ROOT"
export FIXTURE_SANDBOX_FILE="$TASK_TMP/sandbox"

sed -n '1,/^export RIGFORGE_CONTROL_LOCK=/p' "$ROOT/tests/run.sh" >"$TASK_TMP/bootstrap"
awk '/^SUITE_COMPLETE=1$|^printf .rigforge tests:/ {summary=1} summary' "$ROOT/tests/run.sh" >"$TASK_TMP/summary"
[ -s "$TASK_TMP/summary" ] || exit 1

run_case() {
    local name="$1" expected="$2" rc=0
    cat "$TASK_TMP/bootstrap" >"$TASK_TMP/child.sh"
    printf '\nROOT=$FIXTURE_ROOT\nSCRIPT=$ROOT/rigforge.sh\n' >>"$TASK_TMP/child.sh"
    cat >>"$TASK_TMP/child.sh" <<'CHILD'
printf '%s\n' "$SANDBOX" >"$FIXTURE_SANDBOX_FILE"
CHILD
    cat >>"$TASK_TMP/child.sh"
    "$BASH" "$TASK_TMP/child.sh" >"$TASK_TMP/output" 2>&1 || rc=$?
    if [ "$rc" != "$expected" ]; then
        cat "$TASK_TMP/output" >&2
        printf 'FAIL: %s: expected exit %s, got %s\n' "$name" "$expected" "$rc" >&2
        exit 1
    fi
    [ ! -d "$(cat "$FIXTURE_SANDBOX_FILE")" ] || {
        echo 'FAIL: sandbox leaked' >&2
        exit 1
    }
    printf 'PASS: %s\n' "$name"
}

run_case 'early zero exit fails closed' 1 <<'CHILD'
exit 0
CHILD
run_case 'early nonzero exit is preserved' 7 <<'CHILD'
exit 7
CHILD
run_case 'nounset abort fails closed' 1 <<'CHILD'
printf '%s\n' "$UNSET_SUITE_LIVENESS_VALUE"
CHILD
run_case 'sourced parser failure cannot pass' 1 <<'CHILD'
printf 'if\n' >"$SANDBOX/broken.sh"
source "$SANDBOX/broken.sh"
exit 0
CHILD

{
    printf 'ok "completed assertion"\n'
    cat "$TASK_TMP/summary"
} | run_case 'completed suite succeeds' 0
grep -q '0 failed' "$TASK_TMP/output"
{
    printf 'bad "synthetic assertion" "expected failure"\n'
    cat "$TASK_TMP/summary"
} | run_case 'completed assertion failure fails' 1
grep -q '1 failed' "$TASK_TMP/output"

{
    awk '/^printf.*HOME_DIR/ {exit} {print}' "$ROOT/tests/test-api-refresh-liveness.sh"
    sed -n '/^echo "== unit: e2e-real retries NEXT/,/^MINER_LOG_SRC=/p' "$ROOT/tests/test-api-refresh-liveness.sh" | sed '$d'
    printf 'assert_eq "all bounded refresh assertions ran" "$PASS" 27\n'
    cat "$TASK_TMP/summary"
} | run_case 'actual timer-refresh fixtures reach their assertions' 0
printf 'suite liveness regressions: PASS\n'
