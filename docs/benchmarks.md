# Benchmarks — what the tuning actually buys you

RigForge's whole pitch is "stock XMRig, but with the setup and tuning that are fiddly to get right by
hand." So: how much does that tuning actually move the needle? These numbers are **measured on real
hardware, mining live** — not synthetic `--bench` runs — so they reflect what you'd see in the wild.

> **TL;DR** — on the rig below, RigForge's tuning lifts a stock XMRig from **~10,416 H/s** to
> **~10,779 H/s** (**+3.5%**) while *dropping* power draw from **86.8 W to 83.5 W**, for a
> **+7.6%** jump in efficiency (**120.1 → 129.2 H/s per watt**). All free, in one command. The honest
> nuance is below — most of the win is the system tuning (HugePages + MSR), and modern kernels narrow
> the gap, but it's real and it costs you nothing.

## The rig

| | |
|---|---|
| **CPU** | AMD Ryzen 7 **7800X3D** — 8 cores / 16 threads, 96 MiB L3 (V-Cache), max boost 5050 MHz, AVX-512 |
| **RAM** | 2 × 16 GB G.Skill DDR5-**6000** (EXPO active, dual-channel, single-rank) |
| **OS** | Ubuntu 24.04.3 LTS, kernel 6.8 |
| **Pool / algo** | live Monero pool, **RandomX (rx/0)** |

## Method

Each configuration runs as its own XMRig process **mining to the live pool**. After a warm-up to
steady state, we sample the **hashrate** (XMRig's HTTP API, 60-second average) and **CPU-package
power** (Intel RAPL energy counter) every 20 s across a 5-minute window, then rotate to the next
config — repeated across multiple rotation rounds of continuous mining (~45 samples per config). The
rig was thermally rock-steady, so run-to-run variance was negligible (hashrate within ~0.1%, power
within ~0.3%) and the means below are solid.

The four configurations isolate each layer of what RigForge does:

- **Stock XMRig** — what you get running upstream `./xmrig` on a fresh box: **no explicit HugePages**,
  the **prefetcher MSRs at firmware default** (no mod), and the **default CPU governor**. (Transparent
  HugePages left at Ubuntu's default of `madvise`, as any real user would have — see the caveat below.)
- **RigForge — system tuning** — `setup`'s kernel work: 2 MB + 1 GB **HugePages**, the **`ryzen_19h_zen4`
  MSR prefetcher** preset, and the **`performance`** governor. XMRig's own auto-detected knobs otherwise.
- **RigForge — tuned (performance)** — the above plus the winning knobs from `tune --perf`.
- **RigForge — tuned (efficiency)** — the above plus the winning knobs from `tune --efficiency`.

## Results

| Configuration | Hashrate (H/s) | Power (W) | Efficiency (H/s per W) |
|---|--:|--:|--:|
| **Stock XMRig** (no tuning) | 10,416 | 86.8 | 120.1 |
| **RigForge** — system tuning only | 10,756 | 83.6 | 128.7 |
| **RigForge** — tuned for **performance** | **10,779** | 83.5 | 129.2 |
| **RigForge** — tuned for **efficiency** | 10,779 | 83.5 | **129.2** |
| | | | |
| **Stock → fully tuned** | **+3.5%** | **−3.8%** | **+7.6%** |

## What to take away

- **It's a free, measured win.** ~+3.5% hashrate *and* ~+7.6% efficiency, applied in one command —
  with the proof above rather than a marketing number.
- **Stock XMRig burns *more* watts for *less* work.** Without HugePages the CPU stalls on memory
  (TLB walks chewing cycles), so it draws ~87 W to produce *fewer* hashes; with HugePages it's faster
  **and** cooler at ~83 W. Efficiency improves more than raw speed.
- **Most of the gain is the system tuning** (HugePages + the MSR prefetcher), which `setup` applies for
  you. The `tune` knob search then squeezes out the last fraction — small here because XMRig's
  cache-aware auto-detection is already strong on this CPU, but it's the step that *confirms* you're at
  the optimum rather than guessing.
- **Performance and efficiency tuning landed on the *same* config** on this chip — and that's the
  honest result, not a missing feature. RigForge measured the actual power draw and found RandomX pins
  this 7800X3D at ~84 W in **any** all-core configuration (even halving the thread count barely moves
  it), so there's simply **no hashrate-for-watts trade-off to make here**. On hardware where the knobs
  *do* move power, `tune --efficiency` picks the lower-power config; here it correctly declines to
  invent a trade-off that doesn't exist.

## Caveats (read this before quoting the number)

- **One CPU, one system.** This is a single 7800X3D on Ubuntu 24.04. RandomX gains vary a lot by CPU,
  RAM speed, and kernel — treat the percentages as illustrative, not a guarantee.
- **Modern kernels narrow the HugePages gap.** Ubuntu 24.04 enables **Transparent HugePages**
  (`madvise`), which transparently backs some of XMRig's allocation with 2 MB pages even in the "stock"
  run — so the stock baseline here is *closer* to tuned than it would be on an older kernel or a system
  with THP off. RigForge's explicit HugePages + MSR mod still win measurably; just don't expect the 20–30%
  some older write-ups quote.
- **`setup` does the heavy lifting; `tune` refines.** If you skip `tune`, you still get the bulk of the
  benefit from `setup` alone.

## Reproduce it

```bash
# bare baseline: stock upstream XMRig, no system tuning
./xmrig -o <pool> -u <wallet>           # no HugePages reserved, MSRs default

# RigForge: one command does the setup + tuning
sudo ./rigforge.sh                       # build + HugePages + MSR + governor + service
sudo ./rigforge.sh tune --now --long     # full live tune (or just let setup's defaults ride)
sudo ./rigforge.sh doctor                # confirms HugePages 100%, MSR applied, governor, clocks
```
