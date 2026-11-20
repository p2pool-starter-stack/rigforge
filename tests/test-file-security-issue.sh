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
if [ "$1 $2" = "issue list" ]; then cat "$LIST"; fi
EOF
chmod +x "$SCRATCH/gh"
export GH="$SCRATCH/gh" LOG="$SCRATCH/log" LIST="$SCRATCH/list.json"
printf 'body\n' >"$SCRATCH/body.md"
t="Security: workflow audit failing on develop"

run() {
    : >"$LOG"
    bash "$ROOT/scripts/file-security-issue.sh" "$@" >/dev/null || fail "script failed: $*"
}

echo '[]' >"$LIST"
run open "$t" "$SCRATCH/body.md" security-baseline
grep -qx "issue create --title $t --label security --label security-baseline --body-file $SCRATCH/body.md" "$LOG" || fail "no create call"
printf 'PASS: opens one labelled issue\n'

echo "[{\"number\":4,\"title\":\"$t\"}]" >"$LIST"
run open "$t" "$SCRATCH/body.md" security-baseline
grep -q '^issue edit 4 ' "$LOG" || fail "no edit call"
! grep -q '^issue create' "$LOG" || fail "duplicate issue"
printf 'PASS: a second run updates the same issue\n'

run close "$t" "$SCRATCH/body.md"
grep -q '^issue close 4 ' "$LOG" || fail "no close call"
echo '[]' >"$LIST"
run close "$t" "$SCRATCH/body.md"
! grep -q '^issue close' "$LOG" || fail "closed nothing-to-close"
printf 'PASS: close closes only an open issue\n'
