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
    bash "$0" substituted >"$TEST_WINDOW_DIR/substituted.log" 2>&1
    grep -q '^substituted response pathname preserved sentinel$' "$TEST_WINDOW_DIR/substituted.log"
    if bash "$0" allocation-failed >"$TEST_WINDOW_DIR/allocation-failed.log" 2>&1; then
        printf 'failed thermal response allocation unexpectedly succeeded\n' >&2
        exit 1
    fi
    grep -q 'could not allocate the thermal response file' "$TEST_WINDOW_DIR/allocation-failed.log"
    [ ! -e "$TEST_WINDOW_DIR/allocation-failed-posts" ]
    for mode in setup-edit-failed setup-apply-failed; do
        if bash "$0" "$mode" >"$TEST_WINDOW_DIR/$mode.log" 2>&1; then exit 1; fi
        grep -q 'could not enable the control path' "$TEST_WINDOW_DIR/$mode.log"
        [ ! -e "$TEST_WINDOW_DIR/$mode-posts" ]
        cmp "$TEST_WINDOW_DIR/$mode.json" "$TEST_WINDOW_DIR/$mode.json.original"
    done
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
    ! grep -q "$(printf '%064d' 0)" "$TEST_WINDOW_DIR"/*.log
    printf 'thermal refresh-window regressions: PASS\n'
    exit 0
fi
mode="$1"
CFG="$TEST_WINDOW_DIR/$mode.json"
# shellcheck disable=SC2034 # consumed by the sourced phase
RIGFORGE=control_test_apply
started=0 # the sourced phase shadows this clock origin in its dynamic scope
printf '{"DONATION":1,"max_temp_c":100,"control_port":8082,"api_port":8081}' >"$CFG"
source "$ROOT/tests/e2e-pithead-control.sh"
phase() { :; }
ok() { printf '%s\n' "$1"; }
bad() {
    printf '%s\n' "$1" >&2
    exit 1
}
# Exercise the actual shared editor, not a setup stub (#554).
eval "$(sed -n '/^set_cfg()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
jq() {
    local arg
    for arg in "$@"; do
        [[ "$arg" != *"$(printf '%064d' 0)"* ]] || return 91
    done
    if [ "$mode" = setup-edit-failed ] && [ "${1:-}" = --rawfile ]; then return 1; fi
    command jq "$@"
}
control_test_apply() {
    [ "$1" = apply ] || return 1
    cmp -s "$SAVED_CFG" "$CFG" && return 0 # restoration applies the saved config
    [ "$mode" != setup-apply-failed ] || return 1
    jq -e '
        .ACCESS_TOKEN == ("0" * 64) and .api == "enabled" and .control == "enabled" and
        .watchdog == "enabled" and .max_temp_c == 100 and .DONATION == 1 and
        .api_allow_from == "127.0.0.1/32"' "$CFG" >/dev/null
}
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
    [ "$1 $2 $3 $4 $5" = "-q --noproxy * --config -" ] || return 1
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
        if [ "$mode" = substituted ] && [[ "$data" != *DONATION* ]]; then
            LC_ALL=C ls -ld "$output" | cut -c1-10 >"$TEST_WINDOW_DIR/$mode-response-mode"
        fi
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
# Install the real EXIT snapshot/cleanup trap before running any failure case.
eval "$(sed -n '/^_cleanup()/,/^}/p; /^snapshot_config()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
# shellcheck disable=SC2034 # consumed by the extracted cleanup function
HAMMER_PIDS='' RIG_LOCK_HOLDER="$TEST_WINDOW_DIR/holder"
_restore_xmrig() { :; }
systemctl() { [ "$1" = is-active ]; }
cp "$CFG" "$CFG.original"
snapshot_config
PLANTED_RESPONSE=""
if [ "$mode" = substituted ]; then
    SENTINEL="$TEST_WINDOW_DIR/sentinel"
    printf 'preserve original bytes\n' >"$SENTINEL"
    rm() {
        command rm "$@"
        if [ "$*" = "-f ${resp:-}" ] && [ -z "$PLANTED_RESPONSE" ]; then
            ln -s "$SENTINEL" "$resp"
            PLANTED_RESPONSE="$resp"
        fi
    }
elif [ "$mode" = allocation-failed ]; then
    mktemp() {
        # The first allocation belongs to set_cfg; fail the later thermal response.
        if [ ! -e "$TEST_WINDOW_DIR/$mode-setup" ]; then
            : >"$TEST_WINDOW_DIR/$mode-setup"
            command mktemp "$@"
            return
        fi
        [ ! -e "$TEST_WINDOW_DIR/$mode-allocated" ] || return 1
        : >"$TEST_WINDOW_DIR/$mode-allocated"
        command mktemp "$@"
    }
fi
phase_control
_cleanup
trap - EXIT
cmp "$CFG" "$CFG.original"
if [ "$mode" = substituted ]; then
    [ -n "$PLANTED_RESPONSE" ] || bad "response substitution fixture did not run"
    command rm -f "$PLANTED_RESPONSE"
    [ "$(cat "$SENTINEL")" = 'preserve original bytes' ] || bad "substituted response pathname overwrote sentinel"
    [ "$(cat "$TEST_WINDOW_DIR/$mode-response-mode")" = '-rw-------' ] || bad "thermal response file was not secured"
    printf 'substituted response pathname preserved sentinel\n'
fi
