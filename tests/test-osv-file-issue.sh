#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

cat >"$SCRATCH/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG"
case "$1 $2" in
"issue list") cat "$LIST" ;;
"issue view") printf '%s\n' "${PREV_BODY:-}" ;;
"issue create" | "issue edit")
    for a in "$@"; do [ -f "$a" ] && cp "$a" "$BODYCOPY"; done
    ;;
esac
EOF
chmod +x "$SCRATCH/gh"
export GH="$SCRATCH/gh" LOG="$SCRATCH/log" LIST="$SCRATCH/list.json" BODYCOPY="$SCRATCH/body.md"

pkg='{"package":{"name":"left-pad","version":"1.0.0"},"vulnerabilities":[{"id":"GHSA-aaaa","affected":[{"package":{"name":"left-pad"},"ranges":[{"events":[{"introduced":"0"},{"fixed":"1.0.1"}]}]}]},{"id":"GHSA-bbbb","affected":[{"package":{"name":"left-pad"},"ranges":[{"events":[{"introduced":"0"}]}]}]}],"groups":[{"ids":["GHSA-aaaa"],"max_severity":"8.1"},{"ids":["GHSA-bbbb"],"max_severity":"3.0"}]}'
printf '{"results":[{"packages":[%s]}]}\n' "$pkg" >"$SCRATCH/vuln.json"
printf '{"results":[]}\n' >"$SCRATCH/clean.json"
printf '{"results":[{"packages":[{"package":{"name":"x","version":"1"},"vulnerabilities":[],"groups":[{"ids":["GHSA-cccc"],"max_severity":"4.0"}]}]}]}\n' >"$SCRATCH/low.json"

run() {
    : >"$LOG"
    rm -f "$BODYCOPY"
    bash "$ROOT/scripts/osv-file-issue.sh" "$@" >"$SCRATCH/out" 2>&1 || fail "script failed: $(cat "$SCRATCH/out")"
}

echo '[]' >"$LIST"
run develop "$SCRATCH/vuln.json" abc123
grep -q '^issue create --title Security: dependency vulnerabilities on develop --label security --label security-baseline --label branch:develop --body-file' "$LOG" || fail "no create call"
grep -qE '^\| left-pad \| 1.0.0 \| GHSA-aaaa \| 8.1 \| 1.0.1 \| expires: [0-9-]+ \|$' "$BODYCOPY" || fail "fixable row"
grep -qE '^\| left-pad \| 1.0.0 \| GHSA-bbbb \| 3.0 \| - \| review: [0-9-]+ \|$' "$BODYCOPY" || fail "unfixable row: $(grep GHSA "$BODYCOPY")"
for h in "What's the problem" "What it impacts" "How I found it" "How important is it" "Acceptance criteria" "Possible solutions"; do
    grep -qx "## $h" "$BODYCOPY" || fail "heading $h"
done
printf 'PASS: files one issue with the labels and deadlines\n'

echo '[{"number":7,"title":"Security: dependency vulnerabilities on develop"},{"number":8,"title":"other"}]' >"$LIST"
PREV_BODY='| left-pad | 1.0.0 | GHSA-aaaa | 8.1 | 1.0.1 | expires: 2020-01-01 |' run develop "$SCRATCH/vuln.json" abc123
grep -q '^issue edit 7 --body-file' "$LOG" || fail "no edit call"
! grep -q '^issue create' "$LOG" || fail "duplicate issue"
grep -q 'expires: 2020-01-01' "$BODYCOPY" || fail "deadline not kept"
printf 'PASS: a second run updates the same issue and keeps the deadline\n'

run develop "$SCRATCH/clean.json" abc123
grep -q '^issue close 7' "$LOG" || fail "no close"
run develop "$SCRATCH/low.json" abc123
grep -q '^issue close 7' "$LOG" || fail "below-floor finding must not keep the issue open"
printf 'PASS: a clean or below-floor run closes the issue\n'

echo '[]' >"$LIST"
run develop "$SCRATCH/clean.json" abc123
! grep -qE '^issue (create|close)' "$LOG" || fail "clean run with no issue must do nothing"
printf 'PASS: a clean run with no issue does nothing\n'

if bash "$ROOT/scripts/osv-file-issue.sh" 'x;rm' "$SCRATCH/clean.json" >/dev/null 2>&1; then
    fail "hostile ref accepted"
fi
printf 'PASS: a hostile ref is refused\n'
