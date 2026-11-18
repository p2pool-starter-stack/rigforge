#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
_ep_conn() {
    api8080 http://127.0.0.1:8080/1/summary 2>/dev/null |
        jq -r '[(.connection.pool | if . == null or . == "" then "?" else . end), (.connection.uptime // 0 | floor), (.connection.failures // 0 | floor)] | @tsv' 2>/dev/null || true
}

_ep_state() { # <want-pool|@dead> <timeout> -> 0 when the miner's own summary says so
    local want="$1" to="${2:-${E2E_LIVE_TIMEOUT:-180}}" waited=0 p u f
    while :; do
        IFS="$(printf '\t')" read -r p u f <<EOF
$(_ep_conn)
EOF
        if [ "$want" = @dead ]; then
            [ "${p:-?}" = "?" ] && [ "${f:-0}" -gt 0 ] 2>/dev/null && return 0
        elif [ "${p:-}" = "$want" ] && [ "${u:-0}" -gt 0 ] 2>/dev/null; then
            return 0
        fi
        [ "$waited" -lt "$to" ] || return 1
        sleep 5
        waited=$((waited + 5))
    done
}

_ep_pid() { systemctl show -p MainPID --value xmrig 2>/dev/null || true; }

_ep_edit_gen() { # <jq program> [jq options...] — options land before the program
    local tmp rc=0
    tmp=$(mktemp) || return 1
    jq "${@:2}" "$1" "$GEN_CFG" >"$tmp" && cat "$tmp" >"$GEN_CFG" || rc=$?
    rm -f "$tmp"
    return "$rc"
}

phase_effective_payout() {
    phase "effective-payout — the miner's own summary testifies which payout pool is live, watcher off and on (#656)"
    local want pid
    if [ "$(jq -r '.watchdog // "disabled"' "$CFG" 2>/dev/null)" = enabled ]; then
        skip "the miner watchdog is enabled on this rig — its zero-hashrate restart races this phase's deliberate 0 H/s windows (#656)"
        return 0
    fi
    set_cfg '.'
    if jq -e '.watch == false' "$GEN_CFG" >/dev/null 2>&1; then
        ok "generated config carries the explicit watch=false (#656)"
    else
        bad "generated config lacks the explicit watch=false, so the miner could hot-reload anything below (#656)" || true
    fi
    want=$(jq -r '.pools[0].url // empty' "$GEN_CFG" 2>/dev/null)
    if [ -z "$want" ] || ! _ep_state "$want"; then
        bad "miner never reported a live connection to the applied pool — effective payout cannot be observed (#656)" || true
        return 0
    fi
    ok "miner's own summary reports the live connection to the applied pool — the comparison reads the miner, not the file (#656)"
    ORIG_POOLS=$(mktemp)
    GEN_POOLS=$(mktemp)
    jq -c '.pools' "$CFG" >"$ORIG_POOLS"
    jq -c '.pools' "$GEN_CFG" >"$GEN_POOLS"
    if set_cfg '.pools = [(.pools[0] | {user}) + {url: "127.0.0.1:1"}]' soft && _ep_state @dead 90; then
        ok "apply of a replacement pool moved the miner off the payout pool — its summary reports no live connection (#656)"
    else
        bad "miner still reports the payout pool after apply moved the config off it — file and miner diverged unreported (#656)" || true
        _ep_restore_pools
        rm -f "$ORIG_POOLS" "$GEN_POOLS"
        return 0
    fi
    if _ep_restore_pools && _ep_state "$want"; then
        ok "apply of the original pool brought the miner's live connection back (#656)"
    else
        bad "apply of the original pool did not return the miner's live connection (#656)" || true
        rm -f "$ORIG_POOLS" "$GEN_POOLS"
        return 0
    fi
    pid=$(_ep_pid)
    if _ep_edit_gen '.pools = [(.pools[0] | {user}) + {url: "127.0.0.1:1"}]' && jq -e '.pools[0].url == "127.0.0.1:1"' "$GEN_CFG" >/dev/null 2>&1; then
        sleep "${E2E_RELOAD_WINDOW:-20}"
        if [ "$(_ep_pid)" = "$pid" ] && _ep_state "$want" 0; then
            ok "watcher disabled: the hand-edited generated pool did not reach the running miner without a restart (#656)"
        else
            bad "watcher disabled: the miner moved off the payout pool from a file edit alone — the watcher is not disabled (#656)" || true
        fi
    else
        bad "the hand edit of the generated pool never landed, so the watcher-disabled case proves nothing (#656)" || true
    fi
    if "$RIGFORGE" restart >/dev/null 2>&1 && _ep_state @dead 90; then
        ok "the restart, not the file edit, delivered the generated pool change to the miner (#656)"
    else
        bad "the restart after the hand-edit did not deliver the generated pool change (#656)" || true
    fi
    _ep_edit_gen '.watch = true'
    if ! "$RIGFORGE" restart >/dev/null 2>&1 || ! _ep_state @dead 90; then
        bad "watcher-on fixture never put the miner on the replacement pool — the hot-reload case cannot run (#656)" || true
    else
        pid=$(_ep_pid)
        if _ep_edit_gen '.pools = $p[0]' --slurpfile p "$GEN_POOLS" && jq -e '.pools[0].url != "127.0.0.1:1"' "$GEN_CFG" >/dev/null 2>&1 &&
            _ep_state "$want" 60 && [ "$(_ep_pid)" = "$pid" ]; then
            ok "watcher enabled: the pool edit hot-reloaded into the miner's connection without a restart (#656)"
        elif _ep_state "$want" 0; then
            bad "watcher enabled: the pool edit reached the miner only after a restart (#656)" || true
        else
            bad "watcher enabled: the pool edit was not hot-reloaded into the miner's connection (#656)" || true
        fi
    fi
    if _ep_restore_pools && jq -e '.watch == false' "$GEN_CFG" >/dev/null 2>&1 && _ep_state "$want"; then
        ok "apply overwrote the hand-enabled watcher with its own watch=false and the miner stands connected to the payout pool (#656)"
    else
        bad "restore apply left the watcher enabled or the miner off the payout pool (#656)" || true
    fi
    rm -f "$ORIG_POOLS" "$GEN_POOLS"
}

_ep_restore_pools() {
    set_cfg '.pools = ($p | fromjson)' soft --rawfile p "$ORIG_POOLS"
}
