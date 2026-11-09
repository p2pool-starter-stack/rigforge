#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2218,SC2329
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D" RIGFORGE_APPLIANCE=1
source "$SCRIPT"

fail() {
    printf 'opportunistic regression: %s\n' "$1" >&2
    exit 1
}
eq() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }
calls() { grep -c "^$1\$" "$D/calls" || true; }

sudo() { "$@"; }
flock() {
    case "$*" in *" 9") return 0 ;; esac
    shift 2
    "$@"
}
mkdir -p "$D/bin"
cat >"$D/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
is-active)
    st=$(cat "$D/active")
    [ "${2:-}" = --quiet ] || echo "$st"
    [ "$st" = active ]
    ;;
stop)
    echo stop >>"$D/calls"
    echo inactive >"$D/active"
    ;;
start)
    [ ! -e "$D/start-fails" ] || exit 1
    echo start >>"$D/calls"
    echo active >"$D/active"
    ;;
restart)
    echo restart >>"$D/calls"
    echo active >"$D/active"
    ;;
*) echo "$*" >>"$D/calls" ;;
esac
STUB
chmod +x "$D/bin/systemctl"
export D PATH="$D/bin:$PATH"
_opp_clock() { read -r NOW <"$D/now"; }
systemctl() {
    case "$1" in
    is-active)
        local st
        st=$(<"$D/active")
        [ "${2:-}" = --quiet ] || echo "$st"
        [ "$st" = active ]
        ;;
    *) command systemctl "$@" ;;
    esac
}

OS_TYPE=Linux
SCRIPT_DIR="$ROOT"
WORKER_ROOT="$D/worker"
SYSTEMD_DIR="$D/systemd"
CONFIG_JSON="$D/config.json"
MEMINFO="$D/meminfo"
REAL_USER=tester
SERVICE_NAME=xmrig
export RIGFORGE_OPP_DIR="$D/opp" RIGFORGE_PSI_DIR="$D/psi" RIGFORGE_CGROUP_ROOT="$D/cg" RIGFORGE_PROC_UPTIME="$D/uptime" RIGFORGE_PROC_STAT="$D/stat"
mkdir -p "$WORKER_ROOT" "$SYSTEMD_DIR" "$D/opp" "$D/psi" "$D/cg/rigforge.slice/xmrig.service"
printf '{"shared_host":{"cpu_quota_percent":100,"memory_max_mb":4096,"opportunistic":true}}\n' >"$CONFIG_JSON"
SHARED_CPU_QUOTA=100 SHARED_MEMORY_MAX_MB=4096
OPP=true OPP_INTERVAL=60 OPP_CPU_ENTER=60 OPP_CPU_EXIT=30 OPP_MEM_ENTER=10 OPP_MEM_EXIT=2 OPP_ENTER_N=3 OPP_EXIT_N=3 OPP_QUIET_S=180 OPP_MIN_AVAIL_MB=1024
_opp_paths

STEP=60
T=1000 UP=1000 BUSY=0 IDLE=0 SU=0 HM=0 SM=0
reset() {
    rm -f "$D/calls" "$D/start-fails" "$OPP_STATE" "$OPP_OWNED" "$OPP_MANUAL" "$OPP_THERMAL"
    : >"$D/calls"
    echo active >"$D/active"
    T=1000 UP=1000 BUSY=0 IDLE=0 SU=0 HM=0 SM=0
    write_metrics 8000
}
write_metrics() {
    printf 'cpu %s 0 0 %s 0 0 0 0 0 0\n' "$BUSY" "$IDLE" >"$D/stat"
    printf '%s.00 0.00\n' "$UP" >"$D/uptime"
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=%s\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$HM" >"$D/psi/memory"
    printf 'usage_usec %s\n' "$SU" >"$D/cg/rigforge.slice/cpu.stat"
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=%s\n' "$SM" >"$D/cg/rigforge.slice/memory.pressure"
    printf 'MemTotal: 16000000 kB\nMemAvailable: %s kB\n' "$(($1 * 1024))" >"$MEMINFO"
    echo "$T" >"$D/now"
}
tick() {
    T=$((T + STEP)) UP=$((UP + STEP))
    BUSY=$((BUSY + ($1 + $2) * STEP * 4)) IDLE=$((IDLE + STEP * 400 - ($1 + $2) * STEP * 4))
    SU=$((SU + $2 * STEP * 4 * 10000)) HM=$((HM + $3 * STEP * 10000)) SM=$((SM + $4 * STEP * 10000))
    write_metrics "$5"
    _opp_tick >>"$D/out" 2>&1
}
ticks() {
    local n=$1 i
    shift
    for ((i = 0; i < n; i++)); do tick "$@"; done
}
phase() { _opp_paths && _opp_load && echo "$S_PHASE"; }

reset
tick 0 0 0 0 8000
eq 'first sample only baselines' "$(phase)" active
ticks 5 0 0 0 0 8000
eq 'idle host keeps mining' "$(phase)" active
eq 'idle host never stops the miner' "$(calls stop)" 0

reset
ticks 6 0 100 0 0 8000
eq 'miner-only CPU load is not foreground load' "$(phase)" active
eq 'miner-only CPU load never stops the miner' "$(calls stop)" 0
ticks 6 0 100 50 50 8000
eq 'miner-only memory stalls are not foreground stalls' "$(calls stop)" 0

reset
ticks 2 0 0 0 0 8000
ticks 2 80 0 0 0 8000
tick 0 0 0 0 8000
ticks 2 80 0 0 0 8000
eq 'two noisy samples never yield' "$(calls stop)" 0
tick 80 0 0 0 8000
eq 'three consecutive samples yield' "$(calls stop)" 1
eq 'yield records the waiting phase' "$(phase)" waiting
[ -e "$OPP_OWNED" ] || fail 'yield did not record ownership'
grep -q 'yielded: other workloads use 80% of host CPU' "$OPP_STATE" || fail 'yield reason missing'

ticks 2 0 0 0 0 8000
eq 'two calm samples are not enough' "$(calls start)" 0
ticks 5 0 0 0 0 8000
eq 'sustained calm resumes exactly once' "$(calls start)" 1
eq 'resume restores mining' "$(phase)" active
[ ! -e "$OPP_OWNED" ] || fail 'resume kept ownership'
ticks 3 0 30 0 0 8000
eq 'stable resumption does not oscillate' "$(calls stop)" 1

reset
OPP_QUIET_S=900
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
ticks 10 0 0 0 0 8000
eq 'enough calm samples still wait for the quiet interval' "$(calls start)" 0
ticks 6 0 0 0 0 8000
eq 'the quiet interval ends the wait' "$(calls start)" 1
OPP_QUIET_S=180

reset
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
ticks 6 40 0 0 0 8000
eq 'load between the thresholds never resumes' "$(calls start)" 0
for _ in 1 2 3 4; do
    ticks 2 0 0 0 0 8000
    tick 40 0 0 0 8000
done
eq 'alternating samples never resume' "$(calls start)" 0

reset
ticks 2 0 0 0 0 8000
ticks 3 0 0 0 0 800
eq 'low available memory yields' "$(calls stop)" 1
grep -q 'available memory 800 MiB' "$OPP_STATE" || fail 'memory reason missing'
ticks 6 0 0 0 0 5000
eq 'resume stays blocked below the dataset and headroom budget' "$(calls start)" 0
ticks 5 0 0 0 0 5200
eq 'resume proceeds once the budget fits' "$(calls start)" 1

reset
ticks 2 0 0 0 0 8000
ticks 3 0 0 15 0 8000
eq 'foreground memory stalls yield' "$(calls stop)" 1
grep -q 'memory stalls at 15%' "$OPP_STATE" || fail 'stall reason missing'

reset
ticks 2 0 0 0 0 8000
rm "$D/psi/memory"
_opp_tick
eq 'missing metrics hold mining immediately' "$(calls stop)" 1
eq 'missing metrics are reported' "$(phase)" unavailable
[ -e "$OPP_OWNED" ] || fail 'missing metrics did not record ownership'
ticks 1 0 0 0 0 8000
printf 'garbage\n' >"$D/psi/memory"
_opp_tick
eq 'malformed metrics stay held' "$(phase)" unavailable
eq 'malformed metrics do not start the miner' "$(calls start)" 0
ticks 5 0 0 0 0 8000
eq 'returning metrics resume after sustained capacity' "$(calls start)" 1

reset
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
_opp_manual systemctl stop xmrig
[ ! -e "$OPP_OWNED" ] || fail 'manual stop kept policy ownership'
ticks 5 0 0 0 0 8000
eq 'manual stop is never resumed' "$(calls start)" 0
eq 'manual stop is reported' "$(phase)" manual
reset
ticks 2 0 0 0 0 8000
echo inactive >"$D/active"
ticks 5 0 0 0 0 8000
eq 'a miner stopped outside the policy is never started' "$(calls start)" 0
echo failed >"$D/active"
tick 0 0 0 0 8000
eq 'service failure is reported' "$(phase)" failed
eq 'service failure is never restarted by the policy' "$(calls start)" 0

reset
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
touch "$OPP_THERMAL"
ticks 6 0 0 0 0 8000
eq 'thermal hold blocks resume' "$(calls start)" 0
eq 'thermal hold is reported' "$(phase)" thermal
rm "$OPP_THERMAL"
ticks 5 0 0 0 0 8000
eq 'resume follows once the thermal hold releases' "$(calls start)" 1

reset
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
mkdir -p "$D/cg/rigforge.slice/run-u1.service"
echo 4242 >"$D/cg/rigforge.slice/run-u1.service/cgroup.procs"
ticks 6 0 0 0 0 8000
eq 'a running maintenance task blocks resume' "$(calls start)" 0
eq 'maintenance is reported' "$(phase)" maintenance
: >"$D/cg/rigforge.slice/run-u1.service/cgroup.procs"
ticks 5 0 0 0 0 8000
eq 'resume follows once maintenance ends' "$(calls start)" 1
rm -rf "$D/cg/rigforge.slice/run-u1.service"

reset
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
ticks 2 0 0 0 0 8000
grep -q '^exit=' "$OPP_STATE" || fail 'recovery progress is not persisted'
unset S_PHASE S_EXIT S_SINCE
_opp_tick
[ -e "$OPP_OWNED" ] || fail 'ownership lost across controller restart'
eq 'controller restart keeps waiting' "$(phase)" waiting
ticks 5 0 0 0 0 8000
eq 'resume survives a controller restart' "$(calls start)" 1

reset
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
ticks 2 0 0 0 0 8000
touch "$D/start-fails"
ticks 3 0 0 0 0 8000
[ -e "$OPP_OWNED" ] || fail 'failed resume dropped ownership'
eq 'failed resume keeps waiting' "$(phase)" waiting
rm "$D/start-fails"
ticks 2 0 0 0 0 8000
eq 'resume retries after a failed start' "$(calls start)" 1

reset
ticks 2 0 0 0 0 8000
_opp_halt
eq 'controller exit stops the miner' "$(calls stop)" 1
[ -e "$OPP_OWNED" ] || fail 'controller exit did not record ownership'
_opp_halt
eq 'controller exit with a stopped miner changes nothing' "$(calls stop)" 1
reset
printf '{"shared_host":{"cpu_quota_percent":100,"memory_max_mb":4096}}\n' >"$CONFIG_JSON"
_opp_halt
eq 'a controller left running by a disabled config still stops the miner' "$(calls stop)" 1
printf '{"shared_host":{"cpu_quota_percent":100,"memory_max_mb":4096,"opportunistic":true}}\n' >"$CONFIG_JSON"

reset
ticks 2 0 0 0 0 8000
_opp_halt
ticks 3 0 0 0 0 8000
eq 'a controller restart waits out the quiet interval' "$(calls start)" 0
ticks 2 0 0 0 0 8000
eq 'a controller restart resumes after the quiet interval' "$(calls start)" 1

reset
ticks 2 0 0 0 0 8000
rm -rf "$D/cg/rigforge.slice"
_opp_tick
eq 'missing slice accounting holds an active miner' "$(calls stop)" 1
eq 'missing slice accounting is reported' "$(phase)" unavailable
mkdir -p "$D/cg/rigforge.slice/xmrig.service"

reset
echo active >"$D/active"
_opp_thermal_stop "$OPP_THERMAL"
eq 'thermal stop stops the miner' "$(calls stop)" 1
[ -e "$OPP_THERMAL" ] || fail 'thermal stop did not record the hold'
_opp_manual systemctl stop xmrig
[ -e "$OPP_MANUAL" ] || fail 'manual stop was not recorded'
rm "$OPP_THERMAL"
_opp_handoff
[ ! -e "$OPP_OWNED" ] || fail 'thermal release overrode a manual stop'
ticks 12 0 0 0 0 8000
eq 'a manual stop during a thermal hold is never resumed' "$(calls start)" 0
eq 'the manual stop is reported' "$(phase)" manual
_opp_manual systemctl start xmrig
[ ! -e "$OPP_MANUAL" ] || fail 'manual start kept the manual stop'

reset
_opp_gate
touch "$OPP_OWNED"
if (_opp_gate) >/dev/null 2>&1; then fail 'start gate allowed a held miner'; fi
OPP=false
_opp_gate
OPP=true
reset
_opp_handoff
[ -e "$OPP_OWNED" ] || fail 'thermal release did not hand the start to the policy'
eq 'thermal release does not start the miner directly' "$(calls start)" 0
OPP=false
reset
echo inactive >"$D/active"
_opp_handoff
eq 'without the policy a thermal release starts the miner' "$(calls start)" 1
OPP=true

reset
ticks 2 0 0 0 0 8000
ticks 3 80 0 0 0 8000
out=$(_opp_report || true)
case "$out" in *'waiting for host capacity'*'yielded'*) ;; *) fail "report omits state and reason: $out" ;; esac
case "$out" in *'CPU quota 100%, memory 4096 MiB'*) ;; *) fail "report omits the effective budget: $out" ;; esac
json=$(_opportunistic_json)
eq 'feed state' "$(jq -r .state <<<"$json")" waiting
eq 'feed freshness' "$(jq -r .stale <<<"$json")" false
eq 'feed budget' "$(jq -r .budget.memory_max_mb <<<"$json")" 4096
jq -e '.last_transition_epoch != null and .observation_age_s != null and .reason != null' <<<"$json" >/dev/null || fail 'feed omits transition or age'
echo $((T + 300)) >"$D/now"
eq 'old observations are stale' "$(jq -r .stale <<<"$(_opportunistic_json)")" true
if _opp_report >/dev/null; then fail 'stale observation reported healthy'; fi
OPP=false
eq 'disabled feed' "$(_opportunistic_json | jq -r .mode)" disabled
OPP=true

parse() { (CONFIG_JSON=$D/p.json _opp_parse "$1" && echo "$OPP $OPP_INTERVAL $OPP_CPU_ENTER $OPP_EXIT_N $OPP_QUIET_S") 2>&1; }
eq 'absent profile key' "$(parse '{}')" 'false 10 60 6 300'
eq 'true selects defaults' "$(parse '{"opportunistic":true}')" 'true 10 60 6 300'
eq 'explicit values' "$(parse '{"opportunistic":{"interval_s":5,"cpu_enter_pct":70,"exit_samples":2,"quiet_s":0}}')" 'true 5 70 2 0'
for bad in '{"opportunistic":{"interval_s":1}}' '{"opportunistic":{"cpu_enter_pct":30,"cpu_exit_pct":30}}' '{"opportunistic":{"memory_stall_enter_pct":2}}' '{"opportunistic":{"bogus":1}}' '{"opportunistic":"yes"}' '{"opportunistic":{"min_available_mb":1.5}}' '{"opportunistic":{"enter_samples":0}}'; do
    case "$(parse "$bad")" in *'accepts true or an object'*) ;; *) fail "accepted invalid profile $bad" ;; esac
done

OPP=true
SHARED_HOST=true
case "$(echo '[Service]' | _shared_host_unit)" in *'BindsTo=rigforge-opportunistic.service'*) ;; *) fail 'miner unit is not bound to the controller' ;; esac
_opp_unit_section | grep -q 'After=rigforge-opportunistic.service' || fail 'miner unit is not ordered after the controller'
reset
touch "$OPP_OWNED" "$OPP_STATE"
_opp_install_unit
grep -q 'opportunistic-run' "$SYSTEMD_DIR/rigforge-opportunistic.service" || fail 'controller unit missing'
grep -q 'ExecStopPost=+.*opportunistic-halt' "$SYSTEMD_DIR/rigforge-opportunistic.service" || fail 'controller unit lacks the fail-safe stop'
grep -q 'Restart=on-failure' "$SYSTEMD_DIR/rigforge-opportunistic.service" || fail 'controller is not supervised'
OPP=false
_opp_install_unit
[ ! -e "$SYSTEMD_DIR/rigforge-opportunistic.service" ] || fail 'disabling kept the controller unit'
[ ! -e "$OPP_OWNED" ] || fail 'disabling kept policy ownership'
case "$(echo '[Service]' | _shared_host_unit)" in *BindsTo*) fail 'dedicated unit is bound to the controller' ;; esac

mkdir -p "$D/copy" "$D/home"
cp -R "$ROOT/rigforge.sh" "$ROOT/util" "$ROOT/systemd" "$ROOT/VERSION" "$D/copy/"
printf '{"HOME_DIR":"%s","pools":[{"url":"h:3333"}],"shared_host":{"cpu_quota_percent":100,"memory_max_mb":4096,"opportunistic":true}}\n' "$D/home" >"$D/copy/config.json"
printf '#!/bin/sh\nexec "$@"\n' >"$D/bin/sudo"
printf '#!/bin/sh\ncase "$*" in *" 9") exit 0 ;; esac\nshift 2\nexec "$@"\n' >"$D/bin/flock"
printf '#!/bin/sh\nexit 1\n' >"$D/bin/sleep"
printf '#!/bin/sh\nif [ "$1" = -s ]; then echo Linux; else exec /usr/bin/uname "$@"; fi\n' >"$D/bin/uname"
chmod +x "$D/bin/sudo" "$D/bin/flock" "$D/bin/sleep" "$D/bin/uname"
reset
(cd "$D/copy" && RIGFORGE_HOME="$D/copy" bash ./rigforge.sh opportunistic-halt >/dev/null 2>&1)
eq 'the halt verb stops the miner' "$(calls stop)" 1
[ -e "$OPP_OWNED" ] || fail 'the halt verb did not record the hold'
reset
(cd "$D/copy" && RIGFORGE_HOME="$D/copy" bash ./rigforge.sh opportunistic-run >/dev/null 2>&1) || true
[ -f "$OPP_STATE" ] || fail 'the run verb did not take a sample'

printf 'opportunistic regressions passed\n'
