#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC2034,SC2317
set -euo pipefail

echo "== unit: root-guard refuses root-run units on non-root-owned tree (#783) =="

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-"$ROOT/rigforge.sh"}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
ok() { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad() {
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"
    exit 1
}
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi; }
assert_rc() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected rc $2, got $1"; fi; }

unset RIGFORGE_ROOT_GUARD_ALLOW ROOT_GUARD_ALLOW
source "$SCRIPT"
PASS=0
FAIL=0

mkdir -p "$TEST_TMP/util"
cp "$ROOT/util/root-guard.sh" "$TEST_TMP/util/root-guard.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$TEST_TMP/rigforge.sh"
chmod +x "$TEST_TMP/rigforge.sh"
printf 'print("api")\n' >"$TEST_TMP/util/api-server.py"
printf 'print("control")\n' >"$TEST_TMP/util/control-server.py"
printf '{}\n' >"$TEST_TMP/config.json"

_test_root_guard() {
    local uid="${1:-0}" uname="${2:-root}" os="${3:-Linux}"
    (
        set +e
        SCRIPT_DIR="$TEST_TMP"
        OS_TYPE="$os"
        RIGFORGE_ROOT_GUARD_ALLOW=""
        ROOT_GUARD_ALLOW=""
        stat() {
            case "$*" in
            *'-c'*'%U'*) echo "$uname" ;;
            *'-c'*'%u'* | *'-c'*'%g'*) echo "$uid" ;;
            *'-c'*'%a'* | *'-c'*'%A'*) echo "755" ;;
            *) /usr/bin/stat "$@" ;;
            esac
        }
        source "$TEST_TMP/util/root-guard.sh"
        _root_guard_check >/dev/null 2>&1
        echo $?
    )
}

rc=$(_test_root_guard 0 root)
assert_eq "$rc" "0" "root-owned tree passes (#783)"

rc=$(_test_root_guard 1000 vijit)
assert_eq "$rc" "1" "non-root-owned tree refused (#783)"

(
    set +e
    SCRIPT_DIR="$TEST_TMP"
    OS_TYPE=Linux
    ROOT_GUARD_DISABLED=true
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1" "ROOT_GUARD_DISABLED env var is rejected (#783)"
)

(
    set +e
    SCRIPT_DIR="$TEST_TMP"
    OS_TYPE=Linux
    RIGFORGE_ROOT_GUARD_ALLOW=1
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "0" "CLI flag allows non-root (#783)"
)

(
    set +e
    SCRIPT_DIR="$TEST_TMP"
    OS_TYPE=Linux
    RIGFORGE_ROOT_GUARD_ALLOW=""
    ROOT_GUARD_ALLOW=true
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "0" "persisted allowance honours non-root (#783)"
)

rc=$(_test_root_guard 1000 vijit Darwin)
assert_eq "$rc" "0" "Darwin skips guard (#783)"

(
    set +e
    OS_TYPE=Linux
    stat() {
        case "$*" in
        *'-c'*'%U'*) echo "root" ;;
        *'-c'*'%u'* | *'-c'*'%g'* | *'-c'*'%a'* | *'-c'*'%A'*) echo "0" ;;
        *) /usr/bin/stat "$@" ;;
        esac
    }
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "0" "missing SCRIPT_DIR passes (#783)"
)

(
    set +e
    SCRIPT_DIR="/nonexistent/path"
    OS_TYPE=Linux
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "0" "non-existent SCRIPT_DIR passes (#783)"
)

TEST_ANC=$(mktemp -d)
mkdir -p "$TEST_ANC/parent/child"
cp "$TEST_TMP/rigforge.sh" "$TEST_ANC/parent/child/rigforge.sh"
mkdir -p "$TEST_ANC/parent/child/util"
cp "$TEST_TMP/util/root-guard.sh" "$TEST_ANC/parent/child/util/root-guard.sh"
cp "$TEST_TMP/util/api-server.py" "$TEST_ANC/parent/child/util/api-server.py"
cp "$TEST_TMP/util/control-server.py" "$TEST_ANC/parent/child/util/control-server.py"
cp "$TEST_TMP/config.json" "$TEST_ANC/parent/child/config.json"

(
    set +e
    chmod 775 "$TEST_ANC/parent/child"
    SCRIPT_DIR="$TEST_ANC/parent/child"
    OS_TYPE=Linux
    stat() {
        case "$*" in
        *'-c'*'%U'*) echo "root" ;;
        *'-c'*'%u'* | *'-c'*'%g'*) echo "0" ;;
        *'-c'*'%a'* | *'-c'*'%A'*) /usr/bin/stat "$@" ;;
        *) /usr/bin/stat "$@" ;;
        esac
    }
    source "$TEST_ANC/parent/child/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1" "group-writable dir refused even if root-owned (#783)"
)

(
    set +e
    chmod 774 "$TEST_ANC/parent/child"
    chmod 1557 "$TEST_ANC/parent"
    SCRIPT_DIR="$TEST_ANC/parent/child"
    OS_TYPE=Linux
    stat() {
        case "$*" in
        *'-c'*'%U'*) echo "root" ;;
        *'-c'*'%u'* | *'-c'*'%g'*) echo "0" ;;
        *'-c'*'%a'* | *'-c'*'%A'*) /usr/bin/stat "$@" ;;
        *) /usr/bin/stat "$@" ;;
        esac
    }
    source "$TEST_ANC/parent/child/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1" "other-writable ancestor refused (#783)"
    chmod 755 "$TEST_ANC/parent"
)

(
    set +e
    chmod 774 "$TEST_ANC/parent/child/util/api-server.py"
    SCRIPT_DIR="$TEST_ANC/parent/child"
    OS_TYPE=Linux
    stat() {
        case "$*" in
        *'-c'*'%U'*) echo "root" ;;
        *'-c'*'%u'* | *'-c'*'%g'*) echo "0" ;;
        *'-c'*'%a'* | *'-c'*'%A'*) /usr/bin/stat "$@" ;;
        *) /usr/bin/stat "$@" ;;
        esac
    }
    source "$TEST_ANC/parent/child/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1" "group-writable util file refused (#783)"
)

rm -rf "$TEST_ANC"

(
    set +e
    stat() { return 1; }
    SCRIPT_DIR="$TEST_TMP"
    OS_TYPE=Linux
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1" "stat failure fails closed (#783)"
)

(
    set +e
    SCRIPT_DIR="$TEST_TMP"
    OS_TYPE=Linux
    ROOT_GUARD_ALLOW=true
    RIGFORGE_ROOT_GUARD_ALLOW=""
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "0" "systemd-baked ROOT_GUARD_ALLOW honours allowance (#783)"
)

(
    set +e
    SCRIPT_DIR="$TEST_TMP"
    OS_TYPE=Linux
    stat() {
        case "$*" in
        *'-c'*'%U'*) echo "root" ;;
        *'-c'*'%u'* | *'-c'*'%g'*) echo "0" ;;
        *'-c'*'%a'* | *'-c'*'%A'*) echo "755" ;;
        *) /usr/bin/stat "$@" ;;
        esac
    }
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "0" "ancestor walk completes successfully (#783)"
)

(
    set +e
    printf 'print("extra")\n' >"$TEST_TMP/util/extra.py"
    stat() {
        local arg="$1" fpath="${3:-}"
        case "$arg" in
        *-c*)
            case "$2" in
            *%U*)
                case "$fpath" in
                *extra.py*) echo "nonroot" ;;
                *) echo "${RG_UNAME:-root}" ;;
                esac
                ;;
            *%u*)
                case "$fpath" in
                *extra.py*) echo "1000" ;;
                *) echo "${RG_UID:-0}" ;;
                esac
                ;;
            *) echo "${RG_UID:-0}" ;;
            esac
            ;;
        *) /usr/bin/stat "$@" ;;
        esac
    }
    RG_UID=0 RG_UNAME=root
    SCRIPT_DIR="$TEST_TMP"
    OS_TYPE=Linux
    source "$TEST_TMP/util/root-guard.sh"
    _root_guard_check >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1" "non-root util/extra.py refused (#783)"
    rm -f "$TEST_TMP/util/extra.py"
)

(
    set +e
    _persist_appliance_mode() { :; }
    check_prerequisites() { :; }
    _root_guard_check() { return 1; }
    for verb in main upgrade; do
        unset RIGFORGE_ROOT_GUARD_ALLOW
        "$verb" --no-root-guard >/dev/null 2>&1
        rc=$?
        assert_eq "$rc:${RIGFORGE_ROOT_GUARD_ALLOW:-}" "1:1" "$verb --no-root-guard sets the allowance (#783)"
    done
)

echo "root guard: PASS (passed $PASS, failed $FAIL)"
[ "$FAIL" -eq 0 ]
