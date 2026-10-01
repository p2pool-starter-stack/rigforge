# shellcheck shell=bash
# Reserved control-phase lifecycle; overrides only ExecStart, retaining the real service policy.
REFRESH_PROFILE_STAGING="" REFRESH_PROFILE_DROPIN="" REFRESH_PROFILE_SINCE="" REFRESH_PROFILE_TIMER_ACTIVE=""
refresh_profile_start() {
    local dir="${REFRESH_PROFILE_UNIT_ROOT:-/run/systemd/system}/rigforge-api-refresh.service.d"
    local script
    script="$(dirname "$RIGFORGE")/tests/e2e-api-refresh-profile.sh"
    # Refuse collisions and paths requiring systemd quoting rather than generating executable text.
    case "$script$RIGFORGE" in *[!a-zA-Z0-9_./-]*) return 1 ;; esac
    [ ! -L "$dir" ] && [ ! -e "$dir/rigforge-profile.conf" ] && [ ! -L "$dir/rigforge-profile.conf" ] || return 1
    mkdir -p "$dir" || return 1
    REFRESH_PROFILE_TIMER_ACTIVE=0
    systemctl is-active --quiet rigforge-api-refresh.timer && REFRESH_PROFILE_TIMER_ACTIVE=1
    REFRESH_PROFILE_SINCE=$(date -u '+%Y-%m-%d %H:%M:%S')
    local dropin="$dir/rigforge-profile.conf"
    # Stage privately: failed writes must never expose an incomplete service policy.
    REFRESH_PROFILE_STAGING=$(mktemp "$dir/.rigforge-profile.XXXXXX") || return 1
    printf '[Service]\nExecStart=\nExecStart=/bin/bash %s %s\n' "$script" "$RIGFORGE" >|"$REFRESH_PROFILE_STAGING" || return 1
    # POSIX link uses the exact destination (unlike ln's directory handling) and never replaces it.
    link "$REFRESH_PROFILE_STAGING" "$dropin" || return 1
    REFRESH_PROFILE_DROPIN="$dropin"
    rm -f "$REFRESH_PROFILE_STAGING" || return 1
    REFRESH_PROFILE_STAGING=""
    systemctl daemon-reload
}
refresh_profile_state() {
    printf 'refresh-window: state at_ns=%s\n' "$(date +%s%N)"
    local active=0
    systemctl is-active --quiet xmrig && active=1
    printf 'refresh-window: xmrig_active=%s\n' "$active"
    [ "$active" = 1 ] || [ "${1:-}" = allow-inactive ] || return 1
    systemctl show rigforge-api-refresh.timer rigforge-api-refresh.service \
        -p ActiveState -p SubState -p Result -p LastTriggerUSec -p NextElapseUSecRealtime \
        -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus
}
refresh_profile_finish() {
    local log records rc=0
    if [ -n "$REFRESH_PROFILE_STAGING" ]; then
        if rm -f "$REFRESH_PROFILE_STAGING"; then REFRESH_PROFILE_STAGING=""; else rc=1; fi
    fi
    [ -n "$REFRESH_PROFILE_DROPIN" ] || return "$rc"
    refresh_profile_state || rc=1
    # Quiesce both units before collecting: the timer could otherwise dispatch during cleanup.
    systemctl stop rigforge-api-refresh.timer || rc=1
    systemctl stop rigforge-api-refresh.service || rc=1
    log=$(mktemp) || rc=1
    if [ -n "$log" ]; then
        journalctl --sync || rc=1
        journalctl -u rigforge-api-refresh.service --since "$REFRESH_PROFILE_SINCE UTC" --no-pager -o cat >"$log" || rc=1
        # Publish only the fixed-schema measurements; other unit journal messages may contain secrets.
        records=$(sed -nE '/^refresh-profile: pid=[0-9][0-9]* helper=[a-z_][a-z_]* event=(begin|end) at_ns=[0-9][0-9]* duration_ns=[0-9][0-9]* rc=[0-9][0-9]*$/p; /^refresh-profile-cpu: pid=[0-9][0-9]* event=(begin|end) cpu_ticks=[0-9][0-9]* clock_ticks_per_s=[1-9][0-9]* nice=-?[0-9][0-9]* scheduler_wait_ns=[0-9][0-9]*$/p' "$log") || rc=1
        printf '%s\n' "$records"
        # A completed pass needs its own CPU begin/end, not counters from another process.
        printf '%s\n' "$records" | awk '
            $1 == "refresh-profile-cpu:" && $3 == "event=begin" { begun[$2] = 1 }
            $1 == "refresh-profile-cpu:" && $3 == "event=end" && begun[$2] { cpu[$2] = 1 }
            $1 == "refresh-profile:" && $3 == "helper=api_refresh" && $4 == "event=end" && $7 == "rc=0" && cpu[$2] { completed = 1 }
            END { exit !completed }
        ' || rc=1
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
