#!/usr/bin/env bash
# shellcheck shell=bash

dash_curl() {
    curl -kLfsS --max-time 10 ${E2E_DASH_AUTH:+-u "$E2E_DASH_AUTH"} "$E2E_DASH_URL" 2>/dev/null || true
}

dash_worker_state() {
    local state
    state=$(dash_curl | jq -r --arg me "$1" '
        if type == "object" and (.workers | type) == "array"
            and all(.workers[]; type == "object" and (.name | type) == "string" and ((.status == "online") or (.status == "offline")))
        then (if any(.workers[]; .name == $me and .status == "online") then "online"
            elif any(.workers[]; .name == $me and .status == "offline") then "offline" else "absent" end)
        else "invalid" end' 2>/dev/null) || true
    printf '%s' "${state:-invalid}"
}

phase_dashboard() {
    phase "dashboard — workers-alive shows this rig; a stopped rig becomes offline"
    if [ -z "${E2E_DASH_URL:-}" ]; then
        skip "E2E_DASH_URL not set — dashboard phases skipped (agree fixtures with pithead#209)"
        return 0
    fi
    [ -n "${PITHEAD_URL:-}" ] || die "dashboard phase needs PITHEAD_URL to point the miner at the stack"
    set_cfg ".pools[0].url = \"$PITHEAD_URL\""
    local me state waited=0 on_to="${E2E_DASH_ONLINE_TIMEOUT:-120}" to="${E2E_DROPOFF_TIMEOUT:-600}"
    me=$(hostname)
    while :; do
        state=$(dash_worker_state "$me")
        { [ "$state" = online ] || [ "$waited" -ge "$on_to" ]; } && break
        sleep 15
        waited=$((waited + 15))
    done
    case "$state" in
    online) ok "worker '$me' online in the dashboard payload after ${waited}s" ;;
    invalid)
        bad "dashboard returned no valid workers array"
        return 0
        ;;
    *)
        bad "worker '$me' not online in the dashboard payload within ${on_to}s"
        skip "offline check skipped: the worker was never online, so its later state proves nothing"
        return 0
        ;;
    esac
    "$RIGFORGE" stop >/dev/null 2>&1
    waited=0
    while [ "$waited" -lt "$to" ]; do
        [ "$(dash_worker_state "$me")" = offline ] && break
        sleep 15
        waited=$((waited + 15))
    done
    if [ "$waited" -lt "$to" ]; then
        ok "stopped worker became offline within ${waited}s"
    else
        bad "worker did not become offline in a valid workers array during the ${to}s window"
    fi
    "$RIGFORGE" start >/dev/null 2>&1
}
