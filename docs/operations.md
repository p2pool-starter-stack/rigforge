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
| `help` (`-h`, `--help`) | Show usage. |

`setup` is the default, so `sudo ./rigforge.sh` with no argument provisions (or re-provisions) the
worker.

---

## Service management (Linux)

RigForge runs XMRig as a `systemd` service named `xmrig`:

```bash
sudo systemctl status xmrig     # service status
sudo systemctl stop xmrig       # stop the miner
sudo systemctl start xmrig      # start the miner
sudo systemctl restart xmrig    # restart (e.g. after a config change)
```

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
| **Pool unreachable** | Confirm the worker can reach `POOL_HOST:3333` (firewall, DHCP/static IP). Workers use plain Stratum on the LAN — no Tor. |

---

## See also

- [Getting Started](getting-started.md) — first-run setup and verification.
- [Configuration](configuration.md) — config keys and the worker template.
- [Pithead Integration](pithead-integration.md) — the dashboard contract.
