#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [[ $(uname -s) != Linux ]] || ! command -v dpkg-deb >/dev/null 2>&1; then
    printf 'SKIP: build-deb needs Linux with dpkg-deb\n'
    exit 0
fi

fail=0
check() {
    if [ "$2" -eq 0 ]; then printf 'ok: %s\n' "$1"; else
        printf 'FAIL: %s\n' "$1" >&2
        fail=1
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
VER=$(tr -d '[:space:]' <"$ROOT/VERSION")

bundle() {
    local out=$1 ver=$2 stage="$WORK/rigforge-v$2"
    rm -rf "$stage"
    mkdir -p "$stage"
    (cd "$ROOT" && cp -a rigforge.sh util systemd config.minimal.json config.reference.json README.md docs images LICENSE VERSION "$stage/")
    printf '%s\n' "$ver" >"$stage/VERSION"
    tar -czf "$out" -C "$WORK" "rigforge-v$ver"
}

bundle "$WORK/bundle.tar.gz" "$VER"
B="$ROOT/scripts/build-deb.sh"
check "two arguments are required" "$(bash "$B" "$WORK/bundle.tar.gz" >/dev/null 2>&1 && echo 1 || echo 0)"
check "missing archive fails" "$(bash "$B" "$WORK/nope.tar.gz" "$VER" >/dev/null 2>&1 && echo 1 || echo 0)"
check "a non-release version fails" "$(bash "$B" "$WORK/bundle.tar.gz" "v$VER-rc1" >/dev/null 2>&1 && echo 1 || echo 0)"
check "VERSION disagreeing with the tag fails" "$(cd "$WORK" && bash "$B" "$WORK/bundle.tar.gz" 0.0.1 >/dev/null 2>&1 && echo 1 || echo 0)"

mkdir -p "$WORK/a" "$WORK/b"
(cd "$WORK/a" && bash "$B" "$WORK/bundle.tar.gz" "v$VER" >/dev/null)
sleep 1
(cd "$WORK/b" && bash "$B" "$WORK/bundle.tar.gz" "v$VER" >/dev/null)
DEB="$WORK/a/rigforge_${VER}_all.deb"
check "builds rigforge_<VERSION>_all.deb" "$([ -f "$DEB" ] && echo 0 || echo 1)"
check "two builds of one bundle are byte-identical" "$(cmp -s "$DEB" "$WORK/b/rigforge_${VER}_all.deb" && echo 0 || echo 1)"

check "control Package is rigforge" "$([ "$(dpkg-deb -f "$DEB" Package)" = rigforge ] && echo 0 || echo 1)"
check "control Version is $VER" "$([ "$(dpkg-deb -f "$DEB" Version)" = "$VER" ] && echo 0 || echo 1)"
check "control Architecture is all" "$([ "$(dpkg-deb -f "$DEB" Architecture)" = all ] && echo 0 || echo 1)"
DEPENDS=$(dpkg-deb -f "$DEB" Depends)
for p in bash jq curl nftables git build-essential cmake libuv1-dev libssl-dev libhwloc-dev gettext-base python3 msr-tools; do
    check "Depends lists $p" "$(sed 's/[,|]/\n/g; s/ //g' <<<"$DEPENDS" | grep -qx "$p" && echo 0 || echo 1)"
done
check "Maintainer has the Name <email> form" "$(dpkg-deb -f "$DEB" Maintainer | grep -qE '^[^<]+ <[^>]+@[^>]+>$' && echo 0 || echo 1)"

X="$WORK/x"
dpkg-deb --raw-extract "$DEB" "$X"
L="$X/usr/lib/rigforge"
check "code tree under /usr/lib/rigforge" "$([ -f "$L/rigforge.sh" ] && [ -d "$L/util" ] && [ -d "$L/systemd" ] && echo 0 || echo 1)"
check "/usr/bin/rigforge resolves to the code tree" "$([ "$(readlink "$X/usr/bin/rigforge")" = ../lib/rigforge/rigforge.sh ] && echo 0 || echo 1)"
check "state dir /var/lib/rigforge" "$([ -d "$X/var/lib/rigforge" ] && echo 0 || echo 1)"
check "package marker is where util/package-mode.sh reads it" "$(SCRIPT_DIR="$L" bash -c 'source "$SCRIPT_DIR/util/package-mode.sh"; [ "$(_package_channel)" = apt ]' && echo 0 || echo 1)"
check "ships the upgrade unit" "$(cmp -s "$X/usr/lib/systemd/system/rigforge-upgrade.service" "$ROOT/packaging/debian/rigforge-upgrade.service" && echo 0 || echo 1)"
for s in postinst prerm postrm; do
    check "DEBIAN/$s is packaging/debian/$s" "$(cmp -s "$X/DEBIAN/$s" "$ROOT/packaging/debian/$s" && [ -x "$X/DEBIAN/$s" ] && echo 0 || echo 1)"
done
check "no group- or world-writable or setuid file in the package" "$([ -z "$(find "$X/usr" \( -perm -0020 -o -perm -0002 -o -perm -4000 -o -perm -2000 \) ! -type l)" ] && echo 0 || echo 1)"
check "ships no apt keyring" "$([ ! -e "$X/etc/apt" ] && echo 0 || echo 1)"
check "no internal repository references" "$(grep -rqE 'pithead-developer|bench-ci|ai-devkit' "$X" && echo 1 || echo 0)"

[ "$fail" -eq 0 ] && printf 'build-deb: all checks passed\n'
exit "$fail"
