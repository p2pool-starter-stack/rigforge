#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.github/workflows" "$SCRATCH/tests"
cp "$ROOT/tests/coverage.sh" "$SCRATCH/tests/coverage.sh"
cp "$ROOT"/.github/workflows/{ci,security,links}.yml "$SCRATCH/.github/workflows/"
sed -n '/^          check()/,/^          # <workflow file>/{ /^          # <workflow file>/d; s/^          //; p; }' \
    "$ROOT/.github/workflows/tool-bump.yml" >"$SCRATCH/checks.sh"
[ -s "$SCRATCH/checks.sh" ]
cd "$SCRATCH"
row() {
    [ "$1" = rows ]
    rows="${rows}| $2 | \`$3\` | $4 | $5 |"$'\n'
}
gh() {
    case "$*" in
    *lycheeverse/lychee*)
        local c
        c=$(grep -oE 'LYCHEE_VERSION: "[0-9.]+"' .github/workflows/links.yml | grep -oE '[0-9.]+')
        case "$response" in
        current) printf 'lychee-v%s\n' "$c" ;;
        stale) printf 'lychee-v%s.999\n' "$c" ;;
        failed) return 22 ;;
        malformed) printf 'not json\n' ;;
        missing) printf '\n' ;;
        multiline) printf 'lychee-v%s\ninvalid\n' "$c" ;;
        prefixed) printf 'v%s\n' "$c" ;;
        invalid) printf 'lychee-v%s;echo injected\n' "$c" ;;
        esac
        ;;
    *jqlang/jq*) printf 'jq-1\n' ;;
    *) printf 'v1\n' ;;
    esac
}
run_case() {
    local response="$1" want="$2" want_failed="$3" rows='' failed=0
    source "$SCRATCH/checks.sh"
    if ! printf '%s' "$rows" | grep -Fqx -- "$want" || [ "$failed" -ne "$want_failed" ]; then
        printf 'FAIL: gh %s response\n%s\nlookup failures: %s\n' "$response" "$rows" "$failed" >&2
        exit 1
    fi
    printf 'PASS: gh %s response\n' "$response"
}
cur=$(grep -oE 'LYCHEE_VERSION: "[0-9.]+"' "$ROOT/.github/workflows/links.yml" | grep -oE '[0-9.]+')
run_case current "| lychee | \`$cur\` | \`$cur\` | current |" 0
run_case stale "| lychee | \`$cur\` | \`$cur.999\` | **stale** |" 0
run_case failed "| lychee | \`$cur\` | — | **upstream lookup FAILED — not checked** |" 1
run_case missing "| lychee | \`$cur\` | — | **upstream lookup FAILED — not checked** |" 1
for response in malformed multiline prefixed invalid; do
    run_case "$response" "| lychee | \`$cur\` | — | **upstream tag unparseable — not checked** |" 1
done
