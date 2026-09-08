#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329
# Hardware-free regression for the release-gate failure plumbing (#491).
echo "== unit: release e2e gates fail closed (#491) =="
T491="$(mktemp -d "$SANDBOX/gate491.XXXXXX")"

PIT_SET="$(sed -n '/^set_cfg()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
PIT_CLEAN="$(sed -n '/^_cleanup()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
PIT_SNAPSHOT="$(sed -n '/^snapshot_config()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
printf '{"v":1}\n' >"$T491/config.json"
printf '#!/usr/bin/env bash\n[ -z "${CALL_LOG:-}" ] || printf "%%s\n" "$*" >>"$CALL_LOG"\n[ "${FAIL_APPLY:-0}" != 1 ]\n' >"$T491/rigforge"
chmod +x "$T491/rigforge"
pit_set_case() { # jq replacement, apply failure -> rc:config
    (
        eval "$PIT_SET"
        CFG="$T491/config.json" RIGFORGE="$T491/rigforge"
        FAIL_APPLY="$2" set_cfg "$1"
        printf '%s:%s\n' "$?" "$(jq -c . "$CFG")"
    )
}
assert_eq "set_cfg commits and applies a valid edit" "$(pit_set_case '.v=2' 0)" '0:{"v":2}'
printf '{"v":1}\n' >"$T491/config.json"
assert_eq "set_cfg rejects jq failure without replacing config" "$(pit_set_case 'invalid(' 0 2>/dev/null)" '1:{"v":1}'
mkdir -p "$T491/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T491/bin/mv"
chmod +x "$T491/bin/mv"
printf '{"v":1}\n' >"$T491/config.json"
assert_eq "set_cfg propagates mv failure without replacing config" "$(PATH="$T491/bin:$PATH" pit_set_case '.v=4' 0)" '1:{"v":1}'
printf '{"v":1}\n' >"$T491/config.json"
assert_eq "set_cfg propagates apply failure" "$(pit_set_case '.v=3' 1)" '1:{"v":3}'

pit_cleanup_case() { # apply failure -> rc:config:snapshot
    local d="$T491/cleanup-$1"
    mkdir -p "$d"
    printf original >"$d/saved"
    printf mutated >"$d/config"
    set +e
    (
        eval "$PIT_CLEAN"
        SAVED_CFG="$d/saved" CFG="$d/config" RIGFORGE="$T491/rigforge" HAMMER_PIDS=""
        RIG_LOCK_HOLDER="$d/holder" FAIL_APPLY="$1" _cleanup
    ) >/dev/null 2>&1
    local rc=$?
    set -e
    printf '%s:%s:%s\n' "$rc" "$(cat "$d/config")" "$([ -f "$d/saved" ] && echo kept || echo removed)"
}
assert_eq "pithead cleanup restores bytes and removes a successful snapshot" "$(pit_cleanup_case 0)" "0:original:removed"
pit_cleanup_status_case() {
    local d="$T491/cleanup-status"
    mkdir -p "$d"
    printf original >"$d/saved"
    printf mutated >"$d/config"
    (
        eval "$PIT_CLEAN"
        eval "$PIT_SNAPSHOT"
        SAVED_CFG="$d/saved" CFG="$d/config" RIGFORGE="$T491/rigforge" HAMMER_PIDS="" RIG_LOCK_HOLDER="$d/holder"
        E2E_EXIT_RC=0
        trap 'E2E_EXIT_RC=$?; trap - EXIT; _cleanup || [ "$E2E_EXIT_RC" -ne 0 ] || E2E_EXIT_RC=1; exit "$E2E_EXIT_RC"' EXIT
        false
    ) >/dev/null 2>&1
}
pit_cleanup_status_case
assert_rc "successful cleanup preserves the triggering failure status" "$?" "1"
assert_eq "pithead cleanup fails and retains recovery snapshot when apply fails" "$(pit_cleanup_case 1)" "1:original:kept"

PIT_BAD="$(sed -n '/^bad()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
out="$(PIT_BAD="$PIT_BAD" bash -c 'set -e; eval "$PIT_BAD"; FAIL=0; bad prerequisite; printf mutated' 2>/dev/null)"
assert_rc "pithead assertion fails the active phase" "$?" "1"
assert_absent "pithead assertion stops the next mutation" "$out" "mutated"

PIT_LOOP="$(sed -n '/^    for run_phase in phase_connect /,/^    done$/p' "$ROOT/tests/e2e-pithead.sh")"
out="$( (
    FAIL=0
    phase_connect() {
        printf connect
        FAIL=1
    }
    phase_worker_api() { printf worker; }
    phase_api_impact() { printf impact; }
    phase_network() { printf network; }
    phase_stratum_auth() { printf auth; }
    phase_dashboard() { printf dash; }
    phase_dev_fee() { printf fee; }
    eval "$PIT_LOOP"
))"
assert_eq "pithead all stops before later mutation phases after a failed assertion" "$out" "connect"

REAL_CONT="$(sed -n '/^continue_or_cleanup()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
out="$( (
    eval "$REAL_CONT"
    FAIL=1
    cleanup() {
        printf cleanup
        return 0
    }
    bad() { printf bad; }
    summary() {
        printf summary
        exit 7
    }
    continue_or_cleanup cleanup control
    printf write
) 2>/dev/null)"
assert_rc "failed setup exits through summary" "$?" "7"
assert_eq "failed setup cleans up and blocks the next mutation" "$out" "cleanupsummary"

REAL_CTL="$(sed -n '/^_control_cleanup()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
control_retry_case() {
    (
        eval "$REAL_CTL"
        export CALL_LOG="$T491/control-calls"
        rm -f "$CALL_LOG"
        CTL_CLEANUP_DONE=0 CTL_SAVED_CFG="$T491/missing" HERE="$T491" RIGFORGE="$T491/rigforge"
        CTL_CONTROL_ACTIVE=0 CTL_CONTROL_ENABLED=0 CTL_XMRIG_ACTIVE=0 CTL_XMRIG_ENABLED=0
        _restore_unit_state() { :; }
        sleep() { :; }
        curl() { :; }
        _control_cleanup >/dev/null 2>&1
        printf '%s:' "$?"
        _control_cleanup >/dev/null 2>&1
        printf '%s:%s:%s\n' "$?" "$CTL_CLEANUP_DONE" "$([ -f "$CALL_LOG" ] && wc -l <"$CALL_LOG" || echo 0)"
    )
}
assert_eq "failed control cleanup retries instead of false-passing" "$(control_retry_case)" "1:1:0:0"

REAL_UPG="$(sed -n '/^_upgrade_cleanup()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
upgrade_cleanup_case() { # checkout succeeds, rebuild fails twice
    (
        eval "$REAL_UPG"
        UPG_ORIG_REF=original UPG_RESTORE_BUILD=0 HERE="$T491" RIGFORGE=false
        _hgit() { case "$1" in rev-parse) printf '%s\n' "${head:-old}" ;; checkout) head=original ;; esac }
        _control_cleanup() { :; }
        _upgrade_cleanup >/dev/null 2>&1
        printf '%s:' "$?"
        _upgrade_cleanup >/dev/null 2>&1
        printf '%s:%s:%s\n' "$?" "$UPG_ORIG_REF" "$UPG_RESTORE_BUILD"
    )
}
assert_eq "upgrade cleanup retries rebuild and retains source ref until it succeeds" "$(upgrade_cleanup_case)" "1:1:original:1"

REAL_WD="$(sed -n '/^_watchdog_cleanup()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
watchdog_cleanup_case491() {
    local d="$T491/watchdog"
    mkdir -p "$d"
    printf original >"$d/saved"
    printf mutated >"$d/config"
    (
        eval "$REAL_WD"
        export CALL_LOG="$d/calls" FAIL_APPLY=1
        WD_CLEANUP_DONE=0 WD_SAVED_CFG="$d/saved" WD_WORKER_ROOT="" WD_WAS_ACTIVE=0
        HERE="$d" RIGFORGE="$T491/rigforge"
        systemctl() { return 1; }
        _watchdog_cleanup >/dev/null 2>&1
        printf '%s:' "$?"
        _watchdog_cleanup >/dev/null 2>&1
        printf '%s:%s:%s\n' "$?" "$WD_CLEANUP_DONE" "$(wc -l <"$CALL_LOG")"
    )
}
assert_eq "watchdog cleanup propagates apply failure and remains retryable" "$(watchdog_cleanup_case491)" "1:1:0:2"
