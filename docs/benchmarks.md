# Benchmarks — what the tuning actually buys you

RigForge's pitch is "stock XMRig, but with the setup and tuning that are fiddly to get right by
hand." So how much does that tuning actually move the needle? Every number here is **measured on real
hardware, mining live**, not synthetic `--bench` runs, so it reflects what you'd see in the wild.

> **TL;DR** — across two very different CPUs, RigForge's one-command tuning beats stock XMRig by
> **+3.5%** (desktop Ryzen 7800X3D) to **+6.6%** (48-core EPYC 7642) in hashrate, and **+7.6% / +6.0%**
> in efficiency (H/s per watt). On the EPYC it also **matched an expert's hand-tuned config**, and
> auto-dodged a CPU-specific landmine: a prefetch setting that halves RandomX there but wins on the
> X3D. All in one command, with the nuance kept in.

## How it's measured

Each configuration runs as its own XMRig process **mining to the live pool**. After a warm-up to steady
state, we sample the **hashrate** (XMRig's HTTP API, 60-second average) and **CPU-package power** (RAPL
energy counter) over several-minute windows, repeated across rounds. RandomX is low-variance and both
rigs were thermally steady, so the means are solid (hashrate within ~0.1%).

The baselines:

- **Stock XMRig** — upstream `./xmrig` on a fresh box: no explicit HugePages, prefetcher MSRs at
  firmware default, default governor. (Transparent HugePages stay at Ubuntu's `madvise` default, as
  a real user would have.)
- **RigForge** — `setup`'s kernel work (2 MB + 1 GB **HugePages**, the per-family **MSR prefetcher**
  preset, **`performance`** governor) plus the winning knobs from a full live `tune`.

## Rig 1 — Ryzen 7800X3D (desktop)

| | |
|---|---|
| **CPU** | AMD Ryzen 7 **7800X3D** — 8C/16T, 96 MiB L3 (V-Cache), 5050 MHz boost, AVX-512 |
| **RAM** | 2 × 16 GB G.Skill DDR5-**6000** (EXPO, dual-channel) |
| **OS / algo** | Ubuntu 24.04, kernel 6.8 · live Monero **rx/0** |

| Configuration | Hashrate (H/s) | Power (W) | Efficiency (H/s per W) |
|---|--:|--:|--:|
| **Stock XMRig** (no tuning) | 10,416 | 86.8 | 120.1 |
| **RigForge** — system tuning only | 10,756 | 83.6 | 128.7 |
| **RigForge** — tuned (performance) | **10,779** | 83.5 | 129.2 |
| **RigForge** — tuned (efficiency) | 10,779 | 83.5 | **129.2** |
| **Stock → tuned** | **+3.5%** | **−3.8%** | **+7.6%** |

Stock XMRig here burns more watts for less work. Without HugePages the CPU stalls on memory, drawing
~87 W to produce fewer hashes; tuned is faster and cooler. Performance and efficiency tuning landed
on the **same** config: RigForge measured the power and found this chip pins ~84 W in any all-core setup,
so there's no hashrate-for-watts trade-off to make, and it correctly didn't invent one.

## Rig 2 — EPYC 7642 (48-core server) · RigForge vs an expert hand-tune

This box is the interesting one: it was already running a **hand-tuned** miner (the worker an operator had
configured for this EPYC by hand) at 36,860 H/s. So it's not just "RigForge vs naive XMRig"; it's
RigForge's one-command auto-tune against a human who tuned it themselves.

| | |
|---|---|
| **CPU** | AMD **EPYC 7642** — 48C/96T, 256 MiB L3, **4 NUMA nodes**, 2300 MHz |
| **RAM / OS / algo** | 62 GB · Ubuntu 24.04, kernel 6.8 · live Monero **rx/0** |

| Configuration | Hashrate (H/s) | Power (W) | Efficiency (H/s per W) |
|---|--:|--:|--:|
| **Stock XMRig** (no tuning) | 34,599 | 228.4 | 151.5 |
| **Expert hand-tuned** worker (XMRig 6.25) | 36,860 | 230.2 | 160.1 |
| **RigForge** — tuned (XMRig 6.26) | **36,866** | 229.5 | **160.6** |
| **Stock → RigForge** | **+6.6%** | ~flat | **+6.0%** |

- **RigForge matched the human expert** (within 0.02%), and did it with a newer XMRig (6.26 vs 6.25),
  `cpu.yield` off (the expert left it on), and **5× fewer HugePages** (266 vs 1,280 reserved, both hitting
  100%) — i.e. the same result with ~2 GB less RAM tied up.
- **The auto-tune dodged a landmine.** On this EPYC, **prefetch mode 2 halves the hashrate** (~17,900
  H/s), the exact opposite of the 7800X3D, where mode 2 is the winner. A fixed "golden profile" would
  get one of these two chips badly wrong; the per-CPU live tune measured it and stayed on the right mode
  for each.
- The HugePages win is **bigger here** (+6.6% vs the X3D's +3.5%): a 4-NUMA EPYC with a per-node dataset
  leans much harder on huge pages than a single-die desktop chip. Efficiency and performance tuning again
  converged (power ~230 W in any config).

## Caveats (read before quoting a number)

- **Two CPUs, two systems, and RandomX gains vary a lot.** A desktop X3D and a 48-core EPYC already differ by
  more than 3× in raw hashrate; your CPU, RAM speed, NUMA layout, and kernel all matter. Treat the
  percentages as illustrative, not a guarantee.
- **Modern kernels narrow the stock gap.** Ubuntu 24.04's Transparent HugePages (`madvise`) back some of
  even the "stock" allocation with 2 MB pages, so the stock baseline is closer to tuned than on an older
  kernel or with THP off. Don't expect the 20–30% some older write-ups quote.
- **`setup` does the heavy lifting; `tune` refines.** Most of the win is the system tuning; the knob
  search confirms you're at the optimum (and, as the EPYC shows, keeps you off the landmines) rather than
  adding a big jump on top.

## Reproduce it

```bash
# bare baseline: stock upstream XMRig, no system tuning
./xmrig -o <pool> -u <wallet>           # no HugePages reserved, MSRs default

# RigForge: one command does the setup + tuning
sudo ./rigforge.sh                       # build + HugePages + MSR + governor + service
sudo ./rigforge.sh tune --now --long     # full live tune (or just let setup's defaults ride)
sudo ./rigforge.sh doctor                # confirms HugePages 100%, MSR applied, governor, clocks
```
