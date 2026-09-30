# shellcheck shell=bash
# Reserved control-phase lifecycle; overrides only ExecStart, retaining the real service policy.
REFRESH_PROFILE_DROPIN="" REFRESH_PROFILE_SINCE="" REFRESH_PROFILE_TIMER_ACTIVE=""
refresh_profile_start() {
    local dir="${REFRESH_PROFILE_UNIT_ROOT:-/run/systemd/system}/rigforge-api-refresh.service.d"
    local script
    script="$(dirname "$RIGFORGE")/tests/e2e-api-refresh-profile.sh"
    # Refuse collisions and paths requiring systemd quoting rather than generating executable text.
    case "$script$RIGFORGE" in *[!a-zA-Z0-9_./-]*) return 1 ;; esac
    [ ! -L "$dir" ] && [ ! -e "$dir/rigforge-profile.conf" ] && [ ! -L "$dir/rigforge-profile.conf" ] || return 1
    mkdir -p "$dir" || return 1
    REFRESH_PROFILE_SINCE=$(date -u '+%Y-%m-%d %H:%M:%S')
    local dropin="$dir/rigforge-profile.conf"
    (
        umask 077
        set -o noclobber
        printf '[Service]\nExecStart=\nExecStart=/bin/bash %s %s\n' "$script" "$RIGFORGE" >"$dropin"
    ) || return 1
    REFRESH_PROFILE_DROPIN="$dropin"
    systemctl daemon-reload
}
refresh_profile_state() {
    printf 'refresh-window: state at_ns=%s\n' "$(date +%s%N)"
    systemctl is-active --quiet xmrig || return 1
    systemctl show rigforge-api-refresh.timer rigforge-api-refresh.service \
        -p ActiveState -p SubState -p Result -p LastTriggerUSec -p NextElapseUSecRealtime \
        -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus
}
refresh_profile_finish() {
    [ -n "$REFRESH_PROFILE_DROPIN" ] || return 0
    local log rc=0
    refresh_profile_state || rc=1
    # Quiesce both units before collecting: the timer could otherwise dispatch during cleanup.
    if [ -z "$REFRESH_PROFILE_TIMER_ACTIVE" ]; then
        REFRESH_PROFILE_TIMER_ACTIVE=0
        systemctl is-active --quiet rigforge-api-refresh.timer && REFRESH_PROFILE_TIMER_ACTIVE=1
    fi
    systemctl stop rigforge-api-refresh.timer || rc=1
    systemctl stop rigforge-api-refresh.service || rc=1
    log=$(mktemp) || rc=1
    if [ -n "$log" ]; then
        journalctl --sync || rc=1
        journalctl -u rigforge-api-refresh.service --since "$REFRESH_PROFILE_SINCE UTC" --no-pager -o cat >"$log" || rc=1
        # Publish only the fixed-schema measurements; other unit journal messages may contain secrets.
        sed -n '/^refresh-profile: pid=[0-9][0-9]* helper=[a-z_][a-z_]* event=\(begin\|end\) at_ns=[0-9][0-9]* duration_ns=[0-9][0-9]* rc=[0-9][0-9]*$/p' "$log"
        grep -Eq '^refresh-profile: .*helper=api_refresh event=end .*rc=0$' "$log" || rc=1
        rm -f "$log"
    fi
    if rm -f "$REFRESH_PROFILE_DROPIN" && systemctl daemon-reload; then
        if [ "$REFRESH_PROFILE_TIMER_ACTIVE" = 0 ] || systemctl start rigforge-api-refresh.timer; then
            REFRESH_PROFILE_DROPIN=""
            REFRESH_PROFILE_TIMER_ACTIVE=""
        else
            rc=1
        fi
    else
        rc=1
    fi
    return "$rc"
}
