#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329
# Sourced by test-e2e-gate-fail-closed.sh; no hardware or private inputs (#562).
PIT_STRATUM="$(sed -n '/^phase_stratum_auth()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
stratum_gate_case562() { # <unset|empty|present|all> <active|stopped>
    local d="$T491/stratum-$1-$2" rc out
    mkdir -p "$d"
    printf original >"$d/config"
    printf '%s' "$2" >"$d/service"
    : >"$d/edits"
    out="$(
        (
            set -Eeuo pipefail
            eval "$PIT_STRATUM"
            eval "$PIT_DIE"
            eval "$PIT_CLEAN"
            eval "$PIT_RESTORE"
            eval "$PIT_SNAPSHOT"
            eval "$(sed -n '/^bad()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
            CFG="$d/config" SAVED_CFG="" HAMMER_PIDS="" RIG_LOCK_HOLDER="$d/holder"
            PITHEAD_URL=fixture.invalid:3333 RIGFORGE=rigforge562 WLOG="$d/private-log" FAIL=0 E2E_EXIT_RC=0
            unset E2E_STRATUM_PASS
            [ "$1" != empty ] || E2E_STRATUM_PASS=""
            [ "$1" != present ] || E2E_STRATUM_PASS=synthetic-pass562
            phase() { :; }
            ok() { printf '%s\n' "$1"; }
            skip() { printf 'SKIP: %s\n' "$1"; }
            systemctl() { [ "$1" = is-active ] && [ "$(cat "$d/service")" = active ]; }
            set_cfg() {
                printf '%s\n' "$1" >>"$d/edits"
                printf '%s' "$1" >"$CFG"
            }
            rigforge562() {
                case "$1" in
                apply) : ;;
                start) printf active >"$d/service" ;;
                stop) printf stopped >"$d/service" ;;
                restart)
                    printf active >"$d/service"
                    if [[ "$(cat "$CFG")" == *wrong-114* ]]; then
                        printf 'permission denied\n' >"$WLOG"
                    else
                        printf 'new job from fixture\n' >"$WLOG"
                    fi
                    ;;
                *) return 1 ;;
                esac
            }
            wait_for_job() { grep -q 'new job from' "$WLOG"; }
            snapshot_config
            printf mutated >"$CFG" # Prove the real EXIT trap restores on either result.
            if [ "$1" = all ]; then
                phase_stratum_auth
            else
                set -- stratum-auth
                eval "$PIT_DISPATCH"
            fi
            printf 'phase completed\n'
        ) 2>&1
    )"
    rc=$?
    STRATUM_OUT562="$out"
    STRATUM_RESULT562="$rc:$(cat "$d/config"):$(cat "$d/service"):$(wc -l <"$d/edits" | tr -d ' ')"
}
for stratum_input562 in unset empty; do
    for stratum_state562 in active stopped; do
        stratum_gate_case562 "$stratum_input562" "$stratum_state562"
        assert_eq "explicit stratum $stratum_input562 fails and restores $stratum_state562 without edits" "$STRATUM_RESULT562" "2:original:$stratum_state562:0"
        assert_eq "missing stratum diagnostic is fixed and sanitized" "$STRATUM_OUT562" $'\033[31me2e-pithead: stratum-auth: missing E2E_STRATUM_PASS\033[0m'
    done
done
stratum_gate_case562 all stopped
assert_eq "all retains the optional stratum skip and restores runtime" "$STRATUM_RESULT562" "0:original:stopped:0"
assert_contains "all reports its missing-input skip" "$STRATUM_OUT562" 'SKIP:'
stratum_gate_case562 present stopped
assert_eq "supplied stratum password runs three edits and restores config/runtime" "$STRATUM_RESULT562" "0:original:stopped:3"
for stratum_assert562 in 'right pass: worker mines' 'wrong pass: rejected by the proxy' 'wrong pass: no jobs delivered' 'rotation runbook: re-pasting the right pass recovers the worker'; do
    assert_contains "stratum retains $stratum_assert562" "$STRATUM_OUT562" "$stratum_assert562"
done
assert_absent "stratum output hides the synthetic password" "$STRATUM_OUT562" synthetic-pass562

# #570: execute the real editor against a usable foreign primary AND fallback.
# Mining from either must not satisfy the authenticated fixture's assertions.
stratum_fixture_case570() { # <success|edit|apply|reject-apply|recover-apply|restart> <active|stopped>
    local d="$T491/fixture-$1-$2" rc out
    mkdir -p "$d"
    printf '%s\n' '{"DONATION":1,"pools":[{"url":"primary.invalid:3333","user":"identity570","pass":"old","tls":true,"tls-fingerprint":"old-pin","socks5":"proxy.invalid:9050","enabled":false},{"url":"fallback.invalid:3333","user":"fallback570"}]}' >"$d/config"
    cp "$d/config" "$d/original"
    printf '%s' "$2" >"$d/service"
    : >"$d/restarts"
    printf 0 >"$d/applies"
    out="$(
        (
            set -Eeuo pipefail
            eval "$PIT_STRATUM"
            eval "$PIT_SET"
            eval "$PIT_DIE"
            eval "$PIT_CLEAN"
            eval "$PIT_RESTORE"
            eval "$PIT_SNAPSHOT"
            eval "$(sed -n '/^bad()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
            CFG="$d/config" SAVED_CFG="" HAMMER_PIDS="" RIG_LOCK_HOLDER="$d/holder"
            RIGFORGE=rigforge570 WLOG="$d/log" FAIL=0 E2E_EXIT_RC=0
            PITHEAD_URL=fixture.invalid:3333 E2E_STRATUM_PASS=$'synthetic570"\\\npassword'
            phase() { :; }
            ok() { printf '%s\n' "$1"; }
            refresh_profile_finish() { :; }
            systemctl() { [ "$1" = is-active ] && [ "$(cat "$d/service")" = active ]; }
            jq() {
                local arg
                for arg in "$@"; do
                    [[ "$arg" != *"$PITHEAD_URL"* && "$arg" != *"$E2E_STRATUM_PASS"* ]] || return 90
                done
                [ "$failure570" != edit ] || [ "$1" != --rawfile ] || {
                    printf '%s %s\n' "$PITHEAD_URL" "$E2E_STRATUM_PASS" >&2
                    return 91
                }
                command jq "$@"
            }
            rigforge570() {
                case "$1" in
                apply)
                    if ! cmp -s "$CFG" "$d/original"; then
                        local n
                        n=$(($(cat "$d/applies") + 1))
                        printf '%s' "$n" >"$d/applies"
                        case "$failure570:$n" in
                        apply:1 | reject-apply:2 | recover-apply:3)
                            printf '%s %s\n' "$PITHEAD_URL" "$E2E_STRATUM_PASS" >&2
                            return 93
                            ;;
                        esac
                    fi
                    ;;
                start) printf active >"$d/service" ;;
                stop) printf stopped >"$d/service" ;;
                restart)
                    printf active >"$d/service"
                    [ "$failure570" != restart ] || return 92
                    # The private test oracle models work from any foreign endpoint.
                    if command jq -e '.pools | length != 1 or .[0].url != "fixture.invalid:3333"' "$CFG" >/dev/null; then
                        printf 'new job from foreign pool\n' >"$WLOG"
                    else
                        command jq -e '.DONATION == 1 and .pools[0].user == "identity570" and (.pools[0] | keys == ["pass","url","user"])' "$CFG" >/dev/null
                        if [ "$(command jq -r '.pools[0].pass' "$CFG")" = wrong-114 ]; then
                            printf 'permission denied\n' >"$WLOG"
                            printf rejected >>"$d/restarts"
                        else
                            printf '%s' "$E2E_STRATUM_PASS" | command jq -e --rawfile password /dev/stdin '.pools[0].pass == $password' "$CFG" >/dev/null
                            printf 'new job from fixture\n' >"$WLOG"
                            printf accepted >>"$d/restarts"
                        fi
                    fi
                    ;;
                *) return 1 ;;
                esac
            }
            sleep() { :; }
            wait_for_job() { grep -q 'new job from' "$WLOG"; }
            failure570="$1"
            snapshot_config
            phase_stratum_auth required
        ) 2>&1
    )"
    rc=$?
    assert_eq "stratum $1 restores original bytes ($2)" "$(cmp -s "$d/config" "$d/original" && echo restored)" restored
    assert_eq "stratum $1 restores original runtime ($2)" "$(cat "$d/service")" "$2"
    assert_absent "stratum $1 hides endpoint" "$out" fixture.invalid
    assert_absent "stratum $1 hides credential" "$out" synthetic570
    if [ "$1" = success ]; then
        assert_rc "isolated fixture phase succeeds ($2)" "$rc" 0
        assert_eq "only fixture proves acceptance/rejection/recovery ($2)" "$(cat "$d/restarts")" acceptedrejectedaccepted
        assert_contains "isolated rejection delivers no jobs ($2)" "$out" 'wrong pass: no jobs delivered'
    else
        [ "$rc" -ne 0 ] && ok "stratum $1 failure propagates ($2)" || bad "stratum $1 failure propagates ($2)" 'unexpected success'
        case "$1" in
        edit | apply) assert_contains "initial setup failure is diagnosed" "$out" 'stratum-auth: fixture setup failed' ;;
        reject-apply) assert_contains "rejection setup failure is diagnosed" "$out" 'stratum-auth: wrong-password setup failed' ;;
        recover-apply) assert_contains "recovery setup failure is diagnosed" "$out" 'stratum-auth: recovery setup failed' ;;
        esac
    fi
}
for fixture_state570 in active stopped; do
    for fixture_failure570 in success edit apply reject-apply recover-apply restart; do
        stratum_fixture_case570 "$fixture_failure570" "$fixture_state570"
    done
done
