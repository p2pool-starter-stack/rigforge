# Changelog

All notable changes to RigForge are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is in
[`VERSION`](./VERSION); see [`RELEASING.md`](./RELEASING.md) for how a release is cut.

## [Unreleased]

### Added
- Full control over the pool connection: `config.json` can set XMRig's native **`pools`** array
  directly (any port, TLS, and multiple pools for failover), with blank fields falling back to
  Pithead-friendly defaults. The simple `POOL_HOST` shorthand still synthesizes a single
  `POOL_HOST:3333` pool out of the box (#21, #42).
- Dependency-free test suite, Ubuntu end-to-end container harness, and CI (#5).
- Pinned, commit-verified XMRig build via `XMRIG_VERSION` / `XMRIG_COMMIT` (#18, #2).
- `upgrade` command and idempotent re-runs: re-running skips the (slow) recompile and service restart
  when the pinned XMRig is already built; old build archives are pruned so re-runs don't leak disk (#4).
- Config-input validation before building: `DONATION` (integer 0–100) and the pool host
  (hostname / FQDN / IP, no metacharacters) fail fast with a clear message (#8).
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
- Tuning: the generated XMRig config now relies on XMRig's cache-aware auto-detection (thread count,
  assembly path, MSR preset, NUMA) instead of matching CPU model names — fixing a wrong all-cores
  thread list on dual-CCD X3D parts (e.g. 7950X3D) — and sets dedicated-miner defaults (`cpu.yield:
  false`, `cpu.priority: 2`). Removed config keys XMRig silently ignores (the top-level `msr` object
  and `cpu.msr`); the MSR mod is driven by `randomx.wrmsr` (#43, #44).
- Generalized the project's language and config for any RandomX/XMRig pool: the pool/stratum host is
  now configured via `POOL_HOST` (the former `P2POOL_NODE_HOSTNAME` key still works as an alias), and
  the docs lead with the generic worker use case rather than P2Pool specifically (#35).
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
