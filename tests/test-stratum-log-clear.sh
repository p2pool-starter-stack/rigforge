#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${1:-$ROOT/tests/e2e-pithead.sh}"
if [ "$#" -lt 2 ]; then
    STRATUM_CLEAR_DIR=$(mktemp -d)
    export STRATUM_CLEAR_DIR
    trap 'rm -rf "$STRATUM_CLEAR_DIR"' EXIT
    for initial in active stopped; do
        for stage in 1 2 3; do
            case_dir="$STRATUM_CLEAR_DIR/$initial-$stage"
            mkdir -p "$case_dir"
            result=0
            bash "$0" "$HARNESS" "$stage" "$initial" >"$case_dir/output" 2>&1 || result=$?
            [ "$result" -eq 2 ] || {
                printf 'stratum clear stage %s (%s): expected exit 2, got %s\n' "$stage" "$initial" "$result" >&2
                exit 1
            }
            grep -q 'e2e-pithead: could not clear worker log for fresh mining evidence\.' "$case_dir/output"
            [ "$(cat "$case_dir/edits")" -eq "$stage" ]
            [ "$(grep -c '^restart$' "$case_dir/events" || true)" -eq "$((stage - 1))" ]
            case "$stage" in 1) expected_ok=0 ;; 2) expected_ok=1 ;; 3) expected_ok=3 ;; esac
            [ "$(grep -c '^ok:' "$case_dir/events" || true)" -eq "$expected_ok" ]
            awk '/^clear-failed:/ {failed=1; next} failed && /^(restart|ok:|wait-for-job)/ {exit 1} END {if (!failed) exit 1}' "$case_dir/events"
            cmp "$case_dir/config.json" "$case_dir/original.json"
            [ "$(cat "$case_dir/service")" = "$initial" ]
            [ "$(grep -c '^restore-applied$' "$case_dir/events")" -eq 1 ]
            [ ! -e "$(cat "$case_dir/snapshot-path")" ]
            ! grep -q 'synthetic-clear-password' "$case_dir/output"
            printf 'stratum log-clear stage %s (%s): PASS\n' "$stage" "$initial"
        done
    done
    exit 0
fi
TARGET_CLEAR_STAGE="$2" initial="$3"
case_dir="$STRATUM_CLEAR_DIR/$initial-$TARGET_CLEAR_STAGE"
CFG="$case_dir/config.json" WLOG="$case_dir/xmrig.log"
RIGFORGE=stratum_clear_rigforge PITHEAD_URL=fixture.invalid:3333 E2E_STRATUM_PASS=synthetic-clear-password
SAVED_CFG='' SAVED_XMRIG_ACTIVE=0 HAMMER_PIDS='' E2E_EXIT_RC=0 FAIL=0
RIG_LOCK_HOLDER="$case_dir/holder"
printf '{"DONATION":1,"pools":[{"url":"original.invalid:3333","user":"synthetic-worker","pass":"original"}]}' >"$CFG"
cp "$CFG" "$case_dir/original.json"
printf '%s' "$initial" >"$case_dir/service"
printf '0\n' >"$case_dir/edits"
: >"$case_dir/events"
printf 'new job from previous\naccepted (1/0)\n' >"$WLOG"
eval "$(sed -n '/^phase_stratum_auth()/,/^}/p; /^wait_for_job()/,/^}/p; /^set_cfg()/,/^}/p; /^die()/,/^}/p; /^bad()/,/^}/p; /^_cleanup()/,/^}/p; /^_restore_xmrig()/,/^}/p; /^snapshot_config()/,/^}/p' "$HARNESS")"
phase() { :; }
ok() { printf 'ok:%s\n' "$1" >>"$case_dir/events"; }
_connect_bad() { bad "$1"; }
refresh_profile_finish() { :; }
sleep() { :; }
systemctl() { [ "$*" = 'is-active --quiet xmrig' ] && [ "$(cat "$case_dir/service")" = active ]; }
stratum_clear_rigforge() {
    local edit
    case "$1" in
    apply)
        if cmp -s "$CFG" "$case_dir/original.json"; then
            printf 'restore-applied\n' >>"$case_dir/events"
            return 0
        fi
        edit=$(($(cat "$case_dir/edits") + 1))
        printf '%s\n' "$edit" >"$case_dir/edits"
        if [ "$edit" -eq "$TARGET_CLEAR_STAGE" ]; then
            rm -f "$WLOG"
            mkdir "$WLOG"
            printf 'clear-failed:%s\n' "$edit" >>"$case_dir/events"
        fi
        ;;
    restart)
        printf 'restart\n' >>"$case_dir/events"
        [ ! -d "$WLOG" ] || rmdir "$WLOG"
        printf active >"$case_dir/service"
        if [ "$(jq -r '.pools[0].pass' "$CFG")" = wrong-114 ]; then
            printf 'permission denied\n' >"$WLOG"
        else
            printf 'new job from fixture\n' >"$WLOG"
        fi
        ;;
    start) printf active >"$case_dir/service" ;;
    stop) printf stopped >"$case_dir/service" ;;
    *) return 1 ;;
    esac
}
snapshot_config
printf '%s' "$SAVED_CFG" >"$case_dir/snapshot-path"
phase_stratum_auth required
