#!/usr/bin/env bash
set -uo pipefail
[ "$#" -gt 0 ] || {
    echo "require-success: no children listed" >&2
    exit 1
}
rc=0
for pair in "$@"; do
    name="${pair%%=*}"
    result="${pair#*=}"
    echo "$name: ${result:-absent}"
    [ "$result" = success ] || rc=1
done
exit "$rc"
