#!/usr/bin/env bash

watchdog() {
    if [ "$OS_TYPE" != "Linux" ]; then
        error "watchdog drives the live systemd service and is only supported on Linux."
    fi
    parse_config
    local fails_f="$WORKER_ROOT/watchdog.fails" hold_f="$WORKER_ROOT/watchdog.thermal-hold" t hr f
    t=$(_read_temp)
    if [ -f "$hold_f" ]; then
        local lift_reason=""
        if [ -z "$MAX_TEMP_C" ]; then
            lift_reason="max_temp_c is no longer set"
        elif [ -n "$t" ] && awk -v t="$t" -v m="$MAX_TEMP_C" 'BEGIN { exit !(t < m - 5) }'; then
            lift_reason="temp ${t}°C is below $((MAX_TEMP_C - 5))°C"
        fi
        if [ -n "$lift_reason" ]; then
            _shared_host_start_guard
            if ! _opp_handoff; then
                warn "watchdog: failed to start $SERVICE_NAME — thermal hold retained; will retry."
                return 0
            fi
            rm -f "$hold_f"
            log "watchdog: $lift_reason — thermal hold lifted, ${HANDOFF_NOTE:-miner started}."
        else
            log "watchdog: thermal hold active (temp ${t:-unreadable}°C, resumes below $((MAX_TEMP_C - 5))°C) — miner stays stopped."
        fi
        return 0
    fi
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        rm -f "$fails_f"
        log "watchdog: $SERVICE_NAME is not active — dead-process recovery is systemd's (Restart=). Nothing to do."
        return 0
    fi
    if [ -n "$MAX_TEMP_C" ] && [ -n "$t" ] && awk -v t="$t" -v m="$MAX_TEMP_C" 'BEGIN { exit !(t > m) }'; then
        if ! _opp_thermal_stop "$hold_f"; then
            warn "watchdog: failed to stop $SERVICE_NAME at ${t}°C — will retry while above max_temp_c=${MAX_TEMP_C}°C."
            return 0
        fi
        warn "watchdog: temp ${t}°C is above max_temp_c=${MAX_TEMP_C}°C — miner stopped (starts again below $((MAX_TEMP_C - 5))°C)."
        return 0
    fi
    hr=$(_read_api_hashrate)
    if [ -z "$hr" ] || awk -v h="$hr" 'BEGIN { exit !(h == 0) }'; then
        f=$(cat "$fails_f" 2>/dev/null || true)
        [[ "$f" =~ ^[0-9]+$ ]] || f=0
        f=$((f + 1))
        if [ "$f" -ge 2 ]; then
            rm -f "$fails_f"
            _shared_host_start_guard
            sudo systemctl restart "$SERVICE_NAME" 2>/dev/null || true
            warn "watchdog: miner wedged ($f consecutive checks with 0 H/s or an unreachable API) — restarted."
        else
            printf '%s\n' "$f" >"$fails_f"
            log "watchdog: unhealthy check ($f/2: 0 H/s or API unreachable) — restarting at 2 in a row."
        fi
        return 0
    fi
    rm -f "$fails_f"
    log "watchdog: healthy ($hr H/s)."
}
