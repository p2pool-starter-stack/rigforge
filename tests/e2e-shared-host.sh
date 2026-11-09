# shellcheck shell=bash
_shared_host_state() {
    local f
    printf 'nr_hugepages=%s\n' "$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo unreadable)"
    printf 'nr_overcommit_hugepages=%s\n' "$(cat /proc/sys/vm/nr_overcommit_hugepages 2>/dev/null || echo unreadable)"
    printf 'governors=%s\n' "$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
    printf 'msr_module=%s\n' "$([ -d /sys/module/msr ] && echo loaded || echo absent)"
    printf 'cmdline=%s\n' "$(sha256sum </proc/cmdline | cut -c1-16)"
    for f in /etc/fstab /etc/security/limits.conf /etc/modules /etc/default/grub; do
        printf '%s=%s\n' "$f" "$(if [ -f "$f" ]; then sha256sum <"$f" | cut -c1-16; else echo absent; fi)"
    done
}

_shared_host_diagnose() {
    systemctl show xmrig -p ActiveState -p SubState -p Result -p ExecMainStatus -p User -p ControlGroup 2>&1 | sed 's/^/shared-host: /'
    stat -c 'shared-host: log owner %U:%G mode %a size %s' "$WLOG" 2>&1 || true
}

_shared_host_wait_share() {
    local waited=0
    while [ "$waited" -lt "${E2E_SHARED_SHARE_TIMEOUT:-600}" ] && ! grep -q 'accepted (' "$WLOG" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
    done
    grep -q 'accepted (' "$WLOG" 2>/dev/null
}

_opp_phase() { sed -n 's/^phase=//p' /var/lib/rigforge-opportunistic/state 2>/dev/null | head -1; }

_opp_wait() {
    local waited=0 now
    while [ "$waited" -lt "$1" ]; do
        if systemctl is-active --quiet xmrig; then now=active; else now=inactive; fi
        if [ "$now" = "$2" ]; then
            echo "$waited"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

_opp_load() {
    local i
    if [ "$1" = start ]; then
        for ((i = 0; i < $(nproc); i++)); do
            timeout 900 sh -c 'while :; do :; done' &
            OPP_LOAD_PIDS="${OPP_LOAD_PIDS:-} $!"
        done
    else
        # shellcheck disable=SC2086
        kill ${OPP_LOAD_PIDS:-} 2>/dev/null || true
        wait 2>/dev/null || true
        OPP_LOAD_PIDS=""
    fi
}

_shared_host_opportunistic() {
    local yield_s resume_s mem_before mem_after cg=/sys/fs/cgroup/rigforge.slice interval=5 quiet=30 enter=3 exit_n=3 yield_max resume_max
    yield_max=$((interval * (enter + 1) + 25)) resume_max=$((quiet + interval * exit_n + 60))
    printf 'shared-host: opportunistic acceptance thresholds: yield within %ss of load start, resume within %ss of load end, no transition during 60s idle and 60s after resume\n' "$yield_max" "$resume_max"
    if ! set_cfg ".shared_host.opportunistic = {interval_s: $interval, enter_samples: $enter, exit_samples: $exit_n, quiet_s: $quiet, cpu_enter_pct: 60, cpu_exit_pct: 30}" soft; then
        bad "opportunistic apply was refused on this rig (see set_cfg above)"
        return 0
    fi
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    "$RIGFORGE" start >/dev/null 2>&1 || bad "opportunistic miner did not start"
    if systemctl is-active --quiet rigforge-opportunistic.service && [ "$(systemctl show xmrig -p BindsTo --value)" = rigforge-opportunistic.service ]; then ok "opportunistic controller is running and bound to the miner"; else bad "opportunistic controller is missing or not bound"; fi
    sleep $((interval * (enter + 2)))
    if [ "$(_opp_phase)" = active ]; then ok "opportunistic: idle host keeps mining"; else bad "opportunistic: idle host reads '$(_opp_phase)'"; fi
    sleep 60
    if systemctl is-active --quiet xmrig && [ "$(_opp_phase)" = active ]; then ok "opportunistic: sustained mining for 60s without a transition"; else bad "opportunistic: the miner left the active state on an idle host"; fi
    "$RIGFORGE" status 2>&1 | grep -q '^Opportunistic mining: mining within the host budget' && ok "status reports active mining" || bad "status does not report active mining"
    mem_before=$(cat "$cg/memory.current" 2>/dev/null || echo 0)
    _opp_load start
    if yield_s=$(_opp_wait "$yield_max" inactive); then ok "opportunistic: yielded to competing CPU load in ${yield_s}s (limit ${yield_max}s)"; else bad "opportunistic: no yield within ${yield_max}s of competing load"; fi
    sleep 5
    mem_after=$(cat "$cg/memory.current" 2>/dev/null || echo 0)
    printf 'shared-host: slice memory.current before=%s after=%s bytes\n' "$mem_before" "$mem_after"
    if [ "$mem_after" -lt $((mem_before / 4)) ]; then ok "opportunistic: the yield released the miner's memory"; else bad "opportunistic: memory was not released (before $mem_before after $mem_after)"; fi
    "$RIGFORGE" status 2>&1 | grep -q '^Opportunistic mining: waiting for host capacity' && ok "status reports waiting for capacity" || bad "status does not report waiting for capacity"
    : >"$WLOG" 2>/dev/null || true
    _opp_load stop
    if resume_s=$(_opp_wait "$resume_max" active); then ok "opportunistic: resumed ${resume_s}s after the load ended (limit ${resume_max}s)"; else bad "opportunistic: no resume within ${resume_max}s of the load ending"; fi
    if _shared_host_wait_share; then ok "opportunistic: share accepted after resuming ($(grep -oE 'dataset ready \([0-9]+ ms\)' "$WLOG" | tail -1 || true) cold start)"; else bad "opportunistic: no accepted share after resuming"; fi
    sleep 60
    if systemctl is-active --quiet xmrig; then ok "opportunistic: stable after resuming, no restart oscillation"; else bad "opportunistic: the miner stopped again on an idle host"; fi
    _opp_load start
    _opp_wait "$yield_max" inactive >/dev/null || bad "opportunistic: second yield did not happen"
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    _opp_load stop
    sleep "$resume_max"
    if ! systemctl is-active --quiet xmrig; then ok "opportunistic: a manual stop is never resumed by the policy"; else bad "opportunistic: the policy restarted a manually stopped miner"; fi
    "$RIGFORGE" start >/dev/null 2>&1 || bad "opportunistic: manual start failed"
    if ! set_cfg 'del(.shared_host.opportunistic)' soft; then bad "disabling opportunistic mining was refused"; fi
    if ! systemctl cat rigforge-opportunistic.service >/dev/null 2>&1 && [ ! -e /var/lib/rigforge-opportunistic ]; then ok "disabling the policy removed the controller and its state"; else bad "controller unit or state survived disabling"; fi
}

phase_shared_host() {
    phase "shared-host — bounded miner in rigforge.slice, unrelated host settings unchanged (#577)"
    local before during after total huge mem pid cg worker marker_owned=0 peak init
    worker=$(dirname "$(dirname "$(dirname "$GEN_CFG")")")
    [ -e "$worker/.rigforge-shared-host" ] || marker_owned=1
    before=$(_shared_host_state)
    printf 'shared-host: host state before\n%s\n' "$before"
    total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    huge=$(awk '/^Hugetlb:/ {print $2}' /proc/meminfo)
    mem=4096
    [ "$(((total - ${huge:-0}) / 1024 - 1024))" -ge "$mem" ] || mem=3072
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    if [ -d /sys/fs/cgroup/rigforge.slice ] && [ -z "$(systemctl show rigforge.slice -p FragmentPath --value)" ] &&
        [ "$(systemctl show rigforge.slice -p ActiveState --value)" = active ] && [ "$(systemctl show rigforge.slice -p Transient --value)" = no ] &&
        [ -z "$(systemctl show rigforge.slice -p DropInPaths -p RequiredBy -p WantedBy --value | tr -d '[:space:]')" ] &&
        [ -z "$(find /sys/fs/cgroup/rigforge.slice -mindepth 1 -type d)" ] && [ -z "$(cat /sys/fs/cgroup/rigforge.slice/cgroup.procs)" ]; then
        printf 'shared-host: stopping an empty rigforge.slice left without a unit file by an earlier run\n'
        systemctl stop rigforge.slice || bad "could not stop the empty leftover rigforge.slice"
    fi
    if ! set_cfg ".shared_host = {cpu_quota_percent: 200, memory_max_mb: $mem, existing_host_tuning: \"preserve\"} | .threads //= 2 | .pools[0].url = \"$PITHEAD_URL\"" soft; then
        [ "$marker_owned" = 0 ] || rm -rf "$worker/.rigforge-shared-host"
        bad "shared_host apply was refused on this rig (see set_cfg above)"
        return 0
    fi
    [ "$marker_owned" = 0 ] || rm -rf "$worker/.rigforge-shared-host"
    : >"$WLOG" 2>/dev/null || true
    if "$RIGFORGE" start >/dev/null 2>&1; then ok "shared-host miner started through the budget guard"; else bad "shared-host miner did not start"; fi
    if [ "$(systemctl show xmrig -p Slice --value)" = rigforge.slice ]; then ok "miner unit is placed in rigforge.slice"; else bad "miner unit is outside rigforge.slice"; fi
    cg=/sys/fs/cgroup/rigforge.slice
    if [ "$(cat "$cg/cpu.max" 2>/dev/null)" = "200000 100000" ] && [ "$(cat "$cg/memory.max" 2>/dev/null)" = "$((mem * 1048576))" ] &&
        [ "$(cat "$cg/memory.swap.max" 2>/dev/null)" = 0 ]; then
        ok "effective slice limits: cpu.max 200000/100000, memory.max ${mem} MiB, swap 0"
    else
        bad "effective slice limits differ: cpu.max '$(cat "$cg/cpu.max" 2>/dev/null)' memory.max '$(cat "$cg/memory.max" 2>/dev/null)' swap '$(cat "$cg/memory.swap.max" 2>/dev/null)'"
    fi
    pid=$(systemctl show xmrig -p MainPID --value)
    if [ "${pid:-0}" != 0 ] && grep -q '^0::/rigforge.slice/' "/proc/$pid/cgroup" 2>/dev/null; then ok "running miner process is accounted to rigforge.slice"; else bad "running miner process is not in rigforge.slice"; fi
    if jq -e '.cpu."huge-pages" == false and .cpu."memory-pool" == false and .cpu.yield == true and .cpu.priority == 1 and
        .randomx.wrmsr == false and .randomx.rdmsr == false and .randomx."1gb-pages" == false and .randomx.numa == false' "$GEN_CFG" >/dev/null; then
        ok "generated XMRig config uses ordinary pages, yield, priority 1 and no MSR tuning"
    else
        bad "generated XMRig config kept dedicated tuning"
    fi
    if "$RIGFORGE" status 2>&1 | grep -q 'effective CPU quota 200000/100000 us'; then ok "status reports the shared profile's effective limits"; else bad "status does not report the effective shared limits"; fi
    if wait_for_job 120; then ok "shared-host miner received a stratum job"; else
        _shared_host_diagnose
        bad "no stratum job within 120s under shared_host"
    fi
    if _shared_host_wait_share; then
        init=$(grep -oE 'dataset ready \([0-9]+ ms\)' "$WLOG" | tail -1 || true)
        ok "share accepted under shared_host (${init:-dataset init time not logged})"
    else
        _shared_host_diagnose
        bad "no accepted share within ${E2E_SHARED_SHARE_TIMEOUT:-600}s under shared_host"
    fi
    peak=$(cat "$cg/memory.peak" 2>/dev/null || echo unavailable)
    printf 'shared-host: slice memory.peak=%s bytes, memory.max=%s bytes\n' "$peak" "$((mem * 1048576))"
    during=$(_shared_host_state)
    if [ "$during" = "$before" ]; then ok "unrelated host settings unchanged while shared"; else bad "host settings changed while shared: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$during") | tr '\n' ' ')"; fi
    _shared_host_opportunistic
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    if cp "$SAVED_CFG" "$CFG" && "$RIGFORGE" apply >/dev/null 2>&1 && _restore_xmrig; then ok "dedicated configuration and run state restored"; else bad "dedicated restoration failed"; fi
    cg=$(systemctl show xmrig -p ControlGroup --value)
    if [ -z "$(systemctl show rigforge.slice -p FragmentPath --value 2>/dev/null)" ] && [ "$(systemctl show rigforge.slice -p ActiveState --value)" = inactive ] &&
        [ "$(systemctl show xmrig -p Slice --value)" != rigforge.slice ] && [ "${cg#/rigforge.slice/}" = "$cg" ]; then ok "owned slice stopped and removed after disabling the profile"; else
        systemctl show rigforge.slice -p LoadState -p ActiveState -p FragmentPath 2>&1 | sed 's/^/shared-host: slice /'
        bad "rigforge.slice survived disabling the profile"
    fi
    after=$(_shared_host_state)
    if [ "$after" = "$before" ]; then ok "unrelated host settings unchanged after restoration"; else bad "host settings changed after restoration: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"; fi
}
