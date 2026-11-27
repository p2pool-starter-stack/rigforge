#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
check() {
    local want="$1" label="$2"
    shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        echo "PASS: $label"
    else
        echo "FAIL: $label (exit $got, want $want)"
        FAIL=1
    fi
}

BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
for t in bash sed dirname cat; do ln -s "$(command -v "$t")" "$BIN/$t"; done

for s in linux isolation; do
    check 1 "$s.sh exits 1 when the container runtime is missing" env PATH="$BIN" "$BIN/bash" "$ROOT/tests/e2e/$s.sh"
done
check 2 "linux.sh rejects an unknown mode" env PATH="$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" bogus
check 2 "linux.sh rejects an empty mode" env PATH="$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" ""
check 2 "linux.sh rejects extra arguments" env PATH="$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" deploy extra

GATE_LINE="$(grep -F 'scripts/require-success.sh' "$ROOT/.github/workflows/ci.yml")"
for id in deploy appliance isolation allowlist; do
    check 0 "ci.yml gates the $id step" grep -qE "^ +id: $id\$" "$ROOT/.github/workflows/ci.yml"
    var="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
    check 0 "ci.yml maps $var to the $id outcome" grep -qE "^ +$var: \\$\\{\\{ steps\\.$id\\.outcome \\}\\}\$" "$ROOT/.github/workflows/ci.yml"
    case "$GATE_LINE" in
    *"\"$id=\$$var\""*) echo "PASS: gate line lists $id" ;;
    *)
        echo "FAIL: gate line lists $id"
        FAIL=1
        ;;
    esac
done

G="$ROOT/scripts/require-success.sh"
check 0 "gate: all children success" bash "$G" a=success b=success
check 1 "gate: failure blocks" bash "$G" a=success b=failure
check 1 "gate: cancelled blocks" bash "$G" a=success b=cancelled
check 1 "gate: skipped blocks" bash "$G" a=success b=skipped
check 1 "gate: absent result blocks" bash "$G" a=success b=
check 1 "gate: no children blocks" bash "$G"
exit "$FAIL"
