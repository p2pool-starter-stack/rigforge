#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2317,SC2329
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
source "$SCRIPT"
set +e
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
mkdir -p "$D/worker" "$D/worker/xmrig/build" "$D/syscpu/cpu0/cpufreq" "$D/home/worker"
printf '5000000\n' >"$D/cpu_max"
printf '4800000\n' >"$D/syscpu/cpu0/cpufreq/scaling_cur_freq"
printf '{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": false }, "cpu": { "yield": false, "priority": 2 } }\n' >"$D/worker/xmrig/build/config.json"
cat >"$D/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "miner speed 10s/60s/15m 1000.0 n/a n/a H/s max 1000.0 H/s"
printf 'bench benchmark finished in 1.000 seconds (%s h/s) hash sum = \033[1;32m898B6E0431C28A6B\033[0m\n' "1000.0"
EOF
chmod +x "$D/worker/xmrig/build/xmrig"
printf '{ "HOME_DIR": "%s/home", "autotune": "perf", "pools": [{"url":"h:3333"}] }\n' "$D" >"$D/config.json"
OVER="$D/worker/tune-overrides.json"
SNAP="$D/worker/tune-overrides-pre.json"
LOCK="$D/worker/tune.lock"
PRE='{"randomx":{"scratchpad_prefetch_mode":3},"cpu":{"rx":4}}'
HAVE_FLOCK=0
command -v flock >/dev/null 2>&1 && HAVE_FLOCK=1

stub_env() {
    OS_TYPE=Linux
    WORKER_ROOT="$D/worker"
    SCRIPT_DIR="$D"
    CONFIG_JSON="$D/config.json"
    CPUFREQ_MAX="$D/cpu_max"
    CPU_SYSFS="$D/syscpu"
    TUNE_TARGET=perf TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES="0 1" TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1
    AUTOTUNE_MODES="0 1" AUTOTUNE_SAMPLES=1 AUTOTUNE_INTERVAL=0 AUTOTUNE_WARMUP=0
    TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=1
    parse_config() { :; }
    _shared_host_start_guard() { :; }
    _xmrig_knob_pinned() { return 1; }
    _apply_runtime() { :; }
    _reown_worker() { :; }
    _stamp_config_meta() { :; }
    _config_replace() { cp "$1" "$CONFIG_JSON"; }
    _l3_thread_center() { :; }
    lscpu() {
        echo "Model name:            Test CPU"
        echo "L3 cache:              8 MiB"
    }
    nproc() { echo 4; }
    systemctl() { return 0; }
    sudo() { "$@"; }
}

run_autotune() {
    (
        stub_env
        API_CMD="$1"
        cd "$D"
        autotune </dev/null >"$D/at.out" 2>&1
    )
    echo "$?" >"$D/at.rc"
}
run_tune() {
    (
        stub_env
        cd "$D"
        tune "$@" </dev/null >"$D/tune.out" 2>&1
    )
    echo "$?" >"$D/tune.rc"
}
start_lock_holder() {
    bash -c 'exec 9>"$1"; flock -n 9 || exit 7; : >"$1.held"; while :; do sleep 0.2 9>&-; done' _ "$LOCK" >/dev/null 2>&1 &
    local _i
    for _i in $(seq 1 50); do
        [ -f "$LOCK.held" ] && break
        sleep 0.1
    done
    echo $!
}

if [ "$HAVE_FLOCK" = 1 ]; then
    echo "== tune and autotune serialize on a worker-root lock (#842) =="
    printf '%s\n' "$PRE" >"$OVER"
    rm -f "$LOCK" "$LOCK.held"
    HOLD="$(start_lock_holder)"
    check "the lock holder is up" y "$([ -f "$LOCK.held" ] && echo y || echo n)"
    run_tune --bench
    check "a tune over a held lock exits nonzero" 1 "$(cat "$D/tune.rc")"
    check "the refused tune names the running sweep" 1 "$(grep -c 'sweep is already running' "$D/tune.out")"
    check "the refused tune left the overrides alone" "$PRE" "$(cat "$OVER")"
    run_autotune 'echo 1500'
    check "an autotune over a held lock skips with status 0" 0 "$(cat "$D/at.rc")"
    check "the skipped autotune names the running sweep" 1 "$(grep -c 'sweep is already running' "$D/at.out")"
    check "the skipped autotune left the overrides alone" "$PRE" "$(cat "$OVER")"
    kill -9 "$HOLD" 2>/dev/null
    sleep 0.5
    run_autotune 'echo 0.0'
    check "after kill -9 of the holder no stale lock blocks the next autotune" 0 "$(grep -c 'sweep is already running' "$D/at.out")"
    check "the post-kill autotune ran (and skipped on a 0 hashrate, not on the lock)" 0 "$(cat "$D/at.rc")"
    rm -f "$LOCK" "$LOCK.held"
fi

echo "== the overrides a killed sweep left behind are restored before the next baseline (#842) =="
printf '%s\n' "$PRE" >"$OVER"
printf '{"randomx":{"scratchpad_prefetch_mode":9}}' >"$SNAP"
run_autotune 'echo 0.0'
check "recovery exits 0" 0 "$(cat "$D/at.rc")"
check "recovery restored the snapshot, not whatever the sweep left" '{"randomx":{"scratchpad_prefetch_mode":9}}' "$(cat "$OVER")"
check "recovery consumed the snapshot" n "$([ -f "$SNAP" ] && echo y || echo n)"
check "recovery announced itself" 1 "$(grep -c 'restored the overrides an interrupted sweep' "$D/at.out")"
printf '%s\n' "$PRE" >"$OVER"
: >"$SNAP"
run_autotune 'echo 0.0'
check "an empty snapshot (no pre-sweep file) removes the candidate" n "$([ -f "$OVER" ] && echo y || echo n)"
printf '%s\n' "$PRE" >"$OVER"
printf '%s\n' "$PRE" >"$SNAP"
run_tune --bench
check "a tune also restores before its sweep" 1 "$(grep -c 'restored the overrides an interrupted sweep' "$D/tune.out")"
check "the tune consumed the snapshot" n "$([ -f "$SNAP" ] && echo y || echo n)"
check "the tune finished (no false refusal)" 0 "$(cat "$D/tune.rc")"
printf '%s\n' "$PRE" >"$OVER"
printf '%s\n' "$PRE" >"$SNAP"
run_tune --clear
check "tune --clear removes overrides and snapshot" "n n" "$([ -f "$OVER" ] && echo y || echo n) $([ -f "$SNAP" ] && echo y || echo n)"

echo "== a live sweep killed with SIGKILL leaves the state the gate recovers (#842) =="
printf '%s\n' "$PRE" >"$OVER"
rm -f "$SNAP" "$D/killer"
(
    stub_env
    KILLER="$D/killer"
    API_CMD='sleep 30 9>&- & echo $! >"$KILLER"; wait; echo 1500'
    cd "$D"
    tune --live </dev/null >"$D/live.out" 2>&1
) &
LIVEPID=$!
for _ in $(seq 1 100); do
    [ -f "$D/killer" ] && break
    sleep 0.1
done
check "the live sweep reached a candidate window" y "$([ -f "$D/killer" ] && echo y || echo n)"
check "mid-sweep the snapshot holds the pre-state" "$PRE" "$(cat "$SNAP" 2>/dev/null)"
check "mid-sweep the overrides hold the candidate" differs "$([ "$(cat "$OVER")" = "$PRE" ] && echo same || echo differs)"
kill -9 "$LIVEPID" 2>/dev/null
kill "$(cat "$D/killer")" 2>/dev/null
sleep 0.3
check "SIGKILL left the candidate in place (the EXIT trap never ran)" differs "$([ "$(cat "$OVER")" = "$PRE" ] && echo same || echo differs)"
check "SIGKILL left the snapshot behind" y "$([ -f "$SNAP" ] && echo y || echo n)"
run_autotune 'echo 0.0'
check "the next autotune restored the pre-sweep overrides" "$PRE" "$(cat "$OVER")"
check "the killed sweep's lock did not block it" 0 "$(grep -c 'sweep is already running' "$D/at.out")"

echo "== restore drops the snapshot so it cannot overwrite the restored tuning (#842) =="
mkdir -p "$D/stage"
cp "$D/config.json" "$D/stage/config.json"
printf '%s\n' "$PRE" >"$D/stage/tune-overrides.json"
tar -czf "$D/backup.tar.gz" -C "$D/stage" .
printf 'CANDIDATE\n' >"$D/home/worker/tune-overrides.json"
printf 'STALE\n' >"$D/home/worker/tune-overrides-pre.json"
(
    stub_env
    cd "$D"
    restore -y "$D/backup.tar.gz" </dev/null >"$D/restore.out" 2>&1
)
check "restore removed the stale snapshot" n "$([ -f "$D/home/worker/tune-overrides-pre.json" ] && echo y || echo n)"
check "restore's tuning stands (recovery cannot undo it)" "$PRE" "$(cat "$D/home/worker/tune-overrides.json")"

echo "tune gate tests: fail=$fail"
exit "$fail"
