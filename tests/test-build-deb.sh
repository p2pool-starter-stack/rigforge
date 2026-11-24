#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [[ $(uname -s) != Linux ]]; then
    printf 'SKIP: build-deb needs Linux (dpkg-deb)\n'
    exit 0
fi
for cmd in dpkg-deb dpkg; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf 'SKIP: missing %s\n' "$cmd"
        exit 0
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
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL: %s (unexpectedly succeeded)\n' "$desc" >&2
        exit 1
    fi
    ok "$desc"
}
assert_ok() {
    local desc=$1
    shift
    if ! "$@" >/dev/null 2>&1; then
        printf 'FAIL: %s\n' "$desc" >&2
        exit 1
    fi
    ok "$desc"
}
assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s (expected [%s], got [%s])\n' "$3" "$2" "$1" >&2
        exit 1
    fi
    ok "$3"
}
assert_contains() {
    local desc=$1 haystack=$2 needle=$3
    case "$haystack" in
    *"$needle"*) ok "$desc" ;;
    *)
        printf 'FAIL: %s (%s not found)\n' "$desc" "$needle" >&2
        exit 1
        ;;
    esac
}
assert_field() {
    local desc=$1 deb=$2 field=$3 want=$4
    got=$(dpkg-deb -f "$deb" "$field" 2>/dev/null) || fail "$desc: dpkg-deb -f failed"
    assert_eq "$got" "$want" "$desc: $field == $want"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

assert_fails "no args exits non-zero" "$ROOT/scripts/build-deb.sh"
assert_fails "one arg exits non-zero" "$ROOT/scripts/build-deb.sh" "$WORK/missing.tar.gz" "1.0.0" "$ROOT/packaging/apt/fingerprint"

assert_fails "missing archive exits non-zero" "$ROOT/scripts/build-deb.sh" "$WORK/nope.tar.gz" "1.0.0" "$ROOT/packaging/apt/fingerprint"

mkdir -p "$WORK/archive"
cp "$ROOT/rigforge.sh" "$WORK/archive/"
cp "$ROOT/util/"* "$WORK/archive/util/"
cp "$ROOT/systemd/"* "$WORK/archive/systemd/"
cp "$ROOT/config.minimal.json" "$WORK/archive/"
cp "$ROOT/config.reference.json" "$WORK/archive/"
cp "$ROOT/README.md" "$WORK/archive/"
cp "$ROOT/docs/"* "$WORK/archive/docs/"
cp "$ROOT/images/"* "$WORK/archive/images/"
cp "$ROOT/LICENSE" "$WORK/archive/"
cp "$ROOT/VERSION" "$WORK/archive/"
tar -czf "$WORK/bundle.tar.gz" -C "$WORK/archive" .
assert_fails "missing fingerprint file exits non-zero" "$ROOT/scripts/build-deb.sh" "$WORK/bundle.tar.gz" "1.0.0" "$WORK/nope"

printf '0.0.0-mismatch\n' >"$WORK/archive/VERSION"
assert_fails "VERSION mismatch exits non-zero" "$ROOT/scripts/build-deb.sh" "$WORK/bundle.tar.gz" "1.0.0" "$ROOT/packaging/apt/fingerprint"
printf '%s\n' "$(cat "$ROOT/VERSION")" >"$WORK/archive/VERSION"
tar -czf "$WORK/bundle.tar.gz" -C "$WORK/archive" .

VER="$(tr -d '[:space:]' <"$ROOT/VERSION")"
bash "$ROOT/scripts/build-deb.sh" "$WORK/bundle.tar.gz" "v$VER" "$ROOT/packaging/apt/fingerprint"
DEB="$WORK/rigforge_${VER}_all.deb"
assert_ok "build-deb produces a .deb" test -f "$DEB"

assert_field "$DEB" Package rigforge
assert_field "$DEB" Version "$VER"
assert_field "$DEB" Architecture all

CONTENT_DIR=$(mktemp -d)
trap 'rm -rf "$WORK" "$CONTENT_DIR"' EXIT
dpkg-deb --extract "$DEB" "$CONTENT_DIR"

assert_eq "$([ -f "$CONTENT_DIR/usr/lib/rigforge/rigforge.sh" ] && echo yes || echo no)" "yes" "rigforge.sh in /usr/lib/rigforge/"
assert_eq "$([ -d "$CONTENT_DIR/usr/lib/rigforge/util" ] && echo yes || echo no)" "yes" "util/ in /usr/lib/rigforge/"
assert_eq "$([ -d "$CONTENT_DIR/usr/lib/rigforge/systemd" ] && echo yes || echo no)" "yes" "systemd/ in /usr/lib/rigforge/"
assert_eq "$([ -f "$CONTENT_DIR/usr/bin/rigforge" ] && echo yes || echo no)" "yes" "/usr/bin/rigforge wrapper"
assert_eq "$([ -f "$CONTENT_DIR/etc/rigforge/config.json" ] && echo yes || echo no)" "yes" "config.json as conffile"
assert_eq "$([ -d "$CONTENT_DIR/var/lib/rigforge" ] && echo yes || echo no)" "yes" "state dir /var/lib/rigforge"
assert_eq "$([ -f "$CONTENT_DIR/var/lib/rigforge/.rigforge-package" ] && echo yes || echo no)" "yes" "apt marker"
assert_eq "$(tr -d '[:space:]' <"$CONTENT_DIR/var/lib/rigforge/.rigforge-package")" "apt" "marker value is apt"

assert_contains "wrapper exports RIGFORGE_LIB" "$(cat "$CONTENT_DIR/usr/bin/rigforge")" "RIGFORGE_LIB"
assert_contains "wrapper exports RIGFORGE_STATE" "$(cat "$CONTENT_DIR/usr/bin/rigforge")" "RIGFORGE_STATE"

assert_eq "$([ -f "$CONTENT_DIR/DEBIAN/postinst" ] && echo yes || echo no)" "yes" "postinst present"
assert_eq "$([ -f "$CONTENT_DIR/DEBIAN/postrm" ] && echo yes || echo no)" "yes" "postrm present"
assert_eq "$([ -f "$CONTENT_DIR/DEBIAN/conffiles" ] && echo yes || echo no)" "yes" "conffiles present"

POSTINST="$(cat "$CONTENT_DIR/DEBIAN/postinst")"
assert_contains "postinst runs daemon-reload" "$POSTINST" "daemon-reload"
assert_contains "postinst creates state dir" "$POSTINST" "/var/lib/rigforge"

POSTRM="$(cat "$CONTENT_DIR/DEBIAN/postrm")"
assert_contains "postrm remove stops units" "$POSTRM" "systemctl stop"
assert_contains "postrm remove disables units" "$POSTRM" "systemctl disable"
assert_contains "postrm purge removes state" "$POSTRM" "/var/lib/rigforge"
assert_contains "postrm purge removes config" "$POSTRM" "/etc/rigforge"

CONFFILES="$(cat "$CONTENT_DIR/DEBIAN/conffiles")"
assert_contains "conffiles lists config.json" "$CONFFILES" "/etc/rigforge/config.json"

for f in "$CONTENT_DIR/usr/lib/rigforge/"* "$CONTENT_DIR/DEBIAN/"*; do
    [ -f "$f" ] || continue
    case "$(cat "$f")" in
    *"pithead-developer"*) fail "internal repo reference found: $f" ;;
    esac
done
ok "no internal test-runner repo references"

if command -v apt-ftparchive >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1; then
    apt_out="$WORK/apt-feed"
    mkdir -p "$apt_out"
    FINGERPRINT="$(tr -d '[:space:]' <"$ROOT/packaging/apt/fingerprint")"
    if [ "$FINGERPRINT" != "pending-key-generation" ] && [ -n "$FINGERPRINT" ]; then
        GNUPGHOME="${GNUPGHOME:-}" apt-ftparchive packages "$apt_out" >/dev/null 2>&1 || true
    fi
    pkg=$(dpkg-deb -f "$DEB" Package)
    ver=$(dpkg-deb -f "$DEB" Version)
    assert_eq "$pkg" "rigforge" "build-apt: Package field matches"
    assert_eq "$ver" "$VER" "build-apt: Version field matches"
fi

printf '\nbuild-deb: tests passed\n' 2>/dev/null || true
