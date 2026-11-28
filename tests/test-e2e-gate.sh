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
mkdir "$BIN/dead"
printf '#!/bin/sh\n[ "$1" != info ]\n' >"$BIN/dead/docker"
chmod +x "$BIN/dead/docker"
check 1 "linux.sh exits 1 when the container daemon is unreachable" env PATH="$BIN/dead:$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" deploy
check 1 "isolation.sh exits 1 when the container daemon is unreachable" env PATH="$BIN/dead:$BIN" "$BIN/bash" "$ROOT/tests/e2e/isolation.sh"
check 0 "linux.sh names the unreachable daemon" bash -c '"$@" 2>&1 | grep -q "daemon not reachable"' _ env PATH="$BIN/dead:$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" deploy
check 0 "isolation.sh names the unreachable daemon" bash -c '"$@" 2>&1 | grep -q "daemon not reachable"' _ env PATH="$BIN/dead:$BIN" "$BIN/bash" "$ROOT/tests/e2e/isolation.sh"
check 2 "linux.sh rejects an unknown mode" env PATH="$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" bogus
check 2 "linux.sh rejects an empty mode" env PATH="$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" ""
check 2 "linux.sh rejects extra arguments" env PATH="$BIN" "$BIN/bash" "$ROOT/tests/e2e/linux.sh" deploy extra

GATE_LINE="$(grep -F 'scripts/require-success.sh' "$ROOT/.github/workflows/ci.yml")"
for id in deploy appliance isolation allowlist; do
    check 0 "ci.yml gates the $id step" grep -qE "^ +id: $id\$" "$ROOT/.github/workflows/ci.yml"
    var="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
    check 0 "ci.yml maps $var to the $id outcome" grep -qE "^ +$var: \\$\\{\\{ steps\\.$id\\.outcome \\}\\}\$" "$ROOT/.github/workflows/ci.yml"
    case "$id" in
    allowlist) run='docker run .* bash /src/tests/test-api-allowlist-linux\.sh' ;;
    *) run="run: bash tests/e2e/linux\\.sh $id" ;;
    esac
    check 0 "ci.yml runs the $id pass in the $id step" bash -c 'grep -A4 -E "^ +id: $1\$" "$2" | grep -qE -- "^ +$3\$"' _ "$id" "$ROOT/.github/workflows/ci.yml" "$run"
    check 0 "ci.yml runs the $id step after a failed sibling" bash -c 'grep -A1 -E "^ +id: $1\$" "$2" | grep -qE "^ +if: \\\$\{\{ !cancelled\(\) \}\}\$"' _ "$id" "$ROOT/.github/workflows/ci.yml"
    case "$GATE_LINE" in
    *"\"$id=\$$var\""*) echo "PASS: gate line lists $id" ;;
    *)
        echo "FAIL: gate line lists $id"
        FAIL=1
        ;;
    esac
done
check 0 "ci.yml always runs the gate step" bash -c 'grep -A1 -F -- "- name: Require every Docker mode" "$1" | grep -qE "^ +if: \\\$\{\{ always\(\) \}\}\$"' _ "$ROOT/.github/workflows/ci.yml"

G="$ROOT/scripts/require-success.sh"
check 0 "gate: all children success" bash "$G" a=success b=success
check 1 "gate: failure blocks" bash "$G" a=success b=failure
check 1 "gate: cancelled blocks" bash "$G" a=success b=cancelled
check 1 "gate: skipped blocks" bash "$G" a=success b=skipped
check 1 "gate: absent result blocks" bash "$G" a=success b=
check 1 "gate: no children blocks" bash "$G"
check 1 "gate: an argument without a name=result form blocks" bash "$G" success
check 1 "gate: a result without a name blocks" bash "$G" =success
exit "$FAIL"
