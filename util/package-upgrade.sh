#!/usr/bin/env bash

_pkg_state() { printf '%s' "${RIGFORGE_PKG_STATE:-/var/lib/rigforge}"; }

_pkg_upgrade_clear() { rm -f "$(_pkg_state)/upgrade-pending" "$(_pkg_state)/upgrade-failed" 2>/dev/null || true; }

_pkg_operator() {
    local u
    u=$(stat -c '%U' "$CONFIG_JSON" 2>/dev/null || stat -f '%Su' "$CONFIG_JSON" 2>/dev/null || true)
    [ -n "$u" ] && [ "$u" != root ] && id -u "$u" >/dev/null 2>&1 && printf '%s' "$u"
}

_pkg_restart_gate() {
    [ "${RIGFORGE_PKG_UPGRADE:-}" = 1 ] || return 0
    [ "$1:$2" != 0:0 ] || return 0
    [ "$2" -eq 0 ] || _control_failed upgrade
    [ "$1" -eq 0 ] || _sister_api_failed upgrade || true
    return 1
}

_pkg_upgrade_failed() {
    local st tmp
    st=$(_pkg_state)
    [ "$1" -ne 0 ] || return 0
    tmp=$(mktemp "$st/.upgrade-failed.XXXXXX") || return 0
    chmod 0644 "$tmp"
    printf '%s upgrade exited %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >"$tmp"
    mv -f "$tmp" "$st/upgrade-failed"
    warn "Package upgrade did not finish. Retry with: sudo rigforge upgrade"
}

package_upgrade() {
    local st
    st=$(_pkg_state)
    [ -f "$st/upgrade-pending" ] || {
        log "No package upgrade is pending."
        return 0
    }
    rm -f "$st/upgrade-failed"
    (
        RIGFORGE_PKG_UPGRADE=1
        if [ -z "${SUDO_USER:-}${RIGFORGE_OPERATOR:-}" ]; then REAL_USER=$(_pkg_operator || printf '%s' "$REAL_USER"); fi
        trap '_pkg_upgrade_failed "$?"' EXIT
        upgrade
        trap - EXIT
    )
}

_pkg_upgrade_status() {
    local st
    st=$(_pkg_state)
    if [ -f "$st/upgrade-failed" ]; then
        warn "Package upgrade to $(cat "$st/upgrade-pending" 2>/dev/null) did not finish: $(cat "$st/upgrade-failed"). Retry with: sudo rigforge upgrade"
    elif [ -f "$st/upgrade-pending" ]; then
        log "Package upgrade to $(cat "$st/upgrade-pending") is pending; follow it with: journalctl -u rigforge-upgrade. If it is not running, retry with: sudo rigforge upgrade"
    fi
}

_pkg_upgrade_doctor() {
    local st
    st=$(_pkg_state)
    if [ -f "$st/upgrade-failed" ]; then
        _ck_warn "package upgrade to $(cat "$st/upgrade-pending" 2>/dev/null) did not finish ($(cat "$st/upgrade-failed")); retry with: sudo rigforge upgrade" package-upgrade
        return 1
    elif [ -f "$st/upgrade-pending" ]; then
        _ck_info "package upgrade to $(cat "$st/upgrade-pending") is pending; follow it with: journalctl -u rigforge-upgrade" package-upgrade
    fi
}
