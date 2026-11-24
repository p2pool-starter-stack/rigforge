#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${1:-$ROOT/rigforge.sh}"
POSTINST="$ROOT/packaging/debian/postinst"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
STUBS="$D/stubs"
mkdir -p "$STUBS"
CALLS="$D/calls"
cat >"$STUBS/dpkg" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --compare-versions ] && [ "$3" = gt ] || exit 2
[ "$2" != "$4" ] && [ "$(printf '%s\n%s\n' "$2" "$4" | sort -V | tail -1)" = "$2" ]
STUB
cat >"$STUBS/dpkg-query" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$NEW_VERSION"
STUB
cat >"$STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$CALLS"
[ -z "${SYSTEMCTL_FAIL:-}" ]
STUB
chmod +x "$STUBS"/*
export CALLS

fail=0
check() {
    [ "$2" -eq 0 ] || {
        echo "FAIL: $1"
        fail=1
    }
}

postinst() {
    local r="$D/$1"
    mkdir -p "$r/etc/rigforge"
    [ "$4" != y ] || echo '{}' >"$r/etc/rigforge/config.json"
    [ "${5:-y}" != y ] || mkdir -p "$r/run/systemd/system"
    : >"$CALLS"
    NEW_VERSION="$3" RIGFORGE_PKG_ROOT="$r" PATH="$STUBS:$PATH" sh "$POSTINST" configure "$2" >"$r/out" 2>&1
}

postinst first "" 2.0.0 y
check "first install is inert" "$([ ! -e "$D/first/var/lib/rigforge/upgrade-pending" ] && [ ! -s "$CALLS" ] && echo 0 || echo 1)"

postinst noconf 1.0.0 2.0.0 n
check "upgrade without a configured miner is inert" "$([ ! -e "$D/noconf/var/lib/rigforge/upgrade-pending" ] && [ ! -s "$CALLS" ] && echo 0 || echo 1)"

postinst same 2.0.0 2.0.0 y
check "same version is inert" "$([ ! -e "$D/same/var/lib/rigforge/upgrade-pending" ] && [ ! -s "$CALLS" ] && echo 0 || echo 1)"

postinst older 2.0.0 1.9.0 y
check "downgrade is inert" "$([ ! -e "$D/older/var/lib/rigforge/upgrade-pending" ] && [ ! -s "$CALLS" ] && echo 0 || echo 1)"

postinst queue 1.9.0 2.0.0 y
check "upgrade writes the marker" "$([ "$(cat "$D/queue/var/lib/rigforge/upgrade-pending")" = 2.0.0 ] && echo 0 || echo 1)"
check "upgrade starts the unit with --no-block" "$(grep -qx 'systemctl start --no-block rigforge-upgrade.service' "$CALLS" && echo 0 || echo 1)"

postinst nosystemd 1.9.0 2.0.0 y n
rc=$?
check "no systemd: marker kept, exit 0, retry command printed" "$([ "$rc" -eq 0 ] && [ -f "$D/nosystemd/var/lib/rigforge/upgrade-pending" ] && grep -q 'sudo rigforge upgrade' "$D/nosystemd/out" && echo 0 || echo 1)"

set +e
SYSTEMCTL_FAIL=1 postinst sysfail 1.9.0 2.0.0 y
rc=$?
set -e
check "systemctl failure never fails dpkg" "$([ "$rc" -eq 0 ] && grep -q 'sudo rigforge upgrade' "$D/sysfail/out" && echo 0 || echo 1)"

STATE="$D/state"
export RIGFORGE_PKG_STATE="$STATE"
pkg_run() {
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        log() { :; }
        warn() { :; }
        _persist_appliance_mode() { :; }
        check_prerequisites() { :; }
        parse_config() { XMRIG_REBUILD=false; }
        _shared_host_prepare() { :; }
        decide_rebuild() { echo decide_rebuild >>"$CALLS"; }
        prepare_workspace() { :; }
        compile_xmrig() { :; }
        generate_xmrig_config() { echo config >>"$CALLS"; }
        install_service() { echo unit:service >>"$CALLS"; }
        install_autotune() { echo unit:autotune >>"$CALLS"; }
        install_watchdog() { echo unit:watchdog >>"$CALLS"; }
        install_api() { echo unit:api >>"$CALLS"; }
        install_control() { echo unit:control >>"$CALLS"; }
        install_api_firewall() { :; }
        _reown_worker() { :; }
        _upgrade_restart() { echo restart >>"$CALLS"; }
        _shared_host_remove() { :; }
        _post_upgrade_retune() { :; }
        _control_failed() { :; }
        _sister_api_failed() { :; }
        if [ "$1" = fail ]; then
            compile_xmrig() { error "build failed"; }
            error() { exit 1; }
        fi
        package_upgrade
    )
}

mkdir -p "$STATE"
: >"$CALLS"
rc=0
pkg_run ok || rc=$?
check "no marker: package-upgrade is a no-op" "$([ "$rc" -eq 0 ] && [ ! -s "$CALLS" ] && echo 0 || echo 1)"

echo 2.0.0 >"$STATE/upgrade-pending"
: >"$CALLS"
rc=0
pkg_run fail || rc=$?
check "failed upgrade exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "failed upgrade keeps the marker and records the failure" "$([ -f "$STATE/upgrade-pending" ] && [ -s "$STATE/upgrade-failed" ] && echo 0 || echo 1)"
check "failed upgrade does not restart or re-render units" "$(grep -qE 'restart|unit:' "$CALLS" && echo 1 || echo 0)"
status_out=$(
    source "$SCRIPT"
    warn() { echo "$*"; }
    _pkg_upgrade_status
)
check "status shows the failure and the retry command" "$(grep -q 'sudo rigforge upgrade' <<<"$status_out" && echo 0 || echo 1)"
doctor_out=$(
    source "$SCRIPT"
    _ck_warn() { echo "$1"; }
    _pkg_upgrade_doctor || echo DOCTOR_ISSUE
)
check "doctor reports the failure as an issue" "$(grep -q DOCTOR_ISSUE <<<"$doctor_out" && grep -q 'sudo rigforge upgrade' <<<"$doctor_out" && echo 0 || echo 1)"

: >"$CALLS"
rc=0
pkg_run ok || rc=$?
check "successful upgrade exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "successful upgrade clears the marker and failure" "$([ ! -e "$STATE/upgrade-pending" ] && [ ! -e "$STATE/upgrade-failed" ] && echo 0 || echo 1)"
check "successful upgrade re-renders every unit and restarts once" "$(for u in unit:service unit:autotune unit:watchdog unit:api unit:control; do grep -qx "$u" "$CALLS" || exit 1; done && [ "$(grep -cx restart "$CALLS")" -eq 1 ] && echo 0 || echo 1)"

[ "$fail" -eq 0 ] && echo "package upgrade: all checks passed"
exit "$fail"
