#!/usr/bin/env bash
# #546: execute the control phase with fake APIs, units and time, never against the host.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" = 0 ]; then
    TEST_WINDOW_DIR=$(mktemp -d)
    export TEST_WINDOW_DIR
    trap 'rm -rf "$TEST_WINDOW_DIR"' EXIT
    bash "$0" fresh >"$TEST_WINDOW_DIR/fresh.log" 2>&1
    grep -q 'new direct sister-API summary within' "$TEST_WINDOW_DIR/fresh.log"
    grep -q '^finish-window elapsed=30[0-9]' "$TEST_WINDOW_DIR/fresh.log"
    grep -q '^POST thermal=99$' "$TEST_WINDOW_DIR/fresh-posts"
    grep -q '^profile started$' "$TEST_WINDOW_DIR/fresh.log"
    for mode in stale late oldstamp rejected; do
        if bash "$0" "$mode" >"$TEST_WINDOW_DIR/$mode.log" 2>&1; then
            printf '%s unexpectedly passed freshness assertion\n' "$mode" >&2
            exit 1
        fi
        if [ "$mode" != rejected ]; then
            grep -q 'feed stale after 90s' "$TEST_WINDOW_DIR/$mode.log"
            grep -q '^finish-window elapsed=30[0-9]' "$TEST_WINDOW_DIR/$mode.log"
        fi
    done
    printf 'thermal refresh-window regressions: PASS\n'
    exit 0
fi
mode="$1"
CFG="$TEST_WINDOW_DIR/$mode.json"
# shellcheck disable=SC2034 # consumed by the sourced phase
RIGFORGE="$ROOT/rigforge.sh"
started=0 # the sourced phase shadows this clock origin in its dynamic scope
printf '{"DONATION":1,"max_temp_c":100,"control_port":8082,"api_port":8081}' >"$CFG"
source "$ROOT/tests/e2e-pithead-control.sh"
phase() { :; }
ok() { printf '%s\n' "$1"; }
bad() {
    printf '%s\n' "$1" >&2
    exit 1
}
set_cfg() { :; }
xxd() {
    cat >/dev/null
    printf '%064d\n' 0
}
sleep() { SECONDS=$((SECONDS + $1)); }
date() { printf '2026-09-30T00:00:00Z\n'; }
refresh_profile_start() { printf 'profile started\n'; }
refresh_profile_state() { :; }
refresh_profile_finish() { printf 'finish-window elapsed=%s\n' "$((SECONDS - started))"; }
curl() {
    [[ "$*" != *Bearer* ]] || return 1
    [ "$1 $2" = "--config -" ] || return 1
    grep -Eq '^header = "Authorization: Bearer [0-9a-f]{64}"$' || return 1
    local output="" data="" url="" arg temp=100 stamp='2026-09-30T00:00:00Z'
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
        -o)
            output="$1"
            shift
            ;;
        -d)
            data="$1"
            shift
            ;;
        http://*) url="$arg" ;;
        esac
    done
    if [ -n "$output" ]; then
        if [[ "$data" == *DONATION* ]]; then
            jq '.DONATION=2' "$CFG" >"$CFG.tmp"
            mv "$CFG.tmp" "$CFG"
        else
            printf 'POST thermal=%s\n' "$(printf '%s' "$data" | jq -r '.max_temp_c')" >>"$TEST_WINDOW_DIR/$mode-posts"
            if [ "$mode" = rejected ]; then
                printf '{}' >"$output"
                printf 403
                return 0
            fi
        fi
        printf '{"change_id":"fixture"}' >"$output"
        printf 202
    elif [[ "$url" == */status* ]]; then
        printf '{"status":"applied"}'
    else
        if [ "$mode" != stale ] && { [ "$mode" != late ] || [ "$((SECONDS - started))" -ge 95 ]; }; then
            temp=99
            [ "$mode" = oldstamp ] || stamp='2026-09-30T00:00:01Z'
        fi
        printf '{"generated_at":"%s","rigforge":{"watchdog":{"max_temp_c":%s}}}' "$stamp" "$temp"
    fi
}
phase_control
