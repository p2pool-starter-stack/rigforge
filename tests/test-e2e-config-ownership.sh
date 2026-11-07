#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
source "$ROOT/tests/e2e-config-ownership.sh"
PASS=0 FAIL=0
phase() { :; }
ok() { printf 'ok %s\n' "$1" >>"$D/rows"; }
bad() {
    printf 'bad %s\n' "$1" >>"$D/rows"
    return 1
}
skip() { printf 'skip %s\n' "$1" >>"$D/rows"; }
GEN_CFG="$D/build/config.json"
CFG="$D/config.json"
RIGFORGE=co_rigforge

render() {
    jq -n --argjson k "$(jq '.pools[0].keepalive != false' "$CFG")" \
        '{autosave: false, watch: false, "donate-level": 0, pools: [(if $k then {} else {keepalive: false} end)]}' >"$GEN_CFG"
    if [ "$mode" = autosave ]; then jq '.autosave = true' "$GEN_CFG" >"$D/t" && cat "$D/t" >"$GEN_CFG"; fi
}
load() {
    printf '%s' "$(($(cat "$D/pid") + 1))" >"$D/pid"
    jq -r '."donate-level"' "$GEN_CFG" >"$D/loaded"
}
set_cfg() { render; }
systemctl() { cat "$D/pid"; }
sleep() {
    if [ "$mode" = hot-reload ]; then jq -r '."donate-level"' "$GEN_CFG" >"$D/loaded"; fi
    if [ "$mode" = rewrite ]; then printf ' ' >>"$GEN_CFG"; fi
}
live_hashrate() { printf '100'; }
api8080() { printf '{"donate_level":%s}' "$(cat "$D/loaded")"; }
co_rigforge() {
    case "$1 ${2:-}" in
    'stop ' | 'start ') ;;
    'restart ') [ "$mode" = no-load ] && printf '%s' "$(($(cat "$D/pid") + 1))" >"$D/pid" || load ;;
    'setup --dry-run') [ "$mode" = rebuild ] || echo 'skip the build' ;;
    'setup ')
        render
        echo 'XMRig already built at the pinned commit — recompile will be skipped.'
        [ "$mode" = no-restart ] || {
            echo 'Restarting XMRig service...'
            load
        }
        ;;
    esac
}

run_case() {
    mode=$1
    rm -rf "$D/build" "$D/rows"
    mkdir -p "$D/build"
    printf '{"pools":[{"url":"pool:3333"}]}' >"$CFG"
    printf '41' >"$D/pid"
    printf '#!/bin/sh\n' >"$D/build/xmrig"
    render
    load
    phase_config_ownership
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
expect pass ok 'autosave=false and watch=false'
expect pass ok 'byte-identical'
expect pass ok 'not hot-reloaded'
expect pass ok 'restart and no rebuild'
[ "$(grep -c '^bad' "$D/rows")" = 0 ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
[ "$(jq '.pools[0].keepalive' "$GEN_CFG")" = false ] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
run_case autosave
expect autosave bad 'does not set autosave'
run_case rewrite
expect rewrite bad 'changed after the miner started'
run_case hot-reload
expect hot-reload bad 'was hot-reloaded'
run_case no-load
expect no-load bad 'probe proves nothing'
run_case rebuild
expect rebuild bad 'plans a rebuild'
run_case no-restart
expect no-restart bad 'did not restart'

printf 'e2e config-ownership phase tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
