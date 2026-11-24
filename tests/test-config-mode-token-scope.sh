#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export RIGFORGE_HOME="$TEST_DIR/rigforge"
export RIGFORGE_APPLIANCE=0
export NO_COLOR=1
mkdir -p "$RIGFORGE_HOME"
FAIL=0

bad() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL=1
}
assert_eq() { [ "$2" = "$3" ] || bad "$1: expected [$3], got [$2]"; }
assert_has() { case "$2" in *"$3"*) ;; *) bad "$1: missing [$3]" ;; esac }
assert_lacks() { case "$2" in *"$3"*) bad "$1: unexpected [$3]" ;; esac }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

(
    source "$SCRIPT"
    id() { printf '0\n'; }
    sudo() { "$@"; }
    chown() { :; }
    REAL_USER=operator
    CONFIG_JSON="$TEST_DIR/reown.json"
    for os in Linux Darwin; do
        OS_TYPE=$os
        printf '{}\n' >"$CONFIG_JSON"
        chmod 644 "$CONFIG_JSON"
        _reown_worker
        assert_eq "$os re-own leaves config.json owner-only" "$(mode_of "$CONFIG_JSON")" 600
    done
    printf '{}\n' >"$TEST_DIR/shared.json"
    chmod 644 "$TEST_DIR/shared.json"
    CONFIG_JSON="$TEST_DIR/shared.json"
    OS_TYPE=Linux
    SHARED_HOST=true
    WORKER_ROOT="$TEST_DIR/worker"
    mkdir -p "$WORKER_ROOT"
    _reown_worker
    assert_eq "shared-host re-own leaves config.json owner-only" "$(mode_of "$CONFIG_JSON")" 600
    exit "$FAIL"
) || FAIL=1

run_doctor() {
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$1"
        MEMINFO=/nonexistent
        MSR_MODULE_DIR=/nonexistent
        GOVERNOR_FILE=/nonexistent
        HUGEPAGES_1G_NR=/nonexistent
        DMIDECODE=/nonexistent
        CPUFREQ_MAX=/nonexistent
        CPU_SYSFS=/nonexistent
        _DR_JSON_FILE="$2"
        systemctl() { return 3; }
        set +e
        doctor 2>&1
    )
}

printf '{"HOME_DIR":"%s","pools":[{"url":"h:3333"}]}\n' "$TEST_DIR/home" >"$TEST_DIR/doctor.json"
for m in 644 640 604 600 400; do
    chmod "$m" "$TEST_DIR/doctor.json"
    : >"$TEST_DIR/rows-$m"
    out=$(run_doctor "$TEST_DIR/doctor.json" "$TEST_DIR/rows-$m")
    case "$m" in
    644 | 640 | 604)
        assert_has "doctor warns on mode $m" "$out" "readable by group or others"
        assert_has "doctor prints the fix for mode $m" "$out" "sudo chmod 600 $TEST_DIR/doctor.json"
        assert_eq "doctor row for mode $m is a warning" "$(jq -r 'select(.id == "config-mode") | .status' "$TEST_DIR/rows-$m")" warn
        ;;
    *)
        assert_lacks "doctor is quiet on mode $m" "$out" "readable by group or others"
        assert_has "doctor confirms mode $m" "$out" "config.json is owner-only"
        assert_eq "doctor row for mode $m is ok" "$(jq -r 'select(.id == "config-mode") | .status' "$TEST_DIR/rows-$m")" ok
        ;;
    esac
done

STATE="$TEST_DIR/api"
mkdir -p "$STATE"
(
    source "$SCRIPT"
    unset API_CMD
    SERVICE_NAME=xmrig
    CONFIG_JSON="$TEST_DIR/home.json"
    printf '{"HOME_DIR":"%s"}\n' "$TEST_DIR/home" >"$CONFIG_JSON"
    curl() {
        printf 'call\n' >>"$STATE/calls"
        if [ "${1:-}" = --config ]; then cat >>"$STATE/stdin"; fi
        printf '{"hashrate":{"total":[42.5]}}\n'
    }
    systemctl() { [ "$(cat "$STATE/active")" = active ]; }
    launchctl() { if [ -f "$STATE/agent" ]; then printf '{\n\t"PID" = 123;\n}\n'; else return 113; fi; }
    reset() {
        rm -f "$STATE/calls" "$STATE/stdin" "$STATE/agent"
        : >"$STATE/calls"
        : >"$STATE/stdin"
    }
    calls() { wc -l <"$STATE/calls" | tr -d ' '; }

    OS_TYPE=Linux
    ACCESS_TOKEN=tok-secret
    reset
    printf 'active\n' >"$STATE/active"
    assert_has "running service: summary returned" "$(_read_api_summary)" '"hashrate"'
    assert_has "running service: token sent" "$(cat "$STATE/stdin")" 'Authorization: Bearer tok-secret'
    reset
    assert_eq "running service: hashrate read" "$(_read_api_hashrate)" 42.5
    reset
    printf 'inactive\n' >"$STATE/active"
    assert_eq "stopped service: summary is empty" "$(_read_api_summary)" ""
    assert_eq "stopped service: summary exits 0" "$(
        _read_api_summary >/dev/null
        echo $?
    )" 0
    assert_eq "stopped service: no request at all" "$(calls)" 0
    assert_eq "stopped service: token never written" "$(cat "$STATE/stdin")" ""
    assert_eq "stopped service: hashrate read is empty" "$(_read_api_hashrate)" ""
    assert_has "stopped service: status reports the API unreachable" "$(_status_api_summary)" "not reachable"
    assert_eq "stopped service: still no request after status" "$(calls)" 0
    ACCESS_TOKEN=""
    reset
    assert_has "stopped service without a token: request unchanged" "$(_read_api_summary)" '"hashrate"'
    assert_eq "stopped service without a token: one plain request" "$(calls)" 1
    assert_eq "stopped service without a token: no header" "$(cat "$STATE/stdin")" ""

    OS_TYPE=Darwin
    ACCESS_TOKEN=tok-secret
    _mac_paths
    mkdir -p "$(dirname "$MAC_PID")"
    reset
    rm -f "$MAC_PID"
    assert_eq "mac, no pid, no agent: summary is empty" "$(_read_api_summary)" ""
    assert_eq "mac, no pid, no agent: no request" "$(calls)" 0
    set -E
    trap 'printf x >>"$STATE/trap"' ERR
    body=$(_read_api_summary)
    body=$(_status_api_summary)
    trap - ERR
    set +E
    assert_eq "mac, stopped with a token: the error trap stays quiet" "$(cat "$STATE/trap" 2>/dev/null)" ""
    printf '%s\n' "$$" >"$MAC_PID"
    assert_has "mac, live pid: summary returned" "$(_read_api_summary)" '"hashrate"'
    assert_has "mac, live pid: token sent" "$(cat "$STATE/stdin")" 'Authorization: Bearer tok-secret'
    reset
    printf '999999999\n' >"$MAC_PID"
    assert_eq "mac, dead pid: summary is empty" "$(_read_api_summary)" ""
    assert_eq "mac, dead pid: no request" "$(calls)" 0
    : >"$STATE/agent"
    assert_has "mac, login agent running: summary returned" "$(_read_api_summary)" '"hashrate"'
    assert_has "mac, login agent running: token sent" "$(cat "$STATE/stdin")" 'Authorization: Bearer tok-secret'
    exit "$FAIL"
) || FAIL=1

CC="$TEST_DIR/commit"
mkdir -p "$CC"
printf '{"pools":[{"url":"h:3333","pass":"tok"}],"DONATION":1}\n' >"$CC/config.json"
chmod 600 "$CC/config.json"
printf '{"DONATION":4}' >"$CC/s.json"
(
    source "$SCRIPT"
    umask 022
    CONFIG_JSON="$CC/config.json"
    parse_config() { mode_of "$CONFIG_JSON" >"$CC/seen"; }
    out=$(_control_commit "$CC/s.json" "$CC/backups")
    assert_has "commit under umask 022 lands the change" "$out" "committed "
    assert_eq "the candidate is owner-only while parse_config validates it" "$(cat "$CC/seen")" 600
    assert_eq "the committed config.json is owner-only" "$(mode_of "$CC/config.json")" 600
    exit "$FAIL"
) || FAIL=1

RB="$TEST_DIR/rollback"
mkdir -p "$RB/state/spool"
printf '{"pools":[{"url":"h:3333","pass":"tok"}],"DONATION":1}\n' >"$RB/config.json"
chmod 600 "$RB/config.json"
printf '{"DONATION":4}' >"$RB/state/spool/pending-abc123.json"
(
    source "$SCRIPT"
    umask 022
    OS_TYPE=Linux
    SCRIPT_DIR="$RB"
    CONFIG_JSON="$RB/config.json"
    RIGFORGE_CONTROL_STATE="$RB/state"
    parse_config() { :; }
    _control_claim_staged() { cp "$1" "$RB/staged.json" && printf '%s' "$RB/staged.json"; }
    _control_do_apply_fast() { return 1; }
    _control_do_apply() { return 1; }
    control_apply >/dev/null 2>&1
    assert_eq "the control change is rolled back" "$(jq -r .status "$RB/state/status.json")" rolled_back
    assert_eq "the rollback restores the old config" "$(jq -r .DONATION "$RB/config.json")" 1
    assert_eq "config.json stays owner-only after the rollback" "$(mode_of "$RB/config.json")" 600
    exit "$FAIL"
) || FAIL=1

exit "$FAIL"
