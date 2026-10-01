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
# Fixed Linux accounting fixtures keep these checks hardware-free, including on macOS.
export REFRESH_PROFILE_STAT_FILE="$CASE_DIR/stat" REFRESH_PROFILE_SCHEDSTAT_FILE="$CASE_DIR/schedstat"
stat_tail=(S 0 0 0 0 0 0 0 0 0 0 10 20 30 40 20 19)
printf '123 (synthetic (comm) name) %s\n' "${stat_tail[*]}" >"$REFRESH_PROFILE_STAT_FILE"
printf '100000 900000 3\n' >"$REFRESH_PROFILE_SCHEDSTAT_FILE"
cat >"$CASE_DIR/fixture.sh" <<EOF_FIXTURE
source "$ROOT/rigforge.sh"
getconf() { printf '%s\n' "\${TEST_CLOCK_TICKS:-100}"; }
parse_config() { :; }
_health_json() { sleep 0.05; printf 'private-probe-value'; return "\${TEST_PROBE_RC:-0}"; }
api_refresh() { parse_config; _health_json >"\$TEST_PAYLOAD"; }
EOF_FIXTURE
bash "$ROOT/tests/e2e-api-refresh-profile.sh" "$CASE_DIR/fixture.sh" 2>"$CASE_DIR/measurements"
check grep -q '^refresh-profile: .*helper=_health_json event=begin ' "$CASE_DIR/measurements"
check grep -q '^refresh-profile: .*helper=api_refresh event=end .*rc=0$' "$CASE_DIR/measurements"
check grep -q '^refresh-profile-cpu: .*event=begin cpu_ticks=100 clock_ticks_per_s=100 nice=19 scheduler_wait_ns=900000$' "$CASE_DIR/measurements"
check grep -q '^refresh-profile-cpu: .*event=end cpu_ticks=100 clock_ticks_per_s=100 nice=19 scheduler_wait_ns=900000$' "$CASE_DIR/measurements"
check test "$(cat "$TEST_PAYLOAD")" = private-probe-value
check bash -c '! grep -q private-probe-value "$1"' -- "$CASE_DIR/measurements"
check bash -c '! grep -q "synthetic (comm) name" "$1"' -- "$CASE_DIR/measurements"
# Malformed or unavailable counters cannot silently become zero or a successful profile.
cp "$REFRESH_PROFILE_STAT_FILE" "$CASE_DIR/stat-good"
printf '123 (synthetic) S\n' >"$REFRESH_PROFILE_STAT_FILE"
if bash "$ROOT/tests/e2e-api-refresh-profile.sh" "$CASE_DIR/fixture.sh" 2>"$CASE_DIR/bad-stat"; then exit 1; fi
check bash -c '! grep -q "refresh-profile-cpu:" "$1"' -- "$CASE_DIR/bad-stat"
cp "$CASE_DIR/stat-good" "$REFRESH_PROFILE_STAT_FILE"
if TEST_CLOCK_TICKS=unknown bash "$ROOT/tests/e2e-api-refresh-profile.sh" "$CASE_DIR/fixture.sh" 2>"$CASE_DIR/bad-clock"; then exit 1; fi
mv "$REFRESH_PROFILE_SCHEDSTAT_FILE" "$CASE_DIR/schedstat-good"
if bash "$ROOT/tests/e2e-api-refresh-profile.sh" "$CASE_DIR/fixture.sh" 2>"$CASE_DIR/missing-schedstat"; then exit 1; fi
mv "$CASE_DIR/schedstat-good" "$REFRESH_PROFILE_SCHEDSTAT_FILE"
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
check grep -q '^refresh-profile-cpu: .*event=end cpu_ticks=100 ' "$CASE_DIR/collected"
check bash -c '! grep -q sensitive "$1"' -- "$CASE_DIR/collected"
# Timer must be quiesced before the service; restore it only after override removal/reload.
check awk '
    $0 == "stop rigforge-api-refresh.timer" { a = NR }
    $0 == "stop rigforge-api-refresh.service" { b = NR }
    $0 == "daemon-reload" && b { c = NR }
    $0 == "start rigforge-api-refresh.timer" { d = NR }
    END { exit !(a && a < b && b < c && c < d) }
' "$CASE_DIR/calls"
# Export failure must fail conditional callers while still restoring both units.
: >"$CASE_DIR/calls"
refresh_profile_start
sed() { return 7; }
if refresh_profile_finish >"$CASE_DIR/export-failed"; then
    printf 'failed exporter unexpectedly reported successful diagnostics\n' >&2
    exit 1
fi
unset -f sed
check test ! -e "$owned"
check test -z "$REFRESH_PROFILE_DROPIN"
check grep -q '^daemon-reload$' "$CASE_DIR/calls"
check grep -q '^start rigforge-api-refresh.timer$' "$CASE_DIR/calls"
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
command rm "$owned"
# A failed partial write must remain owned until cleanup removes it.
saved_umask=$(umask)
umask 027
exec 9>"$CASE_DIR/caller-fd"
printf() {
    if [[ "$1" == '[Service]'* ]]; then
        builtin printf '[Service]\nExecStart=\n'
        return 7
    fi
    builtin printf "$@"
}
if refresh_profile_start; then exit 1; fi
unset -f printf
check test "$(umask)" = 0027
case $- in *C*) exit 1 ;; esac
builtin printf 'caller descriptor preserved\n' >&9
exec 9>&-
check test "$(cat "$CASE_DIR/caller-fd")" = 'caller descriptor preserved'
umask "$saved_umask"
check test -z "$REFRESH_PROFILE_DROPIN"
check test ! -e "$owned"
staged="$REFRESH_PROFILE_STAGING"
check test "$(cat "$staged")" = "$(builtin printf '[Service]\nExecStart=')"
rm() { return 7; }
if refresh_profile_finish; then exit 1; fi
check test "$REFRESH_PROFILE_STAGING" = "$staged"
check test -e "$staged"
unset -f rm
refresh_profile_finish >"$CASE_DIR/partial-write-collected"
check test ! -e "$owned"
check test ! -e "$staged"
check test -z "$REFRESH_PROFILE_STAGING"
check test -z "$REFRESH_PROFILE_DROPIN"
# A competitor arriving after the initial existence check must not be claimed or removed.
mkdir() {
    command mkdir "$@" || return
    builtin printf 'competing override\n' >"$owned"
}
set -o noclobber
if refresh_profile_start 2>"$CASE_DIR/collision-error"; then exit 1; fi
unset -f mkdir
case $- in *C*) : ;; *) exit 1 ;; esac
set +o noclobber
check test "$(umask)" = "$saved_umask"
check test -z "$REFRESH_PROFILE_DROPIN"
refresh_profile_finish
check test "$(cat "$owned")" = 'competing override'
command rm "$owned"
# A raced symlink to a nonregular target must also remain untouched.
mkdir() {
    command mkdir "$@" || return
    ln -s /dev/null "$owned"
}
if refresh_profile_start 2>"$CASE_DIR/symlink-collision-error"; then exit 1; fi
unset -f mkdir
check test -z "$REFRESH_PROFILE_DROPIN"
refresh_profile_finish
check test -L "$owned"
check test "$(readlink "$owned")" = /dev/null
command rm "$owned"
# Staging allocation failure must fail setup without claiming any override.
mktemp() { return 7; }
if refresh_profile_start; then exit 1; fi
unset -f mktemp
check test -z "$REFRESH_PROFILE_STAGING"
check test -z "$REFRESH_PROFILE_DROPIN"
refresh_profile_finish
check test ! -e "$owned"
# Failure to unlink staging after publication must not prevent live-override cleanup.
rm() {
    if [ "${2:-}" = "$REFRESH_PROFILE_STAGING" ]; then return 7; fi
    command rm "$@"
}
if refresh_profile_start; then exit 1; fi
staged="$REFRESH_PROFILE_STAGING"
check test -n "$REFRESH_PROFILE_DROPIN"
if refresh_profile_finish >"$CASE_DIR/staging-unlink-failed"; then exit 1; fi
check test ! -e "$owned"
check test -e "$staged"
unset -f rm
refresh_profile_finish
check test ! -e "$staged"
check test -z "$REFRESH_PROFILE_STAGING"
# A window without a completed profiled refresh cannot report successful diagnostics.
refresh_profile_start
journalctl() { :; }
if refresh_profile_finish >"$CASE_DIR/missing"; then exit 1; fi
check test ! -e "$owned"
# Even when journal collection fails, remove our override and propagate failure.
for invalid in missing-begin wrong-pid malformed; do
    refresh_profile_start
    journalctl() {
        [ "$1" != --sync ] || return 0
        case "$invalid" in
        missing-begin) command sed '/^refresh-profile-cpu: .*event=begin /d' "$CASE_DIR/measurements" ;;
        wrong-pid) command sed '/^refresh-profile-cpu:/s/pid=[0-9]*/pid=0/' "$CASE_DIR/measurements" ;;
        malformed) command sed '/^refresh-profile-cpu:/s/cpu_ticks=100/cpu_ticks=invalid/' "$CASE_DIR/measurements" ;;
        esac
    }
    if refresh_profile_finish >"$CASE_DIR/$invalid"; then exit 1; fi
    check test ! -e "$owned"
done
refresh_profile_start
journalctl() {
    [ "$1" != --sync ] || return 0
    command sed '/^refresh-profile-cpu:/d' "$CASE_DIR/measurements"
}
if refresh_profile_finish >"$CASE_DIR/missing-cpu"; then exit 1; fi
check test ! -e "$owned"
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
