#!/usr/bin/env bash
# shellcheck shell=bash
_co_pid() { systemctl show -p MainPID --value xmrig 2>/dev/null || true; }

_co_sum() { sha256sum <"$1" | awk '{print $1}'; }

_co_wait_live() {
    local waited=0 hr
    while [ "$waited" -lt "${E2E_LIVE_TIMEOUT:-180}" ]; do
        hr=$(live_hashrate)
        [ -n "$hr" ] && awk -v h="$hr" 'BEGIN{exit !(h + 0 > 0)}' && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

_co_donate() {
    local waited=0 got=""
    while [ "$waited" -lt 60 ]; do
        got=$(api8080 http://127.0.0.1:8080/2/summary | jq -r '.donate_level // empty' 2>/dev/null || true)
        [ -n "$got" ] && break
        sleep 2
        waited=$((waited + 2))
    done
    printf '%s' "$got"
}

_co_hand_edit() {
    local pid donate want orig edited rc=0
    pid=$(_co_pid)
    donate=$(_co_donate)
    [ -n "$donate" ] || return 1
    want=$((donate + 1))
    orig=$(mktemp)
    edited=$(mktemp)
    cp "$GEN_CFG" "$orig"
    if ! jq --argjson d "$want" '."donate-level" = $d' "$orig" >"$edited" || ! cat "$edited" >"$GEN_CFG" ||
        [ "$(jq -r '."donate-level"' "$GEN_CFG")" != "$want" ]; then
        rc=1
    else
        sleep "${E2E_RELOAD_WINDOW:-20}"
        [ "$(_co_pid)" = "$pid" ] && [ "$(_co_donate)" = "$donate" ] || rc=1
        if [ "$rc" = 0 ]; then
            "$RIGFORGE" restart >/dev/null 2>&1 && _co_wait_live && [ "$(_co_donate)" = "$want" ] || rc=2
        fi
    fi
    cat "$orig" >"$GEN_CFG" && "$RIGFORGE" restart >/dev/null 2>&1 && cmp -s "$orig" "$GEN_CFG" || rc=3
    rm -f "$orig" "$edited"
    return "$rc"
}

phase_config_ownership() {
    phase "config-ownership — XMRig neither rewrites nor hot-reloads the generated config; setup restarts on a change (#529)"
    local before rc plan binary binary_before pid keepalive tmp setup_log
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    set_cfg '.'
    before=$(_co_sum "$GEN_CFG")
    "$RIGFORGE" start >/dev/null 2>&1 || true

    if [ "$(jq -c '[.autosave, .watch]' "$GEN_CFG" 2>/dev/null)" = '[false,false]' ]; then
        ok "generated config sets autosave=false and watch=false (#529)"
    else
        bad "generated config does not set autosave=false and watch=false (#529)" || true
    fi

    if _co_wait_live && sleep "${E2E_AUTOSAVE_WINDOW:-30}" && [ "$(_co_sum "$GEN_CFG")" = "$before" ]; then
        ok "generated config stays byte-identical while the miner mines (no autosave write-back) (#529)"
    else
        bad "generated config changed after the miner started, or the miner never went live (#529)" || true
    fi

    rc=0
    _co_hand_edit || rc=$?
    case "$rc" in
    0) ok "hand edit of the generated config is not hot-reloaded (same PID, donate_level unchanged) and a restart loads it (#529)" ;;
    2) bad "hand edit was not hot-reloaded, but a restart did not load it either, so the probe proves nothing (#529)" || true ;;
    3) bad "restoring the generated config after the hand-edit check failed (#529)" || true ;;
    *) bad "hand edit of the generated config did not land, was hot-reloaded, or restarted the miner (#529)" || true ;;
    esac

    plan=$("$RIGFORGE" setup --dry-run </dev/null 2>&1 || true)
    if ! grep -q 'skip the build' <<<"$plan"; then
        bad "setup restart check needs an already-built worker, but setup --dry-run plans a rebuild (#529)" || true
        return 0
    fi
    binary="$(dirname "$GEN_CFG")/xmrig"
    binary_before=$(_co_sum "$binary")
    pid=$(_co_pid)
    keepalive=$(jq '.pools[0].keepalive != false | not' "$CFG")
    tmp=$(mktemp)
    jq --argjson k "$keepalive" '.pools[0].keepalive = $k' "$CFG" >"$tmp" && cat "$tmp" >"$CFG"
    rm -f "$tmp"
    setup_log=$(mktemp)
    if "$RIGFORGE" setup </dev/null >"$setup_log" 2>&1 && grep -q 'recompile will be skipped' "$setup_log" &&
        grep -q 'Restarting XMRig service' "$setup_log" && [ "$(_co_pid)" != "$pid" ] && [ "$(_co_pid)" != 0 ] &&
        [ "$(jq '.pools[0].keepalive != false' "$GEN_CFG")" = "$keepalive" ] &&
        [ "$(_co_sum "$binary")" = "$binary_before" ] && _co_wait_live; then
        ok "setup on an already-built worker applies a changed pool setting with a restart and no rebuild (#529)"
    else
        bad "setup did not restart the miner with the changed pool setting, or rebuilt XMRig (#529)" || true
    fi
    rm -f "$setup_log"
}
