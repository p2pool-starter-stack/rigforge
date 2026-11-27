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
grep -q 'queries: security-extended' "$wf" || fail "CodeQL must run the security-extended suite"
sec=.github/workflows/security.yml
grep -q '^    name: Dependency review$' "$sec" || fail "security.yml needs a Dependency review job"
grep -q "if: github.event_name == 'pull_request'" "$sec" || fail "Dependency review must run on pull requests only"
grep -q 'fail-on-severity: high' "$sec" || fail "Dependency review must fail on high severity"
grep -qE 'uses: actions/dependency-review-action@[0-9a-f]{40} ' "$sec" || fail "dependency-review-action must be pinned to a full commit SHA"
grep -q 'Dependency review' SECURITY.md || fail "SECURITY.md must describe the Dependency review gate"
grep -q 'CodeQL' SECURITY.md || fail "SECURITY.md must record the CodeQL coverage and the shell gap"
printf 'ok: codeql workflow\n'
