#!/usr/bin/env bash
set -euo pipefail
key_file="${1:?usage: revision-key.sh <key-file> < canonical}"
if [ ! -s "$key_file" ]; then
    tmp="$key_file.$$"
    trap 'rm -f "$tmp"' EXIT
    (umask 077 && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$tmp" && ln "$tmp" "$key_file") 2>/dev/null || true
fi
key=$(cat "$key_file")
[ -n "$key" ] || exit 1
{
    printf '%s\n' "$key"
    cat
} | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
