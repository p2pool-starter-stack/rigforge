#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT=${1:-"$ROOT/rigforge.sh"}
PASS=0
FAIL=0
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"
}
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi; }
assert_has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "missing [$2] in [$1]" ;; esac }

echo "== unit: root-guard refuses root-run units on a tree a non-root user can write (#783) =="

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
R=$(cd -P "$T" && pwd -P)
TREE="$R/home/op/rigforge"
mkdir -p "$TREE/util" "$TREE/systemd" "$R/etc-systemd" "$R/etc"
cp "$ROOT/util/root-guard.sh" "$TREE/util/root-guard.sh"
: >"$TREE/rigforge.sh"
: >"$TREE/util/helper.sh"
: >"$TREE/util/server.py"
: >"$TREE/systemd/xmrig.service.template"
: >"$TREE/config.json"

source "$SCRIPT"
source "$TREE/util/root-guard.sh"
set +eu
OS_TYPE=Linux
SCRIPT_DIR="$TREE"
SYSTEMD_DIR="$R/etc-systemd"
SERVICE_NAME=xmrig
ROOT_GUARD_STAMP="$R/etc/rigforge-root-guard"
TAB="$R/stat.tab"
SUDO_OK=1
sudo() { [ "$SUDO_OK" = 1 ] && "$@"; }
stat() {
    local p="${!#}" v
    v=$(awk -v p="$p" '$1 == p { print $2; exit }' "$TAB")
    case "$v" in fail) return 1 ;; '') echo 0:0:755 ;; *) echo "$v" ;; esac
}
reset() {
    printf '%s\n' "$@" >"$TAB"
    rm -rf "$ROOT_GUARD_STAMP" "$TREE/.git" "$TREE/.rigforge-package" "$SYSTEMD_DIR/xmrig.service"
}
guard() {
    out=$(_root_guard_check "$@" 2>&1)
    rc=$?
}

reset
guard ""
assert_eq "$rc:$out" "0:" "root-owned tree passes silently"

reset "$TREE/config.json 1000:1000:600"
guard ""
assert_eq "$rc:$out" "0:" "operator-owned config.json is data and passes on the next run"

reset "$TREE/util/helper.sh 1000:1000:644"
guard ""
assert_eq "$rc" 1 "user-owned sourced util/*.sh refused"
assert_has "$out" "$TREE/util/helper.sh is owned by uid 1000" "refusal names the path"

reset "$TREE/util 0:1000:775"
guard ""
assert_eq "$rc" 1 "util/ writable by a non-root group refused"
assert_has "$out" "$TREE/util is writable by group 1000" "group refusal names the directory"

reset "$TREE/rigforge.sh 0:0:775"
guard ""
assert_eq "$rc" 0 "group-writable by root's group passes"

reset "$TREE/util/server.py 0:0:646"
guard ""
assert_eq "$rc" 1 "other-writable unit-loaded util/*.py refused"

reset "$TREE/systemd/xmrig.service.template 0:1000:664"
guard ""
assert_eq "$rc" 1 "group-writable unit template refused"

reset "$R/home/op 1000:1000:755"
guard ""
assert_eq "$rc" 1 "user-owned ancestor of a root-owned tree refused"
assert_has "$out" "$R/home/op is owned by uid 1000" "ancestor refusal names the ancestor"

reset "$R/home 0:0:1557"
guard ""
assert_eq "$rc" 1 "other-writable ancestor with a special bit refused"

reset "$TREE/systemd fail"
guard ""
assert_eq "$rc" 1 "a stat failure refuses"

reset "$TREE/rigforge.sh 1000:1000:755"
guard ""
assert_eq "$rc" 1 "user-owned checkout refused without the flag"
RIGFORGE_ROOT_GUARD_ALLOW=1 ROOT_GUARD_ALLOW=true guard ""
assert_eq "$rc" 1 "environment variables are not an allowance"

guard 1
assert_eq "$rc" 0 "--no-root-guard allows a user-owned checkout"
assert_has "$out" "continuing because --no-root-guard was given" "--no-root-guard prints a warning"
assert_eq "$(cat "$ROOT_GUARD_STAMP")" "allow $TREE" "--no-root-guard records the allowance"

guard ""
assert_eq "$rc" 0 "recorded allowance is honoured without the flag"
assert_has "$out" "allowance recorded in $ROOT_GUARD_STAMP" "recorded allowance prints a warning"

printf '%s\n' "$TREE/rigforge.sh 1000:1000:755" "$R/etc 1000:1000:755" >"$TAB"
guard ""
assert_eq "$rc" 1 "allowance in a user-writable place is ignored"

reset "$TREE/rigforge.sh 1000:1000:755"
printf 'allow %s\n' "$R/elsewhere" >"$ROOT_GUARD_STAMP"
guard ""
assert_eq "$rc" 1 "allowance for another tree is ignored"

reset "$TREE/rigforge.sh 1000:1000:755"
mkdir "$TREE/.git"
: >"$SYSTEMD_DIR/xmrig.service"
guard ""
assert_eq "$rc" 0 "existing git install without an allowance is allowed once"
assert_has "$out" "predates the root guard" "the one-time allowance warns"
assert_eq "$(cat "$ROOT_GUARD_STAMP")" "allow $TREE" "the one-time allowance is recorded"

reset "$TREE/rigforge.sh 1000:1000:755"
mkdir "$TREE/.git"
guard ""
assert_eq "$rc" 1 "fresh git checkout is not grandfathered"

reset "$TREE/rigforge.sh 1000:1000:755"
mkdir "$TREE/.git"
: >"$SYSTEMD_DIR/xmrig.service"
printf 'brew\n' >"$TREE/.rigforge-package"
guard ""
assert_eq "$rc" 1 "packaged tree is never grandfathered"

reset "$TREE/rigforge.sh 1000:1000:755"
SUDO_OK=0 guard 1
assert_eq "$rc" 0 "a failed allowance write does not stop a flagged run"
assert_has "$out" "could not record the allowance" "a failed allowance write warns"

reset "$TREE/rigforge.sh 1000:1000:755"
OS_TYPE=Darwin guard ""
assert_eq "$rc" 0 "Darwin installs no root-run units and is skipped"

f0=$FAIL
(
    _persist_appliance_mode() { :; }
    check_prerequisites() { :; }
    _root_guard_check() {
        printf '%s' "$1" >"$R/flag"
        return 1
    }
    for verb in main upgrade; do
        "$verb" --no-root-guard >/dev/null 2>&1
        assert_eq "$?:$(cat "$R/flag")" "1:1" "$verb --no-root-guard passes the flag to the guard"
        "$verb" >/dev/null 2>&1
        assert_eq "$?:$(cat "$R/flag")" "1:" "$verb without the flag passes none"
    done
    [ "$FAIL" -eq "$f0" ]
) || FAIL=$((FAIL + 1))

echo "root guard: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
