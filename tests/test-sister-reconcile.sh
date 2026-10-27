#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317,SC2218
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
source "$SCRIPT"
OS_TYPE=Linux
SYSTEMD_DIR="$TEST_DIR/systemd"
SCRIPT_DIR="$ROOT"
API_BIND=0.0.0.0
API_PORT=8081
API_MODE=enabled
REAL_USER=rfop
mkdir -p "$SYSTEMD_DIR"
sudo() { "$@"; }
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
sleep() { :; }
systemctl() {
    printf '%s\n' "$*" >>"$TEST_DIR/calls"
    [ "$*" != "${FAIL_COMMAND:-none}" ]
}
curl() {
    printf '%s\n' "$*" >"$TEST_DIR/curl-args"
    printf '%s' "${HTTP_CODE:-401}"
    return "${HTTP_RC:-0}"
}
if [ "${2:-all}" = all ]; then
    for HTTP_CODE in 200 401 503; do _wait_sister_api; done
    for HTTP_CODE in 000 403 500; do
        if _wait_sister_api >"$TEST_DIR/result" 2>&1; then exit 1; fi
        grep -q 'not active and listening' "$TEST_DIR/result"
    done
    HTTP_CODE=200 HTTP_RC=7
    if _wait_sister_api >/dev/null 2>&1; then exit 1; fi
    HTTP_RC=0
    FAIL_COMMAND='is-active --quiet rigforge-api.service'
    if _wait_sister_api >/dev/null 2>&1; then exit 1; fi
    FAIL_COMMAND=none
    API_BIND=::
    _wait_sister_api
    grep -Fq 'http://[::1]:8081/health' "$TEST_DIR/curl-args"
    API_BIND=127.0.0.1
    _wait_sister_api
    grep -Fq 'http://127.0.0.1:8081/health' "$TEST_DIR/curl-args"
    command() {
        if [ "$*" = '-v python3' ]; then
            [ "${MISSING_PYTHON:-0}" != 1 ]
            return
        fi
        builtin command "$@"
    }
    MISSING_PYTHON=1
    if install_api >"$TEST_DIR/result" 2>&1; then exit 1; fi
    grep -q 'needs python3' "$TEST_DIR/result"
    MISSING_PYTHON=0
    for FAIL_COMMAND in none daemon-reload \
        'enable rigforge-api-refresh.timer' 'enable rigforge-api.service' \
        'restart rigforge-api-refresh.timer rigforge-api.service' \
        'start rigforge-api-refresh.service'; do
        if install_api >"$TEST_DIR/result" 2>&1; then
            [ "$FAIL_COMMAND" = none ]
        else
            [ "$FAIL_COMMAND" != none ]
        fi
    done
    FAIL_COMMAND=none
    HTTP_CODE=000
    if install_api >"$TEST_DIR/result" 2>&1; then exit 1; fi
    API_MODE=disabled
    install_api
fi
parse_config() { :; }
_apply_runtime() { :; }
install_autotune() { :; }
install_watchdog() { return "${WATCHDOG_RC:-0}"; }
install_api() { return "$API_RC"; }
install_control() { printf control >"$TEST_DIR/later"; }
install_api_firewall() { :; }
_autotune_apply_notice() { :; }
_stamp_config_meta() { :; }
_apply_pool_check() { :; }
for WATCHDOG_RC in 0 1; do
    for API_RC in 0 1; do
        if apply >"$TEST_DIR/result" 2>&1; then
            [ "$WATCHDOG_RC:$API_RC" = 0:0 ] || {
                echo "apply returned success despite a failed reconcile" >&2
                exit 1
            }
        else
            [ "$WATCHDOG_RC:$API_RC" != 0:0 ]
        fi
        [ -f "$TEST_DIR/later" ]
        if [ "$API_RC" = 1 ]; then
            grep -q 'configured sister API could NOT be reconciled' "$TEST_DIR/result"
            [ "$RIGFORGE_APPLY_FAIL_REASON" = 'could not start the sister API' ]
        fi
    done
done
source "$ROOT/tests/e2e-pithead-control.sh"
systemctl() { printf 'failed\n'; }
journalctl() { printf 'Permission denied: fixture-private-value\nTraceback: fixture-private-value\n'; }
_control_startup_diagnostics >"$TEST_DIR/diagnostics" 2>&1
grep -q 'unit=rigforge-control active=failed' "$TEST_DIR/diagnostics"
grep -q 'receiver-startup: Permission denied' "$TEST_DIR/diagnostics"
grep -q 'receiver-startup: Traceback' "$TEST_DIR/diagnostics"
! grep -q 'fixture-private-value' "$TEST_DIR/diagnostics"
printf 'sister API reconcile regressions: PASS\n'
