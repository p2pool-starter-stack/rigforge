# RigForge tests

RigForge is one self-contained script, so its tests are layered by how much they exercise for
real, from a dependency-free suite that runs anywhere up to a real-hardware gate that actually
compiles XMRig and mines. Each layer covers what the one below it has to stub.

> The split exists so CI proves everything it can on a GitHub runner, while the things a runner
> physically can't do (compile XMRig, reserve HugePages, write MSRs, set the governor, hash) are
> proven once, by hand, on a real rig before tagging a release.

## The layers

| Layer | File | Runs | What it proves | How to run |
|---|---|---|---|---|
| **Unit + black-box suite** | [`run.sh`](run.sh) | Any host (macOS/Linux), no Docker. **In CI.** | Config parsing, the XMRig-config generation matrix (every CPU/OS profile, simulated via PATH stubs), GRUB/HugePages math, the command surface, tune search, doctor: everything that doesn't need a real `/etc` or real hardware. The bulk of coverage. | `make test` (lint + suite) or `bash tests/run.sh` |
| **Linux container e2e** | [`e2e/linux.sh`](e2e/linux.sh) → [`e2e/in-container.sh`](e2e/in-container.sh) | Disposable Ubuntu container, **needs Docker**. **In CI.** | The genuine Linux deploy path against a real (throwaway) `/etc` with real GNU tools (`sed -i`, `tee`, `envsubst`) + idempotency on re-run. Only the heavy/privileged bits (compile, package install, `systemctl`/`mount`) are stubbed. | `make test-e2e` |
| **Native macOS e2e** | [`e2e/macos.sh`](e2e/macos.sh) | A real Mac, **CI-only** (runs as a step in the macOS job). | The macOS deploy path with genuine BSD tools the Linux CI can only stub: BSD `sed`, the macOS config profile, `mac_*` process control (real `nohup` + PID file), the launchd login agent, `backup`/`restore`. | `make test-e2e-macos` |
| **Coverage gate** | [`coverage.sh`](coverage.sh) | kcov in **Docker**. **In CI.** | Line coverage of `rigforge.sh` + `util/` by running `run.sh` under kcov; enforces the committed floor ([`coverage-floor.txt`](coverage-floor.txt)) plus a patch-coverage gate (diff-cover) on changed lines. | `make coverage` |
| **Release smoke (quick)** | [`smoke.sh`](smoke.sh) | Real Linux rig, **manual**. Not in CI. | The compiled binary actually starts and hashes (`xmrig --bench`, fully offline). Fast pre-tag confidence that the worker we ship runs. | `make smoke` |
| **Release e2e (full)** | [`e2e-real.sh`](e2e-real.sh) | Real Linux rig, **manual, root**. Not in CI. | The real thing end to end: build + tune + kernel tuning + service + a real hash, then a clean uninstall. **The release gate.** | `make e2e-real` (see [`RELEASING.md`](../RELEASING.md)) |
| **Release e2e (worker↔stack)** | [`e2e-pithead.sh`](e2e-pithead.sh) | Real rig + a **live Pithead stack**, **manual, root**. Not in CI. | The integration contract: mining round-trip against the stack, the `:8080` API posture (open/token/`restricted`), stratum auth accept/reject + rotation, dashboard visibility/drop-off, dev-fee independence, and the sister-API **hashrate-impact guard** (#99 must not shave H/s under polling load). | `PITHEAD_URL=host:3333 sudo -E make e2e-pithead` (see [`RELEASING.md`](../RELEASING.md)) |

The first four run automatically on every push/PR (see [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)).
The last two are deliberately kept out of CI, because a real build, HugePages, and live mining are
flaky by nature and against GitHub Actions' ToS. They're a manual pre-tag gate the releaser runs.

## Where does my test go?

- New logic, config-gen behaviour, a CPU/OS profile, or command behaviour → [`run.sh`](run.sh).
  It's the default home for almost everything; hardware and OS are simulated with PATH stubs, so it
  stays hardware-independent and runs the same on any machine.
- A new real-`/etc` system effect (fstab, memlock limits, an MSR/modules edit, a mount) → assert it
  in [`e2e/in-container.sh`](e2e/in-container.sh), which runs against a throwaway filesystem.
- macOS-specific behaviour (BSD tools, launchd, the mac process control) → [`e2e/macos.sh`](e2e/macos.sh).
- Something only provable on real hardware (it actually hashes, MSRs really applied, HugePages
  really reserved) → [`e2e-real.sh`](e2e-real.sh).

## Conventions

- `run.sh` is dependency-free: no bats, no frameworks. Tiny `assert_*` helpers, and every external
  or privileged command is faked in a stub dir placed first on `PATH`. Keep it that way: a contributor
  must be able to run `bash tests/run.sh` on a stock machine.
- It's hardware-independent on purpose: all hardware-probe env hooks are pointed at non-existent
  paths up top, so the same run exercises EPYC / Ryzen-X3D / macOS inputs back to back and gives the
  same result on any host. Don't read real `/sys` or `/proc`; drive behaviour through the stubs.
- The suite must pass under both modern bash and Apple's bash 3.2 (CI runs `/bin/bash tests/run.sh`
  on macOS); avoid bash-4-only syntax.
- Lint everything: `make lint` (shellcheck + shfmt). The file list lives in the Makefile's
  `SHELL_FILES` so CI and local stay in sync — add new `tests/*.sh` there.

## Performance testing (standardized)

Three standardized measurements, each owned by exactly one layer, so a release can't regress
performance unnoticed:

| Measurement | Where | Standard | Knobs |
|---|---|---|---|
| **Absolute hashrate** | `e2e-real.sh` `perf` phase (runs inside `all`) | Offline `xmrig --bench=1M` on the idle machine, compared against the **committed per-host baseline** in [`perf-baselines/`](perf-baselines/). No baseline → the phase reports the measurement and how to record one. | `E2E_PERF_TOLERANCE_PCT` (default 5); `E2E_PERF_RECORD=1` writes/updates the baseline — commit the file. |
| **Hashrate under API load** | `e2e-pithead.sh` `api-impact` phase | Live 10s-window hashrate, 6×5s samples, baseline vs 4 clients hammering the sister API back-to-back. The handler unit's `Nice=19`/`IOSchedulingClass=idle` is the mechanism; this proves it. | `E2E_API_IMPACT_TOLERANCE_PCT` (default 3). |
| **Tune improvement** | `e2e-real.sh` `verify` phase (existing) | The short real tune must produce a winner that beats or ties the baseline candidate (#62–#64 machinery: sustained-clock sampling, variance-aware acceptance, live A/B confirm). | `TUNE_BENCH`, `TUNE_ITERS` (see the phase comments). |

Baselines are per-host on purpose: hashrate is hardware. When a rig's hardware or BIOS tuning
changes deliberately, re-record its baseline in the same PR that documents the change.
