#!/usr/bin/env bash
# Hardware-free execution of the actual readiness helper, phase and EXIT restoration.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
source "$ROOT/tests/e2e-pithead-tokens.sh"
source "$ROOT/tests/e2e-pithead-control.sh"
for fn in _restore_xmrig _cleanup snapshot_config set_cfg; do
    eval "$(sed -n "/^$fn()/,/^}/p" "$ROOT/tests/e2e-pithead.sh")"
done
check() { [ "$1" = "$2" ] || {
    printf 'FAIL: %s (got %s, expected %s)\n' "$3" "$1" "$2" >&2
    exit 1
}; }
# Every child advances a virtual clock; no network, systemd, or real sleep is used.
sleep() { SECONDS=$((SECONDS + $1)); }
phase() { :; }
ok() { printf 'PASS: %s\n' "$1"; }
bad() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}
refresh_profile_finish() { :; }
rigforge_stub() { :; }
systemctl() { return 0; }

curl() {
    local url="${*: -1}" output='' bearer=0 body=0 n=0 arg
    printf '%s\n' "$*" >>"$CASE_DIR/argv"
    while [ "$#" -gt 0 ]; do
        arg=$1
        shift
        case "$arg" in
        --config)
            [ "$1" = - ] || return 99
            shift
            [ -n "$(cat)" ] || return 99
            bearer=1
            ;;
        -H)
            [[ "$1" != Authorization:* ]] || return 99
            shift
            ;;
        -o)
            output=$1
            shift
            ;;
        -fsS) body=1 ;;
        esac
    done
    if [ "$bearer" = 0 ]; then
        # Refuse POST/credentials/config inputs in every readiness probe.
        case "$url" in */health | */status) ;; *) return 99 ;; esac
        if [[ "$url" == *:8082/status ]] && [ "$(jq '.ACCESS_TOKENS | length' "$CFG")" != 0 ]; then
            n=$(cat "$CASE_DIR/setup-probes")
            printf '%s' "$((n + 1))" >"$CASE_DIR/setup-probes"
            if [ "$SCENARIO" = delayed ] && [ "$n" -lt 2 ]; then
                printf 000
                return 7
            fi
            if [ "$SCENARIO" = setup-down ]; then
                printf 000
                return 7
            fi
        fi
        if [[ "$url" == *:8082/status ]] && [ "$(jq '.ACCESS_TOKENS | length' "$CFG")" = 0 ]; then
            n=$(cat "$CASE_DIR/probes")
            printf '%s' "$((n + 1))" >"$CASE_DIR/probes"
            case "$SCENARIO" in
            delayed) [ "$n" -ge 4 ] || {
                printf 000
                return 7
            } ;;
            down)
                printf 'synthetic-private-error\n' >&2
                printf 000
                return 7
                ;;
            timeout)
                printf 000
                return 28
                ;;
            open)
                printf 200
                return 0
                ;;
            denied)
                printf 403
                return 0
                ;;
            error)
                printf 000
                return 60
                ;;
            esac
        fi
        printf 401
    elif [[ "$url" == *:8080/* ]]; then
        printf 403
    elif [ "$body" = 1 ]; then
        [[ "$url" != */status\?* ]] || {
            printf '{"status":"applied"}'
            return
        }
        printf '{}'
    elif [[ "$url" == */apply ]]; then
        if [ "$(jq '.ACCESS_TOKENS | length' "$CFG")" = 0 ]; then
            printf 'post\n' >>"$CASE_DIR/revoked-posts"
            [ "$SCENARIO" != accepted ] || {
                printf 202
                return
            }
            printf 401
        else
            if [ "$SCENARIO" = delayed ] && [ "$(cat "$CASE_DIR/setup-probes")" -lt 3 ]; then
                printf 000
                return 7
            fi
            printf '{"change_id":"0123456789abcdef"}' >"$output"
            printf 202
        fi
    else
        printf 401
    fi
}
for SCENARIO in delayed down timeout open denied error accepted setup-down; do
    CASE_DIR="$TASK_TMP/$SCENARIO"
    mkdir -p "$CASE_DIR"
    CFG="$CASE_DIR/config"
    printf '%s\n' '{"DONATION":1,"ACCESS_TOKEN":"original","ACCESS_TOKENS":{"original":"original"}}' >"$CFG"
    cp "$CFG" "$CASE_DIR/original"
    printf 0 >"$CASE_DIR/probes"
    printf 0 >"$CASE_DIR/setup-probes"
    : >"$CASE_DIR/revoked-posts"
    : >"$CASE_DIR/argv"
    rc=0
    (
        unset SECONDS # Unsetting removes Bash's wall-clock behavior before the fake clock.
        SECONDS=0
        SAVED_CFG='' SAVED_XMRIG_ACTIVE=0 HAMMER_PIDS='' E2E_EXIT_RC=0
        RIG_LOCK_HOLDER="$CASE_DIR/holder" RIGFORGE=rigforge_stub
        snapshot_config
        phase_access_tokens
    ) >"$CASE_DIR/log" 2>&1 || rc=$?
    cmp -s "$CFG" "$CASE_DIR/original" || {
        echo 'FAIL: EXIT did not restore original bytes' >&2
        exit 1
    }
    posts=$(wc -l <"$CASE_DIR/revoked-posts" | tr -d ' ')
    probes=$(cat "$CASE_DIR/probes")
    case "$SCENARIO" in
    delayed)
        check "$rc:$probes:$posts" 0:5:1 'transient refusal recovers before one revocation POST'
        check "$(cat "$CASE_DIR/setup-probes")" 3 'setup waits before authenticated POST'
        grep -Eq 'service=control stage=setup elapsed_s=2' "$CASE_DIR/log"
        grep -Eq 'service=control stage=revocation elapsed_s=4' "$CASE_DIR/log"
        grep -Eq 'a revoked ACCESS_TOKENS entry stops authenticating :8082' "$CASE_DIR/log"
        ;;
    down | timeout)
        check "$rc:$probes:$posts" 1:30:0 'unreachable active listener fails boundedly before POST'
        grep -Eq 'elapsed_s=30 transport_rc=(7|28) http_code=000 active=1' "$CASE_DIR/log"
        ! grep -Eq synthetic-private-error "$CASE_DIR/log"
        ;;
    open | denied | error)
        check "$rc:$probes:$posts" 1:1:0 'unexpected HTTP/TLS error fails without retry or POST'
        ;;
    setup-down)
        check "$rc:$probes:$posts" 1:0:0 'setup failure stops before auth assertions'
        check "$(cat "$CASE_DIR/setup-probes")" 30 'setup deadline is bounded'
        grep -Eq 'service=control stage=setup elapsed_s=30 transport_rc=7 http_code=000 active=1' "$CASE_DIR/log"
        ;;
    accepted)
        check "$rc:$probes:$posts" 1:1:1 'readiness never substitutes for revoked-bearer rejection'
        grep -Eq 'revoked entry still answered 202 on :8082' "$CASE_DIR/log"
        ;;
    esac
    # Plain probes use curl's isolated config and proxy settings, with no bearer.
    grep -E 'http://127.0.0.1:8082/status$' "$CASE_DIR/argv" | while IFS= read -r probe; do
        [[ "$probe" == '-q --noproxy * -s -o /dev/null -w %{http_code} --max-time '* ]] || exit 1
        [[ "$probe" != *Authorization* && "$probe" != *POST* ]] || exit 1
    done
    printf 'PASS: %s (including byte-identical EXIT restoration)\n' "$SCENARIO"
done
# Force a clock tick between the loop condition and timeout calculation. No curl
# may run with max-time 0, which would disable its deadline entirely.
rc=0
(
    unset SECONDS
    SECONDS=0
    set -T
    trap 'if [[ "$BASH_COMMAND" == "remaining="* ]]; then SECONDS=30; fi' DEBUG
    _access_tokens_ready control 8082 revocation
) >"$TASK_TMP/deadline.log" 2>&1 || rc=$?
check "$rc" 1 'deadline tick refuses an unlimited curl timeout'
grep -Eq 'elapsed_s=30 transport_rc=0 http_code=000 active=1' "$TASK_TMP/deadline.log"
printf 'PASS: deadline tick before curl\n'
