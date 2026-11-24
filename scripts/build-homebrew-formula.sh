#!/usr/bin/env bash
set -euo pipefail

PROG=${0##*/}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO_URL=https://github.com/p2pool-starter-stack/rigforge

die() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit 1
}

[[ $# -ge 3 && $# -le 4 ]] || {
    printf 'usage: %s <tag> <SHA256SUMS> <out-file> [tarball]\n' "$PROG" >&2
    printf 'renders Formula/rigforge.rb.in with the release tarball url and the sha256 from SHA256SUMS;\nwith a tarball it also fails unless the file hashes to that sha256.\n' >&2
    exit 2
}
tag=$1 sums=$2 out=$3 tarball=${4:-}

[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be a stable vX.Y.Z version: $tag"
[[ -f $sums ]] || die "missing checksum file: $sums"
asset="rigforge-$tag.tar.gz"
sha=$(awk -v a="$asset" '$2 == a { print $1 }' "$sums")
[[ $sha =~ ^[0-9a-f]{64}$ ]] || die "$sums has no valid sha256 for $asset"

if [[ -n $tarball ]]; then
    [[ -f $tarball ]] || die "missing tarball: $tarball"
    actual=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$tarball"; else shasum -a 256 "$tarball"; fi)
    [[ ${actual%% *} == "$sha" ]] || die "tarball sha256 ${actual%% *} disagrees with $sums ($sha)"
fi

sed -e "s|@URL@|$REPO_URL/releases/download/$tag/$asset|" -e "s|@SHA256@|$sha|" \
    "$ROOT/Formula/rigforge.rb.in" >"$out"
