# shellcheck shell=bash
_rig_lent_to_bench() (
    local lock="${RIGFORGE_RIG_LOCK:-/var/lock/rig-e2e.lock}"
    local marker="${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}" owner
    [ -f "$lock" ] || return 1
    if [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ]; then
        owner=$(tr -d '[:space:]' <"$marker" 2>/dev/null)
        case "$owner" in '' | *[!0-9]*) ;; *) ! kill -0 "$owner" 2>/dev/null || return 1 ;; esac
    fi
    exec 7<"$lock" 2>/dev/null || return 0
    ! flock -n -x 7 2>/dev/null
)

_control_upgrade_throttle_ok() (
    local dir="$1" lock="$1/.upgrade-throttle.lock" stamp="$1/upgrade-last" now tmp min="${CONTROL_UPGRADE_MIN_INTERVAL:-21600}" last=0
    [ ! -L "$dir" ] && [ -d "$dir" ] && [ "$(stat -c '%u:%g:%a' "$dir" 2>/dev/null)" = "0:0:700" ] || return 2
    if [ -e "$lock" ] || [ -L "$lock" ]; then
        [ ! -L "$lock" ] && [ -f "$lock" ] && [ "$(stat -c '%u:%g:%a:%h' "$lock" 2>/dev/null)" = "0:0:600:1" ] || return 2
    fi
    umask 077
    exec 9>>"$lock" 2>/dev/null || return 2
    flock -x 9 2>/dev/null || return 2
    if [ -e "$stamp" ] || [ -L "$stamp" ]; then
        [ ! -L "$stamp" ] && [ -f "$stamp" ] && [ "$(stat -c '%u:%g:%a:%h' "$stamp" 2>/dev/null)" = "0:0:600:1" ] || return 2
        last=$(cat "$stamp" 2>/dev/null) || return 2
    fi
    case "$last" in '' | *[!0-9]*) return 2 ;; esac
    now=$(date +%s) || return 2
    if [ $((now - last)) -lt "$min" ] 2>/dev/null; then
        return 1
    fi
    tmp=$(mktemp "$dir/.upgrade-last.XXXXXX") || return 2
    if ! printf '%s\n' "$now" >"$tmp" || ! mv -f "$tmp" "$stamp"; then
        rm -f "$tmp"
        return 2
    fi
    return 0
)
