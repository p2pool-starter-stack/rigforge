#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
source "$ROOT/tests/e2e-pithead-control.sh"
CFG="$D/config.json"
export E2E_APPLIANCE_POLICY_DROPIN="$D/units/policy.conf"
phase() { :; }
ok() { printf '%s\n' "$1"; }
bad() {
    printf '%s\n' "$1" >&2
    exit 1
}
systemctl() {
    [ "$1" = daemon-reload ] || return 1
    printf 'reload\n' >>"$D/reloads"
}
sha256sum() { cksum "$@"; }
sleep() { :; }
_control_curl() {
    local output="" request="" arg url=""
    shift
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
        -o)
            output="$1"
            shift
            ;;
        --data-binary)
            request="${1#@}"
            shift
            ;;
        http://*) url="$arg" ;;
        esac
    done
    if [ -n "$output" ]; then
        jq -e '.pools == [{url:"pool.example:3333"}] and .watchdog_interval_min == 6' "$request" >/dev/null || return 1
        grep -qx 'Environment=RIGFORGE_APPLIANCE=1' "$E2E_APPLIANCE_POLICY_DROPIN" || return 1
        printf '{"change_id":"0123456789abcdef"}' >"$output"
        [ "$mode" != refused ] && printf 202 || printf 403
    elif [[ "$url" == */status* ]]; then
        case "$mode" in
        applied) printf '{"status":"applied"}' ;;
        wrong-reason) printf '{"status":"rejected","reason":"other"}' ;;
        timeout) printf '{"status":"pending"}' ;;
        *)
            [ "$mode" != mutated ] || printf '{} ' >"$CFG"
            printf '{"status":"rejected","reason":"rejected appliance-pools-read-only:change rig.json"}'
            ;;
        esac
    else return 1; fi
}
for mode in success refused applied wrong-reason timeout mutated; do
    printf '{"pools":[{"url":"pool.example:3333"}]}' >"$CFG"
    : >"$D/reloads"
    rc=0
    (appliance_pool_refusal synthetic 8082) >"$D/$mode.log" 2>&1 || rc=$?
    if [ "$mode" = success ]; then
        [ "$rc" = 0 ]
        grep -q 'appliance pool edit rejected with ownership reason and config unchanged' "$D/$mode.log"
    else
        [ "$rc" != 0 ]
    fi
    [ ! -e "$E2E_APPLIANCE_POLICY_DROPIN" ]
    [ "$(wc -l <"$D/reloads" | tr -d ' ')" = 2 ]
done
printf 'appliance pool control harness: PASS\n'
