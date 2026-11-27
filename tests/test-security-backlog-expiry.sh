#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
cat >"$SCRATCH/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"issue list") echo '[]' ;;
"issue create") for a in "$@"; do [ -f "$a" ] && cp "$a" "$BODYCOPY"; done ;;
esac
EOF
chmod +x "$SCRATCH/gh"
pkg() {
    printf '{"package":{"name":"%s","version":"1.0.0"},"vulnerabilities":[{"id":"%s","affected":[{"package":{"name":"%s"},"ranges":[{"events":[{"introduced":"0"},{"fixed":"1.0.1"}]}]}]}],"groups":[{"ids":["%s"],"max_severity":"%s"}]}' "$1" "$2" "$1" "$2" "$3"
}
printf '{"results":[{"packages":[%s,%s]}]}\n' "$(pkg aaa GHSA-aaaa 9.0)" "$(pkg bbb GHSA-bbbb 8.0)" >"$SCRATCH/vuln.json"
BODYCOPY="$SCRATCH/body.md" GH="$SCRATCH/gh" bash "$ROOT/scripts/osv-file-issue.sh" develop "$SCRATCH/vuln.json" abc123 >/dev/null
sed -E -e '/GHSA-aaaa/s/expires: [0-9-]+/expires: 2026-12-30/' -e '/GHSA-bbbb/s/expires: [0-9-]+/expires: 2026-11-01/' "$SCRATCH/body.md" >"$SCRATCH/lapsed.md"
sed -E 's/expires: [0-9-]+/expires: 2026-12-30/' "$SCRATCH/body.md" >"$SCRATCH/fresh.md"
jq -n --rawfile a "$SCRATCH/lapsed.md" --rawfile b "$SCRATCH/fresh.md" \
    '[{number: 7, body: $a}, {number: 8, body: "review: 2026-10-01"}, {number: 9, body: null}, {number: 10, body: $b}]' >"$SCRATCH/issues.json"
export ISSUES_FILE="$SCRATCH/issues.json" BASE_REF=develop ENFORCE_FROM=2026-12-04 TODAY=2026-11-20

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
run() { bash "$ROOT/scripts/security-backlog-expiry.sh" 2>&1; }

out=$(run) || fail "warn-only period must pass"
grep -q '::warning::.*#7' <<<"$out" || fail "warn-only period must name the lapsed issue"
if grep -q '#10' <<<"$out"; then fail "an issue with no lapsed row must not be flagged"; fi
if grep -q '#8' <<<"$out"; then fail "a review: issue must never gate"; fi

if out=$(TODAY=2026-12-04 run); then fail "enforcing period must fail"; fi
grep -q 'block this PR' <<<"$out" || fail "enforcing failure must say why"

TODAY=2026-12-04 PR_BODY="Part of #7" run >/dev/null || fail "Part of must exempt"
TODAY=2026-12-04 PR_BODY="Fixes #7" run >/dev/null || fail "a PR closing the issue must pass"
if TODAY=2026-12-04 PR_BODY="Fixes #70" run >/dev/null; then fail "closing a different issue must not exempt"; fi
TODAY=2026-12-04 PR_AUTHOR="dependabot[bot]" run >/dev/null || fail "dependabot must be exempt"
TODAY=2026-12-04 HEAD_REF=bot/xmrig-v6.27.0 run >/dev/null || fail "xmrig bump must be exempt"
TODAY=2026-12-04 PR_LABELS="infra,security" run >/dev/null || fail "security label must be exempt"
TODAY=2026-12-04 BASE_REF=main run >/dev/null || fail "main must not be gated"
TODAY=2026-11-01 run >/dev/null || fail "an issue expiring today must not lapse"

printf '#!/usr/bin/env bash\nexit 1\n' >"$SCRATCH/badgh"
chmod +x "$SCRATCH/badgh"
mkdir "$SCRATCH/bin"
cp "$SCRATCH/badgh" "$SCRATCH/bin/gh"
(
    unset ISSUES_FILE
    PATH="$SCRATCH/bin:$PATH" run >/dev/null
) || fail "a gh failure must pass while warn-only"
if (
    unset ISSUES_FILE
    PATH="$SCRATCH/bin:$PATH" TODAY=2026-12-04 run >/dev/null
); then fail "a gh failure must fail when enforcing"; fi

printf 'PASS: security backlog expiry warns, enforces and exempts as designed\n'
