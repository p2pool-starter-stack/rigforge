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
    elif [ "$mode" = alt-never-live ] && [ "$url" = "${E2E_ALT_POOL_URL:-}" ]; then
        conn="" uptime=0 failures=1
    elif [ "$mode" = away-elsewhere ] && [ "$url" = "127.0.0.1:1" ]; then
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
        local wd
        wd=$([ "$(jq -r '.watchdog // "disabled"' "$CFG")" = enabled ] && echo 1 || echo 0)
        [ "$mode" = wd-stuck ] && [ "$(cat "$D/wd")" = 1 ] && wd=1
        [ "$mode" = wd-no-restore ] && [ "$(cat "$D/wd")" = 0 ] && wd=0
        printf '%s' "$wd" >"$D/wd"
        [ "$mode" = stale-apply ] || [ "$mode" = alt-stale ] || {
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
    printf '{"connection":{"pool":"%s","uptime":%s,"failures":%s},"hashrate":{"total":[%s,0,0]}}' "$conn" "$uptime" "$failures" "$([ "$uptime" -gt 0 ] && [ "$mode" != alt-no-hash ] && echo 100 || echo 0)"
}
systemctl() {
    case "$*" in
    *is-active*) [ "$(cat "$D/wd")" = 1 ] ;;
    *) [ "$mode" = pid-blind ] || cat "$D/pid" ;;
    esac
}
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
    if [ "$mode" = watchdog-on ] || [ "$mode" = wd-stuck ] || [ "$mode" = wd-no-restore ]; then
        printf '{"pools":[{"url":"pool:3333","user":"rig.1"}],"DONATION":1,"watchdog":"enabled"}' >"$CFG"
    else
        printf '{"pools":[{"url":"pool:3333","user":"rig.1"}],"DONATION":1}' >"$CFG"
    fi
    printf '41' >"$D/pid"
    printf '1' >"$D/wd"
    unset E2E_ALT_POOL_URL E2E_ALT_POOL_PASS
    case "$mode" in alt*) export E2E_ALT_POOL_URL=alt-pool:3333 E2E_ALT_POOL_PASS=x ;; esac
    rfstub apply
    if [ "$mode" = stale-apply ] || [ "$mode" = alt-stale ]; then
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
expect pass ok 'watchdog stands restored to its original disabled'
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
expect watchdog-on ok 'watchdog stands restored to its original enabled'
[ "$(jq -r '.watchdog' "$CFG")" = enabled ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
run_case wd-stuck
expect wd-stuck bad 'watchdog could not be reconciled off or its timer is still active'
run_case wd-no-restore
expect wd-no-restore ok 'reconciles the miner watchdog off'
expect wd-no-restore bad 'watchdog was not restored to its original enabled'
run_case alt
expect alt ok 'moved the miner off the payout pool'
expect alt ok 'edit hot-reloaded into'
expect alt ok 'did not reach the running miner'
[ "$(grep -c '^bad' "$D/rows")" = 0 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    cat "$D/rows" >&2
}
run_case alt-never-live
expect alt-never-live bad 'file and miner diverged.*summary: ? 0 1'
run_case alt-stale
expect alt-stale bad 'file and miner diverged.*summary: pool:3333 60 0'
run_case alt-no-hash
expect alt-no-hash bad 'not hashing on the payout pool'
run_case pid-blind
expect pid-blind bad 'PID cannot be read from systemd'
run_case away-elsewhere
expect away-elsewhere ok 'moved the miner off the payout pool'

printf 'e2e effective-payout phase tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
