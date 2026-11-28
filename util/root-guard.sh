#!/usr/bin/env bash
# shellcheck shell=bash

ROOT_GUARD_STAMP=/etc/rigforge-root-guard

_rg_unsafe() {
    local s uid gid mode
    s=$(stat -L -c '%u:%g:%a' "$1" 2>/dev/null) || {
        printf '%s cannot be inspected' "$1"
        return 0
    }
    IFS=: read -r uid gid mode <<<"$s"
    if [ "$uid" != 0 ]; then
        printf '%s is owned by uid %s' "$1" "$uid"
        return 0
    fi
    case "${mode: -2:1}" in 2 | 3 | 6 | 7)
        if [ "$gid" != 0 ]; then
            printf '%s is writable by group %s' "$1" "$gid"
            return 0
        fi
        ;;
    esac
    case "${mode: -1}" in 2 | 3 | 6 | 7)
        printf '%s is writable by every user' "$1"
        return 0
        ;;
    esac
    return 1
}

_rg_chain_unsafe() {
    local p="$1"
    while :; do
        _rg_unsafe "$p" && return 0
        [ "$p" != / ] || return 1
        p=$(dirname "$p")
    done
}

_rg_tree_unsafe() {
    local d f
    for d in "$1" "$(dirname "${BASH_SOURCE[0]}")/.."; do
        case "$d" in /*) ;; *)
            printf '%s is not an absolute path' "$d"
            return 0
            ;;
        esac
        _rg_chain_unsafe "$d" && return 0
        d=$(cd -P "$d" 2>/dev/null && pwd -P) || {
            printf '%s cannot be resolved' "$d"
            return 0
        }
        _rg_chain_unsafe "$d" && return 0
        for f in "$d/rigforge.sh" "$d/util" "$d"/util/* "$d/systemd" "$d"/systemd/*; do
            _rg_unsafe "$f" && return 0
        done
        [ -d "$d/.git" ] || continue
        for f in "$d/.git" "$d/.git/config" "$d/.git/hooks" "$d"/.git/hooks/*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            _rg_unsafe "$f" && return 0
        done
    done
    return 1
}

_rg_keeps_root() {
    local d
    [ "$OS_TYPE" = Linux ] && ! _rg_tree_unsafe "$SCRIPT_DIR" >/dev/null || return 1
    for d in "$@"; do
        ! _rg_chain_unsafe "$d" >/dev/null || return 1
    done
}

_rg_worker_kept() {
    local real
    [ -d "${WORKER_ROOT:-}" ] && real=$(cd -P "$WORKER_ROOT" && pwd -P) && _rg_keeps_root "$(dirname "$WORKER_ROOT")" "$(dirname "$real")" && printf '%s' "$real"
}

_rg_claim_worker() {
    local real gone
    real=$(_rg_worker_kept) || return 1
    if [ -n "$(find "$real/xmrig/build/xmrig" -maxdepth 0 ! -user 0 2>/dev/null)" ]; then
        # shellcheck disable=SC2034
        XMRIG_REBUILD=true
        sudo rm -f "$real/xmrig/.rigforge-commit"
        warn "root-guard: the miner in $WORKER_ROOT was not root-owned, so the next setup or upgrade rebuilds it."
    fi
    if sudo chown -R 0:0 "$real" && sudo chmod -R go-w "$real" && gone=$(sudo find "$real" -type l -print -delete); then
        [ -z "$gone" ] || warn "root-guard: removed symbolic links inside $WORKER_ROOT: ${gone//$'\n'/ }"
        return 0
    fi
    warn "root-guard: could not keep $WORKER_ROOT root-owned."
    return 1
}

_rg_config_snapshot() {
    local d="${1%/*}" r t=""
    mkdir -p "$d" && r=$(cd -P "$d" && pwd -P) && { [ "$(id -u)" -ne 0 ] || ! _rg_keeps_root "$(dirname "$d")" "$(dirname "$r")" || { sudo chown 0:0 "$r" && sudo chmod 755 "$r"; }; } &&
        t=$(mktemp "$r/.config-snapshot.XXXXXX") && cat "$CONFIG_JSON" >"$t" && { mv -fT "$t" "$r/${1##*/}" 2>/dev/null || mv -fh "$t" "$r/${1##*/}"; } && return 0
    rm -f "$t"
    return 1
}

_rg_allowed() {
    [ -f "$ROOT_GUARD_STAMP" ] && [ "$(cat "$ROOT_GUARD_STAMP" 2>/dev/null)" = "allow $1" ] &&
        ! _rg_chain_unsafe "$ROOT_GUARD_STAMP" >/dev/null
}

_rg_record() {
    [ "$(cat "$ROOT_GUARD_STAMP" 2>/dev/null)" != "allow $1" ] || return 0
    if printf 'allow %s\n' "$1" | sudo tee "$ROOT_GUARD_STAMP" >/dev/null && sudo chmod 644 "$ROOT_GUARD_STAMP"; then
        warn "root-guard: recorded the allowance for $1 in $ROOT_GUARD_STAMP; remote upgrades will accept this tree."
    else
        warn "root-guard: could not record the allowance in $ROOT_GUARD_STAMP; remote upgrades will refuse this tree until 'sudo $0 upgrade --no-root-guard' succeeds."
        return 1
    fi
}

_root_guard_check() {
    [ "$OS_TYPE" = Linux ] || return 0
    local reason dir fix
    reason=$(_rg_tree_unsafe "$SCRIPT_DIR") || return 0
    dir=$(cd -P "$SCRIPT_DIR" 2>/dev/null && pwd -P) || dir="$SCRIPT_DIR"
    fix="make the tree root-owned (sudo chown -R root:root $dir && sudo chmod -R go-w $dir)"
    if [ "${1:-}" = 1 ]; then
        warn "root-guard: $reason, so a non-root user can change code that root runs; continuing because --no-root-guard was given. To close this, $fix."
        _rg_record "$dir" || true
        return 0
    elif _rg_allowed "$dir"; then
        warn "root-guard: $reason; continuing under the allowance recorded in $ROOT_GUARD_STAMP. To close this, $fix and delete that file."
        return 0
    elif [ -d "$dir/.git" ] && [ -f "$SYSTEMD_DIR/$SERVICE_NAME.service" ] && [ ! -e "$ROOT_GUARD_STAMP" ] && ! _package_install; then
        warn "root-guard: WARNING: $reason, so a non-root user can change code that root runs. This install predates the root guard, so it is allowed once and the allowance is recorded. To close this, $fix and delete $ROOT_GUARD_STAMP."
    else
        warn "root-guard: refusing to install root-run units: $reason, so a non-root user could change code that root runs. Either $fix, or pass --no-root-guard to accept this tree."
        return 1
    fi
    _rg_record "$dir"
}
