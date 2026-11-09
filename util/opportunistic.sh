#!/usr/bin/env bash
# shellcheck disable=SC2034

_opp_parse() {
    OPP=false OPP_INTERVAL=10 OPP_CPU_ENTER=60 OPP_CPU_EXIT=30 OPP_MEM_ENTER=10 OPP_MEM_EXIT=2 OPP_ENTER_N=3 OPP_EXIT_N=6 OPP_QUIET_S=300 OPP_MIN_AVAIL_MB=1024
    local opp
    opp=$(jq -c '(.opportunistic // false) | if . == true then {} else . end' <<<"$1") || error "Cannot read shared_host.opportunistic."
    [ "$opp" != false ] || return 0
    jq -e 'def i($lo; $hi): . == null or (type == "number" and floor == . and . >= $lo and . <= $hi);
        type == "object" and (keys - ["interval_s", "cpu_enter_pct", "cpu_exit_pct", "memory_stall_enter_pct", "memory_stall_exit_pct", "enter_samples", "exit_samples", "quiet_s", "min_available_mb"] | length == 0)
        and (.interval_s | i(2; 300)) and (.cpu_enter_pct | i(5; 100)) and (.cpu_exit_pct | i(0; 95))
        and (.memory_stall_enter_pct | i(1; 100)) and (.memory_stall_exit_pct | i(0; 99))
        and (.enter_samples | i(1; 60)) and (.exit_samples | i(1; 600)) and (.quiet_s | i(0; 86400)) and (.min_available_mb | i(256; 1048576))
        and ((.cpu_exit_pct // 30) < (.cpu_enter_pct // 60)) and ((.memory_stall_exit_pct // 2) < (.memory_stall_enter_pct // 10))' <<<"$opp" >/dev/null ||
        error "shared_host.opportunistic accepts true or an object of interval_s (2-300), cpu_enter_pct (5-100) above cpu_exit_pct (0-95), memory_stall_enter_pct (1-100) above memory_stall_exit_pct (0-99), enter_samples (1-60), exit_samples (1-600), quiet_s (0-86400) and min_available_mb (256-1048576)."
    read -r OPP_INTERVAL OPP_CPU_ENTER OPP_CPU_EXIT OPP_MEM_ENTER OPP_MEM_EXIT OPP_ENTER_N OPP_EXIT_N OPP_QUIET_S OPP_MIN_AVAIL_MB < <(jq -r '[.interval_s // 10, .cpu_enter_pct // 60, .cpu_exit_pct // 30, .memory_stall_enter_pct // 10, .memory_stall_exit_pct // 2, .enter_samples // 3, .exit_samples // 6, .quiet_s // 300, .min_available_mb // 1024] | @tsv' <<<"$opp")
    OPP=true
}

_opp_paths() {
    local root="${WORKER_ROOT:-}"
    [ -n "$root" ] || root=$(_worker_root_from_config)
    OPP_DIR="${RIGFORGE_OPP_DIR:-/var/lib/rigforge-opportunistic}"
    OPP_STATE="$OPP_DIR/state" OPP_OWNED="$OPP_DIR/owned" OPP_MANUAL="$OPP_DIR/manual" OPP_LOCK="$OPP_DIR/lock" OPP_THERMAL="${root:+$root/watchdog.thermal-hold}"
}

_opp_enabled_in_config() {
    [ "$OS_TYPE" = Linux ] && [ -f "$CONFIG_JSON" ] && jq -e '(.shared_host.opportunistic // false) != false' "$CONFIG_JSON" >/dev/null 2>&1
}

_opp_manual() {
    if _opp_enabled_in_config && _opp_paths && [ -d "$OPP_DIR" ]; then
        sudo flock -x "$OPP_LOCK" sh -c 'rm -f "$1"; if [ "$4" = stop ]; then touch "$2"; else rm -f "$2"; fi; shift 2; exec "$@"' sh "$OPP_OWNED" "$OPP_MANUAL" "$@"
    else
        sudo "$@"
    fi
}

_opp_gate() {
    [ "${OPP:-false}" = true ] && _opp_paths || return 0
    [ ! -e "$OPP_OWNED" ] || error "The opportunistic policy is holding the miner for host capacity; it starts the miner when capacity returns, or run 'sudo $0 start' to override."
}

_opp_clock() { NOW=$(date +%s); }

_opp_field() {
    local line f
    OPP_VALUE=""
    [ -r "$1" ] || return 1
    while read -r -a f; do
        [ "${f[0]:-}" = "$2" ] || continue
        line=${f[$3]:-}
        line=${line#total=}
        [[ "$line" =~ ^[0-9]+$ ]] || return 1
        OPP_VALUE=$line
        return 0
    done <"$1"
    return 1
}

_opp_sample() {
    local psi="${RIGFORGE_PSI_DIR:-/proc/pressure}" cg="${RIGFORGE_CGROUP_ROOT:-/sys/fs/cgroup}/rigforge.slice" f cs v
    SMP_SU=0 SMP_SM=0 SMP_SLICE=no
    read -r -a f <"${RIGFORGE_PROC_UPTIME:-/proc/uptime}" || return 1
    cs=${f[0]:-}
    [[ "$cs" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    cs=${cs/./}
    SMP_UP=$((10#$cs * 10000))
    read -r -a f <"${RIGFORGE_PROC_STAT:-/proc/stat}" || return 1
    [ "${f[0]:-}" = cpu ] || return 1
    for v in "${f[@]:1:8}"; do [[ "$v" =~ ^[0-9]+$ ]] || return 1; done
    SMP_TJ=$((f[1] + f[2] + f[3] + f[4] + f[5] + f[6] + f[7] + f[8]))
    SMP_IJ=$((f[4] + f[5]))
    _opp_field "$psi/memory" some 4 || return 1
    SMP_HM=$OPP_VALUE
    if [ -d "$cg" ]; then
        SMP_SLICE=yes
        _opp_field "$cg/cpu.stat" usage_usec 1 || return 1
        SMP_SU=$OPP_VALUE
        _opp_field "$cg/memory.pressure" some 4 || return 1
        SMP_SM=$OPP_VALUE
    fi
    _opp_field "$MEMINFO" MemAvailable: 1 || return 1
    SMP_AV=$((OPP_VALUE / 1024))
    [ "$SMP_UP" -gt 0 ] && [ "$SMP_TJ" -gt 0 ] && [ "$SMP_IJ" -le "$SMP_TJ" ]
}

_opp_load() {
    S_PHASE="" S_SINCE=0 S_YIELD=0 S_REASON="" S_ENTER=0 S_EXIT=0 S_OBS=0 S_CPU="" S_MEM="" S_AVAIL="" S_UP="" S_TJ="" S_IJ="" S_SU="" S_HM="" S_SM=""
    local k v
    [ -f "$OPP_STATE" ] || return 0
    while IFS='=' read -r k v; do
        case "$k" in
        phase) [[ "$v" =~ ^[a-z]+$ ]] && S_PHASE=$v ;;
        reason) S_REASON=${v//[^[:print:]]/} ;;
        since) _uint_in_range "$v" 0 99999999999 && S_SINCE=$v ;;
        yield) _uint_in_range "$v" 0 99999999999 && S_YIELD=$v ;;
        enter) _uint_in_range "$v" 0 100000 && S_ENTER=$v ;;
        exit) _uint_in_range "$v" 0 100000 && S_EXIT=$v ;;
        obs) _uint_in_range "$v" 0 99999999999 && S_OBS=$v ;;
        cpu) _uint_in_range "$v" 0 100 && S_CPU=$v ;;
        mem) _uint_in_range "$v" 0 100 && S_MEM=$v ;;
        avail) _uint_in_range "$v" 0 1099511627776 && S_AVAIL=$v ;;
        up) _uint_in_range "$v" 1 99999999999999999 && S_UP=$v ;;
        tj) _uint_in_range "$v" 1 99999999999999999 && S_TJ=$v ;;
        ij) _uint_in_range "$v" 0 99999999999999999 && S_IJ=$v ;;
        su) _uint_in_range "$v" 0 99999999999999999 && S_SU=$v ;;
        hm) _uint_in_range "$v" 0 99999999999999999 && S_HM=$v ;;
        sm) _uint_in_range "$v" 0 99999999999999999 && S_SM=$v ;;
        esac
    done <"$OPP_STATE"
    return 0
}

_opp_save() {
    printf 'phase=%s\nreason=%s\nsince=%s\nyield=%s\nenter=%s\nexit=%s\nobs=%s\ncpu=%s\nmem=%s\navail=%s\nup=%s\ntj=%s\nij=%s\nsu=%s\nhm=%s\nsm=%s\n' \
        "$S_PHASE" "$S_REASON" "$S_SINCE" "$S_YIELD" "$S_ENTER" "$S_EXIT" "$S_OBS" "$S_CPU" "$S_MEM" "$S_AVAIL" "$S_UP" "$S_TJ" "$S_IJ" "$S_SU" "$S_HM" "$S_SM" >"$OPP_STATE.tmp.$$" &&
        mv -f "$OPP_STATE.tmp.$$" "$OPP_STATE"
}

_opp_record() {
    local old="$S_PHASE"
    S_PHASE=$1 S_REASON=$2
    if [ "$old" != "$1" ]; then
        S_SINCE=$NOW
        log "opportunistic: $1 - $2"
    fi
    _opp_save
}

_opp_yield() {
    touch "$OPP_OWNED" || return 1
    if ! sudo systemctl stop "$SERVICE_NAME" 2>/dev/null; then
        rm -f "$OPP_OWNED"
        warn "opportunistic: failed to stop $SERVICE_NAME; will retry."
        return 1
    fi
    S_ENTER=0 S_EXIT=0 S_YIELD=$NOW
}

_opp_resume() {
    rm -f "$OPP_OWNED"
    if ! sudo systemctl start "$SERVICE_NAME" 2>/dev/null; then
        touch "$OPP_OWNED"
        warn "opportunistic: failed to start $SERVICE_NAME; will retry."
        return 1
    fi
    S_ENTER=0 S_EXIT=0
}

_opp_maintenance() {
    local cg="${RIGFORGE_CGROUP_ROOT:-/sys/fs/cgroup}/rigforge.slice" d
    for d in "$cg"/*/; do
        [ -d "$d" ] || continue
        case "$d" in "$cg/$SERVICE_NAME.service/") continue ;; esac
        [ ! -s "${d}cgroup.procs" ] || return 0
    done
    return 1
}

_opp_tick() {
    _opp_clock
    _opp_paths
    _opp_load
    local st active=no owned=no up tj ij su hm sm av dj dt busy fg=0 mem=0 window=no why=""
    st=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
    case "$st" in active | activating | reloading) active=yes ;; deactivating) return 0 ;; esac
    [ -e "$OPP_OWNED" ] && owned=yes
    if [ "$owned" = yes ] && [ "$active" = no ]; then
        case "$S_PHASE" in waiting | unavailable | thermal | maintenance) ;; *) S_YIELD=$NOW ;; esac
    fi
    if ! _opp_sample || { [ "$active" = yes ] && [ "$SMP_SLICE" = no ]; }; then
        if [ "$active" = yes ]; then
            _opp_yield || return 0
            _opp_record unavailable "required pressure metrics are missing or malformed; mining held"
        elif [ "$owned" = yes ]; then
            S_EXIT=0
            _opp_record unavailable "required pressure metrics are missing or malformed; mining held"
        else
            _opp_stopped "$st"
        fi
        return 0
    fi
    up=$SMP_UP tj=$SMP_TJ ij=$SMP_IJ su=$SMP_SU hm=$SMP_HM sm=$SMP_SM av=$SMP_AV
    if [ -n "$S_UP" ] && [ "$up" -gt "$S_UP" ] && [ "$((up - S_UP))" -le "$((OPP_INTERVAL * 3000000))" ] && [ "$tj" -gt "$S_TJ" ] && [ "$ij" -ge "$S_IJ" ] && [ "$hm" -ge "$S_HM" ]; then
        window=yes
        dt=$((up - S_UP)) dj=$((tj - S_TJ))
        busy=$((dj - (ij - S_IJ)))
        if [ "$su" -gt "$S_SU" ]; then busy=$((busy - (su - S_SU) * ${OPP_HZ:=$(getconf CLK_TCK)} / 1000000)); fi
        [ "$busy" -ge 0 ] || busy=0
        fg=$((busy * 100 / dj))
        if [ "$sm" -ge "$S_SM" ]; then mem=$(((hm - S_HM - (sm - S_SM)) * 100 / dt)); else mem=$(((hm - S_HM) * 100 / dt)); fi
        [ "$mem" -ge 0 ] || mem=0
        [ "$mem" -le 100 ] || mem=100
    fi
    S_UP=$up S_TJ=$tj S_IJ=$ij S_SU=$su S_HM=$hm S_SM=$sm S_OBS=$NOW S_AVAIL=$av
    if [ "$window" = no ]; then
        S_ENTER=0 S_EXIT=0
        S_CPU="" S_MEM=""
        if [ "$active" = yes ]; then _opp_record active "measuring host load"; elif [ "$owned" = yes ]; then _opp_record waiting "measuring host load"; else _opp_stopped "$st"; fi
        return 0
    fi
    S_CPU=$fg S_MEM=$mem
    if [ "$active" = yes ]; then
        rm -f "$OPP_OWNED" "$OPP_MANUAL"
        if [ "$fg" -ge "$OPP_CPU_ENTER" ]; then why="other workloads use $fg% of host CPU (yield at $OPP_CPU_ENTER%)"; fi
        if [ -z "$why" ] && [ "$mem" -ge "$OPP_MEM_ENTER" ]; then why="memory stalls at $mem% (yield at $OPP_MEM_ENTER%)"; fi
        if [ -z "$why" ] && [ "$av" -lt "$OPP_MIN_AVAIL_MB" ]; then why="available memory $av MiB is below $OPP_MIN_AVAIL_MB MiB"; fi
        if [ -n "$why" ]; then S_ENTER=$((S_ENTER + 1)); else S_ENTER=0; fi
        S_EXIT=0
        if [ "$S_ENTER" -ge "$OPP_ENTER_N" ]; then
            _opp_yield || return 0
            _opp_record waiting "yielded: $why"
        else
            _opp_record active "mining within the host budget"
        fi
        return 0
    fi
    if [ "$owned" = no ]; then
        _opp_stopped "$st"
        return 0
    fi
    if [ -e "$OPP_THERMAL" ]; then
        S_EXIT=0
        _opp_record thermal "thermal hold is active; the watchdog releases it"
        return 0
    fi
    if _opp_maintenance; then
        S_EXIT=0
        _opp_record maintenance "a RigForge maintenance task is running in the budget"
        return 0
    fi
    local need=$((SHARED_MEMORY_MAX_MB + OPP_MIN_AVAIL_MB))
    if [ "$fg" -lt "$OPP_CPU_EXIT" ] && [ "$mem" -lt "$OPP_MEM_EXIT" ] && [ "$av" -ge "$need" ]; then S_EXIT=$((S_EXIT + 1)); else S_EXIT=0; fi
    if [ "$S_EXIT" -lt "$OPP_EXIT_N" ]; then
        _opp_record waiting "waiting for capacity: host CPU $fg% (resume below $OPP_CPU_EXIT%), memory stalls $mem% (below $OPP_MEM_EXIT%), $av of $need MiB available"
    elif [ "$((NOW - S_YIELD))" -lt "$OPP_QUIET_S" ]; then
        _opp_record waiting "capacity is back; holding for the ${OPP_QUIET_S}s quiet interval"
    elif _opp_resume; then
        _opp_record active "resumed after sustained capacity"
    else
        _opp_record waiting "capacity is back but the miner failed to start; retrying"
    fi
}

_opp_stopped() {
    S_ENTER=0 S_EXIT=0
    if [ -e "$OPP_THERMAL" ]; then
        _opp_record thermal "thermal hold is active; the watchdog releases it"
    elif [ "$1" = failed ]; then
        _opp_record failed "the miner service failed; the resource policy does not restart it"
    else
        _opp_record manual "the miner was stopped outside the resource policy; it stays stopped"
    fi
}

_opp_locked_tick() {
    _opp_paths
    (
        flock -x -w 5 9 || exit 0
        _opp_tick
    ) 9>"$OPP_LOCK"
}

_opp_run() {
    [ "$OS_TYPE" = Linux ] || error "opportunistic runs on Linux only."
    parse_config
    [ "$OPP" = true ] || error "shared_host.opportunistic is not enabled."
    _opp_paths
    sudo install -d -m 0755 "$OPP_DIR"
    local sig now_sig
    sig=$(cksum <"$CONFIG_JSON")
    while :; do
        _opp_locked_tick || warn "opportunistic: sample failed; retrying."
        sleep "$OPP_INTERVAL"
        now_sig=$(cksum <"$CONFIG_JSON")
        if [ "$now_sig" != "$sig" ]; then
            sig=$now_sig
            if (parse_config) >/dev/null 2>&1; then parse_config >/dev/null; else warn "opportunistic: config.json is invalid; keeping the previous thresholds."; fi
            [ "$OPP" = true ] || error "shared_host.opportunistic was disabled; stopping the controller."
        fi
    done
}

_opp_halt() {
    _opp_paths
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || return 0
    sudo mkdir -p "$OPP_DIR"
    sudo flock -x "$OPP_LOCK" sh -c 'touch "$1" && exec systemctl stop "$2"' sh "$OPP_OWNED" "$SERVICE_NAME" || warn "opportunistic: could not stop $SERVICE_NAME after the controller exited."
}

_opp_handoff() {
    if [ "${OPP:-false}" = true ] && _opp_paths; then
        [ -e "$OPP_MANUAL" ] || sudo flock -x "$OPP_LOCK" touch "$OPP_OWNED"
        log "opportunistic: the resource policy starts the miner when host capacity allows."
    else
        sudo systemctl start "$SERVICE_NAME" 2>/dev/null
    fi
}

_opp_thermal_stop() {
    if [ "${OPP:-false}" = true ] && _opp_paths && [ -d "$OPP_DIR" ]; then
        sudo flock -x "$OPP_LOCK" sh -c 'systemctl stop "$2" 2>/dev/null && touch "$1"' sh "$1" "$SERVICE_NAME"
    else
        sudo systemctl stop "$SERVICE_NAME" 2>/dev/null && touch "$1"
    fi
}

_opp_install_unit() {
    local unit="$SYSTEMD_DIR/rigforge-opportunistic.service"
    if [ "${OPP:-false}" = true ]; then
        SCRIPT_DIR="$SCRIPT_DIR" RIGFORGE_OPERATOR="$REAL_USER" envsubst '$SCRIPT_DIR $RIGFORGE_OPERATOR' \
            <"$SCRIPT_DIR/systemd/rigforge-opportunistic.service.template" | sudo tee "$unit" >/dev/null
        sudo systemctl daemon-reload || error "Could not reload systemd; miner activation refused."
        _opp_paths
        sudo install -d -m 0755 "$OPP_DIR" || error "Could not create $OPP_DIR; miner activation refused."
        sudo systemctl enable ${ENABLE_RUNTIME:+"$ENABLE_RUNTIME"} --now rigforge-opportunistic.service ||
            error "Could not start the opportunistic controller; miner activation refused."
    elif [ -f "$unit" ]; then
        sudo systemctl daemon-reload 2>/dev/null || true
        sudo systemctl disable ${ENABLE_RUNTIME:+"$ENABLE_RUNTIME"} --now rigforge-opportunistic.service 2>/dev/null || true
        sudo rm -f "$unit"
        sudo systemctl daemon-reload 2>/dev/null || true
        _opp_paths
        sudo rm -f "$OPP_OWNED" "$OPP_MANUAL" "$OPP_STATE" "$OPP_LOCK"
        sudo rmdir "$OPP_DIR" 2>/dev/null || true
        log "Opportunistic mining disabled; start a stopped miner with: sudo $0 start"
    fi
}

_opp_unit_section() {
    [ "${OPP:-false}" = true ] || return 0
    printf '[Unit]\nBindsTo=rigforge-opportunistic.service\nAfter=rigforge-opportunistic.service\n'
}

_opp_state_label() {
    case "$1" in
    active) echo "mining within the host budget" ;;
    waiting) echo "waiting for host capacity" ;;
    manual) echo "stopped manually" ;;
    failed) echo "miner service failed" ;;
    thermal) echo "thermal hold" ;;
    maintenance) echo "paused for maintenance" ;;
    unavailable) echo "metrics unavailable" ;;
    *) echo "no observation yet" ;;
    esac
}

_opp_observation() {
    OPP_AGE="" OPP_STALE=true
    _opp_paths
    _opp_load
    [ "$S_OBS" -gt 0 ] || return 0
    _opp_clock
    OPP_AGE=$((NOW - S_OBS))
    [ "$OPP_AGE" -ge 0 ] || OPP_AGE=0
    if [ "$OPP_AGE" -le "$((OPP_INTERVAL * 3))" ]; then OPP_STALE=false; fi
}

_opp_waiting() {
    [ "${OPP:-false}" = true ] || return 1
    _opp_observation
    [ "$OPP_STALE" = false ] && [ "$S_PHASE" = waiting ]
}

_opp_report() {
    [ "${OPP:-false}" = true ] || return 0
    _opp_observation
    local rc=0
    printf 'Opportunistic mining: %s' "$(_opp_state_label "$S_PHASE")"
    [ -z "$S_PHASE" ] || printf ' (since %s: %s)' "$(date -u -d "@$S_SINCE" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$S_SINCE")" "$S_REASON"
    printf '\n'
    if [ -n "$OPP_AGE" ]; then
        printf 'Opportunistic observation: %ss old; host CPU in use by other workloads %s%%, memory stalls %s%%, available memory %s MiB\n' "$OPP_AGE" "${S_CPU:--}" "${S_MEM:--}" "${S_AVAIL:--}"
    fi
    printf 'Opportunistic budget: CPU quota %s%%, memory %s MiB; yield at CPU %s%% / stalls %s%% / under %s MiB, resume below %s%% / %s%% with %s MiB headroom after %s samples and %ss\n' \
        "$SHARED_CPU_QUOTA" "$SHARED_MEMORY_MAX_MB" "$OPP_CPU_ENTER" "$OPP_MEM_ENTER" "$OPP_MIN_AVAIL_MB" "$OPP_CPU_EXIT" "$OPP_MEM_EXIT" "$OPP_MIN_AVAIL_MB" "$OPP_EXIT_N" "$OPP_QUIET_S"
    if [ "$OPP_STALE" = true ]; then
        echo "Opportunistic controller observation is missing or stale; check: systemctl status rigforge-opportunistic"
        rc=1
    elif [ "$S_PHASE" = unavailable ]; then
        rc=1
    fi
    return "$rc"
}

_opportunistic_json() {
    if [ "${OPP:-false}" != true ]; then
        jq -n '{mode: "disabled"}'
        return 0
    fi
    _opp_observation
    jq -n --arg state "${S_PHASE:-unknown}" --arg reason "$S_REASON" --arg since "$S_SINCE" --arg obs "$S_OBS" --arg age "$OPP_AGE" --argjson stale "$OPP_STALE" \
        --arg cpu "$S_CPU" --arg mem "$S_MEM" --arg av "$S_AVAIL" --arg q "$SHARED_CPU_QUOTA" --arg mm "$SHARED_MEMORY_MAX_MB" \
        '{mode: "enabled", state: $state, reason: (if $reason == "" then null else $reason end),
          last_transition_epoch: (if $since == "0" then null else ($since | tonumber) end),
          observed_epoch: (if $obs == "0" then null else ($obs | tonumber) end), observation_age_s: (if $age == "" then null else ($age | tonumber) end), stale: $stale,
          other_cpu_pct: (if $cpu == "" then null else ($cpu | tonumber) end), memory_stall_pct: (if $mem == "" then null else ($mem | tonumber) end),
          available_mb: (if $av == "" then null else ($av | tonumber) end),
          budget: {cpu_quota_percent: ($q | tonumber), memory_max_mb: ($mm | tonumber)}}'
}
