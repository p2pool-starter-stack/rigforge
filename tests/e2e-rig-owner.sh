# shellcheck shell=bash
_rig_owner_mark() { printf '%s\n' "$$" | sudo -n tee "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}" >/dev/null 2>&1 || true; }
_rig_owner_clear() { rm -f "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}" 2>/dev/null || sudo -n rm -f "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}" 2>/dev/null || true; }
