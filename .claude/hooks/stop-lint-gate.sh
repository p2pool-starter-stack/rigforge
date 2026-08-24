#!/usr/bin/env bash
# Stop hook: block the turn from ending until the fast lint gate (make lint) passes.
# Scope is deliberate: `bash tests/run.sh` takes ~2.5 min on this machine, so the suite,
# Docker e2e, coverage (kcov), and the real-hardware gates stay manual — see CLAUDE.md.
set -uo pipefail

input="$(cat)"
# Safety valve against infinite block loops: if this stop is already a continuation
# forced by a stop hook, let it through rather than trapping the session.
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ]; then
    exit 0
fi

cd "${CLAUDE_PROJECT_DIR:?}" || exit 0

if ! out="$(make lint 2>&1)"; then
    {
        echo "STOP BLOCKED: make lint failed. Fix these before finishing:"
        echo "$out"
    } >&2
    exit 2
fi
exit 0
