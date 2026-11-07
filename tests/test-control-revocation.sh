#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/rigforge.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

install_case() {
    local step=$1 d="$T/install-$1" rc
    mkdir -p "$d/bin" "$d/units"
    cat >"$d/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = tee ] && [ "${FAIL_STEP:-}" = render ] && case "$2" in */rigforge-control.service) true ;; *) false ;; esac; then
    exit 1
fi
exec "$@"
EOF
    cat >"$d/bin/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' >"$d/bin/python3"
    cat >"$d/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALL_LOG"
case "$FAIL_STEP:$*" in
daemon-reload:daemon-reload) exit 1 ;;
apply-enable:*enable*--now*rigforge-control-apply.path*) exit 1 ;;
receiver-enable:*enable*rigforge-control.service*) exit 1 ;;
restart:*restart*rigforge-control.service*) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$d/bin/"*
    : >"$d/calls"
    (
        source "$SCRIPT"
        OS_TYPE=Linux CONTROL_MODE=enabled CONTROL_UPGRADE=disabled
        SYSTEMD_DIR="$d/units" SCRIPT_DIR="$ROOT" REAL_USER=tester
        CONTROL_BIND=local CONTROL_PORT=dynamic API_ALLOW_FROM=local RIGFORGE_APPLIANCE=0
        CALL_LOG="$d/calls" FAIL_STEP="$step" PATH="$d/bin:$PATH"
        export CALL_LOG FAIL_STEP PATH
        install_control >/dev/null 2>&1
    )
    rc=$?
    [ "$rc" -ne 0 ] || fail "install_control hid $step failure"
    if [ "$step" = restart ]; then
        grep -q '^stop rigforge-control.service$' "$d/calls" || fail "restart rejection left the stale receiver running"
    fi
}

for step in render daemon-reload apply-enable receiver-enable restart; do
    install_case "$step"
done

stop_helper_case() {
    local mode=$1 expected=$2 d="$T/stop-helper-$1" rc out
    mkdir -p "$d/units"
    [ "$mode" != no-systemd-unit ] || : >"$d/units/rigforge-control.service"
    (
        source "$SCRIPT"
        STOP_CALLS=0 SYSTEMD_DIR="$d/units"
        sudo() { "$@"; }
        systemctl() {
            printf '%s\n' "$*" >>"$d/calls"
            case "$1" in
            stop)
                STOP_CALLS=$((STOP_CALLS + 1))
                [ "$mode" = active ] && [ "$STOP_CALLS" -gt 1 ]
                ;;
            show)
                case "$*:$mode" in
                *LoadState*:absent | *LoadState*:active) printf 'not-found\n' ;;
                *ActiveState*:absent) printf 'inactive\n' ;;
                *ActiveState*:active) printf 'active\n' ;;
                *LoadState*:stuck) printf 'loaded\n' ;;
                *ActiveState*:stuck) printf 'active\n' ;;
                esac
                ;;
            kill) return 0 ;;
            esac
        }
        warn() { printf 'WARN: %s\n' "$*"; }
        _stop_control_receiver
    ) >"$d/output" 2>&1
    rc=$?
    [ "$rc" -eq "$expected" ] || fail "stop helper $mode returned $rc, expected $expected"
    out=$(cat "$d/output")
    case "$mode" in
    absent)
        ! grep -q '^kill ' "$d/calls" || fail "absent inactive receiver was killed"
        ;;
    active)
        grep -q '^kill --kill-who=all --signal=KILL rigforge-control.service$' "$d/calls" || fail "not-found active receiver did not get an exact-unit kill"
        [ "$(grep -c '^stop rigforge-control.service$' "$d/calls")" -eq 2 ] || fail "active receiver stop was not retried"
        ;;
    stuck)
        case "$out" in
        *"Could not stop the control receiver; revocation is NOT confirmed"*) ;;
        *) fail "double stop failure omitted the revocation warning" ;;
        esac
        ;;
    esac
}

stop_helper_case absent 0
stop_helper_case active 0
stop_helper_case stuck 1
stop_helper_case no-systemd 0
stop_helper_case no-systemd-unit 1

recovery="$T/stop-recovery"
mkdir -p "$recovery/bin" "$recovery/units"
cat >"$recovery/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"$recovery/bin/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$recovery/bin/python3"
cat >"$recovery/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALL_LOG"
if [ "$1" = stop ]; then
    count=$(cat "$STOP_COUNT" 2>/dev/null || echo 0)
    printf '%s\n' "$((count + 1))" >"$STOP_COUNT"
    [ "$count" -gt 0 ]
elif [ "$1" = show ]; then
    printf 'loaded\n'
fi
EOF
chmod +x "$recovery/bin/"*
(
    source "$SCRIPT"
    OS_TYPE=Linux CONTROL_MODE=enabled CONTROL_UPGRADE=disabled
    SYSTEMD_DIR="$recovery/units" SCRIPT_DIR="$ROOT" REAL_USER=tester
    CONTROL_BIND=local CONTROL_PORT=dynamic API_ALLOW_FROM=local RIGFORGE_APPLIANCE=0
    CALL_LOG="$recovery/calls" STOP_COUNT="$recovery/stops" PATH="$recovery/bin:$PATH"
    export CALL_LOG STOP_COUNT PATH
    install_control >/dev/null 2>&1
) || fail "install_control did not recover a rejected stop"
grep -q '^kill --kill-who=all --signal=KILL rigforge-control.service$' "$recovery/calls" || fail "stop rejection did not target the exact receiver unit"

disabled_case() {
    local mode=$1 d="$T/disabled-$1" rc unit
    mkdir -p "$d/bin" "$d/units"
    for unit in rigforge-control.service rigforge-control-apply.service rigforge-control-apply.path; do
        : >"$d/units/$unit"
    done
    cat >"$d/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    cat >"$d/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALL_LOG"
if [ "$1" = disable ]; then
    [ "$DISABLE_MODE" = fail ] && exit 1
    for unit in "$@"; do
        case "$unit" in rigforge-*) [ -f "$UNIT_DIR/$unit" ] || exit 1 ;; esac
    done
fi
exit 0
EOF
    chmod +x "$d/bin/"*
    : >"$d/calls"
    (
        source "$SCRIPT"
        OS_TYPE=Linux CONTROL_MODE=disabled CONTROL_UPGRADE=disabled SYSTEMD_DIR="$d/units"
        CALL_LOG="$d/calls" UNIT_DIR="$d/units" DISABLE_MODE="$mode" PATH="$d/bin:$PATH"
        export CALL_LOG UNIT_DIR DISABLE_MODE PATH
        install_control >/dev/null 2>&1
    )
    rc=$?
    case "$mode" in
    absent-upgrade)
        [ "$rc" -eq 0 ] || fail "control-disabled teardown failed when the upgrade unit was absent"
        ! grep -q 'rigforge-control-upgrade.path' "$d/calls" || fail "control-disabled teardown named the absent upgrade unit"
        [ -z "$(ls -A "$d/units")" ] || fail "control-disabled teardown left unit files behind"
        ;;
    fail)
        [ "$rc" -ne 0 ] || fail "control-disabled teardown hid a failing disable"
        [ "$(grep -c '^stop rigforge-control.service$' "$d/calls")" -ge 2 ] || fail "failing disable left the receiver unstopped on exit"
        ;;
    esac
}

disabled_case absent-upgrade
disabled_case fail

stale="$T/stale-upgrade"
mkdir -p "$stale/bin" "$stale/units"
: >"$stale/units/rigforge-control-upgrade.service"
cp "$recovery/bin/sudo" "$recovery/bin/envsubst" "$recovery/bin/python3" "$stale/bin/"
cat >"$stale/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALL_LOG"
if [ "$1" = disable ]; then
    for unit in "$@"; do
        case "$unit" in rigforge-*) [ -f "$UNIT_DIR/$unit" ] || exit 1 ;; esac
    done
fi
exit 0
EOF
chmod +x "$stale/bin/systemctl"
(
    source "$SCRIPT"
    OS_TYPE=Linux CONTROL_MODE=enabled CONTROL_UPGRADE=disabled
    SYSTEMD_DIR="$stale/units" SCRIPT_DIR="$ROOT" REAL_USER=tester
    CONTROL_BIND=local CONTROL_PORT=dynamic API_ALLOW_FROM=local RIGFORGE_APPLIANCE=0
    CALL_LOG="$stale/calls" UNIT_DIR="$stale/units" PATH="$stale/bin:$PATH"
    export CALL_LOG UNIT_DIR PATH
    install_control >/dev/null 2>&1
) || fail "a leftover upgrade service without its path unit failed the control reconcile"
[ ! -e "$stale/units/rigforge-control-upgrade.service" ] || fail "the leftover upgrade service was not removed"

caller_case() {
    local caller=$1 d="$T/caller-$1" rc
    mkdir -p "$d"
    (
        source "$SCRIPT"
        OS_TYPE=Linux SYSTEMD_DIR="$d/units" SERVICE_NAME=xmrig XMRIG_REBUILD=false
        install_control() { return 1; }
        install_api_firewall() { : >"$d/firewall"; }
        parse_config() { :; }
        _persist_appliance_mode() { :; }
        check_prerequisites() { :; }
        ensure_config_exists() { :; }
        decide_rebuild() { :; }
        prepare_workspace() { :; }
        install_dependencies() { :; }
        compile_xmrig() { :; }
        generate_xmrig_config() { :; }
        tune_kernel() { :; }
        configure_limits() { :; }
        install_service() { :; }
        install_autotune() { :; }
        install_watchdog() { :; }
        install_api() { :; }
        link_cli() { :; }
        _reown_worker() { :; }
        finish_deployment() { :; }
        _upgrade_restart() { :; }
        _post_upgrade_retune() { :; }
        _apply_runtime() { :; }
        _stamp_config_meta() { :; }
        _apply_pool_check() { :; }
        _autotune_apply_notice() { :; }
        "$caller"
    )
    rc=$?
    [ -f "$d/firewall" ] || fail "$caller skipped firewall after control failure"
    [ "$rc" -ne 0 ] || fail "$caller hid control failure"
}

caller_case main
caller_case upgrade
caller_case apply

if command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/tests/control-revocation.py" "$ROOT" || exit $?
else
    printf 'SKIP: python3 unavailable; live receiver write regression requires Python\n'
    exit 0
fi
printf 'control revocation regression: PASS\n'
