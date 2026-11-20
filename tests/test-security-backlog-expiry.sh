#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cat >"$SCRATCH/issues.json" <<'J'
[{"number": 7, "body": "## What's the problem\r\nexpires: 2026-11-01\r\n"},
 {"number": 8, "body": "review: 2026-10-01"},
 {"number": 9, "body": null}]
J
export ISSUES_FILE="$SCRATCH/issues.json" BASE_REF=develop ENFORCE_FROM=2026-12-04 TODAY=2026-11-20

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
run() { bash "$ROOT/scripts/security-backlog-expiry.sh" 2>&1; }

out=$(run) || fail "warn-only period must pass"
grep -q '::warning::.*#7' <<<"$out" || fail "warn-only period must name the lapsed issue"
if grep -q '#8' <<<"$out"; then fail "a review: issue must never gate"; fi

if out=$(TODAY=2026-12-04 run); then fail "enforcing period must fail"; fi
grep -q 'block this PR' <<<"$out" || fail "enforcing failure must say why"

TODAY=2026-12-04 PR_BODY="Fixes #7" run >/dev/null || fail "a PR closing the issue must pass"
if TODAY=2026-12-04 PR_BODY="Fixes #70" run >/dev/null; then fail "closing a different issue must not exempt"; fi
TODAY=2026-12-04 PR_AUTHOR="dependabot[bot]" run >/dev/null || fail "dependabot must be exempt"
TODAY=2026-12-04 HEAD_REF=bot/xmrig-v6.27.0 run >/dev/null || fail "xmrig bump must be exempt"
TODAY=2026-12-04 PR_LABELS="infra,security" run >/dev/null || fail "security label must be exempt"
TODAY=2026-12-04 BASE_REF=main run >/dev/null || fail "main must not be gated"
TODAY=2026-11-01 run >/dev/null || fail "an issue expiring today must not lapse"

printf 'PASS: security backlog expiry warns, enforces and exempts as designed\n'
