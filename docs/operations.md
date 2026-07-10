# Operations & Maintenance

Day-to-day running of a RigForge worker: the command reference, managing the service, reading logs,
upgrading, and troubleshooting.

---

## Common tasks

Most days you touch a handful of these. Each is a single command. The full [command
reference](#commands) is below.

| I want to… | Command | What happens |
|---|---|---|
| Change a setting (pool, rig name, TLS, failover) | edit `config.json`, then `sudo ./rigforge.sh apply` | Regenerates the live config and restarts. No rebuild. |
| Redeploy after a `git pull` | `git pull && sudo ./rigforge.sh upgrade` | Rebuilds + restarts (and re-tunes) if the XMRig pin moved; otherwise a no-op. See [the note below](#upgrading-xmrig-redeploy-after-a-git-pull). |
| Run a live tune now | `sudo ./rigforge.sh tune --now` | One live pass against the running miner; keeps the best prefetch mode if it wins. Linux only. |
| Check the worker is healthy | `sudo ./rigforge.sh doctor` | HugePages, MSR, governor, service, with a fix hint for anything off. |
| Watch it mining | `sudo ./rigforge.sh logs` | Live logs; `Ctrl-C` stops following (the miner keeps running). |
| Stop / start / restart | `sudo ./rigforge.sh stop` · `start` · `restart` | Control the miner service. |
| Quick speed check | `sudo ./rigforge.sh bench` | One-off offline benchmark; reports H/s. |
| Save config + tuning | `sudo ./rigforge.sh backup` | Snapshots the only hard-to-recreate state to `./backups`. |

> On macOS, drop the `sudo` (the privileged steps are Linux-only) and run `./rigforge.sh restart` after
> `apply` to pick up changes. `doctor` and the live re-tunes (`tune --now`, `tune --live`) are Linux-only.
> See [Running on macOS](#running-on-macos).

---

## Commands

The complete surface. Most days you only need the handful in [Common tasks](#common-tasks) above; the
rest are here for completeness.

RigForge is a single script. Run it as `sudo ./rigforge.sh [command]`. Optional: set
`"add_to_path": true` in `config.json` and setup installs a `rigforge` command on your PATH, so you can
run `sudo rigforge [command]` from any directory; `uninstall` removes it.

| Command | What it does |
|---|---|
| `setup` *(default)* | Provision the worker: dependencies, build, hardware + kernel tuning, and the service. Idempotent and safe to re-run; skips the recompile when the pinned XMRig is already built. |
| `upgrade` | Rebuild and restart only if the pinned XMRig version/commit changed. A no-op when you're already on the pinned build. If periodic autotune is enabled, it also re-tunes the new build (the fastest knobs can shift between versions). |
| `apply` | Re-read `config.json`, regenerate the live XMRig config, and restart, without recompiling. The fast path after editing `config.json`. On Linux it also reconciles the periodic-autotune timer with config (so changing the `autotune` target takes effect) and reports it (efficiency / performance / disabled). |
| `uninstall` | Remove the service and revert all system changes (fstab, limits, modules, GRUB) and the worker build/logs. Leaves `config.json`. Prompts first; add `--yes` to skip. |
| `doctor` | Read-only health check (run with `sudo` for the deepest checks). Critical findings (counted as issues): the service is active, HugePages are reserved, the `msr` module is loaded, and the MSR mod actually applied, confirmed from XMRig's log and, as root, an `rdmsr` register read-back (see [MSR mod verification](#msr-mod-verification)). Advisory findings (hints, not failures): CPU governor, 1 GB HugePages, HugePages 100%-backed (from the XMRig log), hashrate-capping hardware RigForge can't fix but you can (single-channel or slow RAM via `dmidecode`, and a power/boost-capped CPU clock), and BIOS/firmware recommendations (board/BIOS context, plus enable XMP/EXPO/DOCP or SMT when they're off; manual BIOS changes RigForge can't make from the OS). Prints an actionable hint for anything off. Also binary tamper evidence (#141): the on-disk `xmrig` is compared against the SHA-256 recorded at compile time — a deliberate rebuild refreshes the record, anything else warns and counts as an issue. |
| `bench` | Run a one-off `xmrig --bench` and report the hashrate (a quick perf/health check; set `BENCH=10M` for a longer run). |
| `tune` | The single command for tuning. A bare `tune` measures the fastest CPU-specific knobs (prefetch, `cpu.yield`, thread count) offline and keeps them, an optional, one-time step. Live variants: `--now` / `--short` (a quick prefetch re-tune against the running miner, the *run a live tune now* path), `--now --long` (a full live search of every knob, = `--live`), `--confirm` (A/B-check the winner live). Plus `--efficiency` / `--perf`, `--history`, `--clear`. See [Tuning](#tuning). |
| `bios` | Guided, resumable walk-through of the BIOS/UEFI changes for your hardware — the settings `tune` can't reach from the OS (memory profile XMP/EXPO/DOCP, SMT, PBO/Eco-Mode; `--efficiency` picks the low-power set). Detects the current firmware state via the same probes `doctor` uses, hands you a board-specific checklist one item at a time, saves the pending items, and on the next run re-verifies which changes actually took. RigForge never writes BIOS itself; plan for console access (keyboard/KVM) for the reboot-into-BIOS step. Linux-only. See [Guided BIOS tuning](#guided-bios-tuning). |
| `autotune` | The scheduled live tuner. You normally don't type it; `tune --now` is the friendlier spelling for an on-demand run, and the periodic schedule is what this verb is really for: set `"autotune": "performance"` (raw H/s) or `"autotune": "efficiency"` (hashrate-per-watt) in `config.json` and setup installs a systemd timer (also re-tuned on `upgrade`). Conservative: it keeps a change only if it beats the baseline by a margin, else rolls back. Linux-only. See [Live auto-tuning](#live-auto-tuning-opt-in). |
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
and macOS: systemd on Linux, a launchd login agent on macOS (`enable`/`disable`). `doctor`,
`tune --live`, and `autotune` are Linux-only. See [Running on macOS](#running-on-macos).

### Health check

After setup (and the reboot), confirm everything took effect:

```bash
sudo ./rigforge.sh doctor
```

This catches the common silent failures: HugePages not reserved (needs a reboot) or the MSR mod blocked
by Secure Boot. See [Troubleshooting](#troubleshooting).

> On a fresh install `setup` enables the service but doesn't start it until you reboot (HugePages aren't
> reserved before then), so a `doctor` run between `setup` and the reboot will report "service is not
> active". That's expected; it starts automatically after you reboot.

### Tuning

RigForge auto-configures the hashrate-critical settings, so a freshly-deployed worker already runs well.
`tune` is an optional, one-time step that measures the handful of knobs whose best value is genuinely
CPU-specific (the RandomX prefetch mode, `cpu.yield`, the thread count) and keeps the fastest:

```bash
sudo ./rigforge.sh tune       # measure the fastest knobs for this CPU — thorough, so it takes a while
sudo ./rigforge.sh apply      # regenerate the config with them and restart
```

> Tune once, run for months. The result is saved to a separate overlay (`tune-overrides.json`), so your
> `config.json` is never touched, and it's kept for the life of the rig. After an `upgrade` bumps XMRig,
> RigForge reminds you to re-tune (the fastest knobs can shift between versions).

`tune` optimizes for whatever your [`autotune`](configuration.md#configuration-reference) config is set
to, so if `autotune` is `"efficiency"`, a plain `tune` measures hashrate-per-watt, matching what the
scheduled run does. Override per-run with `--perf` or `--efficiency`. It announces the target at the
start, e.g. `Optimization target: efficiency (hashrate-per-watt)`. Run it without `sudo` and it re-runs
itself with `sudo` for you.

See what's tuned, and what the periodic auto-tuner has been doing, at any time:

```bash
./rigforge.sh tune --history  # applied knobs + the last full run + recent auto-tune decisions
```

Useful variants (all optional):

| Command | What it does |
|---|---|
| `tune --now` *(or `--short`)* | Run a live tune now: a quick convergent pass against the running miner that keeps the best prefetch mode if it wins. The everyday live re-tune; Linux only. |
| `tune --now --long` | A full live sweep of every knob (prefetch, `cpu.yield`, thread count, 1G-pages) against the running miner, not just the prefetch mode. Thorough but slower; measures your running pool's real conditions/algorithm. Alias: `tune --live`. Linux only. |
| `tune --efficiency` / `--perf` | Force the optimization target, hashrate-per-watt vs raw speed, overriding the `autotune` config default for this run (efficiency needs a power source). |
| `tune --confirm` | A/B-check the winner on the live miner and keep it only if it genuinely beats the previous config. Linux only. |
| `tune --history` | Show the current tuning, the last full run, and recent auto-tune decisions. |
| `tune --clear` | Discard all tuning and return to the auto defaults. |

The search internals, every tunable knob, the full list of `TUNE_*` environment variables, and the
power/efficiency and reservation-aware details are all in
[How It Works -> Measured tuning](how-it-works.md#measured-tuning-the-tune-search).

### Guided BIOS tuning

`sudo ./rigforge.sh bios` walks the detect → guide → reboot → re-verify loop for the firmware
settings with the biggest RandomX impact: the memory profile (XMP/EXPO/DOCP), SMT, and the CPU
power/boost posture (`--efficiency` swaps the boost item for Eco-Mode + Curve Optimizer). It reads
the same probes `doctor` reports on, so the two never disagree; pending items are saved to
`rigforge-bios.json` (included in `backup`/`restore`) and the next `bios` run re-checks exactly
those items against fresh probes — an item only counts as applied when its OS-visible fingerprint
flips (memory running at rated speed, SMT on, loaded clock above the boost threshold). The CPU
boost item needs the miner running to measure; with it stopped, `bios` says so and keeps the item
pending rather than guessing. After everything took, re-run `tune --live` — the hardware envelope
changed.

### Live auto-tuning (opt-in)

Run one pass on demand any time with `sudo ./rigforge.sh tune --now`. It sweeps the prefetch modes
against your running miner and keeps the best if it beats the current setting by a margin. For a thorough
pass that sweeps every knob live (threads, yield, 1G-pages, not just prefetch), use `tune --now --long`
(the live equivalent of a bare `tune`). No scheduling needed; either is a quick way to re-tune live after
a BIOS, RAM, or cooling change. `tune --now` is the friendly name for the `autotune` engine; the
standalone `autotune` verb still works and is what the scheduled timer below runs.

For a hands-off schedule, set `autotune` in `config.json` to a target and re-run `setup`. RigForge
installs a systemd timer that periodically optimizes the prefetch mode against your live miner:

| `autotune` | What the scheduled run optimizes for |
| --- | --- |
| `"disabled"` *(default)* | Nothing. No timer is installed. |
| `"performance"` | Raw hashrate (H/s). |
| `"efficiency"` | Hashrate-per-watt (H/s/W), for power-cost-, heat-, or PSU-limited rigs. Needs a power source (built-in RAPL, or a `TUNE_POWER_CMD` for a smart plug / IPMI); without one it falls back to `performance` with a warning. |

Legacy booleans still work: `true` → `performance`, `false` → `disabled`. The chosen target is baked
into the systemd unit at setup, so the scheduled run optimizes for what you picked, and `tune --history`
shows it.

Each run converges in one pass (~minutes). It reads the current hashrate from the miner's API (median of
a few samples, plus average watts when the target is `efficiency`), then sweeps every prefetch mode
(applying each, restarting, and re-measuring over a warmup window) and adopts the best by the target's
metric, but only if it beats the baseline by a margin (else it keeps the current mode). A single run
settles on the best prefetch mode; you don't wait days. The change is merged on top of any offline `tune`
result, so your tuned thread count and `cpu.yield` are preserved.

When it re-tunes: once the prefetch mode converges it's stable, so re-tuning is event-driven, not a blind
daily loop that churns the miner to re-confirm a result that rarely changes.

- After an `upgrade`, the real trigger. The fastest knobs can shift between XMRig versions, so once a
  rebuild finishes (and the new build is live) RigForge re-tunes it automatically.
- A monthly safety-net timer. The default cadence is monthly, to catch slow drift (thermal, ambient
  temperature, fan/dust). Change it with `AUTOTUNE_ONCALENDAR` (any [systemd calendar](https://www.freedesktop.org/software/systemd/man/systemd.time.html)
  spec) before `setup`, e.g. `AUTOTUNE_ONCALENDAR=weekly sudo ./rigforge.sh setup`.

Review the schedule, the next run, and recent decisions any time with `rigforge tune --history` (or
`journalctl -u rigforge-autotune`).

Auto-tune only touches the prefetch mode, the knob most worth re-checking live. For a definitive,
one-time sweep of every knob, run the offline [`tune`](#tuning) above. Linux only.

### MSR mod verification

The MSR "RandomX boost" (writing the CPU's prefetcher MSRs) is one of the biggest levers, worth ~10–15%,
so `doctor` verifies it actually took effect, not just that the `msr` module loaded:

- From XMRig's log (always): the `msr register values for "<preset>" preset have been set successfully`
  line confirms XMRig wrote the per-family preset (e.g. `ryzen_19h_zen4`). A `FAILED` line is flagged,
  usually Secure Boot or a missing `msr.allow_writes=on`.
- Register read-back via `rdmsr` (run `doctor` as root, with `msr-tools` installed; `setup` installs it):
  `doctor` reads the prefetcher registers back and checks they hold the preset's values, catching a write
  a hypervisor or kernel lockdown silently dropped even though XMRig reported success. Run without root,
  without `rdmsr`, or with the `msr` module unloaded, this step is skipped with an advisory, never a false
  alarm; the log check above still confirms the write.

With `miner_user` set (see [configuration](configuration.md)), xmrig runs unprivileged and cannot
write MSRs itself: `randomx.wrmsr` is disabled in the generated config and RigForge applies the same
per-family preset root-side instead (`rigforge.sh msr-apply`, run as a privileged `ExecStartPre=` of the
service). `doctor`'s read-back check verifies the root-side write the same way, and also confirms the
unit actually runs as the configured user.

You almost never need to tune the MSR preset. XMRig auto-selects the right per-family preset, and that's
optimal on the vast majority of CPUs. The knob exists for the rare case where a non-default preset (or
disabling the mod) wins on unusual silicon: set `TUNE_WRMSR="true false"` (or a preset number) to sweep
`randomx.wrmsr` alongside the other knobs. It's applied per-bench (no reboot) and pinned only if it
actually wins.

---

## Service management (Linux)

RigForge runs XMRig as a `systemd` service named `xmrig`:

```bash
sudo systemctl status xmrig     # service status
sudo systemctl stop xmrig       # stop the miner
sudo systemctl start xmrig      # start the miner
sudo systemctl restart xmrig    # restart (e.g. after a config change)
```

RigForge also wraps these so you don't have to remember the unit name:
`sudo ./rigforge.sh status` / `logs` / `start` / `stop` / `restart`.

The service is enabled at install, so it starts automatically on boot (and after the post-setup
reboot).

> On macOS there is no systemd service. RigForge builds and configures XMRig but you run it yourself. See
> [Running on macOS](#running-on-macos) below.

---

## Running on macOS

macOS is a development / light-use target; Ubuntu is the supported deployment platform. On macOS,
`sudo ./rigforge.sh` still does the core work: it installs dependencies (via Homebrew), compiles XMRig
from source, and writes a tuned `config.json`. What it doesn't do is the Linux-only system integration:

- No kernel tuning, and no reboot. macOS doesn't expose HugePages or MSRs, so the HugePages, MSR,
  `hugetlbfs`, and GRUB steps are skipped. The generated config turns those knobs off accordingly
  (`huge-pages`, `1gb-pages`, `wrmsr`/`rdmsr` are `false`) and binds the API to IPv6 `::`. Because the
  biggest RandomX levers (HugePages + MSR) are Linux-only, expect a lower hashrate than a tuned Linux box:
  fine for development, not for a production rig.
- No systemd service / no auto-start on boot. There's no service to install, and the miner doesn't start
  at boot. `setup` doesn't leave you to hand-roll a launch command, though. The same `start` / `stop` /
  `restart` / `status` / `logs` verbs work on macOS too (see below); on macOS they manage XMRig as a
  background process tracked by a PID file under the worker root, instead of via systemd.

### Run the miner

`setup` doesn't start the miner on macOS, so launch it yourself when ready, with the same command you'd
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

To have the miner start on its own, `enable` installs a per-user launchd LaunchAgent, macOS's analogue of
the systemd boot-start:

```bash
./rigforge.sh enable        # start the miner now and at every login
./rigforge.sh disable       # remove the login agent
```

The agent lives at `~/Library/LaunchAgents/com.rigforge.xmrig.plist`, restarts the miner if it crashes,
and starts it at each login. Once enabled, launchd owns the miner: `start` / `stop` / `restart` /
`status` then drive the agent (via `launchctl`) instead of an ad-hoc process, so you never end up with
two miners. `enable` starts it immediately too, unlike systemd's `enable`. A headless, always-on Mac
would want a system `LaunchDaemon` instead of a per-user agent; that's beyond this dev/light-use target,
so run as a LaunchDaemon by hand if you need it.

### Change a setting

Edit `config.json`, regenerate the live config, then restart:

```bash
./rigforge.sh apply             # regenerates the config (no sudo on macOS)
./rigforge.sh restart           # pick up the new config
```

### What's Linux-only

`doctor`, `uninstall`, `tune --live`, and `autotune` need systemd / Linux and aren't available on macOS.
Everything else works anywhere: `setup`, `apply`, `bench`, the offline `tune`, `backup` / `restore`,
`version`, and the full service surface `start` / `stop` / `restart` / `status` / `logs` / `enable` /
`disable` (which uses systemd on Linux and a launchd login agent on macOS).

---

## Logs

```bash
sudo journalctl -u xmrig -f     # live service logs
```

- Log file: `<WORKER_ROOT>/xmrig.log` (e.g. `data/worker/xmrig.log`).
- Rotation: a `logrotate` policy is installed automatically to compress and archive logs.
- Build log: the XMRig compile output is captured to `<WORKER_ROOT>/build.log` (e.g.
  `data/worker/build.log`) during setup, so a failed build is diagnosable after the fact. On any
  unexpected failure the script also names the step that failed and prints the last lines of the build
  log.

---

## Applying configuration changes

After editing `config.json`, apply it in one step:

```bash
sudo ./rigforge.sh apply
```

`apply` re-reads `config.json`, regenerates the live XMRig config, and restarts the service, with no
recompile. Use it for a pool change, a new rig label, TLS, or failover pools. Changing `DONATION` is
the exception: it's compiled into the binary and needs a rebuild. See
[Configuration › Changing settings later](configuration.md#changing-settings-later).

A full `setup` re-run also regenerates the config, but it's meant for re-provisioning, and so that it
won't interrupt a running miner, does not restart an already-built worker on its own. When you want
an edit to take effect, use `apply`. (On macOS, `apply` regenerates the config but you restart the
miner yourself; see [Running on macOS](#running-on-macos).)

---

## Upgrading XMRig (redeploy after a `git pull`)

RigForge pins XMRig to a known version/commit. To move to a newer pinned build:

```bash
git pull                        # get the new pin (and any RigForge changes)
sudo ./rigforge.sh upgrade      # rebuild + restart only if the pin changed
```

`upgrade` is a no-op when the pinned XMRig is already built, so it's cheap to run. A plain
`sudo ./rigforge.sh` (setup) also picks up a changed pin, but `upgrade` is the explicit, restart-aware
path. If you've enabled periodic [autotune](#live-auto-tuning-opt-in), `upgrade` re-tunes the new build
automatically once it's live. The optimal prefetch mode can change between XMRig versions, so the upgrade
is the moment that actually warrants a re-tune (the monthly timer is just a slow safety net).

> Pulled RigForge changes but not a new XMRig pin? Then `upgrade` is a no-op, since the build is
> unchanged. To pick up RigForge's own changes, run `sudo ./rigforge.sh apply` (regenerate the live
> config + restart); if the pull also changed kernel tuning or the service unit, run a full
> `sudo ./rigforge.sh setup`, then `restart`. When unsure, `upgrade` followed by `apply` covers the
> common cases.

> Old build artifacts are archived/pruned across runs, so repeated upgrades don't leak disk.

---

## Backup & restore

A worker's expensive, hard-to-recreate state is small: your `config.json` and the tuning result
(`tune-overrides.json`, which can take hours to produce). The XMRig build and the system tuning are
regenerated by `setup`, so they're not worth saving. `backup` snapshots that state into a portable
archive:

```bash
sudo ./rigforge.sh backup           # -> ./backups/rigforge-backup-YYYYMMDD-HHMMSS.tar.gz
```

The archive is owner-only (`chmod 600`) and includes `config.json`, the tuning files, and a small
manifest (RigForge version + source host). Back up after first-run setup and again after each `tune`.

`restore` puts it back. Point it at an archive:

```bash
sudo ./rigforge.sh restore ./backups/rigforge-backup-20260101-120000.tar.gz   # prompts; -y to skip
sudo ./rigforge.sh setup            # rebuild + apply (or 'apply' if XMRig is already built)
```

Restore overwrites `config.json` and the tuning on the current machine (so it prompts first), then tells
you to run `setup`/`apply` to put the restored config into effect.

### Two reasons to use it

- Recover from data loss. A wiped disk would otherwise mean re-doing setup and re-tuning. With a backup
  it's `restore` + `setup`.
- Roll a tune across a fleet. Tune one machine, `backup`, then `restore` on each identical machine; they
  all get the same config and the same tuning without re-running the slow search.

> NOTE: Tuning is CPU-specific. Only reuse `tune-overrides.json` between identical CPUs. On different
> hardware, restore the config but re-run `tune` (or `tune --clear` to drop the inherited tuning).
> Backups made with the default `HOME_DIR` (`DYNAMIC_HOME`) are fully portable; an absolute `HOME_DIR`
> carries that machine's path.

---

## Verification

After setup (and the reboot, on Linux), confirm the optimizations applied.

HugePages:

```bash
grep Huge /proc/meminfo
```

`HugePages_Total`, `HugePages_Free`, and `Hugepagesize` should be non-zero and match what setup
configured.

MSR (Model-Specific Registers):

```bash
grep -i msr <WORKER_ROOT>/xmrig.log
```

If you see MSR errors, see Troubleshooting below.

---

## Troubleshooting

| Symptom | Likely cause & fix |
|---|---|
| Setup fails during the build | The script names the step that failed and tails the build log. Read the full error in `<WORKER_ROOT>/build.log` (e.g. `data/worker/build.log`). Common causes: a build dependency you declined to install (re-run and accept), or too little RAM during compilation (the build already caps parallelism by RAM; add swap on very low-memory hosts). Re-run `sudo ./rigforge.sh` once resolved; it resumes without redoing finished work. |
| MSR errors in the log | Secure Boot is blocking the `msr` kernel module. Disable Secure Boot in your BIOS/UEFI, then reboot. |
| `doctor`: "MSR registers don't match the preset" | XMRig's log says the write succeeded but the read-back disagrees: the kernel or hypervisor silently dropped it. Common on VMs/cloud instances and under kernel lockdown. Run RigForge on bare metal, and ensure `msr.allow_writes=on` (RigForge sets this) and that lockdown isn't enforced. |
| `doctor`: "couldn't read the MSRs via rdmsr" | The `msr` module isn't loaded (or `doctor` wasn't run as root). Run `sudo ./rigforge.sh doctor`; if it persists, `sudo modprobe msr` (Secure Boot can block it). This is advisory; XMRig's log already confirms the write. |
| `HugePages_Total` is 0 | The kernel tuning needs a reboot to take effect (GRUB change). Reboot, then re-check `grep Huge /proc/meminfo`. |
| HugePages still 0 after reboot | Not enough contiguous memory was reservable, or another tool changed GRUB. Re-run `sudo ./rigforge.sh`; RigForge merges its kernel parameters into `GRUB_CMDLINE_LINUX_DEFAULT` rather than overwriting, so other params are preserved. |
| Low hashrate / few threads | RandomX is L3-bound (~2 MB per thread). A CPU with little L3 runs fewer effective threads; this is expected. See [Hardware › L3 cache](hardware.md#a-note-on-l3-cache). |
| No AVX2 | RandomX still runs but slower. AVX2 is strongly recommended; there's no fix beyond different hardware. |
| Dashboard can't read the worker | The API is open (no token) by default, so first check the worker is reachable from the stack host on `:8080`. If you set an `ACCESS_TOKEN`, the dashboard must send the same token (`workers.api_auth: token` + `workers.api_token`, or `name` if the token is the rig name). See [Pithead Integration › Troubleshooting](pithead-integration.md#troubleshooting). |
| Pool unreachable | Confirm the worker can reach its pool URL (firewall, DHCP/static IP). Workers use plain Stratum on the LAN, no Tor. |

---

## See also

- [Getting Started](getting-started.md) — first-run setup and verification.
- [Configuration](configuration.md) — config keys and how the XMRig config is generated.
- [Pithead Integration](pithead-integration.md) — the dashboard contract.

## Sister API (optional)

Set `"api": "enabled"` in `config.json` and run `sudo ./rigforge.sh apply`. The rig then serves a
second read-only HTTP endpoint (default `:8081`, keys `api_port`/`api_bind`) with everything the
`:8080` XMRig API has **plus** the data only RigForge knows: applied tune knobs and the last tune
run (`/tune`), hashrate-per-watt from RAPL, and the doctor probes — HugePages, MSR state, governor,
RAM channels/speeds, memory-profile and SMT state, throttling — as JSON (`/health`, or nested under
`rigforge` in `/1/summary` and `/2/summary`). It follows XMRig's own architecture: one tiny
persistent server (python3 stdlib, ~10 MB idle) ships pre-computed bytes, so a request costs
microseconds and cannot touch mining performance; a systemd timer recomputes the state every 15
seconds at idle priority, off the request path — responses are at most ~15s stale, within the
resolution of XMRig's own 10s hashrate window. The same
`ACCESS_TOKEN` posture applies (open when unset, Bearer required when set), it is read-only by
construction (GET only), and when XMRig is down the RigForge data still serves with an
`"xmrig_api": "unreachable"` marker — which is exactly when the health data matters. Linux-only;
`"api": "disabled"` + `apply` removes the units cleanly.
