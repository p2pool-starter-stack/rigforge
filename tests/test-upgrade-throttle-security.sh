#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-$ROOT/rigforge.sh}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

status() { jq -r .status "$1/state/status.json"; }

UNIT=$ROOT/systemd/rigforge-control-upgrade.service.template
grep -Fxq 'StateDirectory=rigforge-control-upgrade' "$UNIT" || fail "upgrade unit lacks protected persistent state"
grep -Fxq 'StateDirectoryMode=0700' "$UNIT" || fail "upgrade unit state mode is not 0700"

fake_root_stat() {
    [ "$(id -u)" -eq 0 ] && return
    stat() {
        case "$2" in
        %u:%g:%a) printf '0:0:700\n' ;;
        %u:%g:%a:%h) printf '0:0:600:1\n' ;;
        *) return 1 ;;
        esac
    }
}

run_upgrade() {
    local d=$1 cid=$2
    mkdir -p "$d/state/spool" "$d/processing"
    printf '{"version":"v9.9.9"}\n' >"$d/state/spool/upgrade-$cid.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR=$d
        CONFIG_JSON=$d/config.json
        RIGFORGE_CONTROL_STATE=$d/state
        RIGFORGE_CONTROL_PROCESSING=$d/processing
        RIGFORGE_CONTROL_UPGRADE_STATE=$d/upgrade-state
        CONTROL_UPGRADE_MIN_INTERVAL=3600
        parse_config() { :; }
        _control_claim_staged() {
            local claimed="$RIGFORGE_CONTROL_PROCESSING/$2.json"
            cp "$1" "$claimed" && rm -f "$1" && printf '%s\n' "$claimed"
        }
        _control_upgrade_do() { printf 'build %s\n' "$1" >>"$d/work.log"; }
        _wait_miner_live() { return 0; }
        git() {
            printf 'git %s\n' "$*" >>"$d/work.log"
            case "$*" in
            *describe*) printf 'v1.0.0\n' ;;
            *rev-parse*) printf 'deadbeef\n' ;;
            esac
        }
        fake_root_stat
        control_upgrade >/dev/null 2>&1
    )
}

for object in .upgrade-throttle.lock upgrade-last; do
    case_dir=$TMP/symlink-${object#.}
    mkdir -p "$case_dir"
    mkdir -m 700 "$case_dir/upgrade-state"
    printf 'do not change\n' >"$case_dir/upgrade-state/target"
    chmod 600 "$case_dir/upgrade-state/target"
    cp "$case_dir/upgrade-state/target" "$case_dir/expected"
    ln -s "$case_dir/upgrade-state/target" "$case_dir/upgrade-state/$object"
    run_upgrade "$case_dir" abcdef0123456789
    cmp -s "$case_dir/upgrade-state/target" "$case_dir/expected" || fail "$object changed its symlink target"
    [ "$(status "$case_dir")" = failed ] || fail "$object did not fail the upgrade"
    [ ! -e "$case_dir/work.log" ] || fail "$object allowed git or build work"
done

legacy=$TMP/legacy
mkdir -p "$legacy"
mkdir -m 700 "$legacy/upgrade-state" "$legacy/state"
printf 'legacy lock\n' >"$legacy/legacy-lock-target"
printf 'legacy stamp\n' >"$legacy/legacy-stamp-target"
ln -s "$legacy/legacy-lock-target" "$legacy/state/.upgrade-throttle.lock"
ln -s "$legacy/legacy-stamp-target" "$legacy/state/upgrade-last"
run_upgrade "$legacy" 1111111111111111
[ "$(status "$legacy")" = applied ] || fail "legacy receiver objects blocked the first upgrade"
[ "$(cat "$legacy/legacy-lock-target")" = "legacy lock" ] || fail "legacy lock target changed"
[ "$(cat "$legacy/legacy-stamp-target")" = "legacy stamp" ] || fail "legacy stamp target changed"
[ -f "$legacy/upgrade-state/upgrade-last" ] || fail "protected throttle stamp was not created"
work_before=$(wc -l <"$legacy/work.log" | tr -d ' ')
run_upgrade "$legacy" 2222222222222222
[ "$(status "$legacy")" = throttled ] || fail "repeat upgrade was not throttled"
[ "$(wc -l <"$legacy/work.log" | tr -d ' ')" = "$work_before" ] || fail "throttled upgrade performed work"

if [ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ]; then
    helper_rc() {
        local dir=$1 mode=${2:-}
        shift
        (
            source "$SCRIPT"
            CONTROL_UPGRADE_MIN_INTERVAL=3600
            case "$mode" in
            flock) flock() { return 1; } ;;
            cat) cat() { return 1; } ;;
            mktemp) mktemp() { return 1; } ;;
            mv) mv() { return 1; } ;;
            printf) printf() { return 1; } ;;
            esac
            set +e
            _control_upgrade_throttle_ok "$dir" >/dev/null 2>&1
            rc=$?
            command printf '%s\n' "$rc"
        )
    }

    secure=$TMP/helper-secure
    mkdir -m 700 "$secure"
    [ "$(helper_rc "$secure" :)" = 0 ] || fail "secure throttle directory rejected"
    [ "$(helper_rc "$secure" :)" = 1 ] || fail "secure throttle did not enforce cooldown"

    existing=$TMP/helper-existing
    mkdir -m 700 "$existing"
    : >"$existing/.upgrade-throttle.lock"
    date +%s >"$existing/upgrade-last"
    chmod 600 "$existing/.upgrade-throttle.lock" "$existing/upgrade-last"
    [ "$(helper_rc "$existing" :)" = 1 ] || fail "safe existing throttle objects rejected"

    for bad_stamp in empty malformed; do
        bad=$TMP/helper-stamp-$bad_stamp
        mkdir -m 700 "$bad"
        : >"$bad/upgrade-last"
        [ "$bad_stamp" = malformed ] && printf 'invalid\n' >"$bad/upgrade-last"
        chmod 600 "$bad/upgrade-last"
        [ "$(helper_rc "$bad" :)" = 2 ] || fail "$bad_stamp throttle stamp accepted"
    done

    writable=$TMP/helper-writable
    mkdir -m 770 "$writable"
    [ "$(helper_rc "$writable" :)" = 2 ] || fail "group-writable throttle directory accepted"

    nonroot=$TMP/helper-nonroot
    mkdir -m 700 "$nonroot"
    chown 1:1 "$nonroot"
    [ "$(helper_rc "$nonroot" :)" = 2 ] || fail "non-root throttle directory accepted"

    real_parent=$TMP/helper-real-parent
    mkdir -m 700 "$real_parent"
    ln -s "$real_parent" "$TMP/helper-parent-link"
    [ "$(helper_rc "$TMP/helper-parent-link" :)" = 2 ] || fail "symlink throttle directory accepted"
    missing=$TMP/helper-missing
    [ "$(helper_rc "$missing" :)" = 2 ] || fail "missing throttle directory was created"
    [ ! -e "$missing" ] || fail "helper created its protected parent"

    for object in .upgrade-throttle.lock upgrade-last; do
        hard=$TMP/hard-${object#.}
        mkdir -m 700 "$hard"
        printf 'linked\n' >"$hard/target"
        chmod 600 "$hard/target"
        ln "$hard/target" "$hard/$object"
        [ "$(helper_rc "$hard" :)" = 2 ] || fail "$object hardlink accepted"
        [ "$(cat "$hard/target")" = linked ] || fail "$object hardlink target changed"

        special=$TMP/special-${object#.}
        mkdir -m 700 "$special" "$special/$object"
        [ "$(helper_rc "$special" :)" = 2 ] || fail "$object directory accepted"

        fifo=$TMP/fifo-${object#.}
        mkdir -m 700 "$fifo"
        mkfifo "$fifo/$object"
        [ "$(helper_rc "$fifo" :)" = 2 ] || fail "$object FIFO accepted"

        mode=$TMP/mode-${object#.}
        mkdir -m 700 "$mode"
        printf 'unsafe\n' >"$mode/$object"
        chmod 660 "$mode/$object"
        [ "$(helper_rc "$mode" :)" = 2 ] || fail "$object with unsafe mode accepted"

        owner=$TMP/owner-${object#.}
        mkdir -m 700 "$owner"
        printf '1\n' >"$owner/$object"
        chmod 600 "$owner/$object"
        chown 1:1 "$owner/$object"
        [ "$(helper_rc "$owner" :)" = 2 ] || fail "non-root $object accepted"
    done

    for failure in flock mktemp mv printf; do
        failed=$TMP/helper-failure-$failure
        mkdir -m 700 "$failed"
        if [ "$failure" != flock ]; then
            printf '1\n' >"$failed/upgrade-last"
            chmod 600 "$failed/upgrade-last"
        fi
        [ "$(helper_rc "$failed" "$failure")" = 2 ] || fail "$failure failure did not fail closed"
        if [ "$failure" != flock ]; then
            [ "$(cat "$failed/upgrade-last")" = 1 ] || fail "$failure changed the prior stamp"
            [ -z "$(find "$failed" -name '.upgrade-last.*' -print)" ] || fail "$failure left a temporary stamp"
        fi
    done
    failed=$TMP/helper-failure-cat
    mkdir -m 700 "$failed"
    printf '1\n' >"$failed/upgrade-last"
    chmod 600 "$failed/upgrade-last"
    [ "$(helper_rc "$failed" cat)" = 2 ] || fail "stamp read failure did not fail closed"
    [ "$(cat "$failed/upgrade-last")" = 1 ] || fail "read failure changed the prior stamp"
fi

REAL_UPG_CLEAR=$(sed -n '/^_upgrade_clear_throttles()/,/^}/p' "$ROOT/tests/e2e-real.sh")
REAL_UPG=$(sed -n '/^_upgrade_cleanup()/,/^}/p' "$ROOT/tests/e2e-real.sh")
legacy_links=$TMP/cleanup-legacy-links
mkdir -p "$legacy_links"
printf 'stamp-target\n' >"$legacy_links/stamp-target"
printf 'lock-target\n' >"$legacy_links/lock-target"
ln -s "$legacy_links/stamp-target" "$legacy_links/stamp-link"
ln -s "$legacy_links/lock-target" "$legacy_links/lock-link"
(
    eval "$REAL_UPG_CLEAR"
    eval "$REAL_UPG"
    UPG_ORIG_REF="" UPG_RESTORE_BUILD=0 UPG_STAMP="$legacy_links/protected" UPG_LEGACY_STAMP="$legacy_links/stamp-link" UPG_LEGACY_LOCK="$legacy_links/lock-link"
    _hgit() { return 1; }
    _control_cleanup() { :; }
    _upgrade_cleanup >/dev/null 2>&1
)
[ "$(cat "$legacy_links/stamp-target")" = stamp-target ] || fail "legacy stamp cleanup followed its symlink"
[ "$(cat "$legacy_links/lock-target")" = lock-target ] || fail "legacy lock cleanup followed its symlink"
[ ! -L "$legacy_links/stamp-link" ] && [ ! -L "$legacy_links/lock-link" ] || fail "legacy throttle symlinks survived cleanup"

UPG_OLD_THROTTLE_BLOCK=$(sed -n '/^                if _upgrade_clear_throttles; then/,/^                fi$/p' "$ROOT/tests/e2e-real.sh")
old_gate_result() {
    local cleanup_rc=$1
    (
        st=not-posted failures=0 tok='' control_port='' cur_tag=''
        _upgrade_clear_throttles() { return "$cleanup_rc"; }
        _upg_post_and_poll() { printf posted; }
        bad() { failures=$((failures + 1)); }
        continue_or_cleanup() { :; }
        eval "$UPG_OLD_THROTTLE_BLOCK"
        printf '%s:%s\n' "$st" "$failures"
    )
}
[ "$(old_gate_result 1)" = not-posted:1 ] || fail "old upgrader posted after throttle cleanup failed"
[ "$(old_gate_result 0)" = posted:0 ] || fail "old upgrader POST control did not run"

printf 'PASS: upgrade throttle security\n'
