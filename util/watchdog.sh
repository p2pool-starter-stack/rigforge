#!/usr/bin/env bash

watchdog() {
    if [ "$OS_TYPE" != "Linux" ]; then
        error "watchdog drives the live systemd service and is only supported on Linux."
    fi
    parse_config
    _shared_host_start_guard
    local fails_f="$WORKER_ROOT/watchdog.fails" hold_f="$WORKER_ROOT/watchdog.thermal-hold" t hr f
    t=$(_read_temp)
    if [ -f "$hold_f" ]; then
        if [ -z "$MAX_TEMP_C" ]; then
            if ! sudo systemctl start "$SERVICE_NAME" 2>/dev/null; then
                warn "watchdog: failed to start $SERVICE_NAME — thermal hold retained; will retry."
                return 0
            fi
            rm -f "$hold_f"
            log "watchdog: max_temp_c is no longer set — thermal hold lifted, miner started."
        elif [ -n "$t" ] && awk -v t="$t" -v m="$MAX_TEMP_C" 'BEGIN { exit !(t < m - 5) }'; then
            if ! sudo systemctl start "$SERVICE_NAME" 2>/dev/null; then
                warn "watchdog: failed to start $SERVICE_NAME — thermal hold retained; will retry."
                return 0
            fi
            rm -f "$hold_f"
            log "watchdog: temp ${t}°C is below $((MAX_TEMP_C - 5))°C — thermal hold lifted, miner started."
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
    # Thermal cutoff (opt-in). An unreadable temp skips this — a missing sensor must not stop a
    # healthy miner.
    if [ -n "$MAX_TEMP_C" ] && [ -n "$t" ] && awk -v t="$t" -v m="$MAX_TEMP_C" 'BEGIN { exit !(t > m) }'; then
        if ! sudo systemctl stop "$SERVICE_NAME" 2>/dev/null; then
            warn "watchdog: failed to stop $SERVICE_NAME at ${t}°C — will retry while above max_temp_c=${MAX_TEMP_C}°C."
            return 0
        fi
        touch "$hold_f"
        warn "watchdog: temp ${t}°C is above max_temp_c=${MAX_TEMP_C}°C — miner stopped (starts again below $((MAX_TEMP_C - 5))°C)."
        return 0
    fi
    # Wedge check: the API probe returns empty (unreachable) or the live hashrate (a float). An
    # unreachable API is a STRIKE, not a crash — _read_api_hashrate swallows curl's refused/timeout
    # exit itself (#364), so this unguarded assignment can't errexit the check (verified on a rig:
    # the old reader aborted here with exit 7, the current one returns empty). #210 needed a
    # `|| true` here for exactly that; the reader now owns the guarantee, so the guard is gone.
    hr=$(_read_api_hashrate)
    if [ -z "$hr" ] || awk -v h="$hr" 'BEGIN { exit !(h == 0) }'; then
        # Guard INSIDE the $( ): on bash 3.2 a caller-side `|| true` does NOT stop the ERR trap
        # firing in the child, because 3.2 doesn't carry suppressed errexit into it (#210/#364).
        f=$(cat "$fails_f" 2>/dev/null || true)
        [[ "$f" =~ ^[0-9]+$ ]] || f=0
        f=$((f + 1))
        if [ "$f" -ge 2 ]; then
            rm -f "$fails_f"
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
