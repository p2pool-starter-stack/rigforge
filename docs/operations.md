# Operations & Maintenance

Day-to-day running of a RigForge worker: the command reference, managing the service, reading logs,
upgrading, and troubleshooting.

---

## Commands

RigForge is a single script. Run it as `sudo ./rigforge.sh [command]`:

| Command | What it does |
|---|---|
| `setup` _(default)_ | Provision the worker: dependencies, build, hardware + kernel tuning, and the service. Idempotent — safe to re-run; skips the recompile when the pinned XMRig is already built. |
| `upgrade` | Rebuild **and** restart **only if** the pinned XMRig version/commit changed. A no-op when you're already on the pinned build. |
| `apply` | Re-read `config.json`, regenerate the live XMRig config, and restart — **without** recompiling. The fast path after editing `config.json`. |
| `uninstall` | Remove the service and **revert all system changes** (fstab, limits, modules, GRUB) and the worker build/logs. Leaves `config.json`. Prompts first; add `--yes` to skip. |
| `doctor` | Read-only health check: verifies HugePages are reserved, the `msr` module is loaded, the CPU governor is `performance`, the service is active, and (from the XMRig log) that HugePages are 100% backed. Prints actionable hints for anything off. |
| `bench` | Run a one-off `xmrig --bench` and report the hashrate (a quick perf/health check; set `BENCH=10M` for a longer run). |
| `tune` | Benchmark candidate configs with `xmrig --bench` over several iterations and keep the fastest. Logs every result to `<WORKER_ROOT>/rigforge-tune.json` and writes the winning knobs to a separate `tune-overrides.json` (merged into the generated config). `tune --clear` resets tuning. |
| `status` | Show the systemd service status. |
| `logs` | Follow the live service logs (`journalctl -f`). |
| `start` / `stop` / `restart` | Start, stop, or restart the miner service. |
| `enable` / `disable` | Start the service on boot, or not. |
| `version` (`-v`, `--version`) | Print the RigForge version. |
| `help` (`-h`, `--help`) | Show usage. |

`setup` is the default, so `sudo ./rigforge.sh` with no argument provisions (or re-provisions) the
worker. The service verbs (`status`/`logs`/`start`/`stop`/`restart`) and `doctor` are Linux-only.

### Health check

After setup (and the reboot), confirm everything took effect:

```bash
sudo ./rigforge.sh doctor
```

It's the quickest way to catch the common silent failures — HugePages not reserved (needs a reboot) or
the MSR mod blocked by Secure Boot. See [Troubleshooting](#troubleshooting).

### Auto-tuning

Most of the hashrate-critical settings are already chosen for you (see [How It Works](tuning.md)), but a
few knobs are genuinely CPU-specific. `tune` measures rather than guesses:

```bash
sudo ./rigforge.sh tune       # benchmark candidates, save the winning knobs
sudo ./rigforge.sh apply      # regenerate the config with them + restart
```

`tune` benchmarks candidate configs with `xmrig --bench` over several iterations — sweeping the RandomX
**scratchpad prefetch mode** and **`cpu.yield`** (the knobs whose best value varies per CPU) — records
every result to `<WORKER_ROOT>/rigforge-tune.json`, and writes the winning knobs to a separate
**`tune-overrides.json`**. That overlay is merged into the generated config, so your `config.json` is
never touched; `sudo ./rigforge.sh tune --clear` removes it. Run it on an otherwise-idle machine for
stable numbers. Tunables: `TUNE_ITERS` (default 2), `TUNE_BENCH` (default `1M`).

### Live auto-tuning (opt-in)

Set `"autotune": true` in `config.json` and setup installs a **systemd timer** that periodically runs:

```bash
sudo ./rigforge.sh autotune
```

Each run is one **live trial**: it reads the current hashrate from the worker's API, tries the next
prefetch mode, restarts, measures again, and **keeps the change only if it beats the baseline by a
margin** (`AUTOTUNE_MARGIN`, default 1%) — otherwise it rolls back. Because live hashrate is noisy this
is deliberately conservative; for a definitive sweep prefer the offline `tune`.

---

## Service management (Linux)

RigForge runs XMRig as a `systemd` service named `xmrig`:

```bash
sudo systemctl status xmrig     # service status
sudo systemctl stop xmrig       # stop the miner
sudo systemctl start xmrig      # start the miner
sudo systemctl restart xmrig    # restart (e.g. after a config change)
```

RigForge also wraps these so you don't have to remember the unit name —
`sudo ./rigforge.sh status` / `logs` / `start` / `stop` / `restart`.

The service is enabled at install, so it starts automatically on boot (and after the post-setup
reboot).

> On **macOS** there is no systemd service; RigForge builds and configures XMRig but you run it
> yourself. macOS is a development/light-use target — Ubuntu is the supported deployment platform.

---

## Logs

```bash
sudo journalctl -u xmrig -f     # live service logs
```

- **Log file:** `<WORKER_ROOT>/xmrig.log` (e.g. `data/worker/xmrig.log`).
- **Rotation:** a `logrotate` policy is installed automatically to compress and archive logs.
- **Build log:** the XMRig compile output is captured to a logfile during setup, so a failed build is
  diagnosable after the fact.

---

## Upgrading XMRig

RigForge pins XMRig to a known version/commit. To move to a newer pinned build:

```bash
git pull                        # get the new pin (and any RigForge changes)
sudo ./rigforge.sh upgrade      # rebuild + restart only if the pin changed
```

`upgrade` is a no-op when the pinned XMRig is already built, so it's cheap to run. A plain
`sudo ./rigforge.sh` (setup) also picks up a changed pin, but `upgrade` is the explicit, restart-aware
path.

> Old build artifacts are archived/pruned across runs, so repeated upgrades don't leak disk.

---

## Verification

After setup (and the reboot, on Linux), confirm the optimizations applied:

**HugePages**

```bash
grep Huge /proc/meminfo
```

`HugePages_Total`, `HugePages_Free`, and `Hugepagesize` should be non-zero and match what setup
configured.

**MSR (Model-Specific Registers)**

```bash
grep -i msr <WORKER_ROOT>/xmrig.log
```

If you see MSR errors, see Troubleshooting below.

---

## Troubleshooting

| Symptom | Likely cause & fix |
|---|---|
| **MSR errors in the log** | Secure Boot is blocking the `msr` kernel module. **Disable Secure Boot** in your BIOS/UEFI, then reboot. |
| **`HugePages_Total` is 0** | The kernel tuning needs a **reboot** to take effect (GRUB change). Reboot, then re-check `grep Huge /proc/meminfo`. |
| **HugePages still 0 after reboot** | Not enough contiguous memory was reservable, or another tool changed GRUB. Re-run `sudo ./rigforge.sh`; RigForge **merges** its kernel parameters into `GRUB_CMDLINE_LINUX_DEFAULT` rather than overwriting, so other params are preserved. |
| **Low hashrate / few threads** | RandomX is L3-bound (~2 MB per thread). A CPU with little L3 runs fewer effective threads — this is expected. See [Hardware › L3 cache](hardware.md#a-note-on-l3-cache). |
| **No AVX2** | RandomX still runs but slower. AVX2 is strongly recommended; there's no fix beyond different hardware. |
| **Dashboard can't read the worker** | The HTTP API token must equal the rig name (or be unset), the API must be on `:8080`, and the worker must be reachable from the stack host. See [Pithead Integration › Troubleshooting](pithead-integration.md#troubleshooting). |
| **Pool unreachable** | Confirm the worker can reach its pool URL (firewall, DHCP/static IP). Workers use plain Stratum on the LAN — no Tor. |

---

## See also

- [Getting Started](getting-started.md) — first-run setup and verification.
- [Configuration](configuration.md) — config keys and how the XMRig config is generated.
- [Pithead Integration](pithead-integration.md) — the dashboard contract.
