#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -euo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D" RIGFORGE_APPLIANCE=1
source "$SCRIPT"

fail() {
    printf 'shared host regression: %s\n' "$1" >&2
    exit 1
}
assert_fails() {
    local label="$1"
    shift
    if ("$@") >"$D/result" 2>&1; then fail "$label unexpectedly passed"; fi
}

CONFIG_JSON="$D/config.json"
printf '{}\n' >"$CONFIG_JSON"
_shared_host_parse
[ "$SHARED_HOST" = false ] || fail 'missing profile changed dedicated default'

printf '{"shared_host":false}\n' >"$CONFIG_JSON"
_shared_host_parse
[ "$SHARED_HOST" = false ] || fail 'false profile changed dedicated default'

printf '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":4096}}\n' >"$CONFIG_JSON"
_shared_host_parse
[ "$SHARED_HOST" = true ] || fail 'shared profile not enabled'
[ "$SHARED_CPU_QUOTA" = 75 ] || fail 'CPU quota parsed incorrectly'
[ "$SHARED_MEMORY_MAX_MB" = 4096 ] || fail 'memory limit parsed incorrectly'

for bad in \
    '{"shared_host":true}' \
    '{"shared_host":{}}' \
    '{"shared_host":{"cpu_quota_percent":0,"memory_max_mb":4096}}' \
    '{"shared_host":{"cpu_quota_percent":10001,"memory_max_mb":4096}}' \
    '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":3071}}' \
    '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":0}}' \
    '{"shared_host":{"cpu_quota_percent":75.5,"memory_max_mb":4096}}' \
    '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":4096,"existing_host_tuning":"erase"}}'; do
    printf '%s\n' "$bad" >"$CONFIG_JSON"
    assert_fails 'invalid shared profile' _shared_host_parse
done

printf '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":4096}}\n' >"$CONFIG_JSON"
_shared_host_parse
cat >"$D/generated.json" <<'JSON'
{
  "autosave": true,
  "cpu": {"priority": 2, "yield": false, "huge-pages": true, "huge-pages-jit": true, "memory-pool": true, "rx": 6, "rx/wow": [0,1]},
  "randomx": {"1gb-pages": true, "rdmsr": true, "wrmsr": true, "cache_qos": true, "numa": true, "init": -1},
  "opencl": true, "cuda": true,
  "pools": [{"user": "fixture"}], "http": {"access-token": "sentinel"}, "donate-level": 3
}
JSON
THREADS_CAP=4
_shared_host_config "$D/generated.json"
jq -e '
  .autosave == false and
  .cpu.priority == 1 and .cpu.yield == true and
  .cpu."huge-pages" == false and .cpu."huge-pages-jit" == false and .cpu."memory-pool" == false and
  .cpu.rx == [-1,-1,-1,-1] and .cpu."*" == .cpu.rx and (.cpu | has("rx/wow") | not) and
  .randomx."1gb-pages" == false and .randomx.rdmsr == false and .randomx.wrmsr == false and
  .randomx.cache_qos == false and .randomx.numa == false and .randomx.init == 4 and
  .opencl == false and .cuda == false and
  .pools[0].user == "fixture" and .http."access-token" == "sentinel" and ."donate-level" == 3
' "$D/generated.json" >/dev/null || fail 'shared safeguards or existing operator values lost'
jq '.cpu.rx = [0,-1]' "$D/generated.json" >"$D/smaller.json"
_shared_host_config "$D/smaller.json"
jq -e '.cpu.rx == [0,-1] and .cpu."*" == .cpu.rx' "$D/smaller.json" >/dev/null || fail 'smaller operator thread selection was not preserved'

SHARED_HOST=false
cp "$D/generated.json" "$D/dedicated.json"
_shared_host_config "$D/dedicated.json"
cmp -s "$D/generated.json" "$D/dedicated.json" || fail 'disabled profile changed generated config'

SHARED_HOST=true
OS_TYPE=Linux
_ensure_hugepages() { fail 'shared setup resized HugePages'; }
sudo() { fail 'shared setup invoked a privileged host command'; }
tune_kernel
configure_limits

RIGFORGE_CGROUP_ROOT="$D/cgroup"
MEMINFO="$D/meminfo"
mkdir -p "$RIGFORGE_CGROUP_ROOT/rigforge.slice" "$D/systemd"
SYSTEMD_DIR="$D/systemd"
WORKER_ROOT="$D/worker"
printf 'MemTotal: 8388608 kB\nHugetlb: 0 kB\n' >"$MEMINFO"
systemctl() {
    case "$*" in
    'is-active --quiet '*) return 1 ;;
    'show rigforge.slice -p LoadState --value') printf 'not-found\n' ;;
    esac
}
systemd-run() { :; }
OS_TYPE=Darwin
assert_fails 'non-Linux shared profile' _shared_host_supported
OS_TYPE=Linux
assert_fails 'missing cgroup controllers' _shared_host_supported
printf 'cpu\n' >"$RIGFORGE_CGROUP_ROOT/cgroup.controllers"
assert_fails 'missing memory controller' _shared_host_supported
printf 'cpu memory\n' >"$RIGFORGE_CGROUP_ROOT/cgroup.controllers"
_shared_host_supported || fail 'available controls rejected'
printf 'MemTotal: 4194304 kB\nHugetlb: 0 kB\n' >"$MEMINFO"
assert_fails 'insufficient RAM headroom' _shared_host_supported
printf 'MemTotal: 8388608 kB\nHugetlb: 4194304 kB\n' >"$MEMINFO"
assert_fails 'existing HugeTLB pool not accounted' _shared_host_supported
printf 'MemTotal: 8388608 kB\nHugetlb: 0 kB\n' >"$MEMINFO"
printf '75000 100000\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/cpu.max"
printf '4294967296\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/memory.max"
printf '0\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/memory.swap.max"
printf '10\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/cpu.weight"
_shared_host_verify_budget >/dev/null || fail 'effective budget rejected'
printf 'max 100000\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/cpu.max"
assert_fails 'unbounded effective CPU' _shared_host_verify_budget
printf '75000 100000\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/cpu.max"
printf 'max\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/memory.max"
assert_fails 'unbounded effective memory' _shared_host_verify_budget
printf '4294967296\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/memory.max"
printf '1\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/memory.swap.max"
assert_fails 'nonzero effective swap' _shared_host_verify_budget
printf '0\n' >"$RIGFORGE_CGROUP_ROOT/rigforge.slice/memory.swap.max"

_shared_host_report >"$D/report"
grep -q 'Resource profile: shared host' "$D/report" || fail 'selected mode missing from report'
grep -q 'effective CPU quota 75000/100000 us; memory 4294967296 bytes' "$D/report" || fail 'effective limits missing from report'
printf 'memory\n' >"$RIGFORGE_CGROUP_ROOT/cgroup.controllers"
assert_fails 'report with unavailable CPU control' _shared_host_report
grep -q 'Unsupported: shared_host CPU controller is unavailable' "$D/result" || fail 'unsupported report lacks reason'
printf 'cpu memory\n' >"$RIGFORGE_CGROUP_ROOT/cgroup.controllers"
systemctl() {
    case "$*" in *' -p ControlGroup --value') printf '/system.slice/fixture.service\n' ;; esac
}
assert_fails 'report with unbounded running miner' _shared_host_report
grep -q 'Miner is outside the shared-host budget' "$D/result" || fail 'unbounded running miner not reported'
systemctl() {
    case "$*" in
    'is-active --quiet '*) return 1 ;;
    'show rigforge.slice -p LoadState --value') printf 'not-found\n' ;;
    esac
}

unit=$(printf 'ExecStartPre=+-cpupower frequency-set -g performance\n' | _shared_host_unit)
[[ "$unit" != *frequency-set* ]] || fail 'shared unit still changes CPU governor'
[[ "$unit" == *'Slice=rigforge.slice'* ]] || fail 'shared unit lacks bounded slice'
[[ "$unit" == *'Nice=19'* ]] || fail 'shared unit lacks conservative priority'
[[ "$unit" == *'shared-host-check'* ]] || fail 'shared unit lacks boot-time guard'

printf '[Service]\n' >"$SYSTEMD_DIR/$SERVICE_NAME.service"
assert_fails 'start with unbounded unit' _shared_host_start_guard
assert_fails 'dedicated transition without acknowledgement' _shared_host_prepare
printf '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":4096,"existing_host_tuning":"preserve"}}\n' >"$CONFIG_JSON"
systemctl() {
    case "$*" in
    'is-active --quiet '*) return 1 ;;
    'show rigforge.slice -p LoadState --value') printf 'not-found\n' ;;
    esac
}
sudo() { "$@"; }
_shared_host_prepare >/dev/null || fail 'inactive acknowledged transition rejected'
grep -qFx 'Description=RigForge shared-host resource budget' "$SYSTEMD_DIR/rigforge.slice" || fail 'owned slice not installed'
[ -d "$WORKER_ROOT/.rigforge-shared-host" ] || fail 'shared-host ownership history not recorded'
_shared_host_preserves_tuning "$WORKER_ROOT" || fail 'shared-host history was not preserved'
systemctl() { :; }
assert_fails 'active dedicated transition' _shared_host_prepare

printf 'Description=external resource slice\n' >"$D/external.slice"
systemctl() {
    case "$*" in
    'show rigforge.slice -p FragmentPath --value') printf '%s\n' "$D/external.slice" ;;
    'show rigforge.slice -p LoadState --value') printf 'loaded\n' ;;
    'is-active --quiet '*) return 1 ;;
    esac
}
assert_fails 'effective unowned slice' _shared_host_prepare
grep -q 'not owned by RigForge' "$D/result" || fail 'effective slice refusal lacks reason'
grep -qFx 'Description=RigForge shared-host resource budget' "$SYSTEMD_DIR/rigforge.slice" || fail 'unowned effective slice changed owned fragment'
systemctl() {
    case "$*" in
    'show rigforge.slice -p LoadState --value') printf 'loaded\n' ;;
    'show rigforge.slice -p ActiveState --value') printf 'active\n' ;;
    'is-active --quiet '*) return 1 ;;
    esac
}
assert_fails 'active implicit slice' _shared_host_prepare
grep -q 'implicit or transient' "$D/result" || fail 'implicit slice refusal lacks reason'
systemctl() {
    case "$*" in
    'show rigforge.slice -p LoadState --value') printf 'loaded\n' ;;
    'show rigforge.slice -p ActiveState --value') printf 'inactive\n' ;;
    'show rigforge.slice -p Transient --value') printf 'no\n' ;;
    'show rigforge.slice -p RequiredBy -p WantedBy --value') printf '%s\n' "${IMPLICIT_CONSUMERS:-}" ;;
    'is-active --quiet '*) return 1 ;;
    esac
}
_shared_host_prepare >/dev/null || fail 'inactive synthesized slice rejected'
IMPLICIT_CONSUMERS=external.service
assert_fails 'inactive implicit slice with external consumer' _shared_host_prepare
IMPLICIT_CONSUMERS=rigforge-external.slice
assert_fails 'inactive implicit slice with external child' _shared_host_prepare
unset IMPLICIT_CONSUMERS
systemctl() {
    case "$*" in
    'show rigforge.slice -p LoadState --value') printf 'loaded\n' ;;
    'show rigforge.slice -p ActiveState --value') printf 'inactive\n' ;;
    'show rigforge.slice -p Transient --value') printf 'yes\n' ;;
    'is-active --quiet '*) return 1 ;;
    esac
}
assert_fails 'transient implicit slice' _shared_host_prepare
systemctl() {
    case "$*" in
    'show rigforge.slice -p LoadState --value') printf 'loaded\n' ;;
    'show rigforge.slice -p ActiveState --value') printf 'inactive\n' ;;
    'show rigforge.slice -p Transient --value') printf 'no\n' ;;
    'show rigforge.slice -p DropInPaths --value') printf '%s\n' "$D/external.slice" ;;
    'is-active --quiet '*) return 1 ;;
    esac
}
assert_fails 'implicit slice with drop-in' _shared_host_prepare

systemctl() {
    printf '%s\n' "$*" >>"$D/reload-calls"
    [ "$1" != daemon-reload ]
}
assert_fails 'failed shared unit reload' _shared_host_reload
grep -q 'miner remains stopped' "$D/result" || fail 'reload refusal lacks stopped reason'
grep -qFx "stop $SERVICE_NAME" "$D/reload-calls" || fail 'reload failure left miner running'

printf '{"shared_host":{"cpu_quota_percent":75,"memory_max_mb":4096},"threads":4}\n' >"$CONFIG_JSON"
mkdir -p "$D/data/worker/xmrig/build"
cp "$D/generated.json" "$D/data/worker/xmrig/build/config.json"
_shared_host_in_slice() { return 0; }
_shared_host_check >/dev/null || fail 'safe miner config rejected at startup'
jq '.cpu.rx = [-1,-1,-1,-1,-1]' "$D/generated.json" >"$D/data/worker/xmrig/build/config.json"
assert_fails 'startup with excess miner threads' _shared_host_check
grep -q 'unsafe or stale' "$D/result" || fail 'excess thread refusal lacks reason'
jq '.cpu."*" = [-1,-1,-1]' "$D/generated.json" >"$D/data/worker/xmrig/build/config.json"
assert_fails 'startup with wildcard thread mismatch' _shared_host_check
jq '.cpu.rx = -1' "$D/generated.json" >"$D/data/worker/xmrig/build/config.json"
assert_fails 'startup with ignored numeric thread setting' _shared_host_check
jq '.randomx.init = 5' "$D/generated.json" >"$D/data/worker/xmrig/build/config.json"
assert_fails 'startup with excess dataset init threads' _shared_host_check

printf '{"shared_host":false}\n' >"$CONFIG_JSON"
mkdir -p "$D/data/worker/.rigforge-shared-host" "$D/modules-load"
FSTAB="$D/fstab"
LIMITS_CONF="$D/limits"
MODULES_FILE="$D/modules"
MODULES_LOAD_DIR="$D/modules-load"
GRUB_DEFAULT="$D/grub"
LOGROTATE_DIR="$D/logrotate"
HUGEPAGES_1G_DIR="$D/hugepages"
BIN_DIR="$D/bin"
printf 'hugetlbfs /dev/hugepages hugetlbfs defaults 0 0\n' >"$FSTAB"
printf '%s soft memlock unlimited\n' "$REAL_USER" >"$LIMITS_CONF"
printf 'msr\n' >"$MODULES_FILE"
printf 'msr\n' >"$MODULES_LOAD_DIR/msr.conf"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=4 msr.allow_writes=on"\n' >"$GRUB_DEFAULT"
sudo() {
    case "$1" in
    systemctl)
        shift
        systemctl "$@"
        ;;
    rm)
        shift
        local item
        for item in "$@"; do
            case "$item" in -*) ;; "$D"/*) ;; *) fail 'uninstall tried to remove a path outside sandbox' ;; esac
        done
        command rm "$@"
        ;;
    nft | update-grub) ;;
    rmdir)
        shift
        [[ "$1" == "$D"/* ]] || fail 'uninstall tried to remove a directory outside sandbox'
        command rmdir "$@" || true
        ;;
    cp)
        shift
        command cp "$@"
        ;;
    sed)
        shift
        [ "$1" = -i ] || fail 'uninstall invoked an unexpected sed'
        shift
        command sed "$@" >"${!#}.new" && command mv "${!#}.new" "${!#}"
        ;;
    *) fail 'uninstall invoked an unexpected privileged command' ;;
    esac
}
systemctl() { :; }
uninstall --yes >/dev/null
grep -qFx 'hugetlbfs /dev/hugepages hugetlbfs defaults 0 0' "$FSTAB" || fail 'shared uninstall rewrote existing mounts'
grep -qFx "$REAL_USER soft memlock unlimited" "$LIMITS_CONF" || fail 'shared uninstall rewrote existing memlock'
grep -qFx 'msr' "$MODULES_FILE" || fail 'shared uninstall rewrote existing MSR policy'
[ -f "$MODULES_LOAD_DIR/msr.conf" ] || fail 'shared uninstall removed existing MSR module policy'
grep -qFx 'GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=4 msr.allow_writes=on"' "$GRUB_DEFAULT" || fail 'shared uninstall rewrote existing boot tuning'

update-grub() { :; }
rm -rf "$D/data/worker"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet hugepagesz=2M hugepages=4 msr.allow_writes=on"\n' >"$GRUB_DEFAULT"
uninstall --yes >/dev/null
grep -qFx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' "$GRUB_DEFAULT" || fail 'dedicated uninstall left managed boot tuning'
[ ! -f "$MODULES_LOAD_DIR/msr.conf" ] || fail 'dedicated uninstall kept MSR module policy'

printf 'shared host parse, config, host tuning and cgroup regressions: PASS\n'
