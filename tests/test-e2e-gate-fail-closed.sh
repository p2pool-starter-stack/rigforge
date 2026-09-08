#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329
# Hardware-free regression for the release-gate failure plumbing (#491).
echo "== unit: release e2e gates fail closed (#491) =="
T491="$(mktemp -d "$SANDBOX/gate491.XXXXXX")"

PIT_SET="$(sed -n '/^set_cfg()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
PIT_CLEAN="$(sed -n '/^_cleanup()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
PIT_RESTORE="$(sed -n '/^_restore_xmrig()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
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
        eval "$PIT_RESTORE"
        systemctl() { return 1; }
        SAVED_XMRIG_ACTIVE=0 SAVED_CFG="$d/saved" CFG="$d/config" RIGFORGE="$T491/rigforge" HAMMER_PIDS=""
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
        eval "$PIT_RESTORE"
        eval "$PIT_SNAPSHOT"
        systemctl() { return 1; }
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
PIT_DASH="$(sed -n '/^phase_dashboard()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
printf '#!/usr/bin/env bash\ncase "$1" in apply) : ;; start) printf active >"$SERVICE_STATE" ;; stop) printf stopped >"$SERVICE_STATE" ;; *) exit 1 ;; esac\n' >"$T491/dash-rigforge"
chmod +x "$T491/dash-rigforge"
pit_dashboard_failure_case() { # <active|stopped> -> rc:final-state:snapshot
    local d="$T491/dashboard-$1"
    mkdir -p "$d"
    printf '%s' "$1" >"$d/service"
    printf '{"v":1}\n' >"$d/config"
    cp "$d/config" "$d/saved"
    (
        set -Eeuo pipefail
        eval "$PIT_CLEAN"
        eval "$PIT_RESTORE"
        eval "$PIT_DASH"
        eval "$PIT_BAD"
        CFG="$d/config" SAVED_CFG="$d/saved" SAVED_XMRIG_ACTIVE=0 HAMMER_PIDS=""
        [ "$1" = active ] && SAVED_XMRIG_ACTIVE=1
        RIGFORGE="$T491/dash-rigforge" SERVICE_STATE="$d/service"
        export SERVICE_STATE
        RIG_LOCK_HOLDER="$d/holder" E2E_DASH_URL=http://stack E2E_DROPOFF_TIMEOUT=1 E2E_EXIT_RC=0 FAIL=0
        systemctl() { [ "$1" = is-active ] && [ "$(cat "$SERVICE_STATE")" = active ]; }
        sleep() { :; }
        phase() { :; }
        ok() { :; }
        skip() { :; }
        dash_curl() {
            local n=0
            [ -f "$d/calls" ] && n="$(cat "$d/calls")"
            n=$((n + 1))
            printf '%s' "$n" >"$d/calls"
            if [ "$n" = 1 ]; then printf '{"workers":[{"name":"%s","status":"online"}]}' "$(hostname)"; else printf '{"workers":[]}'; fi
        }
        trap 'E2E_EXIT_RC=$?; trap - EXIT; _cleanup || [ "$E2E_EXIT_RC" -ne 0 ] || E2E_EXIT_RC=1; exit "$E2E_EXIT_RC"' EXIT
        phase_dashboard
    ) >/dev/null 2>&1
    printf '%s:%s:%s\n' "$?" "$(cat "$d/service")" "$([ -f "$d/saved" ] && echo kept || echo removed)"
}
assert_eq "dashboard failure restores an originally active miner" "$(pit_dashboard_failure_case active)" "1:active:removed"
assert_eq "dashboard failure preserves an originally stopped miner" "$(pit_dashboard_failure_case stopped)" "1:stopped:removed"

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
assert_eq "upgrade checkpoints guard setup, VERSION, noop, probe, and rollback" "$(grep -c 'continue_or_cleanup _upgrade_cleanup upgrade' "$ROOT/tests/e2e-real.sh")" "6"

UPG_VERSION_BLOCK="$(sed -n '/^    installed=$(tr /,/^    phase "upgrade — rollback/p' "$ROOT/tests/e2e-real.sh")"
out="$( (
    eval "$REAL_CONT"
    FAIL=0 HERE="$T491/no-version"
    mkdir -p "$HERE"
    ok() { :; }
    bad() { FAIL=$((FAIL + 1)); }
    phase() { :; }
    _upgrade_cleanup() { :; }
    summary() {
        printf 'posts=%s' "${posts:-0}"
        exit 9
    }
    _upg_post_and_poll() {
        posts=$((posts + 1))
        printf failed
    }
    eval "$UPG_VERSION_BLOCK"
) 2>/dev/null)"
assert_rc "missing VERSION aborts upgrade before the noop POST" "$?" "9"
assert_eq "missing VERSION fires no later upgrade mutation" "$out" "posts=0"

upgrade_artifact_case() {
    (
        eval "$REAL_UPG"
        UPG_ORIG_REF="" UPG_RESTORE_BUILD=0 UPG_STAMP="$T491/retained-stamp"
        : >"$UPG_STAMP"
        _hgit() { case "$1 $2" in 'tag -d') return 1 ;; 'show-ref --verify') return 0 ;; esac }
        rm() { return 1; }
        _control_cleanup() { :; }
        _upgrade_cleanup >/dev/null 2>&1
        printf '%s:' "$?"
        _upgrade_cleanup >/dev/null 2>&1
        printf '%s\n' "$?"
    )
}
assert_eq "upgrade cleanup reports and retries retained tag/stamp failures" "$(upgrade_artifact_case)" "1:1"

control_snapshot_remove_case() {
    local d="$T491/control-remove"
    mkdir -p "$d"
    printf original >"$d/saved"
    cp "$d/saved" "$d/config"
    (
        eval "$REAL_CTL"
        CTL_CLEANUP_DONE=0 CTL_SAVED_CFG="$d/saved" HERE="$d" RIGFORGE=true
        CTL_CONTROL_ACTIVE=0 CTL_CONTROL_ENABLED=0 CTL_XMRIG_ACTIVE=0 CTL_XMRIG_ENABLED=0
        _restore_unit_state() { :; }
        curl() { :; }
        sleep() { :; }
        rm() { return 1; }
        _control_cleanup >/dev/null 2>&1
        printf '%s:' "$?"
        _control_cleanup >/dev/null 2>&1
        printf '%s:%s\n' "$?" "$CTL_CLEANUP_DONE"
    )
}
assert_eq "control cleanup does not mark DONE when snapshot removal fails" "$(control_snapshot_remove_case)" "1:1:0"

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
watchdog_marker_case491() {
    local d="$T491/wdmark"
    mkdir -p "$d/worker"
    printf original >"$d/saved"
    cp "$d/saved" "$d/config"
    : >"$d/worker/watchdog.thermal-hold"
    (
        eval "$REAL_WD"
        WD_CLEANUP_DONE=0 WD_SAVED_CFG="$d/saved" WD_WORKER_ROOT="$d/worker" WD_WAS_ACTIVE=0
        HERE="$d" RIGFORGE=true
        systemctl() { return 1; }
        rm() { case "$*" in *watchdog.*) return 1 ;; *) command rm "$@" ;; esac }
        _watchdog_cleanup >/dev/null 2>&1
        printf '%s:' "$?"
        _watchdog_cleanup >/dev/null 2>&1
        printf '%s:%s:%s\n' "$?" "$WD_CLEANUP_DONE" "$([ -e "$d/worker/watchdog.thermal-hold" ] && echo retained || echo lost)"
    )
}
assert_eq "watchdog marker removal failure is reported and retryable" "$(watchdog_marker_case491)" "1:1:0:retained"
watchdog_active_case491() {
    local d="$T491/wdactive"
    mkdir -p "$d"
    printf original >"$d/saved"
    cp "$d/saved" "$d/config"
    printf stopped >"$d/service"
    (
        eval "$REAL_WD"
        export SERVICE_STATE="$d/service"
        WD_CLEANUP_DONE=0 WD_SAVED_CFG="$d/saved" WD_WORKER_ROOT="" WD_WAS_ACTIVE=1
        HERE="$d" RIGFORGE="$T491/dash-rigforge"
        systemctl() { [ "$1" = is-active ] && [ "$(cat "$SERVICE_STATE")" = active ]; }
        _watchdog_cleanup >/dev/null 2>&1
        printf '%s:%s:%s\n' "$?" "$(cat "$SERVICE_STATE")" "$WD_CLEANUP_DONE"
    )
}
assert_eq "watchdog cleanup restores and verifies an originally active miner" "$(watchdog_active_case491)" "0:active:1"
