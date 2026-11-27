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
[ -z "${SYSTEMCTL_FAIL:-}" ] || [ "$1" = cat ]
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
check "first install queues nothing" "$([ ! -e "$D/first/var/lib/rigforge/upgrade-pending" ] && echo 0 || echo 1)"
check "first install creates the state dir" "$([ -d "$D/first/var/lib/rigforge" ] && echo 0 || echo 1)"
check "first install reloads systemd only" "$([ "$(cat "$CALLS")" = 'systemctl daemon-reload' ] && echo 0 || echo 1)"
check "first install prints the first-run step" "$(grep -q 'sudo rigforge setup' "$D/first/out" && echo 0 || echo 1)"

postinst noconf 1.0.0 2.0.0 n
check "upgrade without a configured miner is inert" "$([ ! -e "$D/noconf/var/lib/rigforge/upgrade-pending" ] && [ "$(cat "$CALLS")" = 'systemctl daemon-reload' ] && ! grep -q 'sudo rigforge setup' "$D/noconf/out" && echo 0 || echo 1)"

postinst same 2.0.0 2.0.0 y
check "same version is inert" "$([ ! -e "$D/same/var/lib/rigforge/upgrade-pending" ] && [ "$(cat "$CALLS")" = 'systemctl daemon-reload' ] && ! grep -q 'sudo rigforge setup' "$D/same/out" && echo 0 || echo 1)"

postinst older 2.0.0 1.9.0 y
check "downgrade is inert" "$([ ! -e "$D/older/var/lib/rigforge/upgrade-pending" ] && [ "$(cat "$CALLS")" = 'systemctl daemon-reload' ] && ! grep -q 'sudo rigforge setup' "$D/older/out" && echo 0 || echo 1)"

postinst queue 1.9.0 2.0.0 y
check "upgrade writes the marker" "$([ "$(cat "$D/queue/var/lib/rigforge/upgrade-pending")" = 2.0.0 ] && echo 0 || echo 1)"
check "queued marker is world-readable for unprivileged status" "$(find "$D/queue/var/lib/rigforge/upgrade-pending" -perm 0644 | grep -q . && echo 0 || echo 1)"
check "upgrade starts the unit with --no-block" "$(grep -qx 'systemctl start --no-block rigforge-upgrade.service' "$CALLS" && echo 0 || echo 1)"

postinst nosystemd 1.9.0 2.0.0 y n
rc=$?
check "no systemd: marker kept, exit 0, retry command printed" "$([ "$rc" -eq 0 ] && [ -f "$D/nosystemd/var/lib/rigforge/upgrade-pending" ] && grep -q 'sudo rigforge upgrade' "$D/nosystemd/out" && echo 0 || echo 1)"

set +e
SYSTEMCTL_FAIL=1 postinst sysfail 1.9.0 2.0.0 y
rc=$?
set -e
check "systemctl failure never fails dpkg" "$([ "$rc" -eq 0 ] && grep -q 'sudo rigforge upgrade' "$D/sysfail/out" && echo 0 || echo 1)"

maint() {
    local r="$D/$1" script=$2 arg=$3
    mkdir -p "$r/run/systemd/system" "$r/etc/rigforge" "$r/var/lib/rigforge" "$r/usr/lib/rigforge"
    echo '{}' >"$r/etc/rigforge/config.json"
    echo '{}' >"$r/usr/lib/rigforge/config.json"
    mkdir -p "$r/etc/systemd/system"
    printf 'ExecStart=/usr/lib/rigforge/rigforge.sh watchdog\n' >"$r/etc/systemd/system/rigforge-watchdog.service"
    printf 'ExecStart=/usr/lib/rigforge/xmrig/xmrig\n' >"$r/etc/systemd/system/xmrig.service"
    printf 'ExecStart=/usr/lib/rigforge/rigforge.sh other\n' >"$r/etc/systemd/system/rigforge-other.service"
    : >"$CALLS"
    RIGFORGE_PKG_ROOT="$r" PATH="$STUBS:$PATH" sh "$ROOT/packaging/debian/$script" "$arg" >"$r/out" 2>&1
}
for arg in upgrade failed-upgrade abort-install abort-upgrade disappear remove purge deconfigure; do
    for script in prerm postrm; do
        set +e
        maint "m-$script-$arg" "$script" "$arg"
        rc=$?
        set -e
        check "$script $arg exits 0" "$rc"
    done
done
maint prerm-remove prerm remove
for u in xmrig.service rigforge-upgrade.service rigforge-watchdog.timer rigforge-autotune.timer rigforge-control.service rigforge-api.service; do
    check "prerm remove stops and disables $u" "$(grep -qx "systemctl disable --now $u" "$CALLS" && echo 0 || echo 1)"
done
maint prerm-upgrade prerm upgrade
check "prerm upgrade leaves the miner running" "$([ ! -s "$CALLS" ] && echo 0 || echo 1)"
maint postrm-remove postrm remove
check "remove keeps config and state" "$([ -f "$D/postrm-remove/etc/rigforge/config.json" ] && [ -f "$D/postrm-remove/usr/lib/rigforge/config.json" ] && [ -d "$D/postrm-remove/var/lib/rigforge" ] && echo 0 || echo 1)"
maint postrm-purge postrm purge
check "purge removes config, state and the tree's leftovers" "$([ ! -e "$D/postrm-purge/etc/rigforge" ] && [ ! -e "$D/postrm-purge/var/lib/rigforge" ] && [ ! -e "$D/postrm-purge/usr/lib/rigforge" ] && echo 0 || echo 1)"
check "purge removes the units setup rendered for the package tree" "$([ ! -e "$D/postrm-purge/etc/systemd/system/xmrig.service" ] && [ ! -e "$D/postrm-purge/etc/systemd/system/rigforge-watchdog.service" ] && echo 0 || echo 1)"
check "purge keeps a unit it did not render" "$([ -f "$D/postrm-purge/etc/systemd/system/rigforge-other.service" ] && echo 0 || echo 1)"
check "remove keeps the rendered units" "$([ -f "$D/postrm-remove/etc/systemd/system/xmrig.service" ] && echo 0 || echo 1)"
set +e
SYSTEMCTL_FAIL=1 maint prerm-fail prerm remove
rc=$?
set -e
check "prerm remove fails when a unit cannot be stopped" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "purge never touches tuning" "$(! grep -rqE 'grub|sysctl|hugepages|wrmsr|modprobe' "$ROOT/packaging/debian/postrm" "$ROOT/packaging/debian/prerm" && echo 0 || echo 1)"

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
        _root_guard_check() { :; }
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
        case "$1" in
        fail)
            compile_xmrig() { error "build failed"; }
            error() { exit 1; }
            ;;
        cmdfail) install_watchdog() { false; } ;;
        apifail) install_api() { return 1; } ;;
        esac
        package_upgrade
    )
}

mkdir -p "$STATE"
: >"$CALLS"
rc=0
pkg_run ok || rc=$?
check "no marker: package-upgrade is a no-op" "$([ "$rc" -eq 0 ] && [ ! -s "$CALLS" ] && echo 0 || echo 1)"

for mode in fail cmdfail apifail; do
    rm -f "$STATE/upgrade-failed"
    echo 2.0.0 >"$STATE/upgrade-pending"
    : >"$CALLS"
    set +e
    pkg_run "$mode" >/dev/null 2>&1
    rc=$?
    set -e
    check "$mode: exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
    check "$mode: keeps the marker and records the failure" "$([ -f "$STATE/upgrade-pending" ] && [ -s "$STATE/upgrade-failed" ] && echo 0 || echo 1)"
    check "$mode: failure record is world-readable for unprivileged status" "$(find "$STATE/upgrade-failed" -perm 0644 | grep -q . && echo 0 || echo 1)"
    check "$mode: does not restart the miner" "$(grep -qx restart "$CALLS" && echo 1 || echo 0)"
done
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
set +e
pkg_run ok >/dev/null 2>&1
rc=$?
set -e
check "successful upgrade exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "successful upgrade clears the marker and failure" "$([ ! -e "$STATE/upgrade-pending" ] && [ ! -e "$STATE/upgrade-failed" ] && echo 0 || echo 1)"
check "successful upgrade re-renders every unit and restarts once" "$(for u in unit:service unit:autotune unit:watchdog unit:api unit:control; do grep -qx "$u" "$CALLS" || exit 1; done && [ "$(grep -cx restart "$CALLS")" -eq 1 ] && echo 0 || echo 1)"

eval "$(sed -n '/^make_stubs() {/,/^STUBS=/p' "$ROOT/tests/run.sh" | sed '$d')"
RIG="$D/rig"
RS="$D/rigstubs"
make_stubs "$RS"
mkdir -p "$RIG/home/worker/xmrig/build" "$RIG/etc-systemd" "$RIG/logrotate" "$RIG/state" "$RS/own"
cp "$ROOT/VERSION" "$RIG/"
cp -R "$ROOT/systemd" "$RIG/"
: >"$RIG/home/worker/xmrig/build/xmrig"
chmod +x "$RIG/home/worker/xmrig/build/xmrig"
printf 'ABC\n' >"$RIG/home/worker/xmrig/.rigforge-commit"
printf '0\n' >"$RIG/home/worker/xmrig/.rigforge-donate-min"
printf '#!/usr/bin/env bash\ncase "$*" in -u) echo 0 ;; -un) echo root ;; *) exec /usr/bin/id "$@" ;; esac\n' >"$RS/own/id"
printf '#!/usr/bin/env bash\necho "[chown] $*" >>"$CALL_LOG"\n' >"$RS/own/chown"
chmod +x "$RS/own"/*
rig_run() {
    (
        cd "$RIG"
        env -u SUDO_USER -u USER -u RIGFORGE_OPERATOR PATH="$RS/own:$RS:$PATH" LOGROTATE_DIR="$RIG/logrotate" SYSTEMD_DIR="$RIG/etc-systemd" \
            CALL_LOG="$RIG/calls.log" STUB_UNAME_S=Linux XMRIG_COMMIT=ABC RIGFORGE_PKG_STATE="$RIG/state" \
            RIGFORGE_HOME="$RIG" bash "$SCRIPT" package-upgrade </dev/null 2>&1
    )
}
for wd in disabled enabled; do
    printf '{"HOME_DIR": "%s/home", "DONATION": 1, "watchdog": "%s", "pools": [{"url": "poolbox.lan:3333"}]}\n' "$RIG" "$wd" >"$RIG/config.json"
    OP=$(id -un)
    if [ "$OP" = root ]; then
        chown nobody "$RIG/config.json"
        OP=nobody
    fi
    rm -f "$RIG/etc-systemd"/*
    echo 2.0.0 >"$RIG/state/upgrade-pending"
    : >"$RIG/calls.log"
    set +e
    rig_out=$(rig_run)
    rc=$?
    set -e
    check "watchdog $wd: real package-upgrade exits 0" "$([ "$rc" -eq 0 ] && echo 0 || {
        echo "$rig_out" >&2
        echo 1
    })"
    check "watchdog $wd: renders the miner unit" "$([ -s "$RIG/etc-systemd/xmrig.service" ] && echo 0 || echo 1)"
    check "watchdog $wd: rewrites the generated config" "$([ "$(jq -r '.pools[0].url' "$RIG/home/worker/xmrig/build/config.json")" = poolbox.lan:3333 ] && echo 0 || echo 1)"
    check "watchdog $wd: hands the tree back to the config owner, not root" "$(grep -qF "$OP:$OP" "$RIG/calls.log" && ! grep -qF 'root:root' "$RIG/calls.log" && echo 0 || echo 1)"
    check "watchdog $wd: bakes no root operator into rendered units" "$(grep -rq 'RIGFORGE_OPERATOR=root' "$RIG/etc-systemd" && echo 1 || echo 0)"
    check "watchdog $wd: restarts the miner once and clears the marker" "$([ "$(grep -c 'systemctl\] restart xmrig.service' "$RIG/calls.log")" -eq 1 ] && [ ! -e "$RIG/state/upgrade-pending" ] && echo 0 || echo 1)"
done
check "watchdog enabled: the rendered watchdog unit bakes the config owner" "$(grep -qx "Environment=RIGFORGE_OPERATOR=$OP" "$RIG/etc-systemd/rigforge-watchdog.service" && echo 0 || echo 1)"

[ "$fail" -eq 0 ] && echo "package upgrade: all checks passed"
exit "$fail"
