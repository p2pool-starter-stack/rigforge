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
activates them and refuses miner activation when the effective values cannot be read back. While a
loaded unit is out of profile, every start or restart is refused until `apply` runs again — including
the watchdog's thermal-hold lift and its wedge restart — while the watchdog's thermal stop stays
effective, so a hot miner is stopped regardless. `status`
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
gives the generated XMRig config and `xmrig.log` to the miner account every time it re-owns the
worker directory. Without `miner_user` they are owned by root with the operator's group, and the
config is mode 0640 so non-root `doctor` and `support-bundle` can still read it. This bounds trusted mining workloads; it is not a
security boundary against compromised root code.

Switching an already installed dedicated unit requires stopping the miner and adding
`"existing_host_tuning": "preserve"` inside `shared_host`. This is an acknowledgement that RigForge
will preserve inherited host tuning; it does not inspect ownership, undo it, or reclaim it. If the
owned profile is later disabled, `apply` removes the shared budget and restores RigForge's dedicated
configuration. The next `apply`, `upgrade`, setup or uninstall
stops and removes the owned `rigforge.slice` once no process runs in it; while the miner or a helper
is still inside, removal waits for a later run of one of those commands. Shared selection or the retained history marker makes uninstall preserve global
tuning, even after disabling the profile, because ownership of inherited settings cannot be proven.

Apply the profile with `sudo ./rigforge.sh apply` after editing `config.json`. Repeated setup, apply,
upgrade, and reboot preserve the selected profile.

## Opportunistic mining (opt-in)

Set `opportunistic` inside `shared_host` to let the miner back off when other applications need the
machine and start again after capacity has been back for a sustained period. `true` selects the
defaults; an object overrides any of them:

```json
{
  "shared_host": {
    "cpu_quota_percent": 200,
    "memory_max_mb": 4096,
    "opportunistic": {
      "interval_s": 10,
      "cpu_enter_pct": 60,
      "cpu_exit_pct": 30,
      "memory_stall_enter_pct": 10,
      "memory_stall_exit_pct": 2,
      "min_available_mb": 1024,
      "enter_samples": 3,
      "exit_samples": 6,
      "quiet_s": 300
    }
  }
}
```

The controller is `rigforge-opportunistic.service`, a small loop that samples every `interval_s`
seconds (2 to 300) using kernel counters only, so the miner's own work is never counted as
competition:

| Signal | Source | Meaning |
|---|---|---|
| Other CPU use | `/proc/stat` busy time minus `rigforge.slice` `cpu.stat` `usage_usec` | Percent of total host CPU time used outside the miner's budget. |
| Memory stalls | `/proc/pressure/memory` `some` total minus `rigforge.slice` `memory.pressure` total | Percent of the sample interval in which other tasks stalled on memory. |
| Available memory | `MemAvailable` in `/proc/meminfo` | MiB the host can still hand out without reclaim. |

The miner is stopped after `enter_samples` consecutive samples (1 to 60) with other CPU use at or
above `cpu_enter_pct` (5 to 100), memory stalls at or above `memory_stall_enter_pct` (1 to 100), or
available memory under `min_available_mb` (256 to 1048576). It is started again only when
`exit_samples` consecutive samples (1 to 600) show other CPU use under `cpu_exit_pct` (0 to 95, below
the enter value), memory stalls under `memory_stall_exit_pct` (0 to 99, below the enter value) and
available memory of at least `memory_max_mb` plus `min_available_mb`, and at least `quiet_s` seconds
(0 to 86400) have passed since the miner was stopped. Values between the enter and exit thresholds
change nothing. Every start reinitializes the RandomX dataset, so size `exit_samples` and `quiet_s`
from the dataset initialization time your rig logs (`dataset ready (N ms)`); the bench scenario
records it. A stop, not a pause, is used because a stopped miner releases its dataset memory; the
resume check budgets that memory before starting. Memory does not stay reserved while waiting, and
the profile's ordinary-page rules (no HugePages) are unchanged.

The kernel must provide pressure-stall information (`/proc/pressure/memory`); without it `apply`
refuses the profile. At run time a missing or malformed metric stops the miner at once and
`status` reports `metrics unavailable`; the controller resumes it by the normal rule after the
metrics return. If the controller itself exits for any reason, including a config edit that disabled the
policy before `apply`, `ExecStopPost` stops the miner and records the hold, and systemd restarts
the controller after ten seconds, and the miner unit is bound to the controller
(`BindsTo`, ordered after it), so a miner never runs without a live controller. Restarting the
controller therefore stops mining until the resume rule, including the quiet interval, is met. The
enabled miner unit still starts at boot before the first sample; the controller yields within
`enter_samples` intervals if the host has no capacity, so the boot start is not budget-gated. An invalid `opportunistic` value is
rejected by `apply`.

Independent reasons never override each other. The policy holds a stop it made with an ownership
marker (`owned` in the root-owned `/var/lib/rigforge-opportunistic`, kept across controller restart and reboot, next to the controller's state and lock)
and resumes only a miner it stopped:

| Reason | Who owns it | Policy behavior |
|---|---|---|
| Resource pressure | the controller | Stops and resumes as above. |
| Manual stop | the operator (`rigforge stop` records a `manual` marker; a `systemctl stop` the policy did not make is treated the same) | Never resumed, even if a thermal hold releases meanwhile; `rigforge stop`, `start`, `restart` and an `apply` that restarts the miner clear any policy hold first, serialized with the controller. |
| Thermal hold | the watchdog | Never started while the hold file exists; when the watchdog releases it the start decision passes to the policy rather than starting under load. |
| Maintenance | RigForge builds and helpers inside `rigforge.slice` | No resume while one is running. |
| Service failure | systemd (`Restart=no`) | Reported as `miner service failed` and never restarted by the policy. |

The miner unit refuses to start while the ownership marker exists, so a boot or a dependency
restart cannot bypass the policy; after a reboot a held miner stays held until the controller
resumes it, and `sudo ./rigforge.sh start` overrides the hold. Disabling `opportunistic` and running
`apply` removes the controller, its state and the hold; start a miner left stopped with
`sudo ./rigforge.sh start`.

`status` and `doctor` print one of: mining within the host budget, waiting for host capacity, stopped
manually, miner service failed, thermal hold, paused for maintenance, metrics unavailable, or no
observation yet, with the time and reason of the last transition, the age of the last observation
(older than three intervals is stale: the controller is not sampling, and `doctor` counts it as an issue), the latest CPU, stall and
memory readings, and the effective budget. `doctor` treats a miner waiting for capacity as healthy
rather than as a stopped service. The same data is in the read feed under `rigforge.opportunistic`
(`mode`, `state`, `reason`, `last_transition_epoch`, `observed_epoch`, `observation_age_s`, `stale`,
`other_cpu_pct`, `memory_stall_pct`, `available_mb`, `budget`); it names no process or workload.
A zero hashrate while `state` is `waiting` is intended and is not a crash; the watchdog does not
restart a miner the policy holds.

This first version only stops and starts the miner. Gradual thread scaling and work windows are
separate work, and a warm pause cannot replace the memory release. The thresholds describe your
host, not a guarantee for a foreground workload: measure that workload's service level on your rig.

The opt-in `shared-host` phase of `tests/e2e-pithead.sh` (bench `tier4-e2e`, not part of `all`)
switches a provisioned rig to the profile, checks the effective slice limits, the miner's cgroup,
the generated XMRig settings, `status`, and an accepted share, then restores the dedicated
configuration. It compares HugePages, governors, the MSR module, the kernel command line and the
fstab, limits, modules and GRUB files before, during and after. Measured coexistence with a
foreground workload is the separate bench coexistence scenario owned by #579; the CPU quota and
memory ceiling alone do not establish that workload's service-level budget. The same phase then
enables opportunistic mining and, with recorded thresholds, times the yield to competing CPU load,
checks that the miner's memory is released, times the resume, requires an accepted share and a
quiet minute afterwards, and checks that a manual stop is never resumed.

The XMRig controls follow the [XMRig CPU configuration](https://xmrig.com/docs/miner/config/cpu).
The resource controls follow [systemd resource control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html);
HugeTLB accounting follows the [kernel HugeTLB documentation](https://www.kernel.org/doc/html/latest/admin-guide/mm/hugetlbpage.html).
