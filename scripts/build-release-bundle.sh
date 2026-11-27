#!/usr/bin/env bash
set -euo pipefail

PROG=${0##*/}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

die() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit 1
}

usage() {
    printf 'usage: %s <tag> <binary>...\n' "$PROG" >&2
    printf 'stages the deploy bundle plus the given release binaries under bin/ and writes\nrigforge-<tag>.zip, rigforge-<tag>.tar.gz and SHA256SUMS into the current directory.\nSHA256SUMS lists the two archives and every binary asset by file name. Each binary must\nbe named rigforge-<tag>-<arch>-unknown-linux-musl and be executable.\n' >&2
    exit 2
}

hash_line() {
    local file=$1 name=$2 sum
    if command -v sha256sum >/dev/null 2>&1; then
        sum=$(sha256sum -- "$file")
    else
        sum=$(shasum -a 256 -- "$file")
    fi
    printf '%s  %s\n' "${sum%% *}" "$name"
}

[[ $# -ge 2 ]] || usage
tag=$1
shift
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be a stable vX.Y.Z version: $tag"

binaries=()
names_seen=$'\n'
for bin in "$@"; do
    name=${bin##*/}
    [[ $name =~ ^rigforge-${tag}-(x86_64|aarch64)-unknown-linux-musl$ ]] ||
        die "binary must be named rigforge-$tag-<x86_64|aarch64>-unknown-linux-musl: $bin"
    [[ -f $bin && -x $bin ]] || die "binary is missing or not executable: $bin"
    [[ $names_seen != *$'\n'"$name"$'\n'* ]] || die "duplicate binary name: $name"
    names_seen+="$name"$'\n'
    binaries+=("$bin")
done

stage="rigforge-$tag"
[[ ! -e $stage && ! -e $stage.zip && ! -e $stage.tar.gz && ! -e SHA256SUMS ]] ||
    die "refusing to overwrite existing bundle files for $tag"
mkdir -p "$stage/bin"
cp -a "$ROOT"/rigforge.sh "$ROOT"/util "$ROOT"/systemd "$ROOT"/config.minimal.json \
    "$ROOT"/config.reference.json "$ROOT"/README.md "$ROOT"/docs "$ROOT"/images \
    "$ROOT"/LICENSE "$ROOT"/VERSION "$stage/"
for bin in "${binaries[@]}"; do
    cp -a "$bin" "$stage/bin/"
done
zip -rq "$stage.zip" "$stage"
tar -czf "$stage.tar.gz" "$stage"
{
    hash_line "$stage.zip" "$stage.zip"
    hash_line "$stage.tar.gz" "$stage.tar.gz"
    for bin in "${binaries[@]}"; do
        hash_line "$bin" "${bin##*/}"
    done
} >SHA256SUMS
echo "--- SHA256SUMS ---"
cat SHA256SUMS
