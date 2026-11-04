#!/usr/bin/env bash
# #588: XMRig 6.x thread-profile plumbing for generate_xmrig_config/_tune_config (sourced by rigforge.sh).
#
# XMRig 6.26's per-algorithm profile parser accepts an array or an object and SILENTLY IGNORES a bare
# integer, falling back to the all-core auto profile — so RigForge observes XMRig's own auto profile once
# per process (a brief run against a sink config) and emits only forms XMRig honours:
#   - nothing set        -> cpu.rx omitted entirely; XMRig's own profile loads verbatim
#   - at/above the auto ceiling -> XMRig's observed short array, never a raise above it
#   - capped/tuned below auto -> {mode,threads,max_threads_cnt,intensity,affinity}
RX_AUTO_PROBED=0
RX_AUTO_THREADS=""

# echoes a validated THREADS_CAP, empty when unset/invalid
_rx_validate_cap() {
    [ -n "${THREADS_CAP:-}" ] || return 0
    [[ "$THREADS_CAP" =~ ^[0-9]+$ ]] && [ "$THREADS_CAP" -ge 1 ] && printf '%s' "$THREADS_CAP"
    return 0
}

# echoes the smallest positive integer argument, empty when none apply
_rx_min_count() {
    local v best=""
    for v in "$@"; do
        case "$v" in '' | *[!0-9]*) continue ;; esac
        [ "$v" -ge 1 ] || continue
        [ -z "$best" ] || [ "$v" -lt "$best" ] && best="$v"
    done
    printf '%s' "$best"
}

# runs XMRig once against a sink config (dead local pool, no hugepages/MSRs, autosave on) and echoes the
# auto thread array it writes back — the cache-aware sizing we must never exceed, observed live.
_rx_probe_auto() { # <config.json>
    local bin sinkdir sink pid deadline n=0
    bin="$WORKER_ROOT/xmrig/build/xmrig"
    { [ "${OS_TYPE:-}" = Linux ] && [ -x "$bin" ] && command -v jq >/dev/null 2>&1; } || return 1
    sinkdir=$(mktemp -d) || return 1
    sink="$sinkdir/probe.json"
    jq 'del(.cpu.rx) | .autosave = true | .cpu["huge-pages"] = false | .randomx.wrmsr = false | .randomx.rdmsr = false |
        .pools = [(((.pools | first) // {}) | .url = "127.0.0.1:1" | .user = "rigforge-profile")] |
        .http = {enabled: false} | del(."log-file")' "$1" >"$sink" 2>/dev/null || {
        rm -rf "$sinkdir"
        return 1
    }
    chmod 600 "$sink"
    "$bin" --config "$sink" </dev/null >"$sinkdir/out.log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + ${RX_PROBE_TIMEOUT:-10}))
    while :; do
        if jq -e '.cpu.rx | type == "array" and length >= 1' "$sink" >/dev/null 2>&1; then
            jq -c '.cpu.rx' "$sink" 2>/dev/null
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            rm -rf "$sinkdir"
            return 0
        fi
        [ "$SECONDS" -ge "$deadline" ] && break
        kill -0 "$pid" 2>/dev/null || {
            n=$((n + 1))
            [ "$n" -ge 5 ] && break
        }
        sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf "$sinkdir"
    return 1
}

# observes XMRig's auto profile once per process; RX_AUTO_THREADS then acts as the ceiling.
_rx_ensure_auto() { # <config.json>
    [ -n "${RX_AUTO_THREADS:-}" ] && return 0
    [ "${RX_AUTO_PROBED:-0}" = 1 ] && return 1
    RX_AUTO_PROBED=1
    local arr
    arr=$(_rx_probe_auto "$1") || return 1
    RX_AUTO_THREADS=$(jq -r 'length' <<<"$arr" 2>/dev/null) || return 1
    [ -n "$RX_AUTO_THREADS" ] && [ "$RX_AUTO_THREADS" -ge 1 ]
}

# echoes the profile's requested thread count (number >= 1, array length, object .threads), empty if none
_rx_request_count() { # <config.json>
    jq -r 'if (.cpu.rx | type) == "number" and .cpu.rx >= 1 then .cpu.rx
           elif (.cpu.rx | type) == "array" and (.cpu.rx | length) >= 1 then (.cpu.rx | length)
           elif (.cpu.rx | type) == "object" and (.cpu.rx.threads | type) == "number" and .cpu.rx.threads >= 1 then .cpu.rx.threads
           else empty end' "$1" 2>/dev/null
}

# rewrites an existing config's cpu.rx to min(observed auto, cap, request) in a form XMRig honours;
# at the auto ceiling the observed short array, below it a threads object, unconstrained an empty object.
_rx_finalize_cpu_rx() { # <config.json>
    local cfg="$1" rx req="" auto="" cap="" eff out len
    rx=$(jq -c '.cpu.rx' "$cfg" 2>/dev/null) || return 1
    if [ -n "${THREADS_CAP:-}" ] && [ -z "$(_rx_validate_cap)" ]; then
        warn "THREADS_CAP='${THREADS_CAP}' is not a valid positive integer — ignoring it (thread cap NOT applied)."
    fi
    cap=$(_rx_validate_cap)
    [ "$rx" = false ] && return 0
    req=$(_rx_request_count "$cfg")
    if [ -n "$cap" ] || [ -n "$req" ]; then
        _rx_ensure_auto "$cfg" && auto="$RX_AUTO_THREADS"
    fi
    eff=$(_rx_min_count "$auto" "$cap" "$req")
    if [ "${rx:0:1}" = "[" ]; then
        len=$(jq '.cpu.rx | length' "$cfg" 2>/dev/null)
        { [ -n "$eff" ] && [ "$eff" -lt "$len" ]; } || return 0
    fi
    if [ -z "$eff" ]; then
        out=$(jq '.cpu.rx = {}' "$cfg" 2>/dev/null) && printf '%s\n' "$out" >"$cfg"
        return 0
    fi
    if [ -n "$auto" ] && [ "$eff" -ge "$auto" ]; then
        out=$(jq --argjson n "$auto" '.cpu.rx = [range($n) | -1]' "$cfg" 2>/dev/null)
    else
        out=$(jq --argjson n "$eff" '.cpu.rx = {mode: 0, threads: $n, max_threads_cnt: $n, intensity: 1, affinity: -1}' "$cfg" 2>/dev/null)
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >"$cfg"
}

# bench candidates run under the same ceiling generation applies — never above the observed auto
# profile, so the tuner cannot benchmark a thread count XMRig would refuse to run anyway.
_rx_clamp_candidate() { # <candidate.json> <base config it was merged over>
    local eff cap
    eff=$(_rx_request_count "$1")
    [ -z "$eff" ] && return 0
    if [ -n "${THREADS_CAP:-}" ]; then
        _rx_ensure_auto "$2" || true
    fi
    cap=$(_rx_validate_cap)
    eff=$(_rx_min_count "$eff" "$cap" "${RX_AUTO_THREADS:-}")
    jq --argjson n "$eff" '.cpu.rx = {mode: 0, threads: $n, max_threads_cnt: $n, intensity: 1, affinity: -1}' "$1" >"$1.rx$$" &&
        cat "$1.rx$$" >"$1" && rm -f "$1.rx$$"
}
