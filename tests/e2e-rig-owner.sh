# shellcheck shell=bash
_rig_owner_mark() { # <config.json> [original-access-token]
    local tok
    tok=$(jq -r '.ACCESS_TOKEN // ""' "$1" 2>/dev/null) || tok=""
    printf '%s\n%s\n%s\n' "$$" "$tok" "${2:-}" | sudo -n tee "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}" >/dev/null 2>&1 || true
}
_rig_owner_clear() { rm -f "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}" 2>/dev/null || sudo -n rm -f "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}" 2>/dev/null || true; }
