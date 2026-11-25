#!/usr/bin/env bash
set -euo pipefail

PROG=${0##*/}
PKG_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../packaging/debian" && pwd)"
CLEANUP=()
trap '[[ ${#CLEANUP[@]} -eq 0 ]] || rm -rf -- "${CLEANUP[@]}"' EXIT

die() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit 1
}

[[ $# -eq 2 ]] || {
    printf 'usage: %s <release-tarball.tar.gz|.zip> <tag-or-version>\n' "$PROG" >&2
    exit 2
}

ARCHIVE=$1
VERSION=${2#v}
[[ -f $ARCHIVE ]] || die "release archive not found: $ARCHIVE"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a release version: $2"

umask 022
STAGING=$(mktemp -d)
CLEANUP+=("$STAGING")
case "$ARCHIVE" in
*.tar.gz) tar -xzf "$ARCHIVE" -C "$STAGING" ;;
*.zip) unzip -q "$ARCHIVE" -d "$STAGING" ;;
*) die "unsupported archive format (expect .tar.gz or .zip)" ;;
esac

SRC=""
for d in "$STAGING"/*/; do
    [[ -f $d/rigforge.sh ]] && SRC=${d%/} && break
done
[[ -n $SRC ]] || die "no top-level directory with rigforge.sh in the archive"
[[ "$(tr -d '[:space:]' <"$SRC/VERSION")" == "$VERSION" ]] || die "VERSION in archive ($(tr -d '[:space:]' <"$SRC/VERSION")) disagrees with $VERSION"

export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(stat -c %Y "$SRC/VERSION")}

ROOT="$STAGING/root"
mkdir -p "$ROOT/usr/lib" "$ROOT/usr/bin" "$ROOT/usr/lib/systemd/system" "$ROOT/var/lib/rigforge" "$ROOT/DEBIAN"
cp -a "$SRC" "$ROOT/usr/lib/rigforge"
rm -rf "$ROOT/usr/lib/rigforge/docs/dev"
chmod -R go-w,ug-s "$ROOT/usr/lib/rigforge"
printf 'apt\n' >"$ROOT/usr/lib/rigforge/.rigforge-package"
ln -s ../lib/rigforge/rigforge.sh "$ROOT/usr/bin/rigforge"
install -m 0644 "$PKG_SRC/rigforge-upgrade.service" "$ROOT/usr/lib/systemd/system/"
install -m 0755 "$PKG_SRC/postinst" "$PKG_SRC/prerm" "$PKG_SRC/postrm" "$ROOT/DEBIAN/"
sed "s/@VERSION@/$VERSION/" "$PKG_SRC/control" >"$ROOT/DEBIAN/control"

find "$ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --build --root-owner-group -Zxz "$ROOT" "rigforge_${VERSION}_all.deb" >/dev/null
printf '%s\n' "rigforge_${VERSION}_all.deb"
