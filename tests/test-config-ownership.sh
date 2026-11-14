#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (%s)\n' "$1" "$2"
}

assert_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected [$3], got [$2]"
    fi
}

assert_nonzero() {
    if [ "$2" -ne 0 ]; then
        pass "$1"
    else
        fail "$1" 'expected a non-zero exit'
    fi
}

assert_log_has() {
    if grep -Fq "$2" "$3"; then
        pass "$1"
    else
        fail "$1" "missing [$2]"
    fi
}

assert_log_lacks() {
    if grep -Fq "$2" "$3"; then
        fail "$1" "unexpected [$2]"
    else
        pass "$1"
    fi
}

run_setup() {
    local case_dir="$1" donation="$2" service_state="$3" reboot="$4"
    local render_rc="${5:-0}" action_rc="${6:-0}"
    mkdir -p "$case_dir/worker/xmrig/build" "$case_dir/systemd"
    : >"$case_dir/calls.log"
    (
        set -Eeuo pipefail
        export RIGFORGE_HOME="$case_dir/home"
        export TEST_CALL_LOG="$case_dir/calls.log"
        export TEST_DONATION="$donation"
        export TEST_SERVICE_STATE="$service_state"
        export TEST_REBOOT_REQUIRED="$reboot"
        export TEST_RENDER_RC="$render_rc"
        export TEST_ACTION_RC="$action_rc"
        source "$SCRIPT"

        SCRIPT_DIR="$ROOT"
        WORKER_ROOT="$case_dir/worker"
        SYSTEMD_DIR="$case_dir/systemd"
        OS_TYPE=Linux
        RIGFORGE_APPLIANCE=1
        SERVICE_NAME=xmrig
        REAL_USER=tester
        MINER_USER=""
        ACCESS_TOKEN=""
        THREADS_CAP=""
        POOLS_JSON='[]'
        DONATION="$TEST_DONATION"
        XMRIG_REBUILD=false
        REBOOT_REQUIRED="$TEST_REBOOT_REQUIRED"

        _persist_appliance_mode() { :; }
        check_prerequisites() { :; }
        ensure_config_exists() { :; }
        parse_config() { :; }
        decide_rebuild() { XMRIG_REBUILD=false; }
        prepare_workspace() { cd "$WORKER_ROOT/xmrig/build"; }
        install_dependencies() { :; }
        compile_xmrig() { :; }
        tune_kernel() { REBOOT_REQUIRED="$TEST_REBOOT_REQUIRED"; }
        configure_limits() { :; }
        install_autotune() { :; }
        install_watchdog() { :; }
        install_api() { :; }
        install_control() { :; }
        install_api_firewall() { :; }
        link_cli() { :; }
        _reown_worker() { :; }
        finish_deployment() { :; }
        _cpu_missing_isa() { :; }
        lscpu() { printf 'Model name: Test CPU\n'; }
        hostname() { :; }
        envsubst() {
            if [ "$TEST_RENDER_RC" -ne 0 ]; then
                cat >/dev/null
                return "$TEST_RENDER_RC"
            fi
            cat
        }
        systemctl() {
            printf '[systemctl] %s\n' "$*" >>"$TEST_CALL_LOG"
            if [ "${1:-}" = is-active ]; then
                [ "$TEST_SERVICE_STATE" = active ]
                return
            fi
            case " $* " in
            *' start '* | *' restart '*) return "$TEST_ACTION_RC" ;;
            esac
            return 0
        }
        sudo() { "$@"; }

        main
    ) >"$case_dir/output.log" 2>&1
}

run_rc() {
    set +e
    run_setup "$@"
    local rc=$?
    set -e
    printf '%s' "$rc"
}

echo '== config ownership and setup service transitions (#529) =='

BASE="$TASK_TMP/base"
rc="$(run_rc "$BASE" 0 inactive false)"
assert_eq 'fresh setup succeeds' "$rc" 0
assert_eq 'generated config disables autosave' "$(jq -r '.autosave' "$BASE/worker/xmrig/build/config.json")" false
assert_eq 'generated config disables file watching' "$(jq -r '.watch' "$BASE/worker/xmrig/build/config.json")" false
assert_log_has 'fresh config restarts and starts the service' '[systemctl] restart xmrig.service' "$BASE/calls.log"

rc="$(run_rc "$BASE" 1 active false)"
assert_eq 'changed-config setup succeeds' "$rc" 0
assert_log_has 'changed config restarts a running service' '[systemctl] restart xmrig.service' "$BASE/calls.log"

rc="$(run_rc "$BASE" 1 active false)"
assert_eq 'unchanged setup succeeds' "$rc" 0
assert_log_lacks 'unchanged config avoids a restart' '[systemctl] restart xmrig.service' "$BASE/calls.log"
assert_log_has 'unchanged setup still ensures the service is running' '[systemctl] start xmrig.service' "$BASE/calls.log"

printf '\n' >>"$BASE/worker/xmrig/build/config.json"
rc="$(run_rc "$BASE" 1 active false)"
assert_eq 'byte-edited setup succeeds' "$rc" 0
assert_log_has 'byte-only config drift restarts a running service' '[systemctl] restart xmrig.service' "$BASE/calls.log"

jq 'del(.watch) | .autosave = true' "$BASE/worker/xmrig/build/config.json" >"$BASE/legacy.json"
mv "$BASE/legacy.json" "$BASE/worker/xmrig/build/config.json"
rc="$(run_rc "$BASE" 1 active false)"
assert_eq 'legacy-config migration succeeds' "$rc" 0
assert_log_has 'legacy ownership defaults trigger one restart' '[systemctl] restart xmrig.service' "$BASE/calls.log"

INACTIVE="$TASK_TMP/inactive"
run_rc "$INACTIVE" 0 inactive false >/dev/null
rc="$(run_rc "$INACTIVE" 1 inactive false)"
assert_eq 'changed-config inactive setup succeeds' "$rc" 0
assert_log_has 'changed config restarts and starts an inactive service' '[systemctl] restart xmrig.service' "$INACTIVE/calls.log"

REBOOT="$TASK_TMP/reboot"
run_rc "$REBOOT" 0 inactive false >/dev/null
rc="$(run_rc "$REBOOT" 1 active true)"
assert_eq 'reboot-deferred setup succeeds' "$rc" 0
assert_log_lacks 'reboot-deferred setup does not start' '[systemctl] start xmrig.service' "$REBOOT/calls.log"
assert_log_lacks 'reboot-deferred setup does not restart' '[systemctl] restart xmrig.service' "$REBOOT/calls.log"

RENDER="$TASK_TMP/render"
run_rc "$RENDER" 0 inactive false >/dev/null
rc="$(run_rc "$RENDER" 1 active false 23)"
assert_nonzero 'unit render failure propagates' "$rc"
assert_log_lacks 'unit render failure does not restart' '[systemctl] restart xmrig.service' "$RENDER/calls.log"

ACTION="$TASK_TMP/action"
run_rc "$ACTION" 0 inactive false >/dev/null
rc="$(run_rc "$ACTION" 1 active false 0 19)"
assert_nonzero 'service action failure propagates' "$rc"
assert_log_has 'failed service action was attempted' '[systemctl] restart xmrig.service' "$ACTION/calls.log"

printf 'config ownership tests: %s passed, %s failed\n' "$PASS" "$FAIL"
bash "$ROOT/tests/test-e2e-config-ownership.sh" && [ "$FAIL" -eq 0 ]
