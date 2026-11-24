#!/usr/bin/env bash
set -euo pipefail

PROG=${0##*/}
CLEANUP=()
trap '[[ ${#CLEANUP[@]} -eq 0 ]] || rm -rf -- "${CLEANUP[@]}"' EXIT

die() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit 1
}
usage() {
    cat >&2 <<EOF
usage:
  $PROG <release-tarball> <version> <fingerprint>

Builds a rigforge_<VERSION>_all.deb from the release tarball (zip or tar.gz).
The tarball must be the same bundle release.yml produces (rigforge.sh, util/,
systemd/, config.minimal.json, config.reference.json, README.md, docs/, images/,
LICENSE, VERSION). <version> is the tag version without the v prefix (e.g. 1.20.0).

Package layout:
  /usr/lib/rigforge/         — code tree (rigforge.sh, util/, systemd/, docs/, …)
  /usr/bin/rigforge           — wrapper exporting RIGFORGE_LIB / RIGFORGE_STATE
  /etc/rigforge/config.json   — default config (conffile)
  /var/lib/rigforge/          — runtime state directory
  /etc/apt/keyrings/rigforge.asc — signing key (from fingerprint file)
  .rigforge-package           — marker file with value "apt"
EOF
    exit 2
}

[[ $# -eq 3 ]] || usage

RELEASE_ARCHIVE="$1"
VERSION="${2#v}"
FINGERPRINT_FILE="$3"

[[ -f "$RELEASE_ARCHIVE" ]] || die "release archive not found: $RELEASE_ARCHIVE"
[[ -n "$VERSION" ]] || die "version must not be empty"
[[ -f "$FINGERPRINT_FILE" ]] || die "fingerprint file not found: $FINGERPRINT_FILE"

FINGERPRINT="$(tr -d '[:space:]' <"$FINGERPRINT_FILE")"
[[ -n "$FINGERPRINT" ]] || die "fingerprint file is empty"

STAGING="$(mktemp -d)"
CLEANUP+=("$STAGING")

case "$RELEASE_ARCHIVE" in
*.tar.gz) tar -xzf "$RELEASE_ARCHIVE" -C "$STAGING" ;;
*.zip) unzip -qo "$RELEASE_ARCHIVE" -d "$STAGING" ;;
*) die "unsupported archive format (expect .tar.gz or .zip)" ;;
esac

RELEASE_SRC=""
for d in "$STAGING"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "$d"/rigforge.sh ]] || continue
    RELEASE_SRC="$d"
    break
done
[[ -n "$RELEASE_SRC" ]] || die "could not find release source directory in archive"

ARCHIVE_VERSION="$(tr -d '[:space:]' <"$RELEASE_SRC/VERSION")"
if [ "$ARCHIVE_VERSION" != "$VERSION" ]; then
    die "VERSION in archive ($ARCHIVE_VERSION) disagrees with tag version ($VERSION)"
fi

BUILD_DIR="$(mktemp -d)"
CLEANUP+=("$BUILD_DIR")
DEB_DIR="$BUILD_DIR/rigforge-$VERSION"
mkdir -p "$DEB_DIR"

mkdir_stage() { mkdir -p "$DEB_DIR/$1"; }

PKG_NAME="rigforge"
PKG_ARCH="all"
PKG_VERSION="$VERSION"
PKG_SECTION="net"
PKG_PRIORITY="optional"

mkdir_stage "usr/lib/rigforge"
mkdir_stage "usr/bin"
mkdir_stage "etc/rigforge"
mkdir_stage "var/lib/rigforge"
mkdir_stage "etc/apt/keyrings"
mkdir_stage "usr/share/doc/rigforge"
mkdir_stage "DEBIAN"

cp -a "$RELEASE_SRC"/rigforge.sh "$DEB_DIR/usr/lib/rigforge/"
cp -a "$RELEASE_SRC"/util/ "$DEB_DIR/usr/lib/rigforge/util/"
cp -a "$RELEASE_SRC"/systemd/ "$DEB_DIR/usr/lib/rigforge/systemd/"
cp -a "$RELEASE_SRC"/config.minimal.json "$DEB_DIR/usr/lib/rigforge/"
cp -a "$RELEASE_SRC"/config.reference.json "$DEB_DIR/usr/lib/rigforge/"
cp -a "$RELEASE_SRC"/README.md "$DEB_DIR/usr/lib/rigforge/"
cp -a "$RELEASE_SRC"/VERSION "$DEB_DIR/usr/lib/rigforge/"
cp -a "$RELEASE_SRC"/LICENSE "$DEB_DIR/usr/lib/rigforge/"
cp -a "$RELEASE_SRC"/docs/ "$DEB_DIR/usr/lib/rigforge/docs/"
cp -a "$RELEASE_SRC"/images/ "$DEB_DIR/usr/lib/rigforge/images/"

cat >"$DEB_DIR/usr/bin/rigforge" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
export RIGFORGE_LIB="/usr/lib/rigforge"
export RIGFORGE_STATE="/var/lib/rigforge"
exec "${RIGFORGE_LIB}/rigforge.sh" "$@"
WRAPPER
chmod 755 "$DEB_DIR/usr/bin/rigforge"

cp "$RELEASE_SRC/config.minimal.json" "$DEB_DIR/etc/rigforge/config.json"

echo "apt" >"$DEB_DIR/var/lib/rigforge/.rigforge-package"

cp "$FINGERPRINT_FILE" "$DEB_DIR/etc/apt/keyrings/rigforge.asc" 2>/dev/null || {
    :
}

cat >"$DEB_DIR/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: ${PKG_SECTION}
Priority: ${PKG_PRIORITY}
Architecture: ${PKG_ARCH}
Depends: bash, jq, curl, nftables, git, build-essential, cmake, libuv1-dev, libssl-dev, libhwloc-dev, gettext-base, python3, msr-tools
Maintainer: user@example.com
Description: Companion miner for P2Pool/XMRig workers
 RigForge provisions and runs an XMRig worker for a P2Pool
 coordinator, any RandomX Stratum pool, or a solo daemon pool.
 This package installs RigForge for DIY operators on Ubuntu
 and Debian.
EOF

cat >"$DEB_DIR/DEBIAN/postinst" <<'POSTINST'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/lib/rigforge

systemctl daemon-reload 2>/dev/null || true

if [ -z "${2:-}" ]; then
    echo ""
    echo "RigForge is installed. Run the following to complete setup:"
    echo ""
    echo "  sudo rigforge.sh setup"
    echo ""
    echo "This configures your miner, deploys systemd units, and starts mining."
fi

exit 0
POSTINST
chmod 755 "$DEB_DIR/DEBIAN/postinst"

cat >"$DEB_DIR/DEBIAN/postrm" <<'POSTRM'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
    remove)
        for unit in \
            rigforge-autotune.timer rigforge-watchdog.timer \
            rigforge-api.service rigforge-api-refresh.service rigforge-api-refresh.timer \
            rigforge-control.service rigforge-control-apply.service rigforge-control-apply.path \
            rigforge-control-upgrade.service rigforge-control-upgrade.path; do
            systemctl stop "$unit" 2>/dev/null || true
            systemctl disable "$unit" 2>/dev/null || true
        done
        systemctl daemon-reload 2>/dev/null || true
        ;;
    purge)
        for unit in \
            rigforge-autotune.timer rigforge-watchdog.timer \
            rigforge-api.service rigforge-api-refresh.service rigforge-api-refresh.timer \
            rigforge-control.service rigforge-control-apply.service rigforge-control-apply.path \
            rigforge-control-upgrade.service rigforge-control-upgrade.path; do
            systemctl stop "$unit" 2>/dev/null || true
            systemctl disable "$unit" 2>/dev/null || true
        done
        systemctl daemon-reload 2>/dev/null || true
        rm -rf /etc/rigforge /var/lib/rigforge
        rm -f /usr/bin/rigforge
        rm -rf /usr/lib/rigforge
        rm -f /etc/apt/keyrings/rigforge.asc
        ;;
    *)
        echo "postrem called with unknown argument: $1" >&2
        exit 1
        ;;
esac

exit 0
POSTRM
chmod 755 "$DEB_DIR/DEBIAN/postrm"

cat >"$DEB_DIR/DEBIAN/conffiles" <<'EOF'
/etc/rigforge/config.json
EOF

DEB_NAME="rigforge_${VERSION}_all.deb"
DEB_PATH="$(pwd)/$DEB_NAME"
dpkg-deb --build --root-owner-group -Zxz \
    "$DEB_DIR" "$DEB_PATH"

echo "---"
echo "Built: $DEB_PATH"
echo "Size: $(stat -c '%s' "$DEB_PATH" 2>/dev/null || stat -f '%z' "$DEB_PATH") bytes"
echo "Package: $(dpkg-deb -f "$DEB_PATH" Package)"
echo "Version: $(dpkg-deb -f "$DEB_PATH" Version)"
echo "Architecture: $(dpkg-deb -f "$DEB_PATH" Architecture)"
echo "---"
