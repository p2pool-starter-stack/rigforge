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
  `config.advanced.example.json` documenting every key and its default. The XMRig template is now
  internal (no `WORKER_CONFIG_FILE` key) (#22, #23).
- Dependency-free test suite, Ubuntu end-to-end container harness, and CI (#5).
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

### Fixed
- GRUB configuration now **merges** the HugePage/MSR kernel parameters into the existing
  `GRUB_CMDLINE_LINUX_DEFAULT` instead of overwriting it, preserving other kernel params — a
  boot-safety fix (#19).
- The "run manually" hint pointed at a non-existent `--config` path; it now points at the build-dir
  config the systemd service actually uses (#20).
- `rigforge.sh` aborted under `set -u` when neither `SUDO_USER` nor `USER` was set (containers, cron,
  minimal CI); `REAL_USER` now falls back to `id -un` (#5).

[Unreleased]: https://github.com/p2pool-starter-stack/rigforge/commits/main
