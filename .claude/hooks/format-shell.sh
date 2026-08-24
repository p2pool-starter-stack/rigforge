#!/usr/bin/env bash
# PostToolUse hook: shfmt any edited/written *.sh in place, same flags as `make fmt`.
set -uo pipefail

file="$(jq -r '.tool_input.file_path // empty')"
case "$file" in
*.sh)
    [ -f "$file" ] && shfmt -i 4 -w "$file"
    ;;
esac
exit 0
