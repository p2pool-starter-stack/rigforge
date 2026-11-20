#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
_ep_conn() {
    api8080 http://127.0.0.1:8080/1/summary 2>/dev/null |
        jq -r '[(.connection.pool | if . == null or . == "" then "?" else . end), (.connection.uptime // 0 | floor), (.connection.failures // 0 | floor)] | @tsv' 2>/dev/null || true
}

_ep_state() {
    local want="$1" to="${2:-${E2E_LIVE_TIMEOUT:-180}}" waited=0 p u _f
    while :; do
        IFS="$(printf '\t')" read -r p u _f <<EOF
$(_ep_conn)
EOF
        if [ "$want" = @dead ]; then
            [ -n "${p:-}" ] && { [ "$p" != "$EP_PAYOUT" ] || [ "${u:-0}" -eq 0 ]; } && return 0
        elif [ "${p:-}" = "$want" ] && [ "${u:-0}" -gt 0 ] 2>/dev/null; then
            return 0
        fi
        [ "$waited" -lt "$to" ] || return 1
        sleep 5
        waited=$((waited + 5))
    done
}

_ep_hashing() {
    local waited=0
    while :; do
        [ "$(api8080 http://127.0.0.1:8080/1/summary 2>/dev/null | jq -r '(.hashrate.total[0] // 0) > 0' 2>/dev/null)" = true ] && return 0
        [ "$waited" -lt 60 ] || return 1
        sleep 5
        waited=$((waited + 5))
    done
}

_ep_away_state() { _ep_state "${E2E_ALT_POOL_URL:-@dead}" "$@"; }

_ep_away_apply() {
    set_cfg "$EP_AWAY_PROG" soft --arg u "$EP_AWAY_URL" --arg w "$EP_AWAY_PASS"
}

_ep_away_edit() {
    _ep_edit_gen "$EP_AWAY_PROG" --arg u "$EP_AWAY_URL" --arg w "$EP_AWAY_PASS"
}

_ep_pid() { systemctl show -p MainPID --value xmrig 2>/dev/null || true; }

_ep_edit_gen() {
    local tmp rc=0
    tmp=$(mktemp) || return 1
    jq "${@:2}" "$1" "$GEN_CFG" >"$tmp" && cat "$tmp" >"$GEN_CFG" || rc=$?
    rm -f "$tmp"
    return "$rc"
}

_ep_watchdog_active() { systemctl is-active --quiet rigforge-watchdog.timer 2>/dev/null; }

_ep_watchdog_matches() {
    if [ "$1" = enabled ]; then _ep_watchdog_active; else ! _ep_watchdog_active; fi
}

phase_effective_payout() {
    phase "effective-payout — the miner's own summary testifies which payout pool is live, watcher off and on (#656)"
    local orig_wd rc=0
    orig_wd=$(jq -r '.watchdog // "disabled"' "$CFG")
    EP_AWAY_URL="${E2E_ALT_POOL_URL:-127.0.0.1:1}"
    EP_AWAY_PASS="${E2E_ALT_POOL_PASS:-}"
    EP_AWAY_PROG='.pools = [(.pools[0] | {user}) + {url: $u} + (if $w == "" then {} else {pass: $w} end)]'
    set_cfg '.watchdog = "disabled"'
    if [ "$(jq -r '.watchdog // "disabled"' "$CFG")" = disabled ] && ! _ep_watchdog_active; then
        ok "the phase reconciles the miner watchdog off and its timer is inactive, so a zero-hashrate restart cannot race the deliberate 0 H/s windows (#656)"
        _ep_body
    else
        bad "the miner watchdog could not be reconciled off or its timer is still active; its zero-hashrate restart can race this phase (#656)" || true
    fi
    set_cfg '.watchdog = $w' soft --arg w "$orig_wd" || rc=$?
    if [ "$rc" = 0 ] && _ep_watchdog_matches "$orig_wd"; then
        ok "the watchdog stands restored to its original $orig_wd setting after the phase (#656)"
    else
        bad "the watchdog was not restored to its original $orig_wd setting after the phase (#656)" || true
    fi
}

_ep_body() {
    local want pid
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
    EP_PAYOUT="$want"
    if [ -n "${E2E_ALT_POOL_URL:-}" ] && ! _ep_hashing; then
        bad "miner is not hashing on the payout pool before the switch (#656)" || true
    fi
    ok "miner's own summary reports the live connection to the applied pool — the comparison reads the miner, not the file (#656)"
    ORIG_POOLS=$(mktemp)
    GEN_POOLS=$(mktemp)
    jq -c '.pools' "$CFG" >"$ORIG_POOLS"
    jq -c '.pools' "$GEN_CFG" >"$GEN_POOLS"
    if _ep_away_apply && _ep_away_state 90; then
        ok "apply of a replacement pool moved the miner off the payout pool — its summary reports no live payout connection (#656)"
        if [ -n "${E2E_ALT_POOL_URL:-}" ] && ! _ep_hashing; then
            bad "miner is not hashing on the second pool (#656)" || true
        fi
    else
        bad "miner still reports the payout pool after apply moved the config off it — file and miner diverged unreported; miner summary: $(_ep_conn | tr '\t' ' ') (#656)" || true
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
    if _ep_away_edit && jq -e --arg u "$EP_AWAY_URL" '.pools[0].url == $u' "$GEN_CFG" >/dev/null 2>&1; then
        sleep "${E2E_RELOAD_WINDOW:-20}"
        if [ "$(_ep_pid)" = "$pid" ] && _ep_state "$want" 0; then
            ok "watcher disabled: the hand-edited generated pool did not reach the running miner without a restart (#656)"
        else
            bad "watcher disabled: the miner moved off the payout pool from a file edit alone — the watcher is not disabled (#656)" || true
        fi
    else
        bad "the hand edit of the generated pool never landed, so the watcher-disabled case proves nothing (#656)" || true
    fi
    if "$RIGFORGE" restart >/dev/null 2>&1 && _ep_away_state 90; then
        ok "the restart, not the file edit, delivered the generated pool change to the miner (#656)"
    else
        bad "the restart after the hand-edit did not deliver the generated pool change (#656)" || true
    fi
    _ep_edit_gen '.watch = true'
    if ! "$RIGFORGE" restart >/dev/null 2>&1 || ! _ep_away_state 90; then
        bad "watcher-on fixture never put the miner on the replacement pool — the hot-reload case cannot run (#656)" || true
    else
        pid=$(_ep_pid)
        if _ep_edit_gen '.pools = $p[0]' --slurpfile p "$GEN_POOLS" && jq -e --arg u "$EP_AWAY_URL" '.pools[0].url != $u' "$GEN_CFG" >/dev/null 2>&1 &&
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
