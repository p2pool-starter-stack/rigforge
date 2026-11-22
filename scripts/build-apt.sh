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
    printf 'usage:\n  %s feed <out-dir> <deb-file>\n  %s verify <feed-dir> <public-key-file> <fingerprint>\n\n' "$PROG" "$PROG" >&2
    printf 'feed builds a flat apt feed (Packages, Release, InRelease, Release.gpg) with\napt-ftparchive, signs it with APT_SIGNING_FINGERPRINT (40 hex digits) using the secret\nkey in GNUPGHOME, and verifies it with apt-get update and download from a file:// source.\nverify re-checks a built feed against a pinned fingerprint. Env: APT_SIGNING_FINGERPRINT,\nGNUPGHOME.\n' >&2
    exit 2
}

require_fingerprint() {
    FPR_NORM=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
    [[ $FPR_NORM =~ ^[0-9A-F]{40}$ ]]
}

import_fingerprint() {
    local home=$1 key=$2
    GNUPGHOME=$home gpg --batch --quiet --import "$key" >/dev/null 2>&1 || return 1
    local pubs
    pubs=$(GNUPGHOME=$home gpg --batch --with-colons --list-keys 2>/dev/null |
        awk -F: '$1 == "pub" { n++ } END { print n + 0 }')
    [[ $pubs -eq 1 ]] || return 1
    GNUPGHOME=$home gpg --batch --with-colons --list-keys 2>/dev/null |
        awk -F: '$1 == "fpr" { print $10; exit }'
}

new_keyring() {
    local -n out=$1
    out=$(mktemp -d)
    chmod 700 "$out"
    CLEANUP+=("$out")
}

validsig_from_status() {
    printf '%s\n' "$1" |
        awk -v f="$2" '/VALIDSIG/ { for (i = 1; i <= NF; i++) if ($i == f) found = 1 } END { exit !found }'
}

signatures_check() {
    local feed=$1 pub=$2 fpr=$3
    [[ -f $pub ]] || die "pinned public key file is missing: $pub"
    local home home2 imported
    new_keyring home
    imported=$(import_fingerprint "$home" "$pub") || die 'the pinned public key file is not one usable key'
    [[ $imported == "$fpr" ]] || die 'the pinned public key does not hash to the pinned fingerprint'
    [[ -f $feed/rigforge.asc ]] || die 'the feed must ship the signing public key as rigforge.asc'
    new_keyring home2
    imported=$(import_fingerprint "$home2" "$feed/rigforge.asc") ||
        die 'the key published in the feed is not one usable key'
    [[ $imported == "$fpr" ]] || die 'the key published in the feed does not hash to the pinned fingerprint'
    local status
    status=$(GNUPGHOME=$home gpg --batch --status-fd 1 --verify "$feed/Release.gpg" "$feed/Release" 2>/dev/null) ||
        die 'Release.gpg is not a valid signature for Release'
    validsig_from_status "$status" "$fpr" || die 'Release.gpg was not signed by the pinned fingerprint'
    status=$(GNUPGHOME=$home gpg --batch --status-fd 1 --verify "$feed/InRelease" 2>/dev/null) ||
        die 'InRelease is not a valid signature'
    validsig_from_status "$status" "$fpr" || die 'InRelease was not signed by the pinned fingerprint'
}

apt_roundtrip() {
    local feed=$1 key=$2
    local deb
    set -- "$feed"/*.deb
    [[ $# -eq 1 && -f $1 ]] || die 'the flat feed must hold exactly one .deb'
    deb=$1
    local pkg ver
    pkg=$(dpkg-deb -f "$deb" Package) || die 'the feed .deb has no Package field'
    ver=$(dpkg-deb -f "$deb" Version) || die 'the feed .deb has no Version field'
    local -a sudo_cmd=()
    if [[ $(id -u) -ne 0 ]]; then
        command -v sudo >/dev/null || die 'apt verification needs root or sudo'
        sudo_cmd=(sudo)
    fi
    local state
    state=$(mktemp -d)
    CLEANUP+=("$state")
    chmod 755 "$state"
    mkdir -p "$state/lists/partial" "$state/download"
    cp "$key" "$state/feed-key.asc"
    chmod -R a+rX "$feed" "$state"
    chmod -R 777 "$state/lists" "$state/download"
    printf 'deb [signed-by=%s/feed-key.asc] file:%s ./\n' "$state" "$feed" >"$state/sources.list"
    local -a opts=(
        -o "Dir::Etc::sourcelist=$state/sources.list"
        -o Dir::Etc::sourceparts=-
        -o "Dir::State::lists=$state/lists"
    )
    "${sudo_cmd[@]}" apt-get "${opts[@]}" update
    (cd "$state/download" && "${sudo_cmd[@]}" apt-get "${opts[@]}" download "$pkg")
    cmp "$state/download/$(basename "$deb")" "$deb" || die 'apt downloaded a .deb that differs from the feed'
    printf 'build-apt: apt update and download verified %s %s\n' "$pkg" "$ver"
}

feed_build() {
    local cmd
    for cmd in apt-ftparchive gpg dpkg-deb gzip; do
        command -v "$cmd" >/dev/null || die "missing required command: $cmd (apt-ftparchive is in apt-utils)"
    done
    require_fingerprint "${APT_SIGNING_FINGERPRINT:-}" ||
        die 'APT_SIGNING_FINGERPRINT must be a full 40-hex-digit fingerprint'
    local fpr=$FPR_NORM
    [[ -n ${GNUPGHOME:-} && -d $GNUPGHOME ]] || die 'GNUPGHOME must point at the keyring holding the signing key'
    GNUPGHOME=$GNUPGHOME gpg --batch --with-colons --list-secret-keys "$fpr" 2>/dev/null |
        awk -F: -v f="$fpr" '$1 == "fpr" && $10 == f { found = 1 } END { exit !found }' ||
        die "no secret key for the pinned fingerprint is present in GNUPGHOME"
    [[ $# -eq 2 ]] || usage
    local out=$1 deb=$2
    [[ -f $deb && -r $deb ]] || die "unreadable .deb: $deb"
    dpkg-deb -f "$deb" Package >/dev/null || die "not a usable .deb: $deb"
    local ver
    ver=$(dpkg-deb -f "$deb" Version)
    mkdir -p "$out"
    [[ $(find "$out" -mindepth 1 -maxdepth 1 -print -quit) == "" ]] || die 'the output directory must be empty'
    cp -- "$deb" "$out/"
    deb=$(basename "$deb")
    (
        cd "$out"
        apt-ftparchive packages . >Packages
        gzip -9cn Packages >Packages.gz
        apt-ftparchive \
            -o APT::FTPArchive::Release::Origin=RigForge \
            -o APT::FTPArchive::Release::Label=RigForge \
            -o APT::FTPArchive::Release::Codename=stable \
            -o "APT::FTPArchive::Release::Version=$ver" \
            release . >Release
        GNUPGHOME=$GNUPGHOME gpg --batch --yes --local-user "$fpr" --armor --detach-sign --output Release.gpg Release
        GNUPGHOME=$GNUPGHOME gpg --batch --yes --local-user "$fpr" --armor --clearsign --output InRelease Release
        GNUPGHOME=$GNUPGHOME gpg --batch --armor --export "$fpr" >rigforge.asc
        [[ -s rigforge.asc ]] || die 'exporting the signing public key failed'
    )
    local abs
    abs=$(cd "$out" && pwd)
    signatures_check "$abs" "$abs/rigforge.asc" "$fpr"
    apt_roundtrip "$abs" "$abs/rigforge.asc"
    (cd "$out" && sha256sum Packages Packages.gz Release Release.gpg InRelease rigforge.asc "$deb" >SHA256SUMS)
}

verify_feed() {
    [[ $# -eq 3 ]] || usage
    local dir=$1 pub=$2
    require_fingerprint "$3" || die 'expected a full 40-hex-digit fingerprint'
    local fpr=$FPR_NORM
    [[ -d $dir ]] || die "no such feed directory: $dir"
    dir=$(cd "$dir" && pwd)
    local file
    for file in Packages Packages.gz Release Release.gpg InRelease rigforge.asc; do
        [[ -f $dir/$file ]] || die "the feed is missing $file"
    done
    signatures_check "$dir" "$pub" "$fpr"
    (cd "$dir" && sha256sum -c --quiet SHA256SUMS) || die 'a feed file does not match SHA256SUMS'
    apt_roundtrip "$dir" "$pub"
}

[[ $# -ge 1 ]] || usage
cmd=$1
shift
case $cmd in
feed) feed_build "$@" ;;
verify) verify_feed "$@" ;;
*) usage ;;
esac
