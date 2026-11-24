#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034

_root_guard_check() {
    [ "${RIGFORGE_ROOT_GUARD_ALLOW:-}" = 1 ] && return 0
    [ "${ROOT_GUARD_ALLOW:-}" = true ] && return 0
    [ "$OS_TYPE" = Linux ] || return 0
    [ -n "${SCRIPT_DIR:-}" ] || return 0
    [ -d "$SCRIPT_DIR" ] || return 0

    local dir="$SCRIPT_DIR" owner gid
    while true; do
        owner=$(stat -c '%u' "$dir" 2>/dev/null) || {
            warn "root-guard: stat failed on $dir — refusing"
            return 1
        }
        [ "$owner" = "0" ] || {
            owner=$(stat -c '%U' "$dir" 2>/dev/null || owner="(unknown)")
            gid=$(stat -c '%g' "$dir" 2>/dev/null || gid="(unknown)")
            local perms
            perms=$(stat -c '%A' "$dir" 2>/dev/null || perms="???")
            warn "root-guard: $dir (uid=$owner gid=$gid perms=$perms) is not root-owned — refusing"
            return 1
        }
        local mode
        mode=$(stat -c '%a' "$dir" 2>/dev/null) || {
            warn "root-guard: stat failed on $dir — refusing"
            return 1
        }
        local g_digit="${mode: -2:1}"
        case "$g_digit" in 2 | 3 | 6 | 7)
            warn "root-guard: $dir is group-writable (mode=$mode) — refusing"
            return 1
            ;;
        esac
        local o_digit="${mode: -1}"
        case "$o_digit" in 2 | 3 | 6 | 7)
            warn "root-guard: $dir is other-writable (mode=$mode) — refusing"
            return 1
            ;;
        esac
        local parent
        parent=$(dirname "$dir")
        [ "$parent" = "$dir" ] && break
        dir="$parent"
    done

    local f path owner mode g_digit o_digit
    f=rigforge.sh
    path="$SCRIPT_DIR/$f"
    [ -e "$path" ] || {
        warn "root-guard: $path not found — refusing"
        return 1
    }
    owner=$(stat -c '%u' "$path" 2>/dev/null) || {
        warn "root-guard: stat failed on $path — refusing"
        return 1
    }
    if [ "$owner" != "0" ]; then
        owner=$(stat -c '%U' "$path" 2>/dev/null || owner="(unknown)")
        warn "root-guard: $path is owned by $owner, not root — refusing"
        return 1
    fi
    mode=$(stat -c '%a' "$path" 2>/dev/null) || {
        warn "root-guard: stat failed on $path — refusing"
        return 1
    }
    g_digit="${mode: -2:1}"
    case "$g_digit" in 2 | 3 | 6 | 7)
        warn "root-guard: $path is group-writable (mode=$mode) — refusing"
        return 1
        ;;
    esac
    o_digit="${mode: -1}"
    case "$o_digit" in 2 | 3 | 6 | 7)
        warn "root-guard: $path is other-writable (mode=$mode) — refusing"
        return 1
        ;;
    esac

    if [ -d "$SCRIPT_DIR/util" ]; then
        for f in "$SCRIPT_DIR"/util/*.py; do
            [ -e "$f" ] || continue
            path="$f"
            owner=$(stat -c '%u' "$path" 2>/dev/null) || {
                warn "root-guard: stat failed on $path — refusing"
                return 1
            }
            if [ "$owner" != "0" ]; then
                owner=$(stat -c '%U' "$path" 2>/dev/null || owner="(unknown)")
                warn "root-guard: $path is owned by $owner, not root — refusing"
                return 1
            fi
            mode=$(stat -c '%a' "$path" 2>/dev/null) || {
                warn "root-guard: stat failed on $path — refusing"
                return 1
            }
            g_digit="${mode: -2:1}"
            case "$g_digit" in 2 | 3 | 6 | 7)
                warn "root-guard: $path is group-writable (mode=$mode) — refusing"
                return 1
                ;;
            esac
            o_digit="${mode: -1}"
            case "$o_digit" in 2 | 3 | 6 | 7)
                warn "root-guard: $path is other-writable (mode=$mode) — refusing"
                return 1
                ;;
            esac
        done
    fi

    local cred_files
    cred_files=(config.json util/api-server.py util/control-server.py)
    for f in "${cred_files[@]}"; do
        path="$SCRIPT_DIR/$f"
        [ -e "$path" ] || continue
        owner=$(stat -c '%u' "$path" 2>/dev/null) || {
            warn "root-guard: stat failed on $path — refusing"
            return 1
        }
        if [ "$owner" != "0" ]; then
            owner=$(stat -c '%U' "$path" 2>/dev/null || owner="(unknown)")
            warn "root-guard: $path is owned by $owner, not root — refusing"
            return 1
        fi
        mode=$(stat -c '%a' "$path" 2>/dev/null) || {
            warn "root-guard: stat failed on $path — refusing"
            return 1
        }
        g_digit="${mode: -2:1}"
        case "$g_digit" in 2 | 3 | 6 | 7)
            warn "root-guard: $path is group-writable (mode=$mode) — refusing"
            return 1
            ;;
        esac
        o_digit="${mode: -1}"
        case "$o_digit" in 2 | 3 | 6 | 7)
            warn "root-guard: $path is other-writable (mode=$mode) — refusing"
            return 1
            ;;
        esac
    done

    return 0
}

_persist_root_guard_allow() {
    [ "${RIGFORGE_ROOT_GUARD_ALLOW:-}" = 1 ] || [ "${ROOT_GUARD_ALLOW:-}" = true ] || return 0
    [ "$OS_TYPE" = Linux ] || return 0

    if [ -d "$SCRIPT_DIR/.git" ]; then
        local has_package_marker=false
        [ -d "/homebrew/Cellar/rigforge" ] && has_package_marker=true
        [ -d "/opt/rigforge" ] && has_package_marker=true
        if [ "$has_package_marker" = true ]; then
            warn "root-guard: $SCRIPT_DIR/.git found alongside package marker — refusing auto-allowance; pass --no-root-guard explicitly"
            return 0
        fi
    fi

    local usvc="$SYSTEMD_DIR/rigforge-control-upgrade.service"
    if [ -f "$usvc" ]; then
        if ! grep -q 'Environment=ROOT_GUARD_ALLOW=true' "$usvc" 2>/dev/null; then
            sudo sed -i '/^\[Service\]/a Environment=ROOT_GUARD_ALLOW=true' "$usvc" 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true
            if [ -d "$SCRIPT_DIR/.git" ]; then
                warn "root-guard: persisted allowance into $usvc — the tree $SCRIPT_DIR is now trusted for root-run units; pass --no-root-guard on future upgrades to silence this warning"
            fi
        fi
    fi
}
