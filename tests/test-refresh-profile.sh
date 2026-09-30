#!/usr/bin/env bash
# Hardware-free checks of #546's timing, output boundary and runtime override lifecycle.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR=$(mktemp -d)
trap 'rm -rf "$CASE_DIR"' EXIT
check() { if ! "$@"; then
    printf 'refresh-profile regression failed: %s\n' "$*" >&2
    exit 1
fi; }
export TEST_PAYLOAD="$CASE_DIR/payload"
cat >"$CASE_DIR/fixture.sh" <<EOF_FIXTURE
source "$ROOT/rigforge.sh"
parse_config() { :; }
_health_json() { sleep 0.05; printf 'private-probe-value'; return "\${TEST_PROBE_RC:-0}"; }
api_refresh() { parse_config; _health_json >"\$TEST_PAYLOAD"; }
EOF_FIXTURE
bash "$ROOT/tests/e2e-api-refresh-profile.sh" "$CASE_DIR/fixture.sh" 2>"$CASE_DIR/measurements"
check grep -q '^refresh-profile: .*helper=_health_json event=begin ' "$CASE_DIR/measurements"
check grep -q '^refresh-profile: .*helper=api_refresh event=end .*rc=0$' "$CASE_DIR/measurements"
check test "$(cat "$TEST_PAYLOAD")" = private-probe-value
check bash -c '! grep -q private-probe-value "$1"' -- "$CASE_DIR/measurements"
# A 50ms probe must be visible below one second, rather than rounded to zero as in job 1876.
duration=$(sed -n 's/.*helper=_health_json event=end .*duration_ns=\([0-9]*\) rc=0/\1/p' "$CASE_DIR/measurements")
check test "$duration" -ge 1000000
check test "$((duration % 1000000000))" -ne 0
if TEST_PROBE_RC=7 bash "$ROOT/tests/e2e-api-refresh-profile.sh" "$CASE_DIR/fixture.sh" 2>"$CASE_DIR/failed"; then
    echo 'failed helper unexpectedly succeeded' >&2
    exit 1
else
    check test "$?" = 7
fi
check grep -q 'helper=_health_json event=begin' "$CASE_DIR/failed"
check bash -c '! grep -q "helper=api_refresh event=end" "$1"' -- "$CASE_DIR/failed"
# Stubs below simulate systemd/journal; never issue commands against host units.
export REFRESH_PROFILE_UNIT_ROOT="$CASE_DIR/units"
RIGFORGE="$ROOT/rigforge.sh"
source "$ROOT/tests/e2e-refresh-window.sh"
systemctl() { printf '%s\n' "$*" >>"$CASE_DIR/calls"; }
journalctl() {
    [ "$1" != --sync ] || return 0
    cat "$CASE_DIR/measurements"
    printf 'sensitive unit output must not escape\n'
}
refresh_profile_start
owned="$REFRESH_PROFILE_DROPIN"
check grep -q '^ExecStart=/bin/bash ' "$owned"
check bash -c '! grep -Eq "^(Nice|IOSchedulingClass|TimeoutStartSec)=" "$1"' -- "$owned"
check bash -c '! grep -q "start rigforge-api-refresh.service" "$1"' -- "$CASE_DIR/calls"
refresh_profile_finish >"$CASE_DIR/collected"
check test ! -e "$owned"
check test -z "$REFRESH_PROFILE_DROPIN"
check grep -q 'stop rigforge-api-refresh.service' "$CASE_DIR/calls"
check grep -q 'helper=_health_json event=end' "$CASE_DIR/collected"
check bash -c '! grep -q sensitive "$1"' -- "$CASE_DIR/collected"
# Timer must be quiesced before the service; restore it only after override removal/reload.
check awk '
    $0 == "stop rigforge-api-refresh.timer" { a = NR }
    $0 == "stop rigforge-api-refresh.service" { b = NR }
    $0 == "daemon-reload" && b { c = NR }
    $0 == "start rigforge-api-refresh.timer" { d = NR }
    END { exit !(a && a < b && b < c && c < d) }
' "$CASE_DIR/calls"
# A timer that fails during the window must still restore its original active state.
refresh_profile_start
systemctl() {
    printf '%s\n' "$*" >>"$CASE_DIR/failed-timer-calls"
    [ "$*" != 'is-active --quiet rigforge-api-refresh.timer' ]
}
refresh_profile_finish >"$CASE_DIR/failed-timer-collected"
check grep -q '^start rigforge-api-refresh.timer$' "$CASE_DIR/failed-timer-calls"
systemctl() { printf '%s\n' "$*" >>"$CASE_DIR/calls"; }
# Preserve an already-inactive timer; do not spuriously start it.
systemctl() {
    printf '%s\n' "$*" >>"$CASE_DIR/inactive-calls"
    [ "$*" != 'is-active --quiet rigforge-api-refresh.timer' ]
}
refresh_profile_start
refresh_profile_finish >"$CASE_DIR/inactive-collected"
check bash -c '! grep -q "start rigforge-api-refresh.timer" "$1"' -- "$CASE_DIR/inactive-calls"
systemctl() { printf '%s\n' "$*" >>"$CASE_DIR/calls"; }
# Refuse an existing override without claiming it for cleanup.
printf 'existing override\n' >"$owned"
if refresh_profile_start; then exit 1; fi
refresh_profile_finish
check test "$(cat "$owned")" = 'existing override'
rm "$owned"
# A window without a completed profiled refresh cannot report successful diagnostics.
refresh_profile_start
journalctl() { :; }
if refresh_profile_finish >"$CASE_DIR/missing"; then exit 1; fi
check test ! -e "$owned"
# Even when journal collection fails, remove our override and propagate failure.
refresh_profile_start
journalctl() { return 1; }
if refresh_profile_finish >"$CASE_DIR/journal-failed"; then exit 1; fi
check test ! -e "$owned"
# Allocation failures must not strand a root ExecStart override.
refresh_profile_start
mktemp() { return 1; }
if refresh_profile_finish >"$CASE_DIR/allocation-failed"; then exit 1; fi
unset -f mktemp
check test ! -e "$owned"
# A failed stop must fail diagnostics while still attempting override/timer restoration.
refresh_profile_start
systemctl() { [ "$*" != 'stop rigforge-api-refresh.service' ]; }
if refresh_profile_finish >"$CASE_DIR/stop-failed"; then exit 1; fi
check test ! -e "$owned"
# The dispatch/cleanup are wired into the existing reserved harness.
check grep -q 'refresh_profile_start' "$ROOT/tests/e2e-pithead-control.sh"
check grep -q 'refresh_profile_finish || cleanup_ok=0' "$ROOT/tests/e2e-pithead.sh"
printf 'timer-refresh profiling regressions: PASS\n'
