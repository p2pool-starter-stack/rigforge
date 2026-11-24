#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2317
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export RIGFORGE_HOME="$TEST_DIR/rigforge" RIGFORGE_APPLIANCE=0 NO_COLOR=1
mkdir -p "$RIGFORGE_HOME"
FAIL=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        FAIL=1
    fi
}
calls() {
    local n
    n=$(grep -c "$1" "$TEST_DIR/calls.log" 2>/dev/null) || true
    echo "${n:-0}"
}
held() { if [ -f "$TEST_DIR/home-$1/worker/watchdog.thermal-hold" ]; then echo y; else echo n; fi; }

run_real() {
    local home="$TEST_DIR/home-$1"
    rm -f "$TEST_DIR/calls.log"
    mkdir -p "$home/worker"
    [ "${6:-}" != hold ] || : >"$home/worker/watchdog.thermal-hold"
    printf '{"HOME_DIR": "%s", "max_temp_c": %s, "pools": [{"url": "%s"}]}\n' "${RAW_HOME:-$home}" "$2" "$3" >"$TEST_DIR/config.json"
    [ -z "${RAW_CFG:-}" ] || printf '%s\n' "$RAW_CFG" >"$TEST_DIR/config.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SERVICE_NAME=xmrig
        CONFIG_JSON="$TEST_DIR/config.json"
        _ACT="$5"
        _STOP="${7:-0}"
        sudo() { "$@"; }
        systemctl() {
            echo "[systemctl] $*" >>"$TEST_DIR/calls.log"
            case "$*" in *is-active*) [ "$_ACT" = y ] ;; stop*) return "$_STOP" ;; *) return 0 ;; esac
        }
        _read_api_hashrate() { echo 100; }
        TUNE_TEMP_CMD="echo $4" watchdog
    ) >"$TEST_DIR/out.log" 2>&1
    echo "rc=$?"
}

echo "== watchdog: a config that fails validation still gets the thermal stop =="
rc=$(run_real a 90 nohostport 99 y)
check "an invalid config still exits non-zero" "rc=1" "$rc"
check "the hot miner is stopped" 1 "$(calls 'stop xmrig')"
check "the hold marker is written" y "$(held a)"
check "the stop is explained" 1 "$(grep -c 'miner stopped' "$TEST_DIR/out.log")"
rc=$(run_real b 90 nohostport 60 y)
check "a cool miner is left running" 0 "$(calls 'stop xmrig')"
check "no hold marker without a stop" n "$(held b)"
rc=$(run_real c 90 nohostport 99 n)
check "a stopped miner is not stopped again" 0 "$(calls 'stop xmrig')"
rc=$(run_real g 90 nohostport 99 y "" 1)
check "a failed stop under an invalid config still exits non-zero" "rc=1" "$rc"
check "a failed stop is tried" 1 "$(calls 'stop xmrig')"
check "a failed stop writes no hold marker" n "$(held g)"
check "a failed stop is reported" 1 "$(grep -c 'stopping xmrig failed' "$TEST_DIR/out.log")"
check "a failed stop does not claim the miner stopped" 0 "$(grep -c 'miner stopped' "$TEST_DIR/out.log")"
rc=$(RAW_HOME=/etc run_real h 90 h:3333 99 y)
check "a rejected HOME_DIR still gets the thermal stop" 1 "$(calls 'stop xmrig')"
check "a stop without a hold marker says so" 1 "$(grep -c 'no thermal-hold marker written' "$TEST_DIR/out.log")"
rc=$(RAW_CFG='{"max_temp_c": 90, "pools": [' run_real i 90 h:3333 99 y)
check "a config that is not JSON exits non-zero" "rc=1" "$rc"
check "a config that is not JSON stops nothing" 0 "$(calls 'stop xmrig')"
rc=$(run_real d 300 nohostport 99 y)
check "an out-of-range max_temp_c stops nothing" 0 "$(calls 'stop xmrig')"

echo "== max_temp_c written with a leading zero is read as a decimal number =="
rc=$(run_real e '"090"' h:3333 60 n hold)
check "the run with a cooled, held rig succeeds" "rc=0" "$rc"
check "the cooled rig is started again" 1 "$(calls '] start xmrig')"
check "its hold is lifted" n "$(held e)"
rc=$(run_real f '"090"' h:3333 99 y)
check "the run with a hot rig succeeds" "rc=0" "$rc"
check "the hot rig is stopped" 1 "$(calls 'stop xmrig')"
check "and held" y "$(held f)"

run_held() {
    rm -f "$TEST_DIR/calls.log"
    mkdir -p "$TEST_DIR/held"
    : >"$TEST_DIR/held/watchdog.thermal-hold"
    (
        source "$SCRIPT"
        parse_config() { :; }
        OS_TYPE=Linux
        WORKER_ROOT="$TEST_DIR/held"
        SERVICE_NAME=xmrig
        MAX_TEMP_C=90
        _ACT="$1"
        _STOP="${2:-0}"
        sudo() { "$@"; }
        systemctl() {
            echo "[systemctl] $*" >>"$TEST_DIR/calls.log"
            case "$*" in *is-active*) [ "$_ACT" = y ] ;; stop*) return "$_STOP" ;; *) return 0 ;; esac
        }
        set +e
        TUNE_TEMP_CMD="echo 99" watchdog
    ) >"$TEST_DIR/out.log" 2>&1
}

echo "== watchdog: a miner started during a thermal hold is stopped again =="
run_held y
check "the running miner is stopped" 1 "$(calls 'stop xmrig')"
check "the hold stays" y "$([ -f "$TEST_DIR/held/watchdog.thermal-hold" ] && echo y || echo n)"
check "it is not started" 0 "$(calls '] start xmrig')"
run_held y 1
check "a failed stop during a hold is reported" 1 "$(grep -c 'stopping xmrig failed' "$TEST_DIR/out.log")"
check "a failed stop during a hold does not claim the miner stays stopped" 0 "$(grep -c 'stays stopped' "$TEST_DIR/out.log")"
check "a failed stop during a hold keeps the hold" y "$([ -f "$TEST_DIR/held/watchdog.thermal-hold" ] && echo y || echo n)"
run_held n
check "a miner that is already stopped gets no stop" 0 "$(calls 'stop xmrig')"

run_apply() {
    local dir="$TEST_DIR/apply"
    rm -rf "$dir"
    mkdir -p "$dir/systemd" "$dir/worker/xmrig/build"
    : >"$dir/systemd/xmrig.service"
    [ "$1" = hold ] && : >"$dir/worker/watchdog.thermal-hold"
    (
        source "$SCRIPT"
        parse_config() { :; }
        _stage_xmrig_config() { :; }
        _shared_host_start_guard() { :; }
        _reown_worker() { :; }
        OS_TYPE=Linux
        SYSTEMD_DIR="$dir/systemd"
        SERVICE_NAME=xmrig
        WORKER_ROOT="$dir/worker"
        sudo() { "$@"; }
        systemctl() {
            echo "[systemctl] $*" >>"$dir/calls.log"
            case "$*" in *is-active*)
                echo inactive
                return 3
                ;;
            *) return 0 ;; esac
        }
        set +e
        _apply_runtime
    ) >"$TEST_DIR/out.log" 2>&1
    grep -c '] restart xmrig' "$dir/calls.log" 2>/dev/null || true
}

echo "== tuning sweeps: a bare re-apply leaves a thermally held miner stopped =="
check "with a hold marker the stopped miner is not restarted" 0 "$(run_apply hold)"
check "without a hold a bare re-apply still restarts it" 1 "$(run_apply none)"

exit "$FAIL"
