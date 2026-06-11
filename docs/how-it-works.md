# How It Works

RigForge is **not a custom miner**. It compiles stock, upstream [XMRig](https://github.com/xmrig/xmrig)
and wraps it in the setup, hardware tuning, and service management that are otherwise fiddly to get
right by hand. This page explains what the script actually does, step by step — the RandomX analogue of
an architecture doc.

---

## The setup pipeline

A `setup` run executes these stages in order. Each is idempotent, so re-running skips work that's
already done.

1. **Prerequisites** — detects the OS (Linux vs. macOS) and installs `jq` if it's missing. Privileged
   steps use `sudo` as needed, so run the script with `sudo` (or as root).
2. **Config** — creates a minimal `config.json` interactively if none exists, then parses and validates
   it (see [Configuration](configuration.md)).
3. **Rebuild decision** — figures out whether XMRig actually needs (re)building, based on the pinned
   version/commit vs. what's already compiled.
4. **Workspace** — prepares the worker root; any prior install is **archived, not clobbered**, and old
   archives are pruned so re-runs don't leak disk.
5. **Dependencies** — installs the build toolchain and runtime libraries for the OS (`cmake`, `libuv`,
   `hwloc`, OpenSSL, …).
6. **Compile** — clones XMRig at the pinned commit, patches the donate level, and builds it. Output is
   captured to a logfile; `make -j` is capped by available RAM to avoid OOM on low-memory hosts.
7. **Generate config** — detects the CPU and writes the tuned XMRig `config.json` (pools, donate level,
   HTTP API, and the per-CPU `cpu`/`randomx` sections).
8. **Kernel tuning (Linux)** — HugePages, MSR, and module loading.
9. **Limits (Linux)** — `hugetlbfs` mounts, `fstab`, and memlock limits.
10. **Service (Linux)** — installs and enables the `xmrig` systemd unit with a performance governor and
    log rotation.
11. **Finish** — prints next steps (and, if the kernel was tuned, the reboot prompt).

---

## Compile from source, pinned

RigForge builds XMRig from source rather than shipping a binary:

- **Pinned** to a known `XMRIG_VERSION` / `XMRIG_COMMIT`, and the checkout is **verified against the
  pinned commit** (`git rev-parse HEAD` must match `XMRIG_COMMIT`, or the build aborts) — so every
  worker runs the same audited source, and supply-chain risk is bounded.
- **Donate level patched at build time.** The configured `DONATION` is `sed`'d into `donate.h` so the
  compiled binary honors it (XMRig's floor is otherwise 1%). It's also written into the runtime config.
  Because this patch happens during the compile, changing `DONATION` after XMRig is already built only
  updates the runtime config — re-patching the binary requires a rebuild (see
  [Configuration](configuration.md#changing-settings-later)).
- **Memory-guarded parallelism.** `make -j` is capped based on available RAM, so the build doesn't OOM
  on small machines.
- **Idempotent.** If the pinned build already exists, setup skips the (slow) recompile entirely; the
  [`upgrade`](operations.md#upgrading-xmrig) command rebuilds only when the pin changes.

---

## Hardware tuning

The hashrate win comes from configuration, not the silicon alone. RigForge leans on XMRig's own
auto-detection and adds dedicated-miner defaults:

- **Auto-detected thread count, ASM path, MSR preset and NUMA** — XMRig reads the CPU topology and
  sizes everything to it (`cpu.rx: -1`, `cpu.asm: auto`, `randomx.wrmsr: true`, `randomx.numa: true`),
  which stays correct for CPUs a model-name table would miss. See
  [Hardware › How RigForge tunes](hardware.md#how-rigforge-tunes).
- **Dedicated-miner defaults** — `cpu.yield: false` (busy-wait for max hashrate) and `cpu.priority: 2`.
- **RandomX fast mode** — the full 2 GB dataset in memory for maximum hashrate.
- **Thread layout sized to L3** — RandomX wants ~2 MB of L3 per thread; XMRig sizes threads to the
  detected L3 rather than blindly using every core.

---

## Measured tuning: the `tune` search

The defaults above are good, but a handful of knobs have a best value that genuinely varies per CPU: the
RandomX prefetch mode, `cpu.yield`, the **thread count and placement** (`cpu.rx`), `1gb-pages`, and — opt
in — `cpu.huge-pages-jit` and `randomx.cache_qos`. The `tune` command **measures** rather than guesses.
By default it's an iterative, noise-aware **coordinate hill-climb**:

1. **Seed.** Start from two candidate configurations — XMRig's auto baseline and an educated guess — so
   the search can escape a local optimum one seed happens to land in.
2. **Climb.** Sweep one knob at a time; for each, benchmark its candidate values (holding the others
   fixed) and adopt the best — but only if it beats the current best by a minimum relative margin, so
   benchmark noise can't masquerade as a win.
3. **Repeat until plateau.** Run passes over all knobs until a full pass yields no improvement, or a
   round cap is hit.

For a small knob space where you'd rather not risk a local optimum at all, `TUNE_SEARCH=grid` switches to
an **exhaustive** search of every combination — slower, but guaranteed to find the global best.

The thread search is **SMT-aware**: rather than only nudging ±1 around the L3 ÷ 2 MB estimate, it also
tries XMRig's own auto value and the **physical-** and **logical-core** counts, because RandomX often
peaks at one thread per physical core (SMT siblings share the L2/L3 each thread needs).

A few design choices keep it honest and cheap on jittery RandomX hardware:

- **Median, not max.** Each candidate is measured as the median of several `xmrig --bench` runs, so one
  lucky spike doesn't crown a worse config.
- **Contention-free.** In `--bench` mode `tune` stops the miner service for the run (restarting it
  after, even if interrupted), so the benchmark isn't fighting a live miner for cores and huge pages —
  the single biggest source of bogus readings.
- **Memoized.** Because a coordinate climb keeps revisiting the current point, every measured
  combination is cached — a combo is never benchmarked twice.

Reboot-bound knobs are handled explicitly: `1gb-pages` only matters once 1G HugePages are reserved (a
GRUB change + reboot), so the search sweeps it only when they're actually present and otherwise skips it
with a note. The winning knobs are written to a separate overlay file (`tune-overrides.json`) that's
merged into the generated config — your `config.json` is never edited.

### Tuning environment variables

Every part of the search is overridable; the defaults favour a thorough one-time run.

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
| `TUNE_TARGET` | `perf` | Optimize for `perf` (raw H/s) or `efficiency` (hashrate-per-watt). Same as `tune --efficiency`; efficiency needs a power source or falls back to `perf`. |
| `TUNE_TEMP_CMD` | _(Linux thermal zone)_ | Optional shell command that echoes °C; defaults to `/sys/class/thermal/thermal_zone0/temp`. |

### Power & efficiency

RandomX hashrate isn't free, so `tune` records **watts per candidate** and can rank by **hashrate-per-watt**.
On Linux it reads the CPU-package energy counter (RAPL) automatically — no configuration, run as root.
Watts are sampled **under load and averaged over the measurement window**, so the figure reflects real
mining power. `tune --efficiency` (or `TUNE_TARGET=efficiency`) then picks the most efficient config rather
than the raw-fastest — useful for a power-cost or heat/PSU-constrained rig; without a power source it warns
and falls back to `perf`. To measure whole-system wall power instead of the CPU package alone, point
`TUNE_POWER_CMD` at a source that echoes instantaneous watts.

The **periodic `autotune`** takes the same target: set `"autotune": "efficiency"` in `config.json` and the
nightly run ranks prefetch modes by hashrate-per-watt (sampling watts over the same live window), instead
of `"performance"`'s raw H/s. The target is baked into the systemd unit at setup; same RAPL/`TUNE_POWER_CMD`
sources and the same fall-back-to-`perf`-with-a-warning behavior apply. See
[Operations → Live auto-tuning](operations.md#live-auto-tuning-opt-in).

> **`hs_per_watt` is relative, not absolute.** It only compares candidates measured by the **same method on
> the same machine**. Built-in RAPL counts the **CPU package only** (not RAM, board, PSU loss); a smart plug
> counts **whole-wall AC**. Don't compare the number across methods or across rigs.

### Reservation-aware thread tuning

RandomX wants its scratchpads backed by **HugePages**. `setup` reserves a pool sized for an estimated thread
count; `tune` then benchmarks thread counts within that reservation. A thread count that needs *more* 2 MB
pages than are reserved still runs — but the extra threads fall back to normal pages, so its benchmark is a
**floor, not a fair reading**. `tune` flags each such candidate `hugepages_capped: true` in
`rigforge-tune.json` and ends with a note listing the capped thread counts. To explore a higher count
*properly*, resize the reservation for it and re-tune:

```bash
sudo RIGFORGE_THREADS=<n> ./rigforge.sh setup   # sizes the HugePages reservation for <n> threads
sudo reboot                                     # the GRUB HugePages change needs a reboot
sudo ./rigforge.sh tune                         # now <n> threads benchmarks with full backing
```

`setup` also reads the **tuned** `cpu.rx` from `tune-overrides.json` automatically, so once you've tuned, a
plain `sudo ./rigforge.sh setup` keeps the reservation matched to your winning thread count.

For how to *run* `tune` — the command, `--live`, `--efficiency`, `--confirm`, `--history`, and `--clear` —
see [Operations › Tuning](operations.md#tuning).

---

## Kernel & system tuning (Linux only)

These are why a **reboot** is needed on Linux:

- **HugePages (1 GB + 2 MB).** Backs the RandomX dataset with huge pages to cut TLB misses — the single
  biggest performance lever. Sizing is topology-aware (see `util/proposed-grub.sh`). Making it
  persistent edits **GRUB**, which takes effect on reboot. RigForge **merges** its parameters into the
  existing `GRUB_CMDLINE_LINUX_DEFAULT` instead of overwriting it, so other kernel params are preserved
  (a boot-safety fix).
- **MSR access.** Loads the `msr` module and sets the hardware-prefetcher / cache model-specific
  registers XMRig recommends for the CPU. (Blocked by Secure Boot — see
  [troubleshooting](operations.md#troubleshooting).)
- **`hugetlbfs` mounts + memlock limits.** Mounts the 1 GB HugePage filesystem and raises `memlock` in
  `fstab` and `limits.conf` so XMRig can pin memory. These edits are applied **once** (append-only,
  deduplicated) so re-runs don't accumulate duplicate lines.

macOS doesn't expose HugePages or MSRs, so those stages are skipped there; the macOS path sets
XMRig accordingly (and there's no systemd service — you run the miner yourself). See
[Operations › Running on macOS](operations.md#running-on-macos).

---

## Service management (Linux)

- **systemd unit.** XMRig runs as the `xmrig` service, enabled at boot, restarting on failure.
- **`cpupower` performance governor.** Pins the CPU to its performance frequency so it isn't throttled
  down mid-hash.
- **Log rotation.** A `logrotate` policy compresses and archives `xmrig.log`.
- **Hardened unit.** The service runs as root (required for the MSR mod and HugePages) but with
  defense-in-depth sandboxing: `NoNewPrivileges`, `ProtectSystem=full` (read-only `/usr`,`/etc`,…),
  `PrivateTmp`, `ProtectControlGroups`, `LockPersonality`, and `ReadWritePaths` limited to the worker
  root. Directives that would break RandomX are deliberately **not** set — `PrivateDevices` (hides
  `/dev/cpu/*/msr`), `MemoryDenyWriteExecute` (blocks the JIT), and `ProtectKernelModules`.
- **Scoped `memlock`.** Unlimited `memlock` is granted to the **service** (`LimitMEMLOCK=infinity`) and,
  for manual runs, to the **mining user only** in `limits.conf` — not to every account via `*`.

---

## Safety & idempotency

RigForge is built to be re-run:

- **Idempotent edits.** System-file changes (`fstab`, `limits.conf`, `/etc/modules`) are append-only
  and deduplicated — running setup twice never doubles a line.
- **Non-destructive workspace.** A prior install is archived, not overwritten.
- **Fail-fast with context.** An `ERR` trap names the step that failed; config input is validated
  before the slow build starts.
- **Tested.** A dependency-free suite fakes all hardware and privileged commands so every supported
  platform's config generation and a full deployment (run twice for idempotency) are asserted on any
  machine; a Docker end-to-end run validates the real Linux path. See the project README's
  testing section.

---

## See also

- [Hardware Requirements](hardware.md) — the tuning knobs and L3 math.
- [Operations & Maintenance](operations.md) — commands, upgrades, and troubleshooting.
- [Configuration](configuration.md) — the keys that drive the generated config.
