#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.github/workflows" "$SCRATCH/tests"
cp "$ROOT/tests/coverage.sh" "$SCRATCH/tests/coverage.sh"
cp "$ROOT/Makefile" "$SCRATCH/Makefile"
cp "$ROOT"/.github/workflows/{ci,security,links}.yml "$SCRATCH/.github/workflows/"
sed -n '/^          check()/,/^          kcur=/{ /^          kcur=/d; s/^          //; p; }' \
    "$ROOT/.github/workflows/tool-bump.yml" >"$SCRATCH/checks.sh"
[ -s "$SCRATCH/checks.sh" ]
cd "$SCRATCH"
row() {
    [ "$1" = rows ]
    rows="${rows}| $2 | \`$3\` | $4 | $5 |"$'\n'
}
gh() {
    case "$*" in
    *lycheeverse/lychee*) printf 'lychee-v1\n' ;;
    *jqlang/jq*) printf 'jq-1\n' ;;
    *) printf 'v1\n' ;;
    esac
}
curl() {
    [ "$*" = '-fsS --max-time 30 https://registry.npmjs.org/markdownlint-cli2/latest' ] || return 99
    case "$response" in
    current) printf '{"version":"0.23.3"}\n' ;;
    stale) printf '{"version":"0.24.0"}\n' ;;
    failed) return 22 ;;
    malformed) printf 'not json\n' ;;
    missing) printf '{}\n' ;;
    multiline) printf '{"version":"0.23.3\\ninvalid"}\n' ;;
    prefixed) printf '{"version":"v0.23.3"}\n' ;;
    invalid) printf '{"version":"v0.23.3;echo injected"}\n' ;;
    esac
}
run_case() {
    local response="$1" want="$2" want_failed="$3" rows='' failed=0
    source "$SCRATCH/checks.sh"
    if ! printf '%s' "$rows" | grep -Fqx -- "$want" || [ "$failed" -ne "$want_failed" ]; then
        printf 'FAIL: npm %s response\n%s\nlookup failures: %s\n' "$response" "$rows" "$failed" >&2
        exit 1
    fi
    printf 'PASS: npm %s response\n' "$response"
}
run_case current '| markdownlint-cli2 | `0.23.3` | `0.23.3` | current |' 0
run_case stale '| markdownlint-cli2 | `0.23.3` | `0.24.0` | **stale** |' 0
for response in failed malformed missing; do
    run_case "$response" '| markdownlint-cli2 | `0.23.3` | — | **upstream lookup FAILED — not checked** |' 1
done
run_case multiline '| markdownlint-cli2 | `0.23.3` | — | **upstream tag unparseable — not checked** |' 1
run_case prefixed '| markdownlint-cli2 | `0.23.3` | — | **upstream tag unparseable — not checked** |' 1
run_case invalid '| markdownlint-cli2 | `0.23.3` | — | **upstream tag unparseable — not checked** |' 1
sed 's/^MARKDOWNLINT_VERSION = .*/MARKDOWNLINT_VERSION = 0.24.0/' Makefile >Makefile.new
mv Makefile.new Makefile
run_case stale '| markdownlint-cli2 | `0.24.0` | `0.24.0` | current |' 0
