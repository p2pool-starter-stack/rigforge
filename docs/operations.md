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
| `tune` | Iteratively search the XMRig knobs (prefetch mode, `cpu.yield`, thread count, and `1gb-pages` when reserved) for the fastest combination for this CPU and keep it. Logs every candidate to `<WORKER_ROOT>/rigforge-tune.json` and writes the winning knobs to a separate `tune-overrides.json` (merged into the generated config). `tune --live` measures against the running miner instead of `--bench`; `tune --clear` resets tuning. |
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
sudo ./rigforge.sh tune       # search for the fastest knobs, save the winners
sudo ./rigforge.sh apply      # regenerate the config with them + restart
```

`tune` runs an **iterative, noise-aware search** rather than a single fixed sweep. It:

- **Sweeps the knobs whose best value varies per CPU** — the RandomX **scratchpad prefetch mode**,
  **`cpu.yield`**, the RandomX **thread count** (`cpu.rx`, tried around the L3 ÷ 2 MB sweet spot), and —
  *only when 1G HugePages are actually reserved* — **`1gb-pages`**. (1G pages are reboot-bound: they need
  a GRUB change + reboot, done by `setup`, so flipping them mid-run is meaningless and the knob is
  skipped with a note if they aren't present.)
- **Hill-climbs from two seeds** — XMRig's auto baseline and an educated guess — adopting a knob change
  only when it beats the current best by at least `TUNE_MIN_DELTA`, and **stops at a plateau** (a full
  pass with no improvement). It never benchmarks the same combination twice.
- **Handles noise** by measuring each candidate as the **median** of `TUNE_ITERS` benchmark runs
  (RandomX hashrate is jittery).

Every candidate — its samples, median, and any recorded power/temperature — is written to
`<WORKER_ROOT>/rigforge-tune.json`, and the winning knobs go to a separate **`tune-overrides.json`**.
That overlay is merged into the generated config, so your `config.json` is never touched;
`sudo ./rigforge.sh tune --clear` removes it. Run it on an otherwise-idle machine for stable numbers.

| Env var | Default | Meaning |
|---|---|---|
| `TUNE_ITERS` | `3` | Benchmark runs per candidate; the median is used. |
| `TUNE_BENCH` | `1M` | `xmrig --bench` size (e.g. `10M` for a longer, steadier run). |
| `TUNE_MIN_DELTA` | `0.01` | Minimum *relative* gain (1%) needed to adopt a change. |
| `TUNE_MAX_ROUNDS` | `3` | Cap on hill-climb passes per seed. |
| `TUNE_SEEDS` | `auto guess` | Starting points to climb from. |
| `TUNE_PREFETCH_MODES` | `0 1 2 3` | Prefetch-mode candidates. |
| `TUNE_YIELDS` | `true false` | `cpu.yield` candidates. |
| `TUNE_PRIORITIES` | `2` | `cpu.priority` candidates (single value ⇒ knob off; set e.g. `1 2 3 4 5` to sweep). |
| `TUNE_POWER_CMD` | _(unset)_ | Optional shell command that echoes watts, sampled per candidate for a hashrate-per-watt view. |
| `TUNE_TEMP_CMD` | _(Linux thermal zone)_ | Optional shell command that echoes °C; defaults to `/sys/class/thermal/thermal_zone0/temp`. |

**Power & efficiency (optional).** RandomX hashrate isn't free — wire `TUNE_POWER_CMD` to a wattage
source (a RAPL sampler, an IPMI reading, or a smart-plug script) and `tune` records watts per candidate
and reports the best **hashrate-per-watt** observed, so you can trade a little speed for efficiency:

```bash
sudo TUNE_POWER_CMD='cat /run/my-rapl-watts' ./rigforge.sh tune
```

#### Live tuning (`tune --live`)

By default `tune` benchmarks offline with `xmrig --bench`. To tune under **real-world** conditions
against your actual pool instead, use `--live` (Linux only):

```bash
sudo ./rigforge.sh tune --live
```

Each candidate is applied to the running miner, a warmup window is discarded, and the steady-state
hashrate is read from the worker's API over a few samples (median). This restarts the service once per
candidate, so it's much slower than `--bench` — narrow the search (e.g. `TUNE_SEEDS=auto`, a smaller
`TUNE_PREFETCH_MODES`) for a quicker live pass. Windows are controlled by `TUNE_LIVE_WARMUP` (default
60s), `TUNE_LIVE_SAMPLES` (default 3), and `TUNE_LIVE_INTERVAL` (default 30s). The winning config is
applied automatically when the search finishes. For a hands-off periodic version, see
[Live auto-tuning](#live-auto-tuning-opt-in) below.

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

> On **macOS** there is no systemd service — RigForge builds and configures XMRig but you run it
> yourself. See [Running on macOS](#running-on-macos) below.

---

## Running on macOS

macOS is a **development / light-use** target — Ubuntu is the supported deployment platform. On macOS,
`sudo ./rigforge.sh` still does the core work: it installs dependencies (via **Homebrew**), compiles
XMRig from source, and writes a tuned `config.json`. What it **doesn't** do is the Linux-only system
integration:

- **No kernel tuning, and no reboot.** macOS doesn't expose HugePages or MSRs, so the HugePages, MSR,
  `hugetlbfs`, and GRUB steps are skipped. The generated config turns those knobs off accordingly
  (`huge-pages`, `1gb-pages`, `wrmsr`/`rdmsr` are `false`) and binds the API to IPv6 `::`. Because the
  biggest RandomX levers (HugePages + MSR) are Linux-only, **expect a lower hashrate than a tuned Linux
  box** — fine for development, not for a production rig.
- **No service, no auto-start.** Nothing is installed to run, restart, or boot-start the miner. You
  launch XMRig yourself.

### Start the miner

When setup finishes it prints a ready-to-run command. It launches XMRig in a detached `screen` session
so it keeps running after you close the terminal:

```bash
sudo screen -S xmrig <WORKER_ROOT>/xmrig/build/xmrig --config=<WORKER_ROOT>/xmrig/build/config.json
```

`<WORKER_ROOT>` is `data/worker` inside the repo by default. Re-attach to watch it with
`screen -r xmrig` (detach again with `Ctrl-a` then `d`); stop it with `screen -X -S xmrig quit`. To run
it in the foreground instead (Ctrl-C to stop):

```bash
cd <WORKER_ROOT>/xmrig/build && sudo ./xmrig --config=config.json
```

### Change a setting

Edit `config.json`, regenerate the live config, then restart the miner yourself (there's no service to
restart for you):

```bash
sudo ./rigforge.sh apply        # regenerates config.json; reminds you to restart
# then stop the screen session above and start it again
```

### What's Linux-only

`doctor`, `uninstall`, the service verbs (`status` / `logs` / `start` / `stop` / `restart` / `enable` /
`disable`), `tune --live`, and `autotune` all manage Linux/systemd state and aren't available on macOS.
`setup`, `apply`, `bench`, the offline `tune`, and `version` work anywhere.

---

## Logs

```bash
sudo journalctl -u xmrig -f     # live service logs
```

- **Log file:** `<WORKER_ROOT>/xmrig.log` (e.g. `data/worker/xmrig.log`).
- **Rotation:** a `logrotate` policy is installed automatically to compress and archive logs.
- **Build log:** the XMRig compile output is captured to `<WORKER_ROOT>/build.log` (e.g.
  `data/worker/build.log`) during setup, so a failed build is diagnosable after the fact. On any
  unexpected failure the script also names the step that failed and prints the last lines of the build
  log.

---

## Applying configuration changes

After editing `config.json`, apply it in one step:

```bash
sudo ./rigforge.sh apply
```

`apply` re-reads `config.json`, regenerates the live XMRig config, and restarts the service — no
recompile. Use it for a pool change, a new rig label, TLS, or failover pools. Changing `DONATION` is
the exception: it's compiled into the binary and needs a rebuild — see
[Configuration › Changing settings later](configuration.md#changing-settings-later).

A full `setup` re-run also regenerates the config, but it's meant for re-provisioning and — so it won't
interrupt a running miner — does **not** restart an already-built worker on its own. When you just want
an edit to take effect, use `apply`. (On macOS, `apply` regenerates the config but you restart the
miner yourself — see [Running on macOS](#running-on-macos).)

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
| **Setup fails during the build** | The script names the step that failed and tails the build log. Read the full error in `<WORKER_ROOT>/build.log` (e.g. `data/worker/build.log`). Common causes: a build dependency you declined to install (re-run and accept), or too little RAM during compilation (the build already caps parallelism by RAM — add swap on very low-memory hosts). Re-run `sudo ./rigforge.sh` once resolved; it resumes without redoing finished work. |
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
