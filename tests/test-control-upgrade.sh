# shellcheck shell=bash disable=SC1090,SC2034,SC2329
# control_upgrade units (#308), sourced by run.sh: orchestration, throttle, fetch/checkout, safe.directory.
echo "== unit: control_upgrade orchestration — whitelist, anti-rollback, throttle, rollback (#308) =="
cu_run() { # <staged-json|""> <installed-version> <do:ok|fail|down|buildfail|hardexit|rollbackexit> -> status.json contents
    local d
    d=$(mktemp -d "$SANDBOX/cu.XXXXXX")
    mkdir -p "$d/state/spool"
    mkdir -m 700 "$d/upgrade-state"
    printf '%s' "$2" >"$d/VERSION"
    printf '{"pools":[{"url":"h:3333"}]}\n' >"$d/config.json"
    [ -n "$1" ] && printf '%s\n' "$1" >"$d/state/spool/upgrade-abc123def4567890.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$d"
        CONFIG_JSON="$d/config.json"
        RIGFORGE_CONTROL_STATE="$d/state"
        RIGFORGE_CONTROL_UPGRADE_STATE="$d/upgrade-state"
        CONTROL_UPGRADE_MIN_INTERVAL=0
        DO="$3"
        WML=0
        UDO=0
        _control_upgrade_do() {
            UDO=$((UDO + 1))
            case "$DO" in
            buildfail) [ "$UDO" -eq 1 ] && return 1 ;;
            fail) return 1 ;;
            # #535: error()'s bare `exit 1` (or a SIGTERM) mid-build — forward, or in the rollback rebuild.
            hardexit) exit 1 ;;
            rollbackexit) if [ "$UDO" -eq 1 ]; then return 1; else exit 1; fi ;;
            esac
            return 0
        }
        _wait_miner_live() {
            WML=$((WML + 1))
            { [ "$DO" = down ] && [ "$WML" -eq 1 ]; } && return 1
            return 0
        }
        git() { case "$*" in *describe*) echo v0.0.1 ;; *rev-parse*) echo deadbeefcafe ;; *) return 0 ;; esac }
        set +e
        PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    )
    cat "$d/state/status.json" 2>/dev/null
}
st() { printf '%s' "$1" | jq -r .status 2>/dev/null; }
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" ok)"
assert_eq "upgrade applied on a newer, buildable release" "$(st "$s")" "applied"
assert_contains "applied reason echoes the landed version (#320)" "$s" "upgraded to v9.9.9"
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" down)"
assert_eq "built but miner stays down -> rolled_back" "$(st "$s")" "rolled_back"
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" buildfail)"
assert_eq "build failure after checkout rolls back cleanly -> rolled_back" "$(st "$s")" "rolled_back"
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" fail)"
assert_eq "forward AND rollback both fail -> terminal failed" "$(st "$s")" "failed"
assert_contains "hard-failure reason flags manual intervention" "$s" "manual intervention"
# #535: a run that dies inside _control_upgrade_do, after `started` was written, used to leave `started`
# as the final record forever: the spool entry is consumed, so nothing re-drives it. The EXIT floor
# control_apply got in #509 now records a terminal `failed` with the upgrade's own reason.
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" hardexit)"
assert_eq "upgrade: a hard exit mid-build still records a terminal outcome, not started (#535)" "$(st "$s")" "failed"
assert_contains "upgrade: the lost run names itself and the half-updated checkout (#535)" "$s" "the checkout may be half-updated"
assert_eq "upgrade: the lost run keeps its change_id and keys for the poller (#535/#255)" "$(printf '%s' "$s" | jq -r '.change_id + "|" + (.changed_keys | join(","))')" "abc123def4567890|version"
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" rollbackexit)"
assert_contains "upgrade: a hard exit in the rollback rebuild is floored too (#535)" "$s" "the upgrade run ended before recording an outcome"
s="$(cu_run '{"version":"v1.0.0"}' "2.0.0" ok)"
assert_eq "downgrade refused -> failed (never built)" "$(st "$s")" "failed"
assert_contains "downgrade reason names anti-rollback" "$s" "not newer"
s="$(cu_run '{"version":"v1.0.0"}' "1.0.0" ok)"
assert_eq "same version -> noop, not failed (#320)" "$(st "$s")" "noop"
assert_contains "noop reason still says already on" "$s" "already on v1.0.0"
s="$(cu_run '{"version":"garbage"}' "1.0.0" ok)"
assert_contains "malformed target refused, never run" "$s" "malformed"
s="$(cu_run '{"version":"v9.9.9","evil":"x"}' "1.0.0" ok)"
assert_contains "extra key beyond version refused (strict whitelist)" "$s" "malformed"
s="$(cu_run "" "1.0.0" ok)"
assert_eq "nothing staged -> no status file" "$s" ""
dsl=$(mktemp -d "$SANDBOX/cusl.XXXXXX")
mkdir -p "$dsl/state/spool"
printf '1.0.0' >"$dsl/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$dsl/config.json"
printf '{"version":"v9.9.9"}\n' >"$dsl/evil.json"
ln -s "$dsl/evil.json" "$dsl/state/spool/upgrade-abc123def4567890.json"
sl="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$dsl"
    CONFIG_JSON="$dsl/config.json"
    RIGFORGE_CONTROL_STATE="$dsl/state"
    CONTROL_UPGRADE_MIN_INTERVAL=0
    _control_upgrade_do() { return 0; }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    cat "$dsl/state/status.json" 2>/dev/null
)"
assert_contains "staged symlink refused (D8 spool handoff)" "$sl" "symlink"

echo "== unit: _control_upgrade_throttle_ok (#308) =="
if ! command -v flock >/dev/null; then
    mkdir -p "$SANDBOX/flock-stub"
    printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/flock-stub/flock"
    chmod +x "$SANDBOX/flock-stub/flock"
    PATH="$SANDBOX/flock-stub:$PATH"
fi
td=$(mktemp -d "$SANDBOX/thr.XXXXXX")
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_throttle_ok "$td"
)
assert_eq "throttle: first attempt allowed (and stamps)" "$?" "0"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_throttle_ok "$td"
)
assert_eq "throttle: second attempt within the window blocked" "$?" "1"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=0
    _control_upgrade_throttle_ok "$td"
)
assert_eq "throttle: zero interval always allowed" "$?" "0"
roThr="$SANDBOX/thr-ro"
mkdir -m 700 "$roThr"
ln -s "$roThr/no-such-dir/lock" "$roThr/.upgrade-throttle.lock"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_throttle_ok "$roThr"
) >/dev/null 2>&1
assert_eq "throttle: unopenable lock fails CLOSED (rc 2) (#321)" "$?" "2"

badStamp="$SANDBOX/thr-stamp"
mkdir -p "$badStamp/upgrade-last"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_throttle_ok "$badStamp"
) >/dev/null 2>&1
assert_eq "throttle: unwritable stamp fails CLOSED (rc 2) (#636)" "$?" "2"
noFlock="$SANDBOX/thr-flock"
mkdir -p "$noFlock/bin"
printf '#!/bin/sh\nexit 1\n' >"$noFlock/bin/flock"
chmod +x "$noFlock/bin/flock"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    PATH="$noFlock/bin:$PATH"
    _control_upgrade_throttle_ok "$noFlock"
) >/dev/null 2>&1
assert_eq "throttle: rejected lock fails CLOSED (rc 2) (#636)" "$?" "2"

# _control_upgrade_do against a STUB git (+ stub rigforge.sh) so the real fetch/reachability/checkout
# lines run under coverage — and, more importantly, the D10 reachability guard is exercised for real.
echo "== unit: _control_upgrade_do fetch + reachability + checkout (#308, stub git) =="
udoDir=$(mktemp -d "$SANDBOX/udo.XXXXXX")
mkdir -p "$udoDir/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$udoDir/rigforge.sh"
chmod +x "$udoDir/rigforge.sh"
_mk_git_stub() { # <merge-base-rc> <fetch-rc>
    cat >"$udoDir/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
*"fetch"*) exit ${2:-0} ;;
*"merge-base --is-ancestor"*) exit ${1:-0} ;;
*"rev-parse"*) echo deadbeefcafe; exit 0 ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$udoDir/bin/git"
}
_run_udo() { (
    source "$SCRIPT"
    set +e # sourcing enables -e; a non-zero _control_upgrade_do must not abort before we echo $?
    SCRIPT_DIR="$udoDir"
    PATH="$udoDir/bin:$PATH" _control_upgrade_do "v9.9.9" >/dev/null 2>&1
    echo $?
); }
_mk_git_stub 0 0
assert_eq "_control_upgrade_do: reachable tag, all steps ok -> 0" "$(_run_udo)" "0"
_mk_git_stub 1 0
assert_eq "_control_upgrade_do: unreachable tag (merge-base fails) -> 1 (D10)" "$(_run_udo)" "1"
_mk_git_stub 0 1
assert_eq "_control_upgrade_do: git fetch failure -> 1" "$(_run_udo)" "1"
# #318: the D10 guard must pin origin/main (the branch releases are cut from), never origin/HEAD —
# a fresh clone resolves HEAD to develop, which doesn't contain the release merge commits on main.
assert_contains "D10 reachability guard pins origin/main (#318)" \
    "$(grep 'merge-base --is-ancestor' "$SCRIPT")" 'origin/main'
assert_eq "D10 guard does not consult origin/HEAD (#318)" \
    "$(grep -c 'symbolic-ref' "$SCRIPT")" "0"

cuThr=$(mktemp -d "$SANDBOX/cuthr.XXXXXX")
mkdir -p "$cuThr/state/spool"
mkdir -m 700 "$cuThr/upgrade-state"
printf '1.0.0' >"$cuThr/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$cuThr/config.json"
printf '{"version":"v9.9.9"}\n' >"$cuThr/state/spool/upgrade-abc123def4567890.json"
date +%s >"$cuThr/upgrade-state/upgrade-last"
chmod 600 "$cuThr/upgrade-state/upgrade-last"
sThr="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$cuThr"
    CONFIG_JSON="$cuThr/config.json"
    RIGFORGE_CONTROL_STATE="$cuThr/state"
    RIGFORGE_CONTROL_UPGRADE_STATE="$cuThr/upgrade-state"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_do() { return 0; }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    cat "$cuThr/state/status.json" 2>/dev/null
)"
assert_eq "control_upgrade within the throttle window -> status throttled (#308/#320)" "$(st "$sThr")" "throttled"
assert_contains "throttled reason says why" "$sThr" "too soon"

cuTs=$(mktemp -d "$SANDBOX/cuts.XXXXXX")
mkdir -p "$cuTs/state/spool"
mkdir -m 700 "$cuTs/upgrade-state"
printf '1.0.0' >"$cuTs/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$cuTs/config.json"
printf '{"version":"v9.9.9"}\n' >"$cuTs/state/spool/upgrade-abc123def4567890.json"
ln -s "$cuTs/no-such-dir/lock" "$cuTs/upgrade-state/.upgrade-throttle.lock"
sTs="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$cuTs"
    CONFIG_JSON="$cuTs/config.json"
    RIGFORGE_CONTROL_STATE="$cuTs/state"
    RIGFORGE_CONTROL_UPGRADE_STATE="$cuTs/upgrade-state"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_do() { return 0; }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    cat "$cuTs/state/status.json" 2>/dev/null
)"
assert_eq "unusable throttle state -> failed, never built (#321)" "$(st "$sTs")" "failed"
assert_contains "fail-closed reason names the throttle state, not 'throttled'" "$sTs" "throttle state unavailable"

cuSt=$(mktemp -d "$SANDBOX/cust.XXXXXX")
mkdir -p "$cuSt/state/spool"
mkdir -m 700 "$cuSt/upgrade-state"
printf '1.0.0' >"$cuSt/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$cuSt/config.json"
printf '{"version":"v9.9.9"}\n' >"$cuSt/state/spool/upgrade-abc123def4567890.json"
(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$cuSt"
    CONFIG_JSON="$cuSt/config.json"
    RIGFORGE_CONTROL_STATE="$cuSt/state"
    RIGFORGE_CONTROL_UPGRADE_STATE="$cuSt/upgrade-state"
    CONTROL_UPGRADE_MIN_INTERVAL=0
    _control_upgrade_do() {
        cp "$cuSt/state/status.json" "$cuSt/mid-status.json" 2>/dev/null
        return 0
    }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
)
sMid="$(cat "$cuSt/mid-status.json" 2>/dev/null)"
assert_eq "started record served while the build runs (#320)" "$(st "$sMid")" "started"
assert_contains "started record carries this change's id" "$sMid" "abc123def4567890"
assert_eq "started record indexed under changes/<cid> too (#320)" \
    "$([ -f "$cuSt/state/changes/abc123def4567890.json" ] && echo y || echo n)" "y"
assert_eq "terminal record supersedes started" "$(st "$(cat "$cuSt/state/status.json" 2>/dev/null)")" "applied"

# #308: the control-upgrade oneshot runs as root with NO $HOME, so git can't read root's safe.directory
# config and fatals on "dubious ownership" of the operator-owned install — every git op then fails and
# the upgrade silently dies (a real miner-0 finding; the stubbed suite can't reach it since it stubs
# git). Every `git -C "$SCRIPT_DIR"` in the upgrade path MUST pin -c safe.directory. Drift-guard it.
echo "== unit: control-upgrade git calls pin safe.directory (#308) =="
bare_rf_git=$(grep -nE 'git -C "\$SCRIPT_DIR"' "$SCRIPT" | grep -v 'safe.directory' || true)
assert_eq "no control git call omits -c safe.directory (root oneshot has no HOME)" "$bare_rf_git" ""

echo "== unit: control_upgrade / control_apply refuse while the rig is lent to a bench job (#670) =="
if ! command -v flock >/dev/null 2>&1; then
    echo "  SKIP: no flock(1) on this host (macOS) — the lock-behaviour tests run in the Linux CI jobs"
else
    lentLock="$SANDBOX/rig-e2e.lock"
    : >"$lentLock"
    lent_run() { # <upgrade|apply> <fresh dir> -> status.json contents
        local d="$2"
        mkdir -p "$d/state/spool"
        [ -d "$d/upgrade-state" ] || mkdir -m 700 "$d/upgrade-state"
        printf '1.0.0' >"$d/VERSION"
        printf '{"pools":[{"url":"h:3333"}]}\n' >"$d/config.json"
        if [ "$1" = upgrade ]; then
            printf '{"version":"v9.9.9"}\n' >"$d/state/spool/upgrade-abc123def4567890.json"
        else
            printf '{"DONATION":7}\n' >"$d/state/spool/pending-abc123.json"
        fi
        (
            source "$SCRIPT"
            parse_config() { :; }
            OS_TYPE=Linux
            SCRIPT_DIR="$d"
            CONFIG_JSON="$d/config.json"
            RIGFORGE_CONTROL_STATE="$d/state"
            RIGFORGE_CONTROL_UPGRADE_STATE="$d/upgrade-state"
            RIGFORGE_RIG_LOCK="$lentLock"
            CONTROL_UPGRADE_MIN_INTERVAL=3600
            _control_upgrade_do() {
                echo called >"$d/do-called"
                return 0
            }
            _control_do_apply() {
                echo called >"$d/do-called"
                return 0
            }
            _control_do_apply_fast() {
                echo called >"$d/do-called"
                return 0
            }
            _wait_miner_live() { return 0; }
            git() { case "$*" in *describe*) echo v0.0.1 ;; *rev-parse*) echo deadbeefcafe ;; *) return 0 ;; esac }
            set +e
            PATH="$STUBS:$PATH" "control_$1" >/dev/null 2>&1
        )
        cat "$d/state/status.json" 2>/dev/null
    }
    (
        exec 9>"$lentLock"
        flock -x 9
        exec sleep 30
    ) &
    lentPid=$!
    sleep 0.5
    lentU=$(mktemp -d "$SANDBOX/lent.XXXXXX")
    mkdir -m 700 "$lentU/upgrade-state"
    printf '1\n' >"$lentU/upgrade-state/upgrade-last"
    chmod 600 "$lentU/upgrade-state/upgrade-last"
    sLent="$(lent_run upgrade "$lentU")"
    assert_eq "control_upgrade while the rig lock is held -> busy (#670)" "$(st "$sLent")" "busy"
    assert_contains "busy reason names the bench loan" "$sLent" "lent to a bench job"
    assert_eq "busy upgrade did no fetch/checkout/build" "$([ -e "$lentU/do-called" ] && echo y || echo n)" "n"
    assert_eq "busy upgrade left the throttle stamp unchanged" "$(cat "$lentU/upgrade-state/upgrade-last")" "1"
    lentA=$(mktemp -d "$SANDBOX/lent.XXXXXX")
    sLentA="$(lent_run apply "$lentA")"
    assert_eq "control_apply while the rig lock is held -> busy (#670)" "$(st "$sLentA")" "busy"
    assert_eq "busy apply left config.json untouched" "$(jq -r '.DONATION // "none"' "$lentA/config.json")" "none"
    assert_eq "busy apply did not apply" "$([ -e "$lentA/do-called" ] && echo y || echo n)" "n"
    ownerMark="$SANDBOX/rig-owner"
    printf '%s\n' "$$" >"$ownerMark"
    lentO=$(mktemp -d "$SANDBOX/lent.XXXXXX")
    sOwn="$(RIGFORGE_RIG_OWNER_MARKER="$ownerMark" lent_run upgrade "$lentO")"
    assert_eq "control_upgrade proceeds while the lock is held by a live e2e harness marker (#670)" "$(st "$sOwn")" "applied"
    true &
    deadPid=$!
    wait "$deadPid"
    printf '%s\n' "$deadPid" >"$ownerMark"
    lentD=$(mktemp -d "$SANDBOX/lent.XXXXXX")
    sDead="$(RIGFORGE_RIG_OWNER_MARKER="$ownerMark" lent_run upgrade "$lentD")"
    assert_eq "a stale marker (dead pid) does not bypass the guard (#670)" "$(st "$sDead")" "busy"
    kill "$lentPid" 2>/dev/null || true
    wait "$lentPid" 2>/dev/null || true
    lentF=$(mktemp -d "$SANDBOX/lent.XXXXXX")
    sFree="$(lent_run upgrade "$lentF")"
    assert_eq "control_upgrade proceeds once the rig lock is released (#670)" "$(st "$sFree")" "applied"
    assert_eq "released upgrade stamped the throttle" "$([ -e "$lentF/upgrade-state/upgrade-last" ] && echo y || echo n)" "y"
fi
assert_eq "rig_lock never marks the harness as rig owner for its whole run (#670)" \
    "$(sed -n '/^rig_lock()/,/^}/p' "$ROOT/tests/e2e-real.sh" "$ROOT/tests/e2e-pithead.sh" "$ROOT/tests/e2e-control-replay.sh" | grep -c rigforge-rig-owner)" "0"
for ownerFn in "e2e-pithead.sh:_cleanup" "e2e-real.sh:_control_cleanup" "e2e-real.sh:_upgrade_cleanup"; do
    assert_contains "${ownerFn#*:} removes the rig owner marker (#670)" \
        "$(sed -n "/^${ownerFn#*:}()/,/^}/p" "$ROOT/tests/${ownerFn%%:*}")" 'rm -f "${RIGFORGE_RIG_OWNER_MARKER:-/run/rigforge-rig-owner}"'
done
for ownerFile in e2e-pithead-control.sh e2e-pithead-tokens.sh e2e-control-replay.sh; do
    assert_eq "$ownerFile clears the rig owner marker it sets (#670)" \
        "$(grep -c '_rig_owner_mark$' "$ROOT/tests/$ownerFile")" "$(grep -c '_rig_owner_clear$' "$ROOT/tests/$ownerFile")"
done
