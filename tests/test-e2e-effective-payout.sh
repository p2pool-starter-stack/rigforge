#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
TMPDIR="$D"
GEN_CFG="$D/build/config.json"
CFG="$D/config.json"
RIGFORGE=rfstub
mode=pass
source "$ROOT/tests/e2e-effective-payout.sh"
PASS=0 FAIL=0
phase() { :; }
ok() { printf 'ok %s\n' "$1" >>"$D/rows"; }
bad() {
    printf 'bad %s\n' "$1" >>"$D/rows"
    return 1
}
conn="" uptime=0 failures=0
miner_load() {
    local url
    url=$(jq -r '.pools[0].url' "$GEN_CFG")
    if [ "$mode" = wrong-pool ]; then
        conn="elsewhere:3333" uptime=60 failures=0
    elif [ "$url" = "127.0.0.1:1" ]; then
        conn="" uptime=0 failures=0
    else
        conn="$url" uptime=60 failures=0
    fi
}
rfstub() {
    case "$1 ${2:-}" in
    'apply ')
        local watch=false
        [ "$mode" = watch-enabled ] && watch=true
        jq -n --argjson watch "$watch" --slurpfile c "$CFG" \
            '{watch: $watch, autosave: false, pools: $c[0].pools}' >"$GEN_CFG"
        [ "$mode" = stale-apply ] || {
            printf '%s' "$(($(cat "$D/pid") + 1))" >"$D/pid"
            miner_load
        }
        ;;
    'restart ')
        printf '%s' "$(($(cat "$D/pid") + 1))" >"$D/pid"
        miner_load
        ;;
    'stop ' | 'start ') ;;
    esac
}
set_cfg() {
    local tmp rc=0
    tmp=$(mktemp)
    if jq "${@:3}" "$1" "$CFG" >"$tmp" && [ -s "$tmp" ] && mv "$tmp" "$CFG"; then
        rfstub apply || rc=$?
    else
        rc=1
    fi
    rm -f "$tmp"
    [ "${2:-}" = soft ] && return "$rc"
    [ "$rc" = 0 ] || {
        echo "set_cfg failed" >&2
        return 1
    }
}
api8080() {
    [ "$mode" = apidown ] && return 1
    printf '{"connection":{"pool":"%s","uptime":%s,"failures":%s}}' "$conn" "$uptime" "$failures"
}
systemctl() { cat "$D/pid"; }
sleep() {
    if [ "$mode" = pid-walk ]; then
        printf '%s' "$(($(cat "$D/pid") + 1))" >"$D/pid"
    fi
    if [ "$mode" = hot-always ]; then
        miner_load
    elif [ "$mode" != no-hot ] && [ "$(jq -r '.watch' "$GEN_CFG")" = true ]; then
        miner_load
    fi
    return 0
}

run_case() {
    mode=$1
    rm -rf "$D/build" "$D/rows"
    mkdir -p "$D/build"
    if [ "$mode" = watchdog-on ]; then
        printf '{"pools":[{"url":"pool:3333","user":"rig.1"}],"DONATION":1,"watchdog":"enabled"}' >"$CFG"
    else
        printf '{"pools":[{"url":"pool:3333","user":"rig.1"}],"DONATION":1}' >"$CFG"
    fi
    printf '41' >"$D/pid"
    rfstub apply
    if [ "$mode" = stale-apply ]; then
        conn=$(jq -r '.pools[0].url' "$GEN_CFG") uptime=60 failures=0
    else
        miner_load
    fi
    phase_effective_payout
}

expect() {
    if grep -q "^$2 .*$3" "$D/rows"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s: want %s row matching %s\n' "$1" "$2" "$3" >&2
        cat "$D/rows" >&2
    fi
}

run_case pass
expect pass ok 'carries the explicit watch=false'
expect pass ok 'reads the miner, not the file'
expect pass ok 'moved the miner off the payout pool'
expect pass ok 'live connection back'
expect pass ok 'did not reach the running miner'
expect pass ok 'the restart, not the file edit, delivered'
expect pass ok 'edit hot-reloaded into'
expect pass ok 'overwrote the hand-enabled watcher'
expect pass ok 'reconciles the miner watchdog off'
[ "$(jq -r '.watchdog' "$CFG")" = disabled ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
[ "$(grep -c '^bad' "$D/rows")" = 0 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    cat "$D/rows" >&2
}
run_case watch-enabled
expect watch-enabled bad 'lacks the explicit watch=false'
run_case stale-apply
expect stale-apply ok 'carries the explicit watch=false'
expect stale-apply bad 'file and miner diverged'
run_case hot-always
expect hot-always bad 'the watcher is not disabled'
run_case no-hot
expect no-hot ok 'did not reach the running miner'
expect no-hot bad 'was not hot-reloaded into'
run_case apidown
expect apidown bad 'cannot be observed'
run_case wrong-pool
expect wrong-pool bad 'cannot be observed'
run_case pid-walk
expect pid-walk bad 'moved off the payout pool from a file edit alone'
expect pid-walk bad 'reached the miner only after a restart'
run_case watchdog-on
expect watchdog-on ok 'reconciles the miner watchdog off'
expect watchdog-on ok 'overwrote the hand-enabled watcher'
[ "$(jq -r '.watchdog' "$CFG")" = disabled ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

printf 'e2e effective-payout phase tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
