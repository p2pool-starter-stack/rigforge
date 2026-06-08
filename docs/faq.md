# FAQ

Common questions about what RigForge is, what it does for you, and how it compares to setting XMRig up
by hand. New here? Start with [Getting Started](getting-started.md); the deeper "how" lives in
[How It Works](tuning.md).

---

## Why RigForge vs. doing it by hand?

You can absolutely build, tune, and run XMRig yourself — it's an excellent, well-documented miner. Doing
it by hand means:

- Installing the build toolchain and compiling XMRig from source.
- Reading the [RandomX optimization guide](https://xmrig.com/docs/miner/randomx-optimization-guide) and
  hand-configuring HugePages (1 GB + 2 MB), MSR registers, NUMA, and thread layout **for your specific
  CPU**.
- Editing GRUB for persistent HugePages — without clobbering your existing kernel parameters.
- Wiring up a systemd service, a performance governor, and log rotation.
- Redoing the CPU-specific parts every time you deploy a different machine.

RigForge does all of that in one command, with tuning auto-detected from your CPU, idempotent
re-runs, and a build pinned to an audited XMRig version. It's the difference between a one-off
afternoon of tuning and `sudo ./rigforge.sh`. If you enjoy hand-wiring it, the manual route is a great
learning exercise — RigForge just compiles **stock upstream XMRig**, so you're never locked into a
custom fork.

---

## Is RigForge a custom miner?

No. RigForge compiles **stock, upstream [XMRig](https://github.com/xmrig/xmrig)** — it doesn't fork or
modify the miner itself. All it changes at build time is the donate level (so your configured
`DONATION` is honored); everything else is standard XMRig plus the setup/tuning/service wrapping.

---

## Do I need a specific XMRig version?

No. RigForge always builds a pinned, recent upstream XMRig, and any RandomX-capable XMRig (5.0+, 2019)
speaks the standard Stratum protocol that pools and Pithead's proxy accept. There's no version coupling
between the miner and the stack.

---

## What hardware do I need?

A 64-bit x86 CPU with **AVX2**, ~2.3 GB of free RAM for RandomX fast mode (4 GB+ recommended), and —
for the HugePages/MSR speedups — a Linux box you can reboot once. Full sizing and how the tuning is chosen
are in [Hardware Requirements](hardware.md). Hashrate scales with cores **and L3 cache** (RandomX wants
~2 MB of L3 per thread).

---

## Do I have to use Pithead?

No. RigForge points XMRig at any RandomX Stratum pool — set that pool's endpoint as a `pools[].url`.
Pithead is the **flagship integration** (the API and discovery contract is wired up out of the box),
but it's not required. See [Configuration › Pools](configuration.md#pools-full-control).

---

## Do I put my wallet address in the worker?

**Not with Pithead** — the stack handles payouts centrally, so the worker only needs the pool host. The
XMRig `user` field is just a rig label. If you point RigForge at a pool that expects a wallet address in
the `user` field directly, set `pools[].user` to your wallet address.

---

## Why does it need a reboot?

On Linux, persistent **HugePages** are configured via GRUB, which only takes effect after a reboot —
that's the single biggest RandomX performance lever. macOS doesn't expose HugePages, so it needs no
reboot. See [How It Works › Kernel tuning](tuning.md#kernel--system-tuning-linux-only).

---

## I see MSR errors in the log. What's wrong?

Almost always **Secure Boot** blocking the `msr` kernel module. Disable Secure Boot in your BIOS/UEFI
and reboot. See [Operations › Troubleshooting](operations.md#troubleshooting).

---

## Is it safe to re-run the script?

Yes — `setup` is idempotent. It skips the recompile when the pinned XMRig is already built, never
duplicates system-file edits (`fstab`, `limits.conf`, `/etc/modules`), merges (not overwrites) GRUB
parameters, and archives a prior install rather than clobbering it. To rebuild only when the pinned
version changes, use [`upgrade`](operations.md#upgrading-xmrig).

---

## Does the worker need Tor?

No. Workers talk to the pool/stack over plain Stratum on your **local network**. Tor (for privacy and
no port-forwarding) is a stack-host concern, handled by Pithead — not the miner.

---

## Is macOS supported?

macOS works for development and light use — RigForge builds and configures XMRig there — but **Ubuntu
is the supported deployment target**. The Linux-only tuning (HugePages, MSR, systemd, governor) doesn't
apply on macOS, which the macOS CPU profile accounts for.

---

## See also

- [Getting Started](getting-started.md) — fresh machine to a running worker.
- [How It Works](tuning.md) — the mechanics of every optimization.
- [Pithead Integration](pithead-integration.md) — the worker ↔ dashboard contract.
