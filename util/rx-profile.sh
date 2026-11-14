#!/usr/bin/env bash
RX_AUTO_RC=""
RX_AUTO_THREADS=""

_rx_validate_cap() {
    [ -n "${THREADS_CAP:-}" ] || return 0
    [[ "$THREADS_CAP" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$THREADS_CAP))" -ge 1 ] && printf '%s' "$((10#$THREADS_CAP))"
    return 0
}

_rx_object() {
    jq -cn --argjson n "$1" '{mode: 0, threads: $n, max_threads_cnt: $n, intensity: 1, affinity: -1}'
}

_rx_min_count() {
    local v best=""
    for v in "$@"; do
        case "$v" in '' | *[!0-9]*) continue ;; esac
        [ "$v" -ge 1 ] || continue
        [ -z "$best" ] || [ "$v" -lt "$best" ] && best="$v"
    done
    printf '%s' "$best"
}

_rx_probe_reap() {
    kill -9 "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
    rm -rf "$2"
}

_rx_probe_auto() {
    local bin sinkdir sink pid deadline arr="" oldtrap
    bin="$WORKER_ROOT/xmrig/build/xmrig"
    case "$PWD" in "$WORKER_ROOT"/*) [ -f "$PWD/xmrig" ] && [ -x "$PWD/xmrig" ] && bin="$PWD/xmrig" ;; esac
    { [ "${OS_TYPE:-}" = Linux ] && [ -x "$bin" ] && command -v jq >/dev/null 2>&1; } || return 2
    sinkdir=$(mktemp -d) || return 1
    sink="$sinkdir/probe.json"
    jq '{autosave: true, http: {enabled: false},
         cpu: ({"huge-pages": false} + ((.cpu // {}) | with_entries(select(.key == "max-threads-hint" or .key == "asm")))),
         randomx: {"1gb-pages": false, wrmsr: false, rdmsr: false},
         pools: [{url: "127.0.0.1:1", user: "rigforge-profile"}]}' "$1" >"$sink" 2>/dev/null || {
        rm -rf "$sinkdir"
        return 1
    }
    chmod 600 "$sink"
    "$bin" --config "$sink" </dev/null >"$sinkdir/out.log" 2>&1 &
    pid=$!
    oldtrap=$(trap -p INT TERM HUP)
    # shellcheck disable=SC2064
    trap "_rx_probe_reap $pid '$sinkdir'; exit 143" INT TERM HUP
    deadline=$((SECONDS + ${RX_PROBE_TIMEOUT:-10}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if jq -e '.cpu.rx | type == "array" and length >= 1' "$sink" >/dev/null 2>&1; then
            arr=$(jq -c '.cpu.rx' "$sink" 2>/dev/null)
            break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    _rx_probe_reap "$pid" "$sinkdir"
    trap - INT TERM HUP
    [ -z "$oldtrap" ] || eval "$oldtrap"
    [ -n "$arr" ] && printf '%s' "$arr"
}

_rx_ensure_auto() {
    [ -n "${RX_AUTO_THREADS:-}" ] && return 0
    [ -n "${RX_AUTO_RC:-}" ] && return "$RX_AUTO_RC"
    local arr rc=0 seen cache="${TUNE_TMP:+$TUNE_TMP/rxauto}"
    if [ -n "$cache" ] && [ -s "$cache" ]; then
        seen=$(<"$cache")
        case "$seen" in
        '' | *[!0-9]*) RX_AUTO_RC=1 ;;
        *) RX_AUTO_THREADS="$seen" RX_AUTO_RC=0 ;;
        esac
        return "$RX_AUTO_RC"
    fi
    arr=$(_rx_probe_auto "$1") || rc=$?
    if [ "$rc" = 0 ] && RX_AUTO_THREADS=$(jq -r 'length' <<<"$arr" 2>/dev/null) && [ "${RX_AUTO_THREADS:-0}" -ge 1 ]; then
        RX_AUTO_ARR="$arr" RX_AUTO_RC=0
    else
        RX_AUTO_THREADS="" RX_AUTO_RC=$((rc == 2 ? 2 : 1))
    fi
    [ -z "$cache" ] || printf '%s' "${RX_AUTO_THREADS:-none}" >"$cache"
    return "$RX_AUTO_RC"
}

_rx_request_count() {
    jq -r 'if (.cpu.rx | type) == "number" and .cpu.rx >= 1 then .cpu.rx
           elif (.cpu.rx | type) == "array" and (.cpu.rx | length) >= 1 then (.cpu.rx | length)
           elif (.cpu.rx | type) == "object" and (.cpu.rx.threads | type) == "number" and .cpu.rx.threads >= 1 then .cpu.rx.threads
           else empty end' "$1" 2>/dev/null
}

_rx_finalize_cpu_rx() {
    local cfg="$1" rx req="" auto="" cap="" eff out len rc
    rx=$(jq -c '.cpu.rx' "$cfg" 2>/dev/null) || return 1
    if [ -n "${THREADS_CAP:-}" ] && [ -z "$(_rx_validate_cap)" ]; then
        warn "THREADS_CAP='${THREADS_CAP}' is not a valid positive integer — ignoring it (thread cap NOT applied)."
    fi
    cap=$(_rx_validate_cap)
    [ "$rx" = false ] && return 0
    req=$(_rx_request_count "$cfg")
    if [ -n "$cap" ] || [ -n "$req" ]; then
        _rx_ensure_auto "$cfg" && rc=0 || rc=$?
        if [ "$rc" = 0 ]; then
            auto="$RX_AUTO_THREADS"
        elif [ "$rc" = 1 ]; then
            warn "Could not observe XMRig's auto thread profile; the thread count is applied without the auto-selection ceiling."
        fi
    fi
    eff=$(_rx_min_count "$auto" "$cap" "$req")
    if [ "${rx:0:1}" = "[" ]; then
        len=$(jq '.cpu.rx | length' "$cfg" 2>/dev/null)
        { [ -n "$eff" ] && [ "$eff" -lt "$len" ]; } || return 0
    fi
    if [ -z "$eff" ]; then
        out=$(jq '.cpu.rx = {}' "$cfg" 2>/dev/null) || return 1
        printf '%s\n' "$out" >"$cfg"
        return
    fi
    if [ -n "$auto" ] && [ "$eff" -ge "$auto" ]; then
        out=$(jq --argjson a "${RX_AUTO_ARR:-[]}" --argjson n "$auto" '.cpu.rx = (if ($a | length) == $n then $a else [range($n) | -1] end)' "$cfg" 2>/dev/null)
    else
        out=$(jq --argjson n "$eff" '.cpu.rx = {mode: 0, threads: $n, max_threads_cnt: $n, intensity: 1, affinity: -1}' "$cfg" 2>/dev/null)
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" >"$cfg"
}

_rx_clamp_candidate() {
    local out="$1" eff cap
    if [ "$3" = "-1" ]; then
        jq '.cpu.rx = {}' "$out" >"$out.rx$$" && cat "$out.rx$$" >"$out" && rm -f "$out.rx$$" || return 1
        _rx_finalize_cpu_rx "$out"
        return
    fi
    eff=$(_rx_request_count "$out")
    [ -z "$eff" ] && return 0
    _rx_ensure_auto "$2" || true
    cap=$(_rx_validate_cap)
    eff=$(_rx_min_count "$eff" "$cap" "${RX_AUTO_THREADS:-}")
    jq --argjson n "$eff" '.cpu.rx = {mode: 0, threads: $n, max_threads_cnt: $n, intensity: 1, affinity: -1}' "$out" >"$out.rx$$" &&
        cat "$out.rx$$" >"$out" && rm -f "$out.rx$$"
}
