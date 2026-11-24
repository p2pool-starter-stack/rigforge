#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D/rf" RIGFORGE_APPLIANCE=0 NO_COLOR=1
mkdir -p "$RIGFORGE_HOME"
source "$SCRIPT"
OS_TYPE=Linux

fail() {
    printf 'uninstall state regression: %s\n' "$1" >&2
    exit 1
}
sudo() {
    local a
    case "$1" in
    nft | update-grub | mount | umount) return 0 ;;
    rm | rmdir)
        for a in "${@:2}"; do
            case "$a" in
            "$D"/* | -*) ;;
            *)
                echo "$a" >>"$D/refused"
                return 0
                ;;
            esac
        done
        ;;
    esac
    "$@"
}
systemctl() { :; }

CONFIG_JSON="$D/no-config.json"
SYSTEMD_DIR="$D/systemd"
LOGROTATE_DIR="$D/logrotate"
FSTAB="$D/fstab"
LIMITS_CONF="$D/limits"
MODULES_FILE="$D/modules"
MODULES_LOAD_DIR="$D/no-modules-load.d"
GRUB_DEFAULT="$D/no-grub"
HUGEPAGES_1G_DIR="$D/hugepages"
BIN_DIR="$D/bin"
REAL_USER=opuser
RIGFORGE_CONTROL_STATE="$D/ctl"
RIGFORGE_CONTROL_UPGRADE_STATE="$D/ctlu"
mkdir -p "$SYSTEMD_DIR" "$LOGROTATE_DIR" "$BIN_DIR" "$D/outside"
: >"$D/outside/keep"
: >"$D/refused"

printf 'root hard nofile 1024\n* soft memlock unlimited\n' >"$LIMITS_CONF"
printf 'loop\nmsr\n' >"$MODULES_FILE"
: >"$FSTAB"
configure_limits >/dev/null 2>&1
grep -qFx 'opuser soft memlock unlimited' "$LIMITS_CONF" || fail 'setup did not write the memlock lines for the mining user'
mkdir -p "$D/ctl/spool" "$D/ctlu"
: >"$D/ctl/spool/pending-1.json"
: >"$D/ctlu/stamp"
uninstall --yes >/dev/null 2>&1
[ ! -e "$D/ctl" ] || fail 'uninstall left the control state directory'
[ ! -e "$D/ctlu" ] || fail 'uninstall left the upgrade state directory'
! grep -q '^opuser ' "$LIMITS_CONF" || fail 'uninstall kept the memlock lines setup wrote'
grep -qFx '* soft memlock unlimited' "$LIMITS_CONF" || fail 'uninstall removed a wildcard memlock line that setup never writes'
grep -qFx 'root hard nofile 1024' "$LIMITS_CONF" || fail 'uninstall removed an unrelated limits line'
! grep -qFx 'msr' "$MODULES_FILE" || fail 'uninstall kept the msr line'
[ ! -s "$D/refused" ] || fail 'uninstall tried to remove a path outside the sandbox'

ln -s "$D/outside" "$D/ctl"
RIGFORGE_CONTROL_STATE="$D/ctl/"
uninstall --yes >/dev/null 2>&1
[ ! -L "$D/ctl" ] || fail 'uninstall kept a control state symlink'
[ -f "$D/outside/keep" ] || fail 'uninstall followed a control state symlink'

for v in / // . relative ../.. -rf "$D/outside//"; do
    RIGFORGE_CONTROL_STATE=$v
    RIGFORGE_CONTROL_UPGRADE_STATE=$v
    uninstall --yes >/dev/null 2>&1
    [ ! -s "$D/refused" ] || fail "uninstall tried to remove '$(cat "$D/refused")' for the state path '$v'"
    [ -f "$D/outside/keep" ] || fail "uninstall removed a directory for the state path '$v'"
done

unset RIGFORGE_CONTROL_STATE RIGFORGE_CONTROL_UPGRADE_STATE
uninstall --yes >/dev/null 2>&1
[ "$(tr '\n' ' ' <"$D/refused")" = '/var/lib/rigforge-control /var/lib/rigforge-control-upgrade ' ] || fail 'uninstall did not target the default control state directories'

printf 'uninstall state regressions: PASS\n'
