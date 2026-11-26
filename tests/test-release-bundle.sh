#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/scripts/build-release-bundle.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

cd "$T"
x86=rigforge-v1.2.3-x86_64-unknown-linux-musl
arm=rigforge-v1.2.3-aarch64-unknown-linux-musl
printf 'x86-binary\n' >"$x86"
printf 'arm-binary\n' >"$arm"
chmod +x "$x86" "$arm"

bash "$BUILD" v1.2.3 "$x86" "$arm" >/dev/null || fail "bundling two binaries failed"
[ -f rigforge-v1.2.3.zip ] && [ -f rigforge-v1.2.3.tar.gz ] || fail "archives missing"
printf 'PASS: zip and tar.gz are written\n'

tar -tzf rigforge-v1.2.3.tar.gz | grep -qx "rigforge-v1.2.3/bin/$x86" ||
    fail "tarball has no bin/$x86"
tar -tzf rigforge-v1.2.3.tar.gz | grep -qx "rigforge-v1.2.3/bin/$arm" ||
    fail "tarball has no bin/$arm"
tar -tzf rigforge-v1.2.3.tar.gz | grep -qx "rigforge-v1.2.3/rigforge.sh" ||
    fail "tarball lost the deploy tree"
tar -tzf rigforge-v1.2.3.tar.gz | grep -q '^rigforge-v1.2.3/tests/' &&
    fail "tarball ships tests/"
[ "$(tar -xzf rigforge-v1.2.3.tar.gz -O "rigforge-v1.2.3/bin/$x86")" = "x86-binary" ] ||
    fail "staged binary differs from the asset"
printf 'PASS: both binaries land under bin/ beside the deploy tree\n'

unzip -l rigforge-v1.2.3.zip | grep -q "rigforge-v1.2.3/bin/$arm" ||
    fail "zip has no bin/$arm"
printf 'PASS: the zip mirrors the tar.gz layout\n'

[ "$(grep -c . SHA256SUMS)" -eq 4 ] || fail "SHA256SUMS must list exactly four assets"
for want in rigforge-v1.2.3.zip rigforge-v1.2.3.tar.gz "$x86" "$arm"; do
    grep -q "  $want$" SHA256SUMS || fail "SHA256SUMS misses $want"
done
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS >/dev/null || fail "SHA256SUMS does not verify the built files"
else
    shasum -a 256 -c SHA256SUMS >/dev/null || fail "SHA256SUMS does not verify the built files"
fi
printf 'PASS: SHA256SUMS covers the archives and every binary\n'

rm -f "$arm" rigforge-v1.2.3.tar.gz
mkdir -p dl && cp rigforge-v1.2.3.zip "$x86" dl/
if command -v sha256sum >/dev/null 2>&1; then
    (cd dl && sha256sum -c --ignore-missing ../SHA256SUMS >/dev/null) ||
        fail "a zip-plus-one-binary download cannot be verified"
fi
printf 'PASS: a partial download verifies with --ignore-missing\n'
rm -rf dl
rm -f "$x86" rigforge-v1.2.3.* SHA256SUMS

rc=0
bash "$BUILD" v1.2.3 2>/dev/null || rc=$?
[[ $rc != 0 ]] || fail "a bundle without binaries was accepted"
rc=0
printf 'x\n' >"$x86"
chmod -x "$x86"
bash "$BUILD" v1.2.3 "$x86" 2>/dev/null || rc=$?
[[ $rc = 1 ]] || fail "a non-executable binary was accepted"
chmod +x "$x86"
rc=0
bash "$BUILD" v1.2.3 rigforge-v1.2.3-x86_64-unknown-linux-gnu 2>/dev/null || rc=$?
[[ $rc = 1 ]] || fail "a wrongly named binary was accepted"
rc=0
bash "$BUILD" v1.2 "$x86" 2>/dev/null || rc=$?
[[ $rc = 1 ]] || fail "a non-stable tag was accepted"
rc=0
mkdir -p a b
printf 'x\n' >"a/$x86"
printf 'x\n' >"b/$x86"
chmod +x "a/$x86" "b/$x86"
bash "$BUILD" v1.2.3 "a/$x86" "b/$x86" 2>/dev/null || rc=$?
[[ $rc = 1 ]] || fail "duplicate binary names were accepted"
printf 'PASS: missing, non-executable, misnamed and duplicate binaries fail\n'

arm9=rigforge-v9.9.9-aarch64-unknown-linux-musl
rc=0
bash "$BUILD" v9.9.9 >/dev/null 2>&1 || rc=$?
[[ $rc != 0 ]] || fail "a bare tag with no binaries was accepted"
printf 'arm9-binary\n' >"$arm9"
chmod +x "$arm9"
bash "$BUILD" v9.9.9 "$arm9" >/dev/null || fail "an aarch64-only bundle failed"
tar -tzf rigforge-v9.9.9.tar.gz | grep -qx "rigforge-v9.9.9/bin/$arm9" ||
    fail "aarch64-only bundle has no bin/$arm9"
tar -tzf rigforge-v9.9.9.tar.gz | grep -q "x86_64" &&
    fail "aarch64-only bundle shipped an x86_64 binary"
printf 'PASS: an aarch64-only bundle ships just the aarch64 binary\n'

printf 'PASS: all release-bundle checks passed\n'
