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
    journalctl -u xmrig -n 15 --no-pager -o cat 2>/dev/null | sed 's/^/shared-host: journal: /' || true
}

_shared_host_wait_share() {
    local waited=0
    while [ "$waited" -lt "${E2E_SHARED_SHARE_TIMEOUT:-600}" ] && ! grep -q 'accepted (' "$WLOG" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
    done
    grep -q 'accepted (' "$WLOG" 2>/dev/null
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
    if [ -z "$(systemctl show rigforge.slice -p FragmentPath --value 2>/dev/null)" ] && [ "$(systemctl show rigforge.slice -p ActiveState --value 2>/dev/null)" = active ] &&
        [ -z "$(cat /sys/fs/cgroup/rigforge.slice/cgroup.procs 2>/dev/null)" ] && [ -z "$(find /sys/fs/cgroup/rigforge.slice -mindepth 1 -type d 2>/dev/null)" ]; then
        printf 'shared-host: stopping an empty rigforge.slice left without a unit file by an earlier run\n'
        systemctl stop rigforge.slice
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
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    if cp "$SAVED_CFG" "$CFG" && "$RIGFORGE" apply >/dev/null 2>&1 && _restore_xmrig; then ok "dedicated configuration and run state restored"; else bad "dedicated restoration failed"; fi
    cg=$(systemctl show xmrig -p ControlGroup --value)
    if [ "$(systemctl show rigforge.slice -p LoadState --value 2>/dev/null)" = not-found ] && [ "$(systemctl show xmrig -p Slice --value)" != rigforge.slice ] && [ "${cg#/rigforge.slice/}" = "$cg" ]; then ok "owned slice removed after disabling the profile"; else bad "rigforge.slice survived disabling the profile"; fi
    after=$(_shared_host_state)
    if [ "$after" = "$before" ]; then ok "unrelated host settings unchanged after restoration"; else bad "host settings changed after restoration: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"; fi
}
