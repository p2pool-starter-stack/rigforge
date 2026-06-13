# Hardware Requirements

A worker is where the actual RandomX hashing happens, so its **CPU is what determines your
hashrate**. The requirements themselves are modest — most of the performance comes from tuning,
which RigForge applies for you.

> This page sizes the **miner**. The **stack host** your workers connect to (Monero node, P2Pool,
> proxy, dashboard) is sized separately — see Pithead's
> [Hardware Requirements](https://github.com/p2pool-starter-stack/pithead/blob/main/docs/hardware.md).

---

## Requirements

| Resource | Requirement | Recommended |
|---|---|---|
| **CPU** | 64-bit x86 with **AVX2** support | A high-core-count CPU (e.g. AMD Ryzen / EPYC) — more and faster cores mean more hashrate. XMRig auto-detects the CPU and sizes the tuning to it. |
| **RAM** | **~2.3 GB free** for RandomX *fast mode* — a 2080 MB dataset + 256 MB cache — plus **~2 MB of L3 cache per mining thread** | **4 GB+**; budget more on high-core-count CPUs. |
| **HugePages** | Optional, but a significant speedup | RigForge configures **2 MB and 1 GB** HugePages (plus MSR access) for you — Linux only, and it needs a **reboot** to take effect. |
| **OS** | Ubuntu 22.04+, Debian 12, or macOS | Ubuntu is the supported target. |
| **Network** | Reach your pool / stack host on its Stratum port (Pithead uses **3333**) | Local network; workers do **not** need Tor. |

> RandomX *light mode* needs only 256 MB of RAM but is far slower — **fast mode** (the default) is
> what you want for real hashrate. These figures are from XMRig's own
> [RandomX optimization guide](https://xmrig.com/docs/miner/randomx-optimization-guide).

### A note on L3 cache

RandomX is bottlenecked by **L3 cache**, not core count alone: each mining thread wants ~2 MB of L3.
A CPU with lots of cores but little L3 can't feed every core, so the effective thread count is
roughly `L3 size ÷ 2 MB`. This is exactly the math XMRig's auto thread-sizing uses (and the
`util/proposed-grub.sh` HugePage sizing helper).

---

## What "tuning" actually does

The bulk of a worker's performance comes from configuration RigForge applies automatically, not from
the raw silicon:

- **HugePages (1 GB + 2 MB)** — reduces TLB misses on the 2 GB RandomX dataset. Biggest single win.
- **MSR registers** — `randomx.wrmsr` tells XMRig to disable the hardware prefetchers (they hurt
  RandomX's random access pattern); XMRig auto-detects your CPU family and applies the right preset.
- **Thread count, ASM, NUMA** — XMRig auto-detects these from the CPU topology (see below).
- **Performance governor** — `cpupower` pins the CPU to its performance frequency under load.

The full mechanics are in [How It Works](how-it-works.md).

---

## How RigForge tunes

RigForge **does not** keep a table of CPU models. Instead it relies on XMRig's own cache-aware
auto-detection and layers on a few defaults that make sense because the box is a **dedicated** miner:

| Setting | Value | Why |
|---|---|---|
| `cpu.rx` | `-1` (auto) | XMRig sizes the thread count to L3 cache (~2 MB/thread) from detected topology — correct on EPYC, Ryzen, Intel hybrid, and X3D (incl. dual-CCD parts) alike. |
| `cpu.asm` | `auto` | XMRig picks the Ryzen / Intel / Bulldozer assembly path for the detected CPU. |
| `randomx.wrmsr` | `true` | Auto-applies the correct per-family MSR preset (needs root + the `msr` module). |
| `randomx.numa` | `true` | A no-op on single-NUMA machines; on multi-NUMA CPUs it gives each node its own dataset copy. Note a single-socket EPYC can still expose several NUMA nodes — so RigForge sizes the 1 GB HugePage reservation per NUMA node, not per socket. |
| `cpu.yield` | `false` | Busy-wait for maximum hashrate (we own the whole machine). |
| `cpu.priority` | `2` | Wins scheduling vs. background daemons (XMRig warns >2 can hang a desktop). |
| `cpu.huge-pages` / `randomx.1gb-pages` | `true` (Linux) | The single biggest lever; see below. |

> **Why not a per-model lookup table?** XMRig's auto-config is cache-aware and updated every release,
> so it gets thread placement right for CPUs a static table would miss or mishandle — e.g. **dual-CCD
> X3D** parts (7950X3D/7900X3D), where only one CCD has the V-cache and blindly using *all* cores
> would push threads onto the slow CCD. Letting XMRig decide is both simpler and more correct.

The only branch that remains is **OS-level**: macOS has no HugePages or MSRs, so those are disabled and
the API binds IPv6 `::` instead of `0.0.0.0`.

The resulting XMRig config (pools, donate level, API, CPU section) lives under your worker root; see
[Configuration](configuration.md#how-the-generated-xmrig-config-is-built) for how it's generated.

---

## See also

- [Getting Started](getting-started.md) — provision a worker in one command.
- [How It Works](how-it-works.md) — the mechanics of every optimization above.
- [Configuration](configuration.md) — the config keys and how the XMRig config is generated.
