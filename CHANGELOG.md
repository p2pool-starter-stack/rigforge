# Changelog

All notable changes to RigForge are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is in
[`VERSION`](./VERSION); see [`RELEASING.md`](./RELEASING.md) for how a release is cut.

## [Unreleased]

### Added
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
- Real macOS CI: a `test-macos` job runs the suite on a macos-14 runner (real BSD `sed`, the macOS
  config profile, `mac_*` control, BSD `tar`/`date`) and under Apple's bash 3.2, instead of only
  simulating Darwin via stubs on Linux (#69).
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
- A `docs/` set (getting-started, hardware, configuration, operations, how-it-works (`tuning.md`), Pithead
  integration, FAQ) mirroring Pithead's structure; the README is slimmed to a quick-start that links
  out to it, and the release bundle now ships `docs/` (#25).
- Branded README header: a flame logo (`images/rigforge-mark.svg`, shared with the project website)
  and status badges (CI, license, platform, miner, companion), mirroring Pithead's header.
- `VERSION`, this changelog, `RELEASING.md`, and a tag-driven release pipeline that publishes a GitHub
  Release with `.zip`/`.tar.gz` deploy bundles, `SHA256SUMS`, and changelog-derived notes (#3, #36).

### Changed
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
- GRUB configuration now **merges** the HugePage/MSR kernel parameters into the existing
  `GRUB_CMDLINE_LINUX_DEFAULT` instead of overwriting it, preserving other kernel params — a
  boot-safety fix (#19).
- The "run manually" hint pointed at a non-existent `--config` path; it now points at the build-dir
  config the systemd service actually uses (#20).
- `rigforge.sh` aborted under `set -u` when neither `SUDO_USER` nor `USER` was set (containers, cron,
  minimal CI); `REAL_USER` now falls back to `id -un` (#5).

[Unreleased]: https://github.com/p2pool-starter-stack/rigforge/commits/main
