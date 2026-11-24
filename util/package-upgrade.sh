#!/usr/bin/env bash

_pkg_state() { printf '%s' "${RIGFORGE_PKG_STATE:-/var/lib/rigforge}"; }

_pkg_upgrade_clear() { rm -f "$(_pkg_state)/upgrade-pending" "$(_pkg_state)/upgrade-failed" 2>/dev/null || true; }

package_upgrade() {
    local st rc
    st=$(_pkg_state)
    [ -f "$st/upgrade-pending" ] || {
        log "No package upgrade is pending."
        return 0
    }
    rm -f "$st/upgrade-failed"
    set +e
    (upgrade)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || return 0
    printf '%s upgrade exited %s; the previous build is still running\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >"$st/upgrade-failed"
    warn "Package upgrade failed; the previous build keeps running. Retry with: sudo rigforge upgrade"
    return 1
}

_pkg_upgrade_status() {
    local st
    st=$(_pkg_state)
    if [ -f "$st/upgrade-failed" ]; then
        warn "Package upgrade to $(cat "$st/upgrade-pending" 2>/dev/null) failed: $(cat "$st/upgrade-failed"). Retry with: sudo rigforge upgrade"
    elif [ -f "$st/upgrade-pending" ]; then
        log "Package upgrade to $(cat "$st/upgrade-pending") is queued or running (journalctl -u rigforge-upgrade)."
    fi
}

_pkg_upgrade_doctor() {
    local st
    st=$(_pkg_state)
    if [ -f "$st/upgrade-failed" ]; then
        _ck_warn "package upgrade to $(cat "$st/upgrade-pending" 2>/dev/null) failed ($(cat "$st/upgrade-failed")) — the previous build is still running; retry with: sudo rigforge upgrade" package-upgrade
        return 1
    elif [ -f "$st/upgrade-pending" ]; then
        _ck_info "package upgrade to $(cat "$st/upgrade-pending") is queued or running (journalctl -u rigforge-upgrade)" package-upgrade
    fi
}
