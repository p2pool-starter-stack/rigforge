#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: ci-categorize.sh <job id>" >&2
    exit 2
fi
: "${GITHUB_STEP_SUMMARY:=/dev/null}"

if ! rows="$(env | grep '^CAT_' | sort)"; then
    echo "::error::categorize step has no CAT_* step-outcome variables wired in" >&2
    exit 1
fi

{
    printf '## Outcome categories — %s\n\n' "$1"
    printf '```\n'
    printf '%s\n' "$rows" | while IFS='=' read -r key value; do
        printf '%s = %s\n' "$(printf '%s' "${key#CAT_}" | tr '[:upper:]_' '[:lower:]-')" "$value"
    done
    printf '```\n'
} | tee -a "$GITHUB_STEP_SUMMARY"
