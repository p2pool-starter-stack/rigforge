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
            RIGFORGE=rigforge562 WLOG="$d/private-log" FAIL=0 E2E_EXIT_RC=0
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
