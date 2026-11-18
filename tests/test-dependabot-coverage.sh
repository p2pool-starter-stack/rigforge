#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

dependabot=.github/dependabot.yml

for eco in github-actions pre-commit pip npm docker; do
    grep -q "package-ecosystem: \"$eco\"" "$dependabot" ||
        fail "dependabot.yml has no $eco entry"
done

awk '
    /^  - package-ecosystem:/ { n++ }
    n && /- "infra"/ { hasinfra[n] = 1 }
    n && /- "dependencies"/ { hasdeps[n] = 1 }
    END {
        if (n < 5) { exit 1 }
        for (i = 1; i <= n; i++) {
            if (!hasinfra[i] || !hasdeps[i]) { exit 1 }
        }
    }' "$dependabot" ||
    fail "every dependabot entry must carry the infra and dependencies labels"

awk '/package-ecosystem: "github-actions"/ { ga = 1; next }
    ga && /^[[:space:]]+groups:/ { found = 1 }
    END { exit !found }' "$dependabot" ||
    fail "github-actions updates must carry a nested groups block"

for pin in diff-cover yamllint zizmor; do
    grep -q "^${pin}==" tools/requirements-ci.txt ||
        fail "tools/requirements-ci.txt does not pin $pin"
done
if grep -rq 'pipx install' .github/workflows; then
    fail "workflows must install Python tools from tools/requirements-ci.txt, not pipx"
fi
for wf in .github/workflows/ci.yml .github/workflows/security.yml; do
    grep -q 'tools/requirements-ci.txt' "$wf" ||
        fail "$wf must install from tools/requirements-ci.txt"
done

want=$(sed -n 's/.*"markdownlint-cli2": "\([^"]*\)".*/\1/p' package.json | head -1)
[ -n "$want" ] || fail "package.json does not pin markdownlint-cli2"
grep -q '"node_modules/markdownlint-cli2"' package-lock.json ||
    fail "package-lock.json does not install markdownlint-cli2"
grep -q "\"markdownlint-cli2\": \"$want\"" package-lock.json ||
    fail "package-lock.json does not pin the package.json version ($want)"
grep -q 'npm ci' Makefile || fail "make lint-md must install from the lockfile (npm ci)"
grep -q 'npm ci || echo' Makefile || fail "dev-setup must reach pre-commit install even when npm ci cannot"
grep -q 'npx markdownlint-cli2' Makefile || fail "make lint-md must run the local markdownlint-cli2"
if grep -q 'MARKDOWNLINT_VERSION' Makefile; then
    fail "the Makefile must not hand-pin markdownlint-cli2 outside package.json"
fi

for d in tests/e2e tests/coverage tests/docker; do
    grep -qE '^FROM [^[:space:]]+:[^@[:space:]]+@sha256:[0-9a-f]{64}$' "$d/Dockerfile" ||
        fail "$d/Dockerfile must pin its image by tag and digest"
    grep -q "\"/$d\"" "$dependabot" ||
        fail "dependabot.yml has no docker entry for /$d"
done
rc=0
stray=$(grep -rEl --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=graphify-out --include='*.yml' --include='*.yaml' --include='*.sh' --include='*.py' --include='Makefile' '@sha256:[0-9a-f]{64}' .) || rc=$?
[ "$rc" -le 1 ] || fail "stray image-digest scan could not run (grep exit $rc)"
[ -z "$stray" ] || fail "image digests belong only in the tests Dockerfile pins: $stray"

if grep -qE 'check (diff-cover|zizmor|markdownlint-cli2|kcov)' .github/workflows/tool-bump.yml; then
    fail "tool-bump.yml still watches tools that Dependabot now covers"
fi
for tool in shellcheck shfmt actionlint gitleaks lychee jq; do
    grep -qE "check ${tool}( |$)" .github/workflows/tool-bump.yml ||
        fail "tool-bump.yml dropped $tool, which Dependabot cannot cover"
done

grep -q -- '--label dependencies' .github/workflows/xmrig-bump.yml ||
    fail "xmrig-bump.yml PRs must carry the dependencies label"

printf 'PASS: dependabot covers every manifest it can read and tool-bump keeps the rest\n'
