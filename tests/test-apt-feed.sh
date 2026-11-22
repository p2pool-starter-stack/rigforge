#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [[ $(uname -s) != Linux ]]; then
    printf 'FAIL: the apt feed test needs Linux (apt-ftparchive, apt-get, gpg)\n' >&2
    exit 1
fi
for cmd in apt-ftparchive gpg dpkg-deb gzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf 'FAIL: missing %s (apt-ftparchive ships in apt-utils)\n' "$cmd" >&2
        exit 1
    fi
done

ok() { printf 'ok: %s\n' "$1"; }
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_fails() {
    local desc=$1
    shift
    if "$@" >"$WORK/capture" 2>&1; then
        printf 'FAIL: %s (command unexpectedly succeeded)\n' "$desc" >&2
        cat "$WORK/capture" >&2
        exit 1
    fi
    ok "$desc"
}
assert_ok() {
    local desc=$1
    shift
    if ! "$@" >"$WORK/capture" 2>&1; then
        printf 'FAIL: %s\n' "$desc" >&2
        cat "$WORK/capture" >&2
        exit 1
    fi
    ok "$desc"
}
assert_contains() {
    local desc=$1 hay=$2 needle=$3
    printf '%s\n' "$hay" | grep -qF -- "$needle" || fail "$desc"
    ok "$desc"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"

KEYRING=$WORK/gnupg
gen_key() {
    local ring=$1
    mkdir -m 700 "$ring"
    printf 'Key-Type: RSA\nKey-Length: 2048\nKey-Usage: sign\nName-Real: RigForge Test\nName-Email: apt-test@example.invalid\nExpire-Date: 0\n%%no-protection\n%%commit\n' >"$ring/params"
    GNUPGHOME=$ring gpg --batch --quiet --gen-key "$ring/params"
    GNUPGHOME=$ring gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }'
}
FPR=$(gen_key "$KEYRING")
[[ ${#FPR} -eq 40 ]] || fail 'test key generation produced no fingerprint'
GNUPGHOME=$KEYRING gpg --batch --armor --export "$FPR" >"$WORK/pub.asc"
FPR2=$(gen_key "$WORK/gnupg2")
[[ ${#FPR2} -eq 40 && $FPR2 != "$FPR" ]] || fail 'second test key generation failed'
GNUPGHOME=$WORK/gnupg2 gpg --batch --armor --export "$FPR2" >"$WORK/other.asc"

mkdir -p "$WORK/pkg/DEBIAN" "$WORK/pkg/usr/share/doc/rigforge"
cat >"$WORK/pkg/DEBIAN/control" <<'EOF'
Package: rigforge
Version: 9.9.9
Architecture: all
Maintainer: RigForge <apt-test@example.invalid>
Description: test fixture for the apt feed test
EOF
printf 'fixture\n' >"$WORK/pkg/usr/share/doc/rigforge/README"
dpkg-deb --build -Zgzip "$WORK/pkg" "$WORK/rigforge_9.9.9_all.deb" >/dev/null

ZERO_FPR=0000000000000000000000000000000000000000
build_run() {
    env -i PATH="$PATH" HOME="$HOME" APT_SIGNING_FINGERPRINT="$1" GNUPGHOME="$2" \
        bash "$ROOT/scripts/build-apt.sh" feed "$3" "$4"
}

assert_fails 'feed refuses when APT_SIGNING_FINGERPRINT is unset' \
    env -i PATH="$PATH" HOME="$HOME" GNUPGHOME="$KEYRING" \
    bash "$ROOT/scripts/build-apt.sh" feed "$WORK/reject-unset" "$WORK/rigforge_9.9.9_all.deb"
assert_fails 'feed refuses a fingerprint that is not a full 40 hex digits' \
    build_run 'deadbeef' "$KEYRING" "$WORK/reject-short" "$WORK/rigforge_9.9.9_all.deb"
assert_fails 'feed refuses when GNUPGHOME is unset' \
    env -i PATH="$PATH" HOME="$HOME" APT_SIGNING_FINGERPRINT="$FPR" \
    bash "$ROOT/scripts/build-apt.sh" feed "$WORK/reject-gnupg" "$WORK/rigforge_9.9.9_all.deb"
assert_fails 'feed refuses when GNUPGHOME holds no secret key for the fingerprint' \
    build_run "$ZERO_FPR" "$KEYRING" "$WORK/reject-missing-key" "$WORK/rigforge_9.9.9_all.deb"

assert_ok 'feed builds, signs and verifies through apt from file://' \
    build_run "$FPR" "$KEYRING" "$WORK/feed" "$WORK/rigforge_9.9.9_all.deb"

for file in Packages Packages.gz Release Release.gpg InRelease rigforge.asc SHA256SUMS; do
    [[ -s $WORK/feed/$file ]] || fail "the feed is missing $file"
done
ok 'the feed carries Packages, Packages.gz, Release, Release.gpg, InRelease, rigforge.asc and SHA256SUMS'
assert_contains 'Packages references the .deb flat-relative' "$(cat "$WORK/feed/Packages")" './rigforge_9.9.9_all.deb'
assert_contains 'Release names the origin' "$(cat "$WORK/feed/Release")" 'Origin: RigForge'

assert_ok 'verify accepts the feed against the pinned key and fingerprint' \
    bash "$ROOT/scripts/build-apt.sh" verify "$WORK/feed" "$WORK/pub.asc" "$FPR"
assert_fails 'verify refuses a pinned fingerprint the feed key does not hash to' \
    bash "$ROOT/scripts/build-apt.sh" verify "$WORK/feed" "$WORK/pub.asc" "$ZERO_FPR"
assert_fails 'verify refuses a pinned public key that did not sign the feed' \
    bash "$ROOT/scripts/build-apt.sh" verify "$WORK/feed" "$WORK/other.asc" "$FPR2"

apt_against() {
    local dir=$1 sub=$2 state
    state=$(mktemp -d)
    chmod 755 "$state"
    mkdir -p "$state/lists/partial" "$state/download"
    cp "$WORK/pub.asc" "$state/feed-key.asc"
    chmod -R a+rX "$dir" "$state"
    chmod -R 777 "$state/lists" "$state/download"
    printf 'deb [signed-by=%s/feed-key.asc] file:%s ./\n' "$state" "$dir" >"$state/sources.list"
    local -a opts=(
        -o "Dir::Etc::sourcelist=$state/sources.list"
        -o Dir::Etc::sourceparts=-
        -o "Dir::State::lists=$state/lists"
    )
    case $sub in
    update) apt-get "${opts[@]}" update ;;
    download)
        apt-get "${opts[@]}" update >/dev/null 2>&1
        (cd "$state/download" && apt-get "${opts[@]}" download rigforge)
        ;;
    esac
}

assert_ok 'apt accepts the signed feed on a clean update' apt_against "$WORK/feed" update
assert_ok 'apt downloads the pinned .deb from the signed feed' apt_against "$WORK/feed" download

assert_ok 'a feed signed by the other key self-verifies' \
    build_run "$FPR2" "$WORK/gnupg2" "$WORK/foreign" "$WORK/rigforge_9.9.9_all.deb"
cp "$WORK/pub.asc" "$WORK/foreign/rigforge.asc"
(cd "$WORK/foreign" && sha256sum Packages Packages.gz Release Release.gpg InRelease rigforge.asc rigforge_9.9.9_all.deb >SHA256SUMS)
assert_fails 'verify refuses a foreign-key-signed feed whose published key and checksums were swapped to the pinned one' \
    bash "$ROOT/scripts/build-apt.sh" verify "$WORK/foreign" "$WORK/pub.asc" "$FPR"
assert_fails 'apt refuses to update from that foreign-key-signed feed' apt_against "$WORK/foreign" update

cp -a "$WORK/feed" "$WORK/tamper-release"
printf 'Origin: EvilCorp\n' >>"$WORK/tamper-release/Release"
assert_fails 'verify refuses a Release edited after signing (Release.gpg breaks)' \
    bash "$ROOT/scripts/build-apt.sh" verify "$WORK/tamper-release" "$WORK/pub.asc" "$FPR"
rm "$WORK/tamper-release/InRelease"
assert_fails 'apt refuses a Release edited after signing when it must fall back to Release.gpg' \
    apt_against "$WORK/tamper-release" update

cp -a "$WORK/feed" "$WORK/tamper-inrelease"
awk '{ print } NR == 3 { print "Origin: EvilCorp" }' \
    "$WORK/feed/InRelease" >"$WORK/tamper-inrelease/InRelease"
printf 'Origin: EvilCorp\n' >>"$WORK/tamper-inrelease/Release"
assert_fails 'verify refuses an InRelease payload edited after signing' \
    bash "$ROOT/scripts/build-apt.sh" verify "$WORK/tamper-inrelease" "$WORK/pub.asc" "$FPR"
assert_fails 'apt refuses an InRelease payload edited after signing' apt_against "$WORK/tamper-inrelease" update

cp -a "$WORK/feed" "$WORK/tamper-deb"
printf 'appended\n' >>"$WORK/tamper-deb/rigforge_9.9.9_all.deb"
assert_fails 'verify refuses a .deb that no longer matches SHA256SUMS' \
    bash "$ROOT/scripts/build-apt.sh" verify "$WORK/tamper-deb" "$WORK/pub.asc" "$FPR"
assert_fails 'apt refuses to download a .deb that was byte-appended after signing' \
    apt_against "$WORK/tamper-deb" download

printf 'ok: apt feed tests passed\n'
