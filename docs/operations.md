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
| `doctor` | Read-only health check (run with `sudo` for the deepest checks). **Critical** findings (counted as issues): the service is active, HugePages are reserved, the `msr` module is loaded, and the **MSR mod actually applied** — confirmed from XMRig's log and, as root, an `rdmsr` register read-back (see [MSR mod verification](#msr-mod-verification)). **Advisory** findings (hints, not failures): CPU governor, 1 GB HugePages, HugePages 100%-backed (from the XMRig log), **hashrate-capping hardware** RigForge can't fix but you can — single-channel or slow RAM (via `dmidecode`) and a power/boost-capped CPU clock — and **BIOS/firmware** recommendations (board/BIOS context, plus enable XMP/EXPO/DOCP or SMT when they're off; manual BIOS changes RigForge can't make from the OS). Prints an actionable hint for anything off. |
| `bench` | Run a one-off `xmrig --bench` and report the hashrate (a quick perf/health check; set `BENCH=10M` for a longer run). |
| `tune` | Iteratively search the XMRig knobs (prefetch mode, `cpu.yield`, thread count, and `1gb-pages` when reserved) for the fastest combination for this CPU and keep it. Logs every candidate to `<WORKER_ROOT>/rigforge-tune.json` and writes the winning knobs to a separate `tune-overrides.json` (merged into the generated config). `tune --live` measures against the running miner instead of `--bench`; `tune --confirm` A/B-checks the tuned winner live and reverts it if it doesn't actually beat the previous config; `tune --efficiency` optimizes hashrate-per-watt instead of raw H/s; `tune --clear` resets tuning. |
| `autotune` | One live trial against the running miner. **Enable periodic runs** by setting `"autotune": true` in `config.json` (setup installs a systemd timer). Conservative — keeps a change only if it beats the baseline by a margin, else rolls back. Linux-only. See [Live auto-tuning](#live-auto-tuning-opt-in). |
| `backup` | Snapshot `config.json` + the tuning files into a timestamped `tar.gz` under `./backups`. See [Backup & restore](#backup--restore). |
| `restore` | Restore `config.json` + tuning from a backup archive: `restore [-y] <archive>`. Prompts before overwriting. |
| `status` | Show the systemd service status. |
| `logs` | Follow the live service logs (`journalctl -f`). |
| `start` / `stop` / `restart` | Start, stop, or restart the miner service. (`up` / `down` are aliases for `start` / `stop`.) |
| `enable` / `disable` | Start the service on boot, or not. |
| `version` (`-v`, `--version`) | Print the RigForge version. |
| `help` (`-h`, `--help`) | Show usage. |

`setup` is the default, so `sudo ./rigforge.sh` with no argument provisions (or re-provisions) the
worker. The service verbs (`status`/`logs`/`start`/`stop`/`restart`/`enable`/`disable`) work on Linux
and macOS — systemd on Linux, a launchd login agent on macOS (`enable`/`disable`). `doctor`,
`tune --live`, and `autotune` are Linux-only. See [Running on macOS](#running-on-macos).

### Health check

After setup (and the reboot), confirm everything took effect:

```bash
sudo ./rigforge.sh doctor
```

It's the quickest way to catch the common silent failures — HugePages not reserved (needs a reboot) or
the MSR mod blocked by Secure Boot. See [Troubleshooting](#troubleshooting).

> On a fresh install `setup` **enables** the service but doesn't start it until you reboot (HugePages
> aren't reserved before then), so a `doctor` run between `setup` and the reboot will report "service is
> not active" — that's expected; it starts automatically after you reboot.

### Auto-tuning

Most of the hashrate-critical settings are already chosen for you (see [How It Works](tuning.md)), but a
few knobs are genuinely CPU-specific. `tune` measures rather than guesses:

```bash
sudo ./rigforge.sh tune       # search for the fastest knobs, save the winners
sudo ./rigforge.sh apply      # regenerate the config with them + restart
```

> **Tune once, run for months.** Tuning is a one-time, measurement-heavy step — a thorough run can take
> hours (longer with `grid` or a large `TUNE_BENCH`), and that's fine: the result is kept for the life of
> the rig. Offline `--bench` measures **Monero's RandomX (rx/0)**; for a different RandomX variant, use
> `tune --live` so it measures your actual pool's algorithm. After an `upgrade` bumps XMRig, it reminds
> you to re-tune, since the fastest knobs can shift between versions.

`tune` runs an **iterative, noise-aware search** rather than a single fixed sweep. It:

- **Sweeps the knobs whose best value varies per CPU** — the RandomX **scratchpad prefetch mode**,
  **`cpu.yield`**, and the RandomX **thread count** (`cpu.rx`). The thread search is **SMT-aware**: it
  tries XMRig's auto value, the **physical-core** and **logical-core** counts (one thread per physical
  core vs. hyperthreaded — RandomX often prefers the former), and a window around the L3 ÷ 2 MB sweet
  spot. **`1gb-pages`** is swept *only when 1G HugePages are actually reserved* (they're reboot-bound — a
  GRUB change + reboot done by `setup` — so flipping them mid-run is meaningless; the knob is skipped
  with a note if absent). Three more knobs are **off by default** and searched only when you opt in:
  `cpu.huge-pages-jit` (`TUNE_HPJIT="false true"` — XMRig warns it can make hashrate unstable),
  `randomx.cache_qos` (`TUNE_CACHEQOS="false true"`, an Intel L3-CAT lever), and the MSR preset
  `randomx.wrmsr` (`TUNE_WRMSR="true false"`, or a preset number — see [MSR mod](#msr-mod-verification)).
- **Hill-climbs from two seeds** — XMRig's auto baseline and an educated guess — adopting a knob change
  only when it beats the current best by at least `TUNE_MIN_DELTA`, and **stops at a plateau** (a full
  pass with no improvement). It never benchmarks the same combination twice. Set **`TUNE_SEARCH=grid`**
  for an **exhaustive** search of every knob combination instead — slower, but immune to local optima.
- **Handles noise** by measuring each candidate as the **median** of `TUNE_ITERS` benchmark runs
  (RandomX hashrate is jittery), and — in `--bench` mode — by **stopping the miner service** for the run
  (see below) so nothing competes for the CPU or huge pages.

Every candidate — its samples, median, and any recorded power/temperature — is written to
`<WORKER_ROOT>/rigforge-tune.json`, and the winning knobs go to a separate **`tune-overrides.json`**.
That overlay is merged into the generated config, so your `config.json` is never touched;
`sudo ./rigforge.sh tune --clear` removes it. In `--bench` mode `tune` **stops the `xmrig` service for
the duration and restarts it afterwards** (even if interrupted), so the benchmark has the whole machine
to itself; still, run it when the box is otherwise idle for the steadiest numbers.

| Env var | Default | Meaning |
|---|---|---|
| `TUNE_SEARCH` | `climb` | `climb` (hill-climb, fast) or `grid` (exhaustive over all knob combos, robust but slower). |
| `TUNE_ITERS` | `5` | Benchmark runs per candidate; the median is used. |
| `TUNE_BENCH` | `10M` | `xmrig --bench` size. Longer = steadier and closer to sustained load; set `1M` for a quick pass. |
| `TUNE_MIN_DELTA` | `0.01` | Minimum *relative* gain (1%) needed to adopt a change. |
| `TUNE_MAX_ROUNDS` | `3` | Cap on hill-climb passes per seed. |
| `TUNE_SEEDS` | `auto guess` | Starting points to climb from. |
| `TUNE_PREFETCH_MODES` | `0 1 2 3` | Prefetch-mode candidates. |
| `TUNE_YIELDS` | `true false` | `cpu.yield` candidates. |
| `TUNE_THREADS` | _(auto: SMT-aware set)_ | `cpu.rx` thread-count candidates. Defaults to auto + physical/logical cores + an L3 window; override with an explicit list. |
| `TUNE_PRIORITIES` | `2` | `cpu.priority` candidates (single value ⇒ knob off; set e.g. `1 2 3 4 5` to sweep). |
| `TUNE_HPJIT` | _(off)_ | Set `false true` to sweep `cpu.huge-pages-jit` (XMRig: small Ryzen boost, unstable hashrate). |
| `TUNE_CACHEQOS` | _(off)_ | Set `false true` to sweep `randomx.cache_qos` (Intel L3 Cache Allocation Technology). |
| `TUNE_WRMSR` | _(off)_ | Sweep the `randomx.wrmsr` MSR preset, e.g. `true false` (or a preset number). Rarely needed — XMRig auto-picks the right preset; set this only to confirm it on unusual hardware. Applied per-bench, no reboot. |
| `TUNE_POWER_CMD` | _(RAPL)_ | Override the power source with a shell command that echoes **instantaneous watts** (IPMI, a smart plug, wall-AC). Without it, the built-in CPU-package RAPL reader is used on Linux. |
| `TUNE_TARGET` | `perf` | What to optimize for: `perf` (raw H/s) or `efficiency` (hashrate-per-watt). Same as `tune --efficiency`. Efficiency needs a power source (RAPL or `TUNE_POWER_CMD`) or it falls back to `perf`. |
| `TUNE_TEMP_CMD` | _(Linux thermal zone)_ | Optional shell command that echoes °C; defaults to `/sys/class/thermal/thermal_zone0/temp`. |

**Power & efficiency.** RandomX hashrate isn't free, so `tune` records **watts per candidate** and reports
the best **hashrate-per-watt**. On Linux it reads the CPU-package energy counter (RAPL) automatically — no
configuration needed (run as root). Watts are sampled **under load and averaged over the measurement
window**, so the figure reflects real mining power, and the metric can rank candidates by efficiency
rather than collapsing onto raw H/s. To measure something other than the CPU package — e.g. whole-system
wall power — point `TUNE_POWER_CMD` at a source that echoes instantaneous watts:

```bash
sudo TUNE_POWER_CMD='my-smart-plug-watts' ./rigforge.sh tune   # else: built-in RAPL, no setup
```

By default `tune` **optimizes for raw hashrate**. To optimize for **efficiency** instead — picking the
config with the best hashrate-per-watt, for a power-cost or heat/PSU-constrained rig — add `--efficiency`
(or `TUNE_TARGET=efficiency`). It needs a power source; without one it warns and falls back to `perf`:

```bash
sudo ./rigforge.sh tune --efficiency       # rank by hashrate-per-watt, not raw H/s
```

> **`hs_per_watt` is relative, not absolute.** It only compares candidates measured by the **same method on
> the same machine**. Built-in RAPL counts the **CPU package only** (not RAM, board, PSU loss); a smart
> plug counts **whole-wall AC**. Don't compare the number across methods or across rigs.

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

Each run is one **live trial**: it reads the current hashrate from the worker's API (the **median** of
`AUTOTUNE_SAMPLES` readings, default 3, taken `AUTOTUNE_INTERVAL`s apart), tries the next prefetch mode,
restarts, measures again, and **keeps the change only if it beats the baseline by a margin**
(`AUTOTUNE_MARGIN`, default 1%) — otherwise it rolls back. The prefetch change is **merged into** any
`tune-overrides.json` a prior offline `tune` wrote, so your tuned thread count and `cpu.yield` are kept.
Because live hashrate is noisy this is deliberately conservative; for a definitive sweep prefer the
offline `tune`.

### Reservation-aware thread tuning

RandomX wants its scratchpads backed by **HugePages**. `setup` reserves a pool sized for an estimated
thread count; `tune` then benchmarks thread counts within that reservation. A thread count that needs
*more* 2 MB pages than are reserved still runs — but the extra threads fall back to normal pages, so its
benchmark is a **floor, not a fair reading**. `tune` detects this: each such candidate is flagged
`hugepages_capped: true` in `rigforge-tune.json`, and `tune` ends with a note listing the capped thread
counts.

To explore a higher thread count *properly*, resize the reservation for it and re-tune:

```bash
sudo RIGFORGE_THREADS=<n> ./rigforge.sh setup   # sizes the HugePages reservation for <n> threads
sudo reboot                                     # the GRUB HugePages change needs a reboot
sudo ./rigforge.sh tune                         # now <n> threads benchmarks with full backing
```

`setup` also reads the **tuned** `cpu.rx` from `tune-overrides.json` automatically, so once you've tuned,
a plain `sudo ./rigforge.sh setup` keeps the reservation matched to your winning thread count.

### MSR mod verification

The MSR "RandomX boost" (writing the CPU's prefetcher MSRs) is one of the biggest levers — ~10–15% — so
`doctor` verifies it actually took effect, not just that the `msr` module loaded:

- **From XMRig's log** (always): the `msr register values for "<preset>" preset have been set
  successfully` line confirms XMRig wrote the per-family preset (e.g. `ryzen_19h_zen4`). A `FAILED` line
  is flagged — usually Secure Boot or a missing `msr.allow_writes=on`.
- **Register read-back via `rdmsr`** (run `doctor` as root, with `msr-tools` installed — `setup`
  installs it): `doctor` reads the prefetcher registers back and checks they hold the preset's values,
  catching a write a hypervisor or kernel lockdown silently dropped even though XMRig reported success.
  Run without root, without `rdmsr`, or with the `msr` module unloaded, this step is skipped with an
  advisory — never a false alarm; the log check above still confirms the write.

You almost never need to **tune** the MSR preset — XMRig auto-selects the right per-family preset, and
that's optimal on the vast majority of CPUs. The knob exists for the rare case where a non-default preset
(or disabling the mod) wins on unusual silicon: set `TUNE_WRMSR="true false"` (or a preset number) to
sweep `randomx.wrmsr` alongside the other knobs — it's applied per-bench (no reboot) and pinned only if
it actually wins.

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
- **No systemd service / no auto-start on boot.** There's no service to install, and the miner doesn't
  start at boot. But `setup` doesn't leave you to hand-roll a launch command — the same `start` / `stop`
  / `restart` / `status` / `logs` verbs work on macOS too (see below); on macOS they manage XMRig as a
  background process tracked by a PID file under the worker root, instead of via systemd.

### Run the miner

`setup` doesn't start the miner on macOS, so launch it yourself when ready — with the same command you'd
use on Linux:

```bash
./rigforge.sh start         # background the miner (records a PID file)
./rigforge.sh status        # is it running?
./rigforge.sh logs          # follow the live log (Ctrl-C to stop following)
./rigforge.sh stop          # stop it
./rigforge.sh restart       # stop + start
```

No `sudo` is needed on macOS (the HugePages/MSR steps that need root are Linux-only). `start` runs the
binary from the worker build dir with the generated config; the log is at `<WORKER_ROOT>/xmrig.log`
(`data/worker/xmrig.log` by default).

### Start automatically (at login)

To have the miner start on its own, `enable` installs a per-user **launchd LaunchAgent** — macOS's
analogue of the systemd boot-start:

```bash
./rigforge.sh enable        # start the miner now and at every login
./rigforge.sh disable       # remove the login agent
```

The agent lives at `~/Library/LaunchAgents/com.rigforge.xmrig.plist`, restarts the miner if it crashes,
and starts it at each login. **Once enabled, launchd owns the miner** — `start` / `stop` / `restart` /
`status` then drive the agent (via `launchctl`) instead of an ad-hoc process, so you never end up with
two miners. (`enable` starts it immediately too, unlike systemd's `enable`. A *headless, always-on* Mac
would want a system `LaunchDaemon` instead of a per-user agent — that's beyond this dev/light-use
target; run as a LaunchDaemon by hand if you need it.)

### Change a setting

Edit `config.json`, regenerate the live config, then restart:

```bash
./rigforge.sh apply             # regenerates the config (no sudo on macOS)
./rigforge.sh restart           # pick up the new config
```

### What's Linux-only

`doctor`, `uninstall`, `tune --live`, and `autotune` need systemd / Linux and aren't available on macOS.
Everything else works anywhere — `setup`, `apply`, `bench`, the offline `tune`, `backup` / `restore`,
`version`, and the full service surface `start` / `stop` / `restart` / `status` / `logs` / `enable` /
`disable` (which uses systemd on Linux and a launchd login agent on macOS).

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

## Backup & restore

A worker's **expensive, hard-to-recreate state** is small: your `config.json` and the **tuning** result
(`tune-overrides.json` — which can take hours to produce). The XMRig build and the system tuning are
regenerated by `setup`, so they're not worth saving. `backup` snapshots just that valuable state into a
portable archive:

```bash
sudo ./rigforge.sh backup           # -> ./backups/rigforge-backup-YYYYMMDD-HHMMSS.tar.gz
```

The archive is owner-only (`chmod 600`) and includes `config.json`, the tuning files, and a small
manifest (RigForge version + source host). Back up after first-run setup and again after each `tune`.

**Restore** puts it back — point it at an archive:

```bash
sudo ./rigforge.sh restore ./backups/rigforge-backup-20260101-120000.tar.gz   # prompts; -y to skip
sudo ./rigforge.sh setup            # rebuild + apply (or 'apply' if XMRig is already built)
```

Restore overwrites `config.json` and the tuning on the current machine (so it prompts first), then tells
you to run `setup`/`apply` to put the restored config into effect.

### Two reasons to use it

- **Recover from data loss.** A wiped disk would otherwise mean re-doing setup *and* re-tuning. With a
  backup it's `restore` + `setup`.
- **Roll a tune across a fleet.** Tune one machine, `backup`, then `restore` on each identical machine —
  they all get the same config and the same tuning without re-running the (slow) search.

> ⚠️ **Tuning is CPU-specific.** Only reuse `tune-overrides.json` between **identical** CPUs. On
> different hardware, restore the config but re-run `tune` (or `tune --clear` to drop the inherited
> tuning). Backups made with the default `HOME_DIR` (`DYNAMIC_HOME`) are fully portable; an absolute
> `HOME_DIR` carries that machine's path.

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
| **`doctor`: "MSR registers don't match the preset"** | XMRig's log says the write succeeded but the read-back disagrees — the kernel or hypervisor silently dropped it. Common on VMs/cloud instances and under kernel lockdown. Run RigForge on **bare metal**, and ensure `msr.allow_writes=on` (RigForge sets this) and that lockdown isn't enforced. |
| **`doctor`: "couldn't read the MSRs via rdmsr"** | The `msr` module isn't loaded (or `doctor` wasn't run as root). Run `sudo ./rigforge.sh doctor`; if it persists, `sudo modprobe msr` (Secure Boot can block it). This is advisory — XMRig's log already confirms the write. |
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
