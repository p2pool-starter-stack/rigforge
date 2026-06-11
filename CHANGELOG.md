# Changelog

All notable changes to RigForge are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is in
[`VERSION`](./VERSION); see [`RELEASING.md`](./RELEASING.md) for how a release is cut.

## [Unreleased]

### Added
- **Docs: stratum authentication against a Pithead stack.** Pithead can now require a stratum
  password (`p2pool.stratum_password`); when it's on, a rig must send the matching pool `pass` or the
  proxy rejects it (`Permission denied`). [Pithead Integration](docs/pithead-integration.md#stratum-authentication-optional)
  and the [`pass` config reference](docs/configuration.md#pools-full-control) now explain how to set
  it — no code change, the existing `pools[].pass` field carries the secret. Added tests asserting a
  Pithead-style password (hex and `._:@-` literals) flows through verbatim and an invalid pass (with a
  space) is rejected.
- **`tune --history`** — a readable summary of this rig's tuning: the **winning tune options** applied
  right now (from `tune-overrides.json`), the last full `tune` run (target, best H/s, candidates tried),
  and — on Linux — the periodic auto-tuner's **schedule, next scheduled run**, and recent keep/rollback
  decisions (from the systemd journal). Read-only and best-effort; works without a built worker and
  degrades gracefully when nothing's been tuned yet.
- **Optional `rigforge` command on your PATH.** Set `"add_to_path": true` in `config.json` and `setup`
  installs a `rigforge` command — a symlink in `/usr/local/bin` pointing at the script — so you can run
  `sudo rigforge doctor` / `tune` / `apply` from any directory instead of `./rigforge.sh`. The script
  resolves itself through the symlink, so the repo (config.json, `util/`, the worker build) is still
  found. **Off by default** — setup makes no system-wide convenience change you didn't ask for.
  Best-effort and idempotent: it never fails a deploy, won't clobber a non-RigForge file already at that
  path, and `uninstall` removes it.
- **`tune` optimization target — raw hashrate vs. efficiency (#79).** `tune --efficiency` (or
  `TUNE_TARGET=efficiency`) ranks candidates by **hashrate-per-watt** instead of raw H/s — for power-cost
  or heat/PSU-constrained rigs. The variance gate (#63) carries over proportionally, and efficiency mode
  requires a power source (built-in RAPL or `TUNE_POWER_CMD`), falling back to `perf` with a warning when
  none is available. The chosen target is recorded in `rigforge-tune.json`. Default stays `perf`.
- **`doctor` BIOS/firmware advisory (#78).** `doctor` now reads what the booted OS exposes — board + BIOS
  version/date from `/sys/class/dmi/id`, the memory profile (rated vs. configured speed via `dmidecode`),
  and SMT state — and turns it into concrete, manual BIOS recommendations: enable **XMP/EXPO/DOCP** when
  RAM runs below its rated speed, and enable **SMT/Hyper-Threading** when it's off. Detect-and-recommend
  only — RigForge can't read or change BIOS setup variables from a running OS — so it's purely advisory
  and degrades gracefully when the probes aren't available.
- Hardware-aware tuning knobs: MSR verification & reservation-aware threads (#65, #66):
  - **MSR mod verification (#66):** `doctor` no longer just checks that the `msr` module loaded — it now
    confirms the prefetcher mod actually **applied**. It reads XMRig's own log line (`msr register values
    for "<preset>" … set successfully`) and, when `msr-tools` is present, reads the registers back with
    `rdmsr` and checks they hold the preset's values (verified against XMRig v6.26.0's table for
    `ryzen_17h/19h/19h_zen4/1Ah_zen5` and `intel`) — catching a write silently dropped by a hypervisor or
    kernel lockdown. `setup` now installs `msr-tools` so the check works out of the box.
  - **Opt-in `wrmsr` tuning knob (#66):** `tune` can sweep the MSR preset as a knob — `TUNE_WRMSR="true
    false"` (or a preset number) — applied per-bench (no reboot) and pinned to the winner only when it
    actually wins, like the other off-by-default knobs.
  - **Reservation-aware thread exploration (#65):** `tune` computes each candidate thread count's 2MB
    HugePage need (via the same `proposed-grub.sh` math `setup` uses) and flags any candidate that exceeds
    the current reservation as `hugepages_capped` in `rigforge-tune.json` — it ran *without* full
    huge-page backing, so its hashrate is a floor, not a fair reading. `tune` reports the capped thread
    counts and the documented resize path. `setup` now sizes the reservation for the **tuned** thread
    count (the pinned `cpu.rx`, or an explicit `RIGFORGE_THREADS=<n>`), so `setup` and `tune` stay
    consistent.
- Trustworthy tuning measurement & decisions (#62, #63, #64):
  - **Variance-aware acceptance (#63):** `tune` adopts a candidate only when its median beats the best by
    both the `TUNE_MIN_DELTA` floor **and** more than the combined sample-noise band (`TUNE_SIGMA` ×
    √(sd_cand² + sd_best²)), so jitter on noisy hardware can't trigger a phantom adoption. Each
    candidate's stddev is recorded in `rigforge-tune.json`. Applies to the hill-climb and grid searches.
  - **Thermal-throttle rejection (#62):** the default `--bench` window is already sustained (`TUNE_BENCH`
    10M ≈ minutes of load); `tune` now samples the effective CPU clock *throughout* each candidate's
    window and, if it dips below `TUNE_MIN_FREQ_MHZ` (default ~80% of max boost), flags the candidate as
    **throttled** in the log and never adopts it — so a thermally-throttled reading can't crown a config.
  - **Live A/B confirm (#64):** `tune --confirm` applies the winner, measures it live, then restores the
    previous config and measures that, and keeps the winner only if it genuinely wins live (else reverts
    and reports) — bridging the gap between offline `--bench` conditions and production.
- `doctor` now flags **hashrate-capping hardware** it can't fix but you can (#67): single-channel or
  slow RAM (parsed from `dmidecode`, run as root) and a power/boost-capped CPU clock (effective clock
  vs. max boost, checked while the miner is loaded) — since RandomX fast-mode is dataset-latency bound,
  these silently cost hashrate. Purely advisory, gated on tool/data availability, and degrades to a
  gentle note when `dmidecode`/sysfs aren't readable.
- Auto-tuning (#46, #54). `tune` searches for the fastest XMRig knobs for your CPU with an iterative,
  noise-aware coordinate hill-climb: starting from two seeds (XMRig's auto baseline and an educated
  guess) it sweeps the RandomX scratchpad prefetch mode, `cpu.yield`, and the RandomX thread count
  (`cpu.rx`, around L3 ÷ 2 MB), measures each candidate as the **median** of several `xmrig --bench`
  runs, adopts a change only when it beats the current best by a minimum margin (`TUNE_MIN_DELTA`), and
  stops when a full pass makes no gain (plateau). Every measured candidate is memoized so a combination
  is never benchmarked twice. The reboot-bound `1gb-pages` knob is swept only when 1G HugePages are
  actually reserved (otherwise skipped with a note). Results — every candidate with its samples, median,
  and optional watts/temperature for a hashrate-per-watt view — are logged to
  `<WORKER_ROOT>/rigforge-tune.json`; the winning knobs go to a separate `tune-overrides.json` that's
  merged into the generated config, so your `config.json` is never touched. `tune --live` measures
  against the running miner over steady-state API windows instead of `--bench`; `tune --clear` resets.
  Opt-in periodic live tuning: set `autotune: true` in config to install a systemd timer that runs
  `autotune` (one live trial against the running miner via its API; keeps a change only if it beats the
  baseline by a margin, else rolls back).
- Auto-tuning robustness: `tune --bench` now **stops the miner service for the benchmark run** (and
  restarts it after, even on error) so readings aren't contended; the thread search is **SMT-aware**
  (tries the physical- and logical-core counts, not just an L3 ± window); `TUNE_SEARCH=grid` adds an
  exhaustive, local-optimum-proof search; `cpu.huge-pages-jit` and `randomx.cache_qos` are opt-in
  tunable knobs (`TUNE_HPJIT` / `TUNE_CACHEQOS`); and the default measurement is a steadier median of 5.
  `autotune` now compares a **median** of API samples and **merges** its prefetch change into existing
  overrides instead of overwriting them, so a prior `tune`'s thread count and `cpu.yield` survive. The
  default `TUNE_BENCH` is now `10M` (steadier, closer to sustained load — you tune once); `--bench` notes
  that it measures Monero's rx/0 and points other RandomX variants at `--live`; a pinned thread count
  carries a HugePages-resizing reminder; and `upgrade` nudges you to re-tune when saved tuning carries
  over to a new XMRig build.
- `backup` / `restore` commands (mirroring Pithead). `backup` snapshots the expensive, hard-to-recreate
  state — `config.json` + the tuning files (`tune-overrides.json`, `rigforge-tune.json`) — into a
  timestamped, owner-only `tar.gz` under `./backups`; `restore [-y] <archive>` puts it back (prompting
  before it overwrites). Recovers a worker after data loss without re-tuning, and rolls one machine's
  config + tuning across a fleet of identical machines. Tuning is CPU-specific, so it's only portable
  between identical CPUs.
- `uninstall` command: cleanly reverts every change setup made — removes the systemd service and
  logrotate policy, strips the HugePage/MSR lines from `fstab`/`limits.conf`/`/etc/modules`, reverts the
  managed GRUB kernel parameters, unmounts the 1G HugePage filesystem, and removes the worker
  build/logs (leaving `config.json`). Idempotent; prompts unless `--yes` (#12).
- Command surface: `apply`, `doctor`, `bench`, `status`, `logs`, `start`, `stop`, `restart`, `enable`,
  `disable`, and `version` subcommands alongside `setup`/`upgrade`/`help`. `doctor` is a read-only
  health check that verifies HugePages are reserved, the `msr` module is loaded, the CPU governor is
  `performance`, the service is active, and (from the XMRig log) that HugePages are 100% backed — with
  actionable hints. `apply` regenerates the config and restarts without rebuilding; `bench` runs a
  one-off `xmrig --bench` (#11, #45).
- The pool connection is now XMRig's native **`pools`** array, set directly in `config.json` — any
  port, TLS, and multiple pools for failover. Each entry needs a `host:port` `url`; other fields fall
  back to Pithead-friendly defaults — so the minimal config is a single
  `pools: [{ "url": "host:port" }]` (#21, #42).
- The rig's dashboard label is the pool `user` (defaults to the hostname); the API token follows the
  rig name so the Pithead `Bearer <rig name>` contract still holds. Two-tier config like Pithead: a
  minimal `config.json` (just a `pools` entry — everything else defaults) plus a
  `config.advanced.example.json` documenting every key and its default. The generated XMRig config is
  built entirely in-script — no template file and no `WORKER_CONFIG_FILE` key (#22, #23, #55).
- Dependency-free test suite, Ubuntu end-to-end container harness, and CI (#5).
- Test coverage gate (#68): `make coverage` measures line coverage of `rigforge.sh` +
  `util/proposed-grub.sh` via kcov (in a digest-pinned container, with a pinned static `jq`), and CI
  enforces both a committed **total floor** (`tests/coverage-floor.txt`, ratcheted up over time) and
  **patch coverage** of new/changed lines (`diff-cover` vs `main`) — self-contained, no external
  service. To credit black-box runs (not just sourced functions), the script's base directory is now
  overridable via `RIGFORGE_HOME` (defaults to the script's own dir, so a normal deploy is unchanged),
  letting the suite run the *real* `rigforge.sh` against a per-test sandbox instead of a copy. The CI
  `lint` job now runs `make lint` so its file list can't drift from the Makefile.
- Release smoke check (#61): `make smoke` (or `SMOKE_RUN_SETUP=1 make smoke`) runs the real worker
  through `xmrig --bench` — fully offline (no pool, wallet, or network) — as a manual, real-hardware
  pre-tag gate, passing only if a hashrate is reported and the run is clean. The unit/e2e suites stub
  XMRig and so can't prove the shipped binary actually starts and hashes; this does. `bench` now also
  fails loudly — surfacing the XMRig output — on `MEMORY ALLOC FAILED` or a config-parse error, not
  just on a missing hashrate. Documented as a required step in RELEASING.md; kept out of CI by design.
- Full real-hardware release e2e (`tests/e2e-real.sh` / `make e2e-real`), generalizing the bench smoke
  check: a phased pre-tag gate that runs the genuine deploy on a real Linux rig and asserts each step —
  `provision` (real deps + XMRig build + tuning + kernel tuning + service) → reboot → `verify` (doctor
  confirms HugePages/MSR/governor/service, `bench` produces a real hashrate, a short `tune` runs end to
  end) → `teardown` (`uninstall` + assert a clean revert). This is the "CI does all it can; the release
  gate does the rest for real" layer — it exercises everything the suites stub. Out of CI by design.
  Validated end-to-end on a real Ryzen 7800X3D rig, where it found and fixed two bugs the stubbed suites
  could never catch (#74, #75).
- Real macOS CI (#69): a `test-macos` job runs the suite on a macos-14 runner (and under Apple's bash
  3.2) instead of only simulating Darwin via stubs on Linux, plus a **native macOS e2e**
  (`tests/e2e/macos.sh` / `make test-e2e-macos`) that runs the real `rigforge.sh` end to end with only
  brew/git/cmake/make stubbed — exercising BSD `sed` (the donate.h patch), the macOS config profile,
  real `nohup`/PID-file process control, the real `launchctl` login agent (headless-tolerant), and BSD
  `tar`/`date` `backup`/`restore`.
- Headless-safe `setup`: dependency installation is non-interactive (an interactive `read` prompt aborted
  the run on a non-tty stdin under `set -e`) and passes `-o DPkg::Lock::Timeout` so a fresh-boot
  unattended-upgrades apt lock waits rather than fails (#74).
- `bench` / `tune --bench` work on real hardware: `xmrig --bench` prints its result then waits for
  Ctrl+C instead of exiting and block-buffers stdout, and the generated config redirected the result to
  a log file / would mine / served the API — so the measurement hung. The new `_xmrig_bench` helper runs
  xmrig against its own `--log-file`, waits for the `benchmark finished` line, then stops it (#75).
- Pinned, commit-verified XMRig build via `XMRIG_VERSION` / `XMRIG_COMMIT` (#18, #2).
- `upgrade` command and idempotent re-runs: re-running skips the (slow) recompile and service restart
  when the pinned XMRig is already built; old build archives are pruned so re-runs don't leak disk (#4).
- Every `config.json` field is validated before building, failing fast with a clear message: the pool
  `url` host (valid hostname / FQDN / IPv4 / bracketed-IPv6, no placeholders or metacharacters) and
  port (1–65535), `user`/`pass`/`ACCESS_TOKEN` character sets, the `keepalive`/`tls`/`enabled`
  booleans, `DONATION` (integer 0–100), and `HOME_DIR` (a clean absolute path) (#8).
- Build robustness: build output is captured to a logfile, an ERR trap names the failed step, and
  `make -j` is capped by available RAM to avoid OOM on low-memory hosts (#9).
- Pinned, checksum-verified `shellcheck` + `shfmt` formatting check in CI, plus a `make fmt` target (#6).
- Documented the Pithead worker-API contract (port 8080, read-only, token = rig name) in the docs (#24).
- Community-health files: SECURITY policy, CONTRIBUTING guide, issue/PR templates (#16).
- A `docs/` set (getting-started, hardware, configuration, operations, how-it-works, Pithead
  integration, FAQ) mirroring Pithead's structure; the README is slimmed to a quick-start that links
  out to it, and the release bundle now ships `docs/` (#25).
- Branded README header: a flame logo (`images/rigforge-mark.svg`, shared with the project website)
  and status badges (CI, license, platform, miner, companion), mirroring Pithead's header.
- `VERSION`, this changelog, `RELEASING.md`, and a tag-driven release pipeline that publishes a GitHub
  Release with `.zip`/`.tar.gz` deploy bundles, `SHA256SUMS`, and changelog-derived notes (#3, #36).

### Changed
- **Live auto-tuning now converges in one run.** Instead of trying one prefetch mode per daily run
  (~4 days to sweep all four), each `autotune` run **live-sweeps every prefetch mode** and adopts the
  fastest (median measurement + a margin gate, else it keeps the current mode) — converging in a single
  ~minutes-long pass. The timer still fires daily by default to re-verify/catch drift; `AUTOTUNE_ONCALENDAR`
  changes the cadence and `AUTOTUNE_MODES` the modes swept. For a definitive all-knob sweep, run `tune`.
- **`status` and `logs` no longer prompt for sudo.** They're read-only — `systemctl status` is
  world-readable and the operator (in the `adm` group) can follow the service journal — so neither runs
  `sudo` anymore. The privileged verbs (`start`/`stop`/`restart`/`enable`/`disable`) still elevate as
  needed.
- Simplified the tuning docs for first-time users: `docs/operations.md` now leads with the one-time
  `tune` → `apply` path, a short "useful variants" table, and `tune --history`, with a pointer to
  `docs/how-it-works.md` for the rest. The search internals, the full `TUNE_*` environment-variable
  reference, and the power/efficiency and reservation-aware details moved to `how-it-works.md` (next to
  the mechanics they belong with), removing the duplication that made the section hard to follow.
- Repo readability polish: renamed `docs/tuning.md` → `docs/how-it-works.md` (matching the page title
  and every inbound link), the Linux container e2e `tests/e2e/run.sh` → `tests/e2e/linux.sh` (parallel to
  `tests/e2e/macos.sh`), and the `make test-stack` target → `make test-suite`. Added section banners + a
  table of contents to `rigforge.sh`, a suite index to `tests/run.sh`, and a `tests/README.md` mapping the
  test layers. Also fixed `make help`, which silently hid every target with a digit in its name
  (`test-e2e`, `test-e2e-macos`, `e2e-real`) — it now lists all ten. No behaviour change.
- CI now runs on Node-24 GitHub Actions: `actions/checkout` bumped to v6.0.3 (resolving the Node-20
  deprecation warning), with pinned `shellcheck` 0.11.0 and `diff-cover` 10.3.0. `util/proposed-grub.sh`
  now uses `#!/usr/bin/env bash` + `set -uo pipefail` and exact-match argument parsing, matching the rest
  of the repo. `make help` lists the targets.
- Hardened the `xmrig` systemd unit with defense-in-depth sandboxing (`NoNewPrivileges`,
  `ProtectSystem=full`, `PrivateTmp`, `ProtectControlGroups`, `LockPersonality`, `ReadWritePaths`
  scoped to the worker root) — chosen to not break the MSR mod, RandomX JIT, or HugePages. `memlock`
  is now scoped to the service (`LimitMEMLOCK=infinity`) and the mining user, instead of granted to
  every account via `*` (#13).
- Tuning: the generated XMRig config now relies on XMRig's cache-aware auto-detection (thread count,
  assembly path, MSR preset, NUMA) instead of matching CPU model names — fixing a wrong all-cores
  thread list on dual-CCD X3D parts (e.g. 7950X3D) — and sets dedicated-miner defaults (`cpu.yield:
  false`, `cpu.priority: 2`). Removed config keys XMRig silently ignores (the top-level `msr` object
  and `cpu.msr`); the MSR mod is driven by `randomx.wrmsr` (#43, #44).
- Generalized the project's language and config for any RandomX/XMRig pool: the docs and config lead
  with the generic worker use case rather than P2Pool specifically (#35).
- XMRig HTTP API on Linux is now read-only (`restricted: true`) while staying LAN-reachable, so
  Pithead can still read per-rig stats at `:8080` (#17, #7).
- Removed the `.local` / Avahi mDNS handling — point workers at an IP or DNS-resolvable hostname (#15, #14).
- `generate_xmrig_config` now builds the entire XMRig config from scratch with `jq`; the bundled
  `worker-config/example-config.json.template` and its `TEMPLATE_CONFIG` plumbing are gone, and
  `worker-config/` is dropped from the release bundle — one fewer file to keep in sync (#55).
- The full service surface — `start` / `stop` / `restart` / `status` / `logs` / `enable` / `disable` —
  now works on **macOS** (previously Linux-only). With no systemd there, `start`/`stop`/`status` manage
  XMRig as a background process tracked by a PID file; `enable`/`disable` install/remove a per-user
  **launchd LaunchAgent** (`~/Library/LaunchAgents/com.rigforge.xmrig.plist`) so the miner starts at
  login and restarts on crash. Once enabled, launchd owns the miner and the run verbs delegate to
  `launchctl`, so there's no competing process. After setup, macOS now points you at
  `./rigforge.sh start` instead of a raw `screen`/`xmrig` command.
- The macOS CPU profile now uses `cpu.priority: 2` (matching the Linux dedicated-miner default) instead
  of `5`. XMRig warns a priority above 2 can make the machine unresponsive, and macOS is a
  light-use/dev target — pinning it to the most aggressive level was inconsistent.
- The generated config now leaves `cpu.huge-pages-jit` at XMRig's upstream default (`false`) instead of
  forcing it on. XMRig documents the knob as only a "very small Ryzen boost" with "unstable hashrate" —
  not worth the jitter on a production rig (and it added noise to the `tune` search).
- Dropped `cpu.hwloc` from the generated config: it is **not** a recognized XMRig `cpu` JSON key (hwloc
  is enabled at build time via `WITH_HWLOC=ON` and used automatically), so emitting it was a silent
  no-op. No behaviour change — just a cleaner, fully-valid config.
- Docs: `apply` is now the documented path for applying a `config.json` edit (regenerate + restart) —
  a plain `setup` re-run regenerates the config but won't restart an already-built worker, so edits
  used to silently not take effect. Added a **Running on macOS** guide (what differs, how to launch the
  miner, which commands are Linux-only), a build-failure troubleshooting entry, and assorted accuracy
  fixes across the docs.

### Fixed
- **The nightly auto-tune no longer re-owns your files to root.** The `autotune` systemd timer runs as
  root with no `SUDO_USER`, so its post-run re-own was handing `data/worker` + `config.json` back to
  `root:root` each night — undoing the operator-ownership fix and forcing `sudo` to edit `config.json`.
  The autotune service unit now bakes in `RIGFORGE_OPERATOR` (the operator captured at setup time) and
  the re-own honours it, so the timer hands files back to you. (The autotune `.service`/`.timer` are now
  rendered from templates in `systemd/`, alongside `xmrig.service.template`, instead of inline heredocs.)
- **`doctor` no longer aborts when run without `sudo`.** The RAM-layout probe runs `dmidecode` (root-only),
  so a non-root `doctor` made `dmidecode | awk` non-zero under `set -o pipefail` — tripping errexit and
  aborting the whole health check with a spurious "rigforge aborted" message right after the governor
  line. `_mem_summary` now always exits 0 (falling back to the "run as root" advisory), and `doctor`'s
  other optional probes (`rdmsr`, CPU clock, SMT) guard *inside* the command substitution so a missing
  sysfs file (e.g. on a VM) can't trip the trap either. Non-root `doctor` now completes cleanly.
- **`sudo` runs no longer leave root-owned files behind.** `setup`/`upgrade`/`tune`/`apply`/`restore`
  wrote the build, generated config, logs, and tuning files as root (and the first-run `config.json` was
  created root-owned), so an operator following the documented "edit `config.json` → `apply`" loop hit
  permission-denied and a non-`sudo` re-`setup`/`git clean` failed. Each command now hands the worker tree
  and `config.json` back to the invoking operator on completion.
- **A fresh `setup` no longer starts the miner before the mandatory reboot.** HugePages aren't reserved
  until the GRUB change takes effect on reboot, so the service is now **enabled** (not started) on a first
  install — it starts automatically after the reboot, instead of running degraded until then.
- `apply`/`tune` before `setup` now give a clear "no config — run setup first" message instead of
  "is not valid JSON"; the first-run prompt no longer aborts on a non-interactive stdin.
- **`tune` hashrate-per-watt was measured at idle (#81).** In `--bench` mode, watts were read *after* the
  benchmark finished and every `xmrig` child was killed — i.e. while the machine coasted back to idle —
  so `hs_per_watt` divided a loaded hashrate by idle power and couldn't rank candidates. Power is now
  sampled **under load and averaged over the window** (in both `--bench` and `--live`). Added a **built-in
  RAPL** reader (the CPU-package energy-counter delta — works on Linux as root with no `TUNE_POWER_CMD`),
  with `TUNE_POWER_CMD` kept as the instantaneous-watts override for IPMI / smart-plug / wall-AC sources;
  a single counter wrap is corrected. Documented that `hs_per_watt` is **relative within one method and
  machine** (RAPL = CPU package only; a smart plug = whole-wall AC), not an absolute or cross-rig figure.
- **Fail-closed worker-root resolution:** `uninstall`/`backup`/`restore` resolved `HOME_DIR` without the
  validation `parse_config` enforces, so a malformed or hostile `HOME_DIR` could flow into a privileged
  `sudo rm -rf`. The validation is now shared, and every consumer refuses an invalid `HOME_DIR`.
- **logrotate ownership:** the rotated `xmrig.log` is now recreated owned by the real operator
  (`SUDO_USER`), not `whoami` — which is `root` under `sudo ./rigforge.sh` and locked the operator out of
  a manual run.
- `compile_xmrig` removes any partial/stale clone before cloning, so a re-run after an interrupted or
  commit-mismatched build no longer aborts with "destination path already exists".
- `setup` no longer relies on `command -v` to decide whether a build *package* is installed (meaningless
  for `-dev`/meta packages) — it queries the package manager directly. The first-boot `jq` bootstrap now
  carries the same apt lock-timeout as the main dependency install (#74).
- GRUB configuration now **merges** the HugePage/MSR kernel parameters into the existing
  `GRUB_CMDLINE_LINUX_DEFAULT` instead of overwriting it, preserving other kernel params — a
  boot-safety fix (#19).
- The "run manually" hint pointed at a non-existent `--config` path; it now points at the build-dir
  config the systemd service actually uses (#20).
- `rigforge.sh` aborted under `set -u` when neither `SUDO_USER` nor `USER` was set (containers, cron,
  minimal CI); `REAL_USER` now falls back to `id -un` (#5).

[Unreleased]: https://github.com/p2pool-starter-stack/rigforge/commits/main
