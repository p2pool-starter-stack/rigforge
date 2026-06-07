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
| **CPU** | 64-bit x86 with **AVX2** support | A high-core-count CPU (e.g. AMD Ryzen / EPYC) — more and faster cores mean more hashrate. RigForge auto-detects the CPU and applies a matching profile. |
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
roughly `L3 size ÷ 2 MB`. This is exactly the math behind the AMD profiles below (and the
`util/proposed-grub.sh` HugePage sizing helper).

---

## What "tuning" actually does

The bulk of a worker's performance comes from configuration RigForge applies automatically, not from
the raw silicon:

- **HugePages (1 GB + 2 MB)** — reduces TLB misses on the 2 GB RandomX dataset. Biggest single win.
- **MSR registers** — sets hardware-prefetcher / cache-QoS model-specific registers XMRig recommends
  for your CPU family.
- **Thread layout, ASM, NUMA** — a per-CPU profile (see below) picks the assembly path, thread count,
  priorities, and NUMA binding.
- **Performance governor** — `cpupower` pins the CPU to its performance frequency under load.

The full mechanics are in [How It Works](tuning.md).

---

## Per-CPU tuning profiles

RigForge detects the CPU (via `lscpu` on Linux, `sysctl` on macOS) and writes a matching XMRig
config. The profiles it ships:

| CPU family | What RigForge applies |
|---|---|
| **AMD EPYC** (multi-socket / high-NUMA) | NUMA-aware RandomX (`randomx.numa = true`), automatic ASM, MSR tuning, dataset spread across NUMA nodes. |
| **AMD Ryzen X3D** (large 3D V-Cache) | The `ryzen` ASM path, an explicit per-core RandomX thread list, raised CPU priority, AVX2 dataset init. |
| **Generic Linux x86** | Auto thread count (`cpu.rx = -1`), automatic ASM, HugePages + MSR enabled, API bound LAN-wide. |
| **macOS (Apple Silicon / Intel)** | No HugePages/MSR (not available on macOS), boolean ASM, conservative priorities, read-only API bound LAN-wide (IPv6 `::`). |

> You don't choose a profile — detection is automatic. If your CPU isn't specifically recognized, the
> generic profile gives XMRig sensible defaults and lets it auto-tune thread count.

The resulting XMRig config (pools, donate level, API, CPU section) lives under your worker root; see
[Configuration](configuration.md) for how the template feeds into it.

---

## See also

- [Getting Started](getting-started.md) — provision a worker in one command.
- [How It Works](tuning.md) — the mechanics of every optimization above.
- [Configuration](configuration.md) — the config keys and the XMRig template.
