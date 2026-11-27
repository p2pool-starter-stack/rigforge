#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

wf=.github/workflows/codeql.yml
[ -f "$wf" ] || fail "$wf is missing"
grep -qF 'name: Analyze (' "$wf" || fail "job must be named Analyze (<language>)"
grep -q 'language: \[actions, python\]' "$wf" || fail "matrix must cover actions and python"
grep -q 'branches: \[main, develop\]' "$wf" || fail "must run on pushes to main and develop"
grep -q '^  pull_request:' "$wf" || fail "must run on pull requests"
grep -q 'security-events: write' "$wf" || fail "analyze job needs security-events: write"
if grep -E 'uses: github/codeql-action/' "$wf" | grep -vqE '@[0-9a-f]{40} '; then
    fail "codeql-action must be pinned to a full commit SHA"
fi
grep -q 'CodeQL' SECURITY.md || fail "SECURITY.md must record the CodeQL coverage and the shell gap"
printf 'ok: codeql workflow\n'
