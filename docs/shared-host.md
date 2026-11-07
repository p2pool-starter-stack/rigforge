# Shared-host profile

Set `shared_host` when RigForge will share a Linux machine with other workloads. The profile is
opt-in; an omitted key or `false` keeps the dedicated-miner behavior.

```json
{
  "shared_host": {
    "cpu_quota_percent": 100,
    "memory_max_mb": 4096
  },
  "threads": 4
}
```

`cpu_quota_percent` is a percentage of one CPU as understood by systemd: `100` permits one CPU,
`200` permits two, and so on. It is a ceiling, not a promise of foreground-workload capacity or a
priority guarantee across unrelated cgroup hierarchies. It accepts integers from 1 through 10000.
`memory_max_mb` is the miner cgroup's resident-memory ceiling, including RandomX dataset
initialization, scratchpads, and helper processes. It accepts 3072 through 1048576 MiB. Set
`threads` when a lower initialization and mining thread ceiling is needed; without it the profile
uses one initialization thread.

The profile requires Linux systemd with unified cgroup v2 CPU and memory controllers, zero swap in
the miner cgroup, and enough statically visible memory to leave at least 1024 MiB outside the
configured ceiling and existing HugeTLB reservations. RigForge verifies the controls after systemd
activates them and refuses miner activation when the effective values cannot be read back. `status`
and `doctor` report the selected profile, requested limits, effective limits, and unsupported or
stopped states.

Shared-host operation uses ordinary pages. It does not create or expand persistent HugePages,
change the CPU governor, apply MSR or cache tuning, enable NUMA, or rewrite pre-existing host
settings. XMRig runs with `priority: 1`, `yield: true`, no HugePages or memory pool, no MSR/cache
controls, and one dataset. The miner and RigForge's compile, prefetch, and periodic autotune helpers
run in the owned `rigforge.slice` budget. Full `tune` and `bench` are refused; `tune --now` and
periodic autotune only perform the limited prefetch work supported by the profile.

A rebuild during setup or `upgrade` sizes compiler parallelism from `memory_max_mb` (one job per
2 GiB, at least one) instead of host RAM, and stops a running miner first so the compiler has the
whole ceiling. Setup restarts the miner after the rebuild; `upgrade` restarts it when it was running
before. If setup or `upgrade` fails after the build has stopped the miner, the miner stays stopped;
fix the cause and run `sudo ./rigforge.sh start`.

The existing `miner_user` choice remains in force (root when omitted). The unit drops capabilities,
uses `Nice=19` with CPU weight 10, and disables automatic restart so a failed budget check or memory
exhaustion leaves the miner stopped with a reason. Because the unit keeps no capabilities, RigForge
gives the generated XMRig config and `xmrig.log` to the miner account (root when `miner_user` is
omitted) every time it re-owns the worker directory. This bounds trusted mining workloads; it is not a
security boundary against compromised root code.

Switching an already installed dedicated unit requires stopping the miner and adding
`"existing_host_tuning": "preserve"` inside `shared_host`. This is an acknowledgement that RigForge
will preserve inherited host tuning; it does not inspect ownership, undo it, or reclaim it. If the
owned profile is later disabled, `apply` removes the shared budget and restores RigForge's dedicated
configuration. Shared selection or the retained history marker makes uninstall preserve global
tuning, even after disabling the profile, because ownership of inherited settings cannot be proven.

Apply the profile with `sudo ./rigforge.sh apply` after editing `config.json`. Repeated setup, apply,
upgrade, and reboot preserve the selected profile.

The opt-in `shared-host` phase of `tests/e2e-pithead.sh` (bench `tier4-e2e`, not part of `all`)
switches a provisioned rig to the profile, checks the effective slice limits, the miner's cgroup,
the generated XMRig settings, `status`, and an accepted share, then restores the dedicated
configuration. It compares HugePages, governors, the MSR module, the kernel command line and the
fstab, limits, modules and GRUB files before, during and after. Measured coexistence with a
foreground workload is the separate bench coexistence scenario owned by #579; the CPU quota and
memory ceiling alone do not establish that workload's service-level budget.

The XMRig controls follow the [XMRig CPU configuration](https://xmrig.com/docs/miner/config/cpu).
The resource controls follow [systemd resource control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html);
HugeTLB accounting follows the [kernel HugeTLB documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/hugetlbpage.html).
