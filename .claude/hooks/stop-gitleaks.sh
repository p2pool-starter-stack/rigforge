#!/usr/bin/env bash
# Stop hook: block the turn from ending if gitleaks finds a secret in the working tree.
# This repo has no .gitleaks.toml — the built-in ruleset is the contract, same as CI
# (security.yml, pinned 8.30.1) and the pre-commit hook.
set -uo pipefail

input="$(cat)"
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ]; then
    exit 0
fi

cd "${CLAUDE_PROJECT_DIR:?}" || exit 0

if ! out="$(gitleaks dir . --no-banner --redact --verbose --exit-code 1 2>&1)"; then
    {
        echo "STOP BLOCKED: gitleaks found potential secrets in the working tree:"
        echo "$out"
        echo "Remove the secret (synthetic values only) before finishing."
    } >&2
    exit 2
fi
exit 0
