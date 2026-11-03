#!/usr/bin/env bash
set -euo pipefail
key_file="${1:?usage: revision-key.sh <key-file> < canonical}"
[ ! -L "$key_file" ] || exit 1
if [ ! -s "$key_file" ]; then
    [ ! -e "$key_file" ] || rm -f "$key_file"
    tmp=$(umask 077 && mktemp "$key_file.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$tmp"
    if [ "$(id -u)" = 0 ] && [ -n "${RIGFORGE_KEY_OWNER:-}" ]; then chown "$RIGFORGE_KEY_OWNER" "$tmp"; fi
    ln "$tmp" "$key_file" 2>/dev/null || true
fi
key=$(cat "$key_file")
[ -n "$key" ] || exit 1
{
    printf '%s\n' "$key"
    cat
} | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
