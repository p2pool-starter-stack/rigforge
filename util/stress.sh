#!/usr/bin/env bash

_stress_now() { date +%s; }
_stress_sleep() { sleep "$1"; }

_stress_hashing() {
    local input="$1"
    [ -s "$input" ] || input="$2"
    awk '/speed.*H\/s/ { ok = 0; seen = 0; for (i = 1; i <= NF; i++) { if ($i == "speed") seen = 1; else if (seen && ($i == "n/a" || $i ~ /^[0-9]+([.][0-9]+)?$/)) { if ($i != "n/a" && $i + 0 > 0) ok = 1; break } } } END { exit !ok }' "$input" 2>/dev/null
}

_stress_fatal() { grep -qiE 'MEMORY ALLOC FAILED|unable to (open|parse) config|error parsing config' "$@" 2>/dev/null; }

_stress_unit_busy() {
    local state
    state=$(systemctl is-active "$1" 2>/dev/null || true)
    case "$state" in
    active | activating | reloading | refreshing | deactivating) return 0 ;;
    *) return 1 ;;
    esac
}

_stress_cleanup() {
    local rc="${1:-0}"
    if [ "${_STRESS_CLEANED:-0}" = 1 ]; then return "$rc"; fi
    _STRESS_CLEANED=1
    if [ -n "${_STRESS_PID:-}" ]; then
        _selftest_stop "$_STRESS_PID"
        _STRESS_PID=""
    fi
    [ -z "${_STRESS_TMP:-}" ] || rm -rf -- "$_STRESS_TMP"
    if [ "${_STRESS_MINER_WAS_ACTIVE:-0}" = 1 ] && [ "${_STRESS_THERMAL_TRIP:-0}" != 1 ]; then
        if ! sudo systemctl start "$SERVICE_NAME" >/dev/null 2>&1; then
            warn "stress: could not restore $SERVICE_NAME; start it manually."
            rc=1
        fi
    fi
    if [ "${_STRESS_AUTOTUNE_TIMER_ACTIVE:-0}" = 1 ]; then
        if ! sudo systemctl start rigforge-autotune.timer >/dev/null 2>&1; then
            warn "stress: could not restore rigforge-autotune.timer; start it manually."
            rc=1
        fi
    fi
    if [ "${_STRESS_WATCHDOG_TIMER_ACTIVE:-0}" = 1 ]; then
        if ! sudo systemctl start rigforge-watchdog.timer >/dev/null 2>&1; then
            warn "stress: could not restore rigforge-watchdog.timer; start it manually."
            rc=1
        fi
    fi
    return "$rc"
}

_stress_signal() {
    case "$1" in
    HUP) exit 129 ;;
    INT) exit 130 ;;
    TERM) exit 143 ;;
    esac
}

stress() {
    [ "$OS_TYPE" = Linux ] || error "stress runs XMRig against Linux hardware and is only supported on Linux."
    if _tune_should_elevate; then
        log "stress needs root — re-running with sudo..."
        exec sudo "$0" stress "$@"
    fi

    local minutes=30 seconds deadline now temp peak="" peak_label rc=0 reason=""
    local bin cfg safe_cfg out logf last
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --minutes)
            [ "$#" -ge 2 ] || error "--minutes needs a whole number from 1 to 1440."
            minutes=$2
            shift
            ;;
        *) error "Unknown option for stress: '$1' (use --minutes N). Run '$0 help'." ;;
        esac
        shift
    done
    _uint_in_range "$minutes" 1 1440 || error "stress --minutes must be a whole number from 1 to 1440 (got: $minutes)."
    minutes=$((10#$minutes))

    parse_config
    bin="$WORKER_ROOT/xmrig/build/xmrig"
    cfg="$WORKER_ROOT/xmrig/build/config.json"
    [ -x "$bin" ] || error "No built worker at $bin. Run 'setup' first."
    [ -f "$cfg" ] || error "No generated worker config at $cfg. Run 'setup' first."

    _STRESS_CLEANED=0
    _STRESS_PID=""
    _STRESS_MINER_WAS_ACTIVE=0
    _STRESS_AUTOTUNE_TIMER_ACTIVE=0
    _STRESS_WATCHDOG_TIMER_ACTIVE=0
    _STRESS_THERMAL_TRIP=0
    _STRESS_HOLD_FILE="$WORKER_ROOT/watchdog.thermal-hold"
    _STRESS_TMP=$(mktemp -d)
    trap '_stress_cleanup $?' EXIT
    trap '_stress_signal HUP' HUP
    trap '_stress_signal INT' INT
    trap '_stress_signal TERM' TERM

    safe_cfg="$_STRESS_TMP/config.json"
    out="$_STRESS_TMP/stdout"
    logf="$_STRESS_TMP/xmrig.log"
    jq 'del(.http, .pools, ."log-file", .benchmark, .bench, ."bench-algo", ."bench-size", .seed, .hash, .submit, .verify, .stress) | .background = false | ."print-time" = 10 | .autosave = false | .watch = false | ."pause-on-active" = false | ."pause-on-battery" = false' "$cfg" >"$safe_cfg" || error "Could not prepare the offline stress config."

    if systemctl is-active --quiet rigforge-autotune.timer 2>/dev/null; then
        _STRESS_AUTOTUNE_TIMER_ACTIVE=1
        sudo systemctl stop rigforge-autotune.timer >/dev/null 2>&1 || error "Could not pause the autotune timer."
    fi
    if systemctl is-active --quiet rigforge-watchdog.timer 2>/dev/null; then
        _STRESS_WATCHDOG_TIMER_ACTIVE=1
        sudo systemctl stop rigforge-watchdog.timer >/dev/null 2>&1 || error "Could not pause the watchdog timer."
    fi
    if _stress_unit_busy rigforge-autotune.service || _stress_unit_busy rigforge-watchdog.service; then
        error "A scheduled autotune or watchdog check is already running; try stress again after it finishes."
    fi

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        _STRESS_MINER_WAS_ACTIVE=1
        sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || error "Could not stop $SERVICE_NAME for the stress run."
    fi

    log "Running offline XMRig stress for $minutes minute(s)..."
    "$bin" --stress --config="$safe_cfg" --log-file="$logf" >"$out" 2>&1 &
    _STRESS_PID=$!
    seconds=$((minutes * 60))
    now=$(_stress_now)
    deadline=$((now + seconds))
    while :; do
        temp=$(_read_temp)
        if [ -n "$temp" ] && { [ -z "$peak" ] || awk -v t="$temp" -v p="$peak" 'BEGIN { exit !(t > p) }'; }; then peak=$temp; fi
        if [ -n "$MAX_TEMP_C" ] && [ -n "$temp" ] && awk -v t="$temp" -v m="$MAX_TEMP_C" 'BEGIN { exit !(t > m) }'; then
            reason="temperature ${temp}°C exceeded max_temp_c=${MAX_TEMP_C}°C"
            rc=1
            _STRESS_THERMAL_TRIP=1
            if [ "$_STRESS_MINER_WAS_ACTIVE" = 1 ] && ! touch "$_STRESS_HOLD_FILE"; then
                reason="$reason; could not record the watchdog thermal hold — the miner remains stopped; recover it manually after it cools"
            fi
            break
        fi
        if _stress_fatal "$logf" "$out"; then
            rc=1
            reason="XMRig reported a fatal memory or config error"
            break
        fi
        now=$(_stress_now)
        if ! kill -0 "$_STRESS_PID" 2>/dev/null; then
            wait "$_STRESS_PID" 2>/dev/null || rc=$?
            [ "$rc" -ne 0 ] || rc=1
            reason="XMRig exited before the stress window completed"
            break
        fi
        if [ "$now" -ge "$deadline" ]; then break; fi
        _stress_sleep 2
    done

    _selftest_stop "$_STRESS_PID"
    _STRESS_PID=""
    if [ "$rc" -eq 0 ] && _stress_fatal "$logf" "$out"; then
        rc=1
        reason="XMRig reported a fatal memory or config error"
    elif [ "$rc" -eq 0 ] && ! _stress_hashing "$logf" "$out"; then
        rc=1
        reason="XMRig's latest speed report was not a positive hashrate"
    fi
    last=""
    if [ "$rc" -ne 0 ]; then last=$(tail -n 15 "$logf" "$out" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'); fi
    peak_label=unavailable
    [ -z "$peak" ] || peak_label="${peak}°C"
    if ! _stress_cleanup "$rc"; then
        rc=1
        [ -n "$reason" ] || reason="could not restore the prior service and timer state"
    fi
    trap - EXIT HUP INT TERM
    if [ "$rc" -eq 0 ]; then
        log "Stress PASS: hashed for $minutes minute(s); peak temperature $peak_label."
    else
        warn "Stress FAIL: $reason; peak temperature $peak_label."
        if [ -n "$last" ]; then warn "stress: last XMRig output:"$'\n'"$last"; fi
    fi
    return "$rc"
}
