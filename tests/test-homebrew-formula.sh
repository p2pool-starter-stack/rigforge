#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
BUILD=scripts/build-homebrew-formula.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

printf 'tarball-bytes\n' >"$T/rigforge-v1.2.3.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then sha=$(sha256sum "$T/rigforge-v1.2.3.tar.gz"); else sha=$(shasum -a 256 "$T/rigforge-v1.2.3.tar.gz"); fi
sha=${sha%% *}
printf '%s  rigforge-v1.2.3.zip\n%s  rigforge-v1.2.3.tar.gz\n' "$(printf 'z%.0s' {1..64})" "$sha" >"$T/SHA256SUMS"

bash "$BUILD" v1.2.3 "$T/SHA256SUMS" "$T/out.rb" "$T/rigforge-v1.2.3.tar.gz" || fail "render with a matching tarball"
grep -q "^  url \"https://github.com/p2pool-starter-stack/rigforge/releases/download/v1.2.3/rigforge-v1.2.3.tar.gz\"$" "$T/out.rb" || fail "url is not the release tarball"
grep -q "^  sha256 \"$sha\"$" "$T/out.rb" || fail "sha256 is not the one in SHA256SUMS"
grep -q '@' "$T/out.rb" && fail "unrendered placeholder left in the formula"
printf 'PASS: formula renders url and sha256 from SHA256SUMS\n'

printf 'other\n' >"$T/bad.tar.gz"
rc=0
bash "$BUILD" v1.2.3 "$T/SHA256SUMS" "$T/bad.rb" "$T/bad.tar.gz" 2>"$T/err" || rc=$?
[ "$rc" = 1 ] && grep -q disagrees "$T/err" || fail "a tarball that disagrees with SHA256SUMS was not refused for that reason"
printf 'PASS: tarball/SHA256SUMS disagreement fails\n'

grep -v tar.gz "$T/SHA256SUMS" >"$T/nosum"
bash "$BUILD" v1.2.3 "$T/nosum" "$T/x.rb" 2>/dev/null && fail "a SHA256SUMS without the tarball was accepted"
for bad in v1.2 1.2.3 v1.2.3-rc1; do
    bash "$BUILD" "$bad" "$T/SHA256SUMS" "$T/x.rb" 2>/dev/null && fail "tag $bad was accepted"
done
printf 'PASS: missing checksum and non-stable tags fail\n'

formula=Formula/rigforge.rb
[ -f "$formula" ] || fail "$formula is missing"
fsha=$(sed -n 's/^  sha256 "\([0-9a-f]\{64\}\)"$/\1/p' "$formula")
furl=$(sed -n 's/^  url "\(.*\)"$/\1/p' "$formula")
ftag=${furl#*/releases/download/}
ftag=${ftag%%/*}
printf '%s  rigforge-%s.tar.gz\n' "$fsha" "$ftag" >"$T/committed.sums"
bash "$BUILD" "$ftag" "$T/committed.sums" "$T/committed.rb" || fail "committed formula has no valid tag and sha256"
cmp -s "$T/committed.rb" "$formula" || fail "$formula differs from Formula/rigforge.rb.in rendered with its own url and sha256"
[ "$(printf '%s\n%s\n' "${ftag#v}" "$(tr -d '[:space:]' <VERSION)" | sort -V | tail -1)" = "$(tr -d '[:space:]' <VERSION)" ] || fail "formula pins $ftag, newer than VERSION"
printf 'PASS: committed formula matches the template and is not newer than VERSION\n'

if command -v ruby >/dev/null 2>&1; then
    ruby -c "$formula" >/dev/null || fail "formula is not valid Ruby"
    printf 'PASS: formula is valid Ruby\n'
fi

for need in 'depends_on "bash"' 'depends_on "jq"' 'depends_on "flock"' '.rigforge-package' 'write_env_script' 'rigforge --version' 'test do'; do
    grep -qF "$need" "$formula" || fail "formula lacks: $need"
done
grep -q 'RIGFORGE_STATE: "#{var}/rigforge"' "$formula" || fail "formula does not export RIGFORGE_STATE"
grep -q 'RIGFORGE_LIB' "$formula" && fail "formula must not set RIGFORGE_LIB: libexec is user-owned and the root guard would refuse it"
grep -qF 'user-writable tree' "$formula" || fail "formula lacks the user-writable code tree caveat"
grep -qF 'copy the old file to' "$formula" || fail "formula lacks the config migration caveat"
grep -q 'service do\|plist' "$formula" && fail "formula must not define a service"
printf 'PASS: formula wraps rigforge.sh, marks the tree and defines no service\n'

wf=.github/workflows/homebrew-formula.yml
grep -q 'release.draft' "$wf" && grep -q 'release.prerelease' "$wf" && grep -q "FORMULA_BOT_APP_ID != ''" "$wf" || fail "bump job must skip drafts, prereleases and an unconfigured bot"
grep -q 'push --force-with-lease origin "\$BRANCH"' "$wf" && grep -q 'BRANCH: homebrew/formula-bump' "$wf" || fail "bump must push the fixed branch"
grep -Eq 'push[^|]*origin (HEAD:)?main' "$wf" && fail "bump must never push main directly"
grep -q 'gh pr create --base main' "$wf" || fail "bump must open a PR against main"
grep -q 'rigforge.rb' .github/workflows/release.yml || fail "release must upload the generated rigforge.rb"
printf 'PASS: bump workflow is PR-only, gated and uploads the release formula\n'
