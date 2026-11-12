# shellcheck shell=bash
_rig_lent_to_bench() (
    local lock="${RIGFORGE_RIG_LOCK:-/var/lock/rig-e2e.lock}"
    local marker="${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}"
    local source="${1:-}"
    [ -f "$lock" ] || return 1
    if [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] && _rig_owner_marker_admits "$marker" "$source"; then
        return 1
    fi
    exec 7<"$lock" 2>/dev/null || return 0
    ! flock -n -x 7 2>/dev/null
)

_rig_owner_marker_admits() (
    local marker="$1" source="$2" cfg="${CONFIG_JSON:-}" lines owner token orig allow host
    [ -n "$source" ] && [ -n "$cfg" ] && [ -f "$cfg" ] && [ ! -L "$cfg" ] || return 1
    mapfile -t lines <"$marker" 2>/dev/null || return 1
    [ "${#lines[@]}" -eq 3 ] || return 1
    owner="${lines[0]}"
    token="${lines[1]}"
    orig="${lines[2]}"
    case "$owner" in '' | *[!0-9]*) return 1 ;; esac
    kill -0 "$owner" 2>/dev/null || return 1
    [ -n "$token" ] && [ "$token" != "$orig" ] || return 1
    [ "$(jq -r '.ACCESS_TOKEN // ""' "$cfg" 2>/dev/null)" = "$token" ] || return 1
    allow=$(jq -r '.api_allow_from // ""' "$cfg" 2>/dev/null) || return 1
    case "$allow" in
    */32)
        host="${allow%/32}"
        [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
        ;;
    */128)
        host="${allow%/128}"
        [ -n "$host" ] && [ "${host#*:}" != "$host" ] || return 1
        ;;
    '')
        return 1
        ;;
    *)
        host="$allow"
        if [ "${host#*:}" != "$host" ]; then
            [ "${host#*/}" = "$host" ] || return 1
        elif ! [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            return 1
        fi
        ;;
    esac
    [ "$source" = "$host" ] || [ "${source#::ffff:}" = "$host" ]
)

_control_consume_source() (
    local f="$1/.peer-$2" v
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    [ -z "$(tail -n +2 -- "$f" 2>/dev/null)" ] || return 0
    v=$(head -n 1 "$f" 2>/dev/null)
    rm -f "$f"
    printf '%s' "$v"
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
