# How It Works

RigForge is **not a custom miner**. It compiles stock, upstream [XMRig](https://github.com/xmrig/xmrig)
and wraps it in the setup, hardware tuning, and service management that are otherwise fiddly to get
right by hand. This page explains what the script actually does, step by step — the RandomX analogue of
an architecture doc.

---

## The setup pipeline

A `setup` run executes these stages in order. Each is idempotent, so re-running skips work that's
already done.

1. **Prerequisites** — checks it's running as root and detects the OS (Linux vs. macOS).
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

- **Pinned** to a known `XMRIG_VERSION` / `XMRIG_COMMIT`, with the source checksum verified — so every
  worker runs the same audited build, and supply-chain risk is bounded.
- **Donate level patched at build time.** The configured `DONATION` is `sed`'d into `donate.h` so the
  compiled binary honors it (XMRig's floor is otherwise 1%). It's also written into the runtime config.
- **Memory-guarded parallelism.** `make -j` is capped based on available RAM, so the build doesn't OOM
  on small machines.
- **Idempotent.** If the pinned build already exists, setup skips the (slow) recompile entirely; the
  [`upgrade`](operations.md#upgrading-xmrig) command rebuilds only when the pin changes.

---

## Hardware tuning

The hashrate win comes from configuration, not the silicon alone. RigForge detects the CPU and applies:

- **A per-CPU profile** — assembly path, thread count, priorities, and NUMA binding tailored to the
  CPU family (AMD EPYC, Ryzen X3D, generic x86, macOS). See
  [Hardware › Per-CPU profiles](hardware.md#per-cpu-tuning-profiles).
- **RandomX fast mode** — the full 2 GB dataset in memory for maximum hashrate.
- **Thread layout sized to L3** — RandomX wants ~2 MB of L3 per thread; the profile sizes threads
  accordingly rather than blindly using every core.

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

macOS doesn't expose HugePages or MSRs, so those stages are skipped there; the macOS profile sets
XMRig accordingly.

---

## Service management (Linux)

- **systemd unit.** XMRig runs as the `xmrig` service, enabled at boot, restarting on failure.
- **`cpupower` performance governor.** Pins the CPU to its performance frequency so it isn't throttled
  down mid-hash.
- **Log rotation.** A `logrotate` policy compresses and archives `xmrig.log`.

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

- [Hardware Requirements](hardware.md) — the per-CPU profiles and L3 math.
- [Operations & Maintenance](operations.md) — commands, upgrades, and troubleshooting.
- [Configuration](configuration.md) — the keys that drive the generated config.
