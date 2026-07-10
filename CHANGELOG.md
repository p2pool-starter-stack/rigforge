# Changelog

All notable changes to RigForge are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is in
[`VERSION`](./VERSION); see [`RELEASING.md`](./RELEASING.md) for how a release is cut.

## [Unreleased]

### Added

- **Live status summary (#143).** `status` now opens with a one-glance block from a single
  worker-API fetch — hashrate, pool, uptime (`1d 2h 3m`), accepted/rejected shares, huge pages —
  then the unchanged platform detail. Facts only (no ✓/! judgment — that's doctor's), never sudo,
  and a stopped miner or bad config degrades to one explanatory line plus the platform block.

- **Shared-rig lock for the release gates (#183).** `e2e-real` and `e2e-pithead` take a kernel
  `flock` on `/var/lock/rig-e2e.lock` before their first service- or API-touching action, so
  RigForge's rig-mutating gates and Pithead's e2e testing can't collide on the shared miner-0: a
  second arrival exits 75 (`EX_TEMPFAIL`) naming the holder (project, suite, pid, start time, via
  the `/run/rig-e2e.holder` sidecar), and `RIG_LOCK_WAIT=1` queues instead of failing. The lock
  dies with the holding process — a killed run needs no cleanup. Pithead's harness carries the
  same helper against the same path; the path is the whole contract. Test-harness only:
  `rigforge.sh` itself stays lock-free.

## [1.4.0] - 2026-07-10

### Fixed

- **Per-release benchmark history + anti-ratchet perf gate.** `E2E_PERF_RECORD` now also appends
  `{tag, recorded, bench_1m_hs}` to `tests/perf-baselines/<host>.history.jsonl`
  (`E2E_PERF_TAG=vX.Y.Z` names the release), and the perf gate judges measurements against the
  current baseline **and** the host's best-ever history entry — so refreshing baselines each
  release can never walk hashrate down tolerance-by-tolerance. Recording per release is now a
  documented RELEASING.md step; histories seeded from the v1.3.0 baselines for all eight rigs.
- **`apply` creates the miner user (#140).** Toggling `miner_user` via `apply` (its documented
  config-change path) rendered `User=` into the unit but only `setup` created the user, so the
  service crash-looped with `status=217/USER`. Caught live on miner-0 during the release gate;
  `apply` now runs the same guarded `useradd` as `setup`.

### Added

- **Signed releases (#137).** The release workflow signs `SHA256SUMS` with minisign
  (`SHA256SUMS.minisig`), so releases prove origin, not just integrity — every listed asset is
  covered by inclusion. Fork-safe: without the `MINISIGN_SECRET_KEY` secret the release publishes
  unsigned with a notice. Verification commands in `SECURITY.md` › Release signing.
- **Config typo lint (#138).** `parse_config` now warns on unknown top-level keys and pool fields
  (case-insensitive did-you-mean for near-misses, key names only — never values). A misspelled
  `ACCESS_TOKEN` previously just… didn't apply, silently. Warn, not error: an unknown key is at
  worst a no-op, and erroring would break fleet `apply`s on any future rename. `_`-prefixed keys
  are the comment convention; `RIG_NAME` is reserved for the flashable-image seed (#1).
- **Binary tamper evidence (#141).** `compile_xmrig` records the built binary's SHA-256 next to
  the existing commit pin; `doctor` recomputes and compares (a changed binary is a counted issue),
  and a mismatch also fails the "already built" check so the next `setup`/`upgrade` rebuilds —
  self-healing. Evidence, not proofing (root can rewrite the record too); legacy builds without a
  record are advisory only, never a forced fleet recompile.
- **Opt-in API firewall (#142).** `api_allow_from` (an IPv4/CIDR, default empty) scopes the
  read-only API port(s) — `:8080` always, `:8081` when the sister API is on — to that source plus
  loopback, via an own `inet rigforge` nftables table re-applied on boot and destroyed on
  `uninstall`. Matches only the API dports, so SSH and the outbound stratum connection are
  untouchable; the strict IPv4 validation doubles as the injection guard. The Pithead contract
  (`0.0.0.0`, `restricted:true`, the token rules) is unchanged — this layers network scoping
  under it. nftables only (Ubuntu 24.04's native firewall); a missing `nft` with the key set is a
  hard error, never a silent open port.
- **Opt-in non-root miner (#140).** `miner_user` runs xmrig as a dedicated nologin system user:
  RigForge applies the CPU's MSR preset root-side (`msr-apply`, an `ExecStartPre=+`) so the miner
  never needs `/dev/cpu/*/msr`; the generated config sets `randomx.wrmsr/rdmsr: false`; HugePages
  need no root (boot-time reservation + the unit's `LimitMEMLOCK`); `doctor` verifies both the
  unit's user and the applied preset by register read-back. On CPU families outside the verified
  preset tables the MSR boost is skipped with a warning — the reason this ships opt-in,
  default-off (empty = exactly today's root behavior). `uninstall` leaves the user in place with
  a removal hint (exact-removal discipline: we can't prove we created it).

## [1.3.0] - 2026-07-10

### Added

- **Guided BIOS tuning (#80).** `sudo ./rigforge.sh bios` walks the detect → guide → reboot →
  re-verify loop for the firmware settings tuning can't reach from the OS: the memory profile
  (XMP/EXPO/DOCP), SMT, and the CPU power/boost posture (`--efficiency` swaps the boost item for
  Eco-Mode + Curve Optimizer). Detection reuses `doctor`'s exact probes, the checklist gives the
  exact BIOS menu path for the detected board (ASUS/ASRock/Gigabyte/MSI + a generic fallback),
  pending items persist in `rigforge-bios.json` (included in `backup`/`restore`), and the next run
  re-verifies which changes actually took — an item only counts as applied when its OS-visible
  fingerprint flips, and an unverifiable item stays pending with an honest note. RigForge never
  writes BIOS itself.

### Fixed

- **Sister API re-architected so polling cannot shave hashrate (#164).** The release gate caught
  the v1.2.x per-connection design (systemd `Accept=yes` — the inetd model) costing 3-5% hashrate
  under worst-case polling on a 16-thread rig: every request paid a full process lifecycle (unit +
  cgroup + a 3,600-line bash parse + ~15 jq spawns), and four fix iterations (priorities, quotas,
  caching, pacing) proved no scheduler knob fixes a per-request-process architecture. It now works
  the way XMRig's own API does: a systemd timer runs the probe pass every 15s at idle priority and
  writes the response bodies atomically (the node_exporter textfile-collector pattern), and one
  tiny persistent server (python3 stdlib, ~80 lines, sandboxed, fail-closed on an unreadable
  config) ships those bytes — a request costs microseconds, on any rig, at any polling rate.
  Responses are at most ~15s stale, within the resolution of XMRig's own 10s hashrate window. The
  wire contract is unchanged (same routes, token rule, headers, key sets — the contract tests
  didn't move); upgrades remove the old socket units automatically. The `api-impact` gate phase
  now also bounds `/health` latency under full mining load (`E2E_API_LATENCY_S`).

## [1.2.1] - 2026-07-10

### Fixed

- **Sister API responsiveness under full mining load.** The per-request handler ran at `Nice=19` +
  `IOSchedulingClass=idle` (SCHED_IDLE-like) — on a rig where XMRig pins every core, that meant it
  was never scheduled, so a `/health` request took ~51s on a loaded 96-core EPYC. Relaxed to
  `Nice=10` (still yields to the miner — hashrate is unaffected, verified on the production fleet).
  The `e2e-pithead` `api-impact` phase now also bounds response latency under load, not just the
  hashrate hit — the half the original gate missed by running on a rig with spare cores.

## [1.2.0] - 2026-07-10

### Added

- **Sister API (#99).** Opt-in (`"api": "enabled"`) read-only stats superset on its own port
  (default `:8081`): XMRig's `/1/summary`+`/2/summary` passed through verbatim plus a namespaced
  `rigforge` object — applied tune knobs and the last tune run, RAPL watts and hashrate-per-watt,
  the doctor probes as JSON, and pinned version provenance — plus bare `/health` and `/tune`.
  Socket-activated (no resident process, no new dependencies), same `ACCESS_TOKEN` posture as
  `:8080`, sandboxed read-only handler running at idle CPU priority so it cannot shave hashrate.
- **Stratum password at first run (#113).** The interactive setup now asks for the stack's stratum
  password (Enter skips it); the docs gain the rotation runbook. Pairs with Pithead's opt-in
  `p2pool.stratum_password`.
- **`pools[].tls-fingerprint` (#115).** Pin the stratum server's certificate by its SHA-256.
  Verified against the pinned XMRig: without a pin, stratum TLS does **no** server authentication —
  the docs now state the trust model plainly, and a pin without `"tls": true` is a hard error.
- **Worker↔stack release gate (#114).** `make e2e-pithead` drives a real provisioned worker against
  a live Pithead stack: mining round-trip, the `:8080` contract, stratum auth accept/reject/rotation,
  dashboard visibility, dev-fee vs the compiled `donate.h` floor, and the sister-API
  hashrate-impact guard.
- **Standardized performance testing.** `e2e-real` gains a `perf` phase comparing the offline bench
  against a committed per-host baseline (`tests/perf-baselines/`); `e2e-pithead`'s `api-impact`
  phase owns the relative under-load measurement. A perf regression fails the release gate.
- **doctor: read-only API posture check (#135).** Warns when the live config no longer pins
  `http.restricted: true`.
- **Developer tooling.** `make dev-setup` (one-command local toolchain + git hooks), `make ci`
  (the full local CI mirror), actionlint in CI (workflow correctness beside zizmor's security
  audit), and commit-time markdown/yaml linting in pre-commit — all pinned, all single-sourced
  through the Makefile.

### Fixed

- **Bootstrap `config.json` permissions (#131).** The interactively created config is `chmod 600`
  from the moment it exists — previously it sat world-readable (with the wallet the operator is
  told to paste in) until the first `apply`.
- **`SERVICE_NAME` override (#133).** `install_service` installed/enabled/started a hardcoded
  `xmrig.service` regardless of the documented override, leaving a unit `uninstall` couldn't manage.
- **GRUB cmdline corruption (#134).** Kernel parameters containing `&`, `\`, or `|` now survive the
  `/etc/default/grub` rewrite (sed-replacement escaping in both `tune` and `uninstall`).
- **Robustness sweep (#135).** `warn`/`error` print to stderr; the tune cleanup trap is armed at
  temp-dir creation (no leak on live-mode aborts); a deny-list stops catastrophic `HOME_DIR` values
  (`/`, `/etc`, bare `/home`) before any `sudo rm -rf`; `awk -v` everywhere; lint file list derived
  from `git ls-files`.

### Documentation

- SECURITY.md, README and operations no longer claim the `:8080` API is token-gated by default
  (stale since v1.1.0); SECURITY.md documents the `:8081` posture (#132, #99).
- README states the licensing split (RigForge MIT, XMRig GPLv3 compiled from source on your
  machine) and whose wallet the donation address is (#136).
- `DONATION` docs now state that lowering it below the compiled `donate.h` floor requires a
  rebuild — XMRig clamps and autosaves the clamped value, so `apply` alone cannot lower it
  (caught by the first live `e2e-pithead` run).

## [1.1.0] - 2026-07-01

### Added

- **Supply-chain & secret-scanning CI gates (#117).** Three cross-cutting hardening gates on top of
  the existing SHA-pinned actions and commit-verified XMRig build:
  - **gitleaks** — a new `Security` workflow scans the full git history for committed secrets (pool
    credentials, tokens, the stratum access-password) on every push and PR, plus a matching
    [`.pre-commit-config.yaml`](./.pre-commit-config.yaml) hook so a leak is caught before it's pushed.
    The binary is version- and checksum-pinned, like the existing shellcheck/shfmt installs.
  - **Dependabot** ([`.github/dependabot.yml`](./.github/dependabot.yml)) — keeps the hand-pinned
    GitHub Actions current (`github-actions` ecosystem only; RigForge has no pip/npm/docker deps) and
    surfaces action security advisories.
  - **zizmor** — static-audits the workflows for template injection, over-broad `GITHUB_TOKEN`, and
    credential persistence, and (online) cross-references the actions we pin against the GitHub
    Advisory Database. Runs on push/PR plus a weekly schedule, so a CVE disclosed against a pinned
    action trips the gate even with no open PRs. Hardened the existing `ci.yml`/`release.yml` to a
    read-only default token and `persist-credentials: false` on checkout to make the audit clean.
- **DX glue + config/docs lint (#118).** Rounds out the non-shell tooling around the existing
  shellcheck/shfmt + kcov core:
  - **`.editorconfig`** — encodes the whitespace house style (`shfmt -i 4`, LF, final newline) so
    editors match CI without per-editor setup.
  - **pre-commit** — `.pre-commit-config.yaml` now orchestrates `make lint` (shellcheck/shfmt via the
    Makefile's `SHELL_FILES`, no duplicated list), the existing gitleaks hook, and freebie hygiene
    hooks (private-key detection, large-file guard, end-of-file + trailing-whitespace fixers).
  - **yamllint + markdownlint** — new CI gates (and `make lint-yaml` / `make lint-md`) over the
    workflows/configs and the docs, each with a tuned config (`.yamllint`, `.markdownlint-cli2.yaml`).
  - **lychee** — a link-checker (`make lint-links`) that runs on a weekly schedule rather than per-PR,
    since external links are flaky-by-nature.
- **Contributing: inbound contributions are MIT-licensed (#119).** `CONTRIBUTING.md` now states that
  contributions are licensed under the project's MIT License — a lightweight alternative to a CLA.

### Changed

- **Worker HTTP API is now OPEN (read-only) by default.** `ACCESS_TOKEN` no longer defaults to the rig
  name; left unset, the rig's `:8080` API is served `restricted` (read-only) with **no token** — which
  matches Pithead's new default no-auth stats probe, so a stock rig needs zero token coordination. Set
  `ACCESS_TOKEN` to require a `Bearer` token (then match it on the dashboard with `workers.api_auth:
  token`/`name`). Pairs with pithead [#171](https://github.com/p2pool-starter-stack/pithead/issues/171)
  / [#172](https://github.com/p2pool-starter-stack/pithead/issues/172).

### Fixed

- **Live tuning works with the new open API default.** Every live-hashrate read — `autotune` and its
  monthly timer, `tune --live`, `tune --confirm`, and the `upgrade` re-tune — always sent an
  `Authorization: Bearer` header. Once the API defaulted to open with no token, that empty Bearer drew a
  `401`, and under `set -e` the failed `curl -f` aborted the read, silently breaking live tuning on a
  stock config. The header is now sent only when `ACCESS_TOKEN` is set. The dependency-free suite stubs
  the API, so this surfaced only on the real-hardware release gate — which now sends its warmup probe the
  same way.

## [1.0.1] - 2026-06-13

### Fixed

- **HugePage sizing is now NUMA-aware (1 GB pages) (#111).** RandomX fast mode keeps a NUMA-local copy of the
  ~2080 MB dataset **per NUMA node**, but the reservation math multiplied the per-dataset 1 GB pages by the
  **socket** count, not the NUMA-node count. On a single-socket, multi-NUMA CPU — e.g. an EPYC 7642 with 4
  NUMA nodes — `setup` reserved 3× 1 GB instead of 12×, so after a reboot three of four nodes lost 1 GB
  backing and hashrate dropped hard. Sizing now scales the 1 GB reservation (and the pure-2 MB fallback)
  by NUMA nodes, detected via `lscpu` then `/sys/devices/system/node`, falling back to the socket count.
  2 MB scratchpad sizing is per-thread total and unaffected. Verified on a 4-NUMA EPYC (now reserves 12).

## [1.0.0] - 2026-06-13

First stable release. RigForge turns a fresh Ubuntu/Debian (or macOS) machine into a fully tuned
[XMRig](https://github.com/xmrig/xmrig) mining worker in **one command** — it compiles stock, upstream
XMRig from a pinned, commit-verified source, applies kernel- and CPU-level tuning for maximum RandomX
hashrate, and runs it as a managed service. Point it at any RandomX Stratum pool and walk away.
MIT-licensed, and validated end to end on a real Ryzen 7800X3D rig.

### What you get

- **One-command setup.** `sudo ./rigforge.sh` installs the build toolchain, compiles XMRig, tunes the
  kernel and CPU, writes a config from your pool URL, and starts a managed service. Idempotent and
  safe to re-run.
- **Real, measured gains.** Mining live on a Ryzen 7800X3D: **+3.5% hashrate and +7.6% efficiency** over
  stock XMRig — faster *and* cooler, because HugePages stop the CPU stalling on memory. On a 48-core EPYC
  the gap is **+6.6%**, where the per-CPU live tune also dodged a prefetch setting that *halves* RandomX
  on that chip. Method and honest caveats in [Benchmarks](docs/benchmarks.md).
- **Tuned for your CPU.** Builds on XMRig's cache-aware auto-detection (threads, asm, MSR, NUMA) with
  dedicated-miner defaults; `tune` then searches the fastest knobs for your exact silicon, and opt-in
  `autotune` keeps it dialed in on a monthly, hands-off schedule.
- **Simple to run.** `doctor` (one-stop health check), `status` / `logs` / `start` / `stop` / `restart`,
  `apply` (apply a config edit, no rebuild), `upgrade` (rebuild when the XMRig pin moves), and
  `backup` / `restore`.
- **Any RandomX pool** — solo, P2Pool, or a public pool like SupportXMR — and it's the companion miner
  for [Pithead](https://github.com/p2pool-starter-stack/pithead) if you run a stack.

### What it does to your machine — and how to undo it

RigForge runs as **root**, so here is exactly what you are getting into:

- **It is not a custom miner.** It builds *stock* upstream XMRig at a pinned commit that is verified
  against a hardcoded hash before it compiles — the same binary you would build yourself, minus the
  fiddly setup.
- **No telemetry, ever.** The only outbound traffic is your pool, that XMRig clone from GitHub, and your
  distro's package mirrors. No analytics, no version ping, no beacon.
- **Honest 1% dev fee.** XMRig's donation is left at its **1% upstream default** and goes to the XMRig
  project — RigForge substitutes no wallet of its own into the mining path. Set `"DONATION": 0` to turn
  it off entirely.
- **System changes, all reversible.** A `systemd` service, GRUB HugePage kernel parameters (one
  **reboot** required on Linux), MSR module access, `fstab` / `limits` entries, a `cpupower` performance
  governor, and a **read-only, token-gated stats API on `:8080`** that binds the LAN for the Pithead
  dashboard — firewall it off if you mine solo (see [SECURITY.md](SECURITY.md)). `uninstall` reverts
  every one of these and keeps your `config.json`.

### Platforms

Ubuntu 22.04+ / Debian 12 is the supported target; other apt/dnf/pacman distros work as a courtesy.
macOS is supported for development and light use — it builds and configures, but does no kernel tuning
and installs no service.

### Get started

```bash
git clone https://github.com/p2pool-starter-stack/rigforge.git
cd rigforge && chmod +x rigforge.sh
sudo ./rigforge.sh
```

The full walkthrough — prerequisites, the Linux reboot, and verification — is in
[Getting Started](docs/getting-started.md).

<details>
<summary><strong>Full 1.0.0 feature list</strong> — every capability and hardening that went into this release</summary>

#### Added

- **Privacy & security, documented up front (#109).** A new README "Privacy & security" section and a
  SECURITY.md "What RigForge exposes (and what it doesn't)" section state it plainly: **no telemetry** (the
  only outbound traffic is your pool, the commit-verified XMRig clone, and your distro's package mirrors);
  an **honest 1% dev fee** that is XMRig's own upstream default and is turned off with `"DONATION": 0`; and
  a **read-only, token-gated stats API** on `:8080` that binds the LAN for the Pithead dashboard — with the
  exact `ufw` commands to firewall it off when you don't run Pithead.
- **Release gate covers the live auto-tune engine, the periodic-tune timer, and every verb alias (#110).**
  The real-hardware gate (`tests/e2e-real.sh`) now drives `autotune` — the live prefetch sweep the monthly
  timer runs — against the running miner, asserts the autotune **timer install and teardown**, and
  exercises the `up`/`down`, `-v`/`--version`, `-h`/`--help` aliases, closing the gaps where the gate
  claimed "every verb" but skipped these.
- **Docs: benchmarks — measured stock-vs-tuned results on two CPUs.** A new [Benchmarks](docs/benchmarks.md)
  page (and a README highlight) reports hashrate **and** efficiency (H/s per watt) for stock XMRig vs.
  RigForge, measured **mining live** on a desktop **Ryzen 7800X3D** (+3.5% H/s, +7.6% efficiency) and a
  48-core **EPYC 7642** (+6.6% / +6.0%). On the EPYC RigForge also **matched an operator's hand-tuned
  config** and the per-CPU live tune **avoided a landmine** — prefetch mode 2 *halves* RandomX on the EPYC
  but *wins* on the X3D, which a fixed profile would get wrong. Honest caveats included (Transparent
  HugePages narrow the stock gap on modern kernels; efficiency and performance tuning converge because
  RandomX power is ~flat across configs on both chips). No code change.
- **`tune --now --short` / `--long` — pick the depth of an on-demand live re-tune.** `tune --now` (now
  also spelled `--short`) stays the quick prefetch-only pass the scheduled timer runs; `tune --now --long`
  runs the **full all-knob** live sweep (prefetch, `cpu.yield`, thread count, 1G-pages) against the running
  miner — the same search as `tune --live`, which remains as an alias. This gives one mental model for
  on-demand tuning: `tune --now` with a `--short`/`--long` depth, instead of remembering `--now` vs
  `--live`. (Offline `tune` / `tune --bench` is unchanged — fastest and cleanest, but rx/0 only; the live
  `--long` is the one to use when you mine a non-Monero RandomX variant whose algorithm `--bench` can't
  measure.)
- **Docs: connecting to a public pool (SupportXMR, etc.).** [Configuration › Pools](docs/configuration.md#connecting-to-a-public-pool-supportxmr-etc)
  now has two side-by-side, copy-paste recipes — a Pithead stack vs. a public pool — so it's obvious what
  to put where. The public-pool one spells out the one thing that trips people up: your **Monero wallet
  goes in `pools[].user`** (the pool pays whoever logs in), plus a worker name in `pass` and the pool's
  **TLS port** with `"tls": true`. Discoverability links added from the README, the docs index, Getting
  Started, and the FAQ; the pool-field reference is no longer framed as Pithead-only. No code change.
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
- **Periodic `autotune` target — `disabled` / `performance` / `efficiency` (#95).** The hands-off
  auto-tuner is now a single tri-state `autotune` key (advanced config only; **default `"disabled"`**).
  `"performance"` schedules a live tune for raw hashrate; `"efficiency"` schedules one for
  **hashrate-per-watt** — sampling watts over the same live window and ranking by H/s/W, extending the
  `tune --efficiency` target (#79) to the scheduled run. The target is baked into the systemd unit at setup
  so timer-driven runs optimize for what you chose; with no power source it falls back to `performance` and
  warns. `tune --history` shows the active target, and `apply` **reconciles the installed timer with
  config** (so changing the `autotune` target and running `apply` actually takes effect, not just shows the
  new value) and prints it. Legacy booleans still parse (`true` → `performance`,
  `false` → `disabled`); an unknown value hard-errors rather than silently disabling tuning.
  - **Re-tuning is event-driven.** Once the prefetch mode converges it's stable, so re-tuning happens when
    it actually matters: **`upgrade` re-tunes the new build** (the fastest knobs can shift between XMRig
    versions) once the rebuilt miner is live. The safety-net timer's default cadence is **monthly** — it
    only catches slow drift, so it doesn't churn the miner nightly to re-confirm a stable result. Override
    with `AUTOTUNE_ONCALENDAR`.
  - **Manual `tune` follows the same target.** A plain `tune` (or `tune --live`) now defaults its
    optimization target to the `autotune` config value, so "efficiency" means efficiency everywhere instead
    of the manual command silently optimizing raw hashrate. Override per-run with `--perf`/`--efficiency`.
    `tune` now **announces the target** at the start (`Optimization target: …`) and, run without `sudo`,
    **re-runs itself with `sudo`** (interactive only) instead of failing partway.
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
  Opt-in periodic live tuning via the `autotune` config key installs a systemd timer that runs `autotune`
  against the running miner, keeping a change only when it beats the baseline by a margin (else it rolls
  back).
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

#### Changed

- **Live auto-tuning converges in one run.** Each `autotune` run **live-sweeps every prefetch mode**
  against the running miner and adopts the fastest (median measurement + a margin gate, else it keeps the
  current mode), converging in a single ~minutes-long pass. The safety-net timer fires **monthly** by
  default to catch slow drift; `AUTOTUNE_ONCALENDAR` changes the cadence and `AUTOTUNE_MODES` the modes
  swept. For a definitive all-knob sweep, run `tune`.
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

#### Fixed

- **`setup` re-run now applies your `config.json` edits (#109).** On a no-rebuild re-run, the regenerated
  config was written to the worker root instead of the build directory the service loads
  (`--config=$BUILD_DIR/config.json`), so an edit-then-`setup` silently kept mining the old config. setup
  now writes it where the service reads it, matching `apply` and the rebuild path.
- **A missing or failing `cpupower` can no longer wedge the miner (#109).** The performance-governor
  `ExecStartPre` is now best-effort (leading `-`); on VMs/cloud kernels with no active cpufreq driver — or
  distros that ship no `cpupower` — a failed governor-set no longer aborts startup into a `Restart=always`
  loop.
- **The first-run prompt validates the pool host before writing (#109).** A host-less URL like `:3333`
  used to pass the port check, get written, then fail `parse_config` — leaving a broken `config.json` that
  suppressed the prompt on the re-run. It's now rejected before anything is written.
- **The generated live config is written owner-only (`0600`) (#109).** It holds the pool/wallet and the
  HTTP API token, so a root `jq` redirect no longer leaves it world-readable.
- **`tune` no longer spuriously aborts mid-benchmark (and read 0 H/s).** `xmrig --bench` exits on its own
  when the benchmark finishes, so an unguarded `kill` of the (already-gone) process returned non-zero and,
  under `set -Eeuo pipefail`, fired the ERR trap **inside** the measurement subshell — aborting it before
  it returned the result. The symptom was a burst of `rigforge aborted while starting up (exit 1)` lines
  (one per `TUNE_ITERS` benchmark) and `measured 0 H/s` candidates. The kill is now guarded, so the result
  survives whether or not xmrig is still alive. A timing race, which is why it surfaced only on some hosts.
- **`doctor` no longer says "apply the items below" when there's nothing to apply.** The firmware/BIOS
  context line always promised "apply the items below in BIOS/UEFI", even when no XMP/EXPO or SMT
  recommendation followed (RAM already at its rated speed, SMT on). It now works out the recommendations
  first and says "no BIOS changes recommended" when everything's already optimal.
- **`setup` no longer prints a garbled CPU model.** Run as root, modern `lscpu` also emits a DMI-derived
  `BIOS Model name:` line (e.g. `…  Unknown CPU @ 4.2GHz`), and the unanchored `grep "Model name"`
  concatenated both — so every `setup` logged `Detected CPU: <model> <model> Unknown CPU @ 4.2GHz`.
  The model parse (and `doctor`'s) now anchor to `^Model name:`, showing just the clean model.
- **The periodic auto-tune no longer re-owns your files to root.** The `autotune` systemd timer runs as
  root with no `SUDO_USER`, so its post-run re-own was handing `data/worker` + `config.json` back to
  `root:root` on each run — undoing the operator-ownership fix and forcing `sudo` to edit `config.json`.
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

</details>

[Unreleased]: https://github.com/p2pool-starter-stack/rigforge/compare/v1.4.0...main
[1.4.0]: https://github.com/p2pool-starter-stack/rigforge/releases/tag/v1.4.0
[1.3.0]: https://github.com/p2pool-starter-stack/rigforge/releases/tag/v1.3.0
[1.2.1]: https://github.com/p2pool-starter-stack/rigforge/releases/tag/v1.2.1
[1.2.0]: https://github.com/p2pool-starter-stack/rigforge/releases/tag/v1.2.0
[1.1.0]: https://github.com/p2pool-starter-stack/rigforge/releases/tag/v1.1.0
[1.0.1]: https://github.com/p2pool-starter-stack/rigforge/releases/tag/v1.0.1
[1.0.0]: https://github.com/p2pool-starter-stack/rigforge/releases/tag/v1.0.0
