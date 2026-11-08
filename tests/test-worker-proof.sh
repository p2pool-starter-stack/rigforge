#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ "${1:-}" = --case ]; then
    mode=$2 fault=$3
    if [ "${WORKER_PROOF_BASELINE:-0}" = 1 ]; then
        source_text=$(git -C "$ROOT" show HEAD:tests/e2e-pithead.sh)
    else
        source_text=$(cat "$ROOT/tests/e2e-pithead.sh")
    fi
    eval "$(printf '%s\n' "$source_text" | sed '/^proof_preflight "/,$d; /^require_preflight "/,$d')"
    CFG="$CASE_DIR/config" RIGFORGE=fixture_rigforge RIG_LOCK_HOLDER="$CASE_DIR/holder"
    printf original >"$CFG"
    state=initial
    git() {
        if [ "$fault" = operator-checkout ]; then
            [ "$1" = -C ] && [ "$2" = "$HERE" ] && [ "$3" = -c ] && [ "$4" = "safe.directory=$HERE" ] || return 128
        fi
        case "$*" in
        *'rev-parse --verify'*)
            if [ "$fault" = stale ] || { [ "$fault" = changed-head ] && [ "$state" != initial ]; }; then
                printf '%040d\n' 2
            else
                printf '%040d\n' 1
            fi
            ;;
        *'diff --quiet'*) [ "$fault" != dirty ] ;;
        *'ls-files --others'*)
            [ "$fault" != git-failed ] || return 1
            [ "$fault" != untracked ] || printf untracked
            ;;
        *) return 1 ;;
        esac
    }
    uname() { case "$1" in -s) printf Linux ;; -m) printf x86_64 ;; *) return 1 ;; esac }
    require_preflight() { :; }
    replay_lock() { printf locked >"$CASE_DIR/locked"; }
    systemctl() { return 1; }
    refresh_profile_finish() { [ "$fault" != cleanup ]; }
    fixture_rigforge() { [ "$1" = apply ]; }
    passes() {
        local n
        for ((n = 0; n < $1; n++)); do ok assertion; done
    }
    phase_connect() {
        phase connect
        state=connected
        printf mutated >"$CFG"
        passes 8
    }
    phase_worker_api() {
        [ "$state" = connected ]
        phase worker-api
        state=worker
        passes 5
    }
    phase_api_impact() {
        [ "$state" = worker ]
        phase api-impact
        state=loaded
        case "$fault" in
        fatal) return 7 ;;
        assertion) bad assertion ;;
        partial)
            passes 2
            return 0
            ;;
        duplicate) phase api-impact ;;
        unexplained-skip)
            skip unexplained
            return 0
            ;;
        signal) kill -TERM "$$" ;;
        esac
        passes 3
    }
    phase_network() {
        [ "$state" = loaded ]
        [ "$fault" != missing ] || return 0
        phase network
        printf reached >"$CASE_DIR/network"
        passes 10
    }
    phase_stratum_auth() {
        phase stratum-auth
        if [ "$fault" = allowed-skip ] || [ "$fault" = unapproved-skip ]; then
            skip 'E2E_STRATUM_PASS not set (stack auth off, or secret not provided) — phases skipped'
        else
            passes 4
        fi
    }
    phase_dashboard() {
        phase dashboard
        passes 2
    }
    phase_dev_fee() {
        phase dev-fee
        passes 1
    }
    phase_control() {
        phase control
        passes 4
        (ok subprocess-assertion)
    }
    phase_access_tokens() {
        phase access-tokens
        passes 7
    }
    phase_control_replay() {
        phase control-replay
        phase_connect
        passes 1
    }
    set -- "$mode"
    eval "$(printf '%s\n' "$source_text" | awk '/^proof_preflight "|^require_preflight "/ {started=1} started')"
    exit
fi

TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
context=$(jq -cn '{schema:1,head:("0"*39+"1"),ref:"refs/heads/proof-fixture",input:("a"*64),run:("b"*32),group:"network-sequence",row:"worker",platform:"linux-x86_64",allowed_skips:{}}')
checks=0
run_case() {
    local mode=$1 fault=$2 expected=$3 rc=0 ctx=$context receipt
    CASE_DIR="$TASK_TMP/$mode-$fault"
    mkdir -p "$CASE_DIR"
    ctx=$(printf '%s' "$ctx" | jq --arg group "$mode" '.group=$group')
    if [ "$fault" = wrong-platform ]; then
        ctx=$(printf '%s' "$ctx" | jq '.platform="linux-aarch64"')
    fi
    if [ "$fault" = allowed-skip ]; then
        ctx=$(printf '%s' "$ctx" | jq '.allowed_skips={"stratum-auth":"stratum-fixture-absent"}')
    fi
    CASE_DIR="$CASE_DIR" E2E_PROOF_CONTEXT="$ctx" bash "$0" --case "$mode" "$fault" >"$CASE_DIR/output" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then
        printf 'FAIL: %s/%s returned %s, expected %s\n' "$mode" "$fault" "$rc" "$expected" >&2
        cat "$CASE_DIR/output" >&2
        exit 1
    fi
    case "$fault" in
    stale | dirty | untracked | git-failed | wrong-platform)
        [ ! -e "$CASE_DIR/locked" ]
        [ "$(cat "$CASE_DIR/config")" = original ]
        ;;
    *)
        [ "$(cat "$CASE_DIR/config")" = original ]
        receipt=$(sed -n 's/^worker-proof: //p' "$CASE_DIR/output" | tail -n 1)
        [ -n "$receipt" ] || {
            printf 'FAIL: missing worker proof receipt\n' >&2
            exit 1
        }
        printf '%s\n' "$receipt" >"$CASE_DIR/receipt"
        printf '[%s]\n' "$ctx" >"$CASE_DIR/plan"
        local check_rc=0
        python3 "$ROOT/tests/worker-proof.py" check "$CASE_DIR/plan" "$CASE_DIR/receipt" >/dev/null 2>&1 || check_rc=$?
        if [ "$expected" = 0 ]; then [ "$check_rc" = 0 ]; else [ "$check_rc" != 0 ]; fi
        ;;
    esac
    case "$fault" in fatal | assertion | signal) [ ! -e "$CASE_DIR/network" ] ;; esac
    checks=$((checks + 1))
}

run_case network-sequence success 0
run_case network-sequence operator-checkout 0
run_case all success 0
run_case all allowed-skip 0
run_case control-replay-thermal success 0
run_case control-replay-pools success 0
for fault in missing duplicate partial unexplained-skip cleanup changed-head assertion; do
    run_case network-sequence "$fault" 1
done
run_case all unapproved-skip 1
run_case network-sequence fatal 7
run_case network-sequence signal 143
for fault in stale dirty untracked git-failed wrong-platform; do run_case network-sequence "$fault" 2; done
printf 'worker proof integration: %s passed\n' "$checks"
