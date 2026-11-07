# Benchmarks

RigForge automates setup and tuning of upstream XMRig; it is not a separate mining engine.

**Evidence status, 2026-11-02: historical observations only.** The measurements below were first
committed in `0790840` (#107, 2026-06-12) and are retained unchanged from the report as reviewed
in #580 at revision `ff4e60f8a8e48ac791c4372252edd2ec0308eb20`. Neither is the tested RigForge revision.
The measurement date, baked RigForge SHA, full upstream XMRig commit and build flags are not recorded
in that report. It does not validate the RigForge baked into Pithead 2.0.0 or establish a current
candidate's percentage uplift.

All power readings below are **CPU-package RAPL**, and efficiency is H/s per CPU-package watt.
Wall power and wall energy are unavailable in this report. These readings do not establish
whole-system efficiency, electricity savings or temperature improvements.

## Historical method and its limits

The historical report describes separate XMRig processes mining live, with warm-up followed by
several-minute sampling windows across rounds. Hashrate came from XMRig's HTTP API (60-second
average), and package power from the RAPL energy counter. This was not a standard RandomX
correctness benchmark. Individual trials, spread and uncertainty are not published here, so the
reported means alone do not establish repeatability or a precision bound.

The reported configurations were:

- Stock XMRig: upstream automatic configuration, described as a fresh OS with no explicit
  HugePages reservation, firmware-default prefetcher MSRs, default governor and Ubuntu's
  `madvise` Transparent HugePages setting.
- RigForge: `setup`'s kernel work (2 MB + 1 GB HugePages, per-family MSR prefetcher preset,
  `performance` governor) plus the winning knobs from a live `tune`.

A verified clean-baseline restoration between arms, counterbalanced order, identical source/build
and donation settings, and difficulty-weighted accepted work are not documented. The figures below
remain illustrative historical observations, not a controlled comparison of the frozen candidate.

## Rig 1 — Ryzen 7800X3D (desktop)

| | |
|---|---|
| **CPU** | AMD Ryzen 7 **7800X3D** — 8C/16T, 96 MiB L3 (V-Cache), 5050 MHz boost, AVX-512 |
| **RAM** | 2 × 16 GB G.Skill DDR5-**6000** (EXPO, dual-channel) |
| **OS / algo** | Ubuntu 24.04, kernel 6.8 · live Monero **rx/0** |

| Configuration | Hashrate (H/s) | CPU-package power (W, RAPL) | Efficiency (H/s per CPU-package W) |
|---|--:|--:|--:|
| **Stock XMRig** (no tuning) | 10,416 | 86.8 | 120.1 |
| **RigForge** — system tuning only | 10,756 | 83.6 | 128.7 |
| **RigForge** — tuned (performance) | **10,779** | 83.5 | 129.2 |
| **RigForge** — tuned (efficiency) | 10,779 | 83.5 | **129.2** |
| **Stock → tuned** | **+3.5%** | **−3.8%** | **+7.6%** |

The reported performance and efficiency tuning runs selected the same configuration. The table
records higher local hashrate and lower package power in those tuned runs; it does not isolate
which tuning change caused the difference or measure cooling or wall-power savings.

## Rig 2 — EPYC 7642 (48-core server)

The historical report also included a hand-tuned worker. It used XMRig 6.25, while the RigForge
run used 6.26. This version mismatch prevents attributing their similar hashrates to automation
versus expert tuning; it is not evidence of equivalence.

| | |
|---|---|
| **CPU** | AMD **EPYC 7642** — 48C/96T, 256 MiB L3, **4 NUMA nodes**, 2300 MHz |
| **RAM / OS / algo** | 62 GB · Ubuntu 24.04, kernel 6.8 · live Monero **rx/0** |

| Configuration | Hashrate (H/s) | CPU-package power (W, RAPL) | Efficiency (H/s per CPU-package W) |
|---|--:|--:|--:|
| **Stock XMRig** (no tuning) | 34,599 | 228.4 | 151.5 |
| **Expert hand-tuned** worker (XMRig 6.25) | 36,860 | 230.2 | 160.1 |
| **RigForge** — tuned (XMRig 6.26) | **36,866** | 229.5 | **160.6** |
| **Stock → RigForge** | **+6.6%** | ~flat | **+6.0%** |

Other reported differences included `cpu.yield` off for RigForge and on for the hand-tuned worker,
and 266 versus 1,280 reserved HugePages (both reported full HugePages use). Prefetch mode 2 was
reported at approximately 17,900 H/s on this EPYC, about half the tuned rows above, while it was selected on the desktop. These
observations motivate measuring each machine separately, not a universal tuning claim.

## Caveats (read before quoting a number)

- CPU, RAM, firmware, socket count, NUMA layout, kernel and starting OS state affect results.
  Missing fields in the historical record must remain unknown, not inferred from a CPU model.
- Modern kernels likely narrow the stock gap. Ubuntu 24.04's `madvise` Transparent HugePages can back
  some of even the stock allocation with 2 MB pages, so the stock baseline may sit closer to tuned than
  on an older kernel or with THP off; these tables did not measure that effect. Don't expect the
  20–30% some older write-ups quote.
- Stopping the RigForge service does not undo persistent HugePages, MSR, governor, boot-parameter
  or service changes. A stock run on that OS is not automatically a clean baseline.
- These tables cannot support a universal uplift, expert-equivalence claim or wall-efficiency claim.
  Keep launch percentages removed or qualified until the exact candidate has suitable evidence.

## Candidate comparison protocol

This work remains pending under #580 and gates numeric launch claims. Benchmark/stress tooling
belongs to #533, and shared-host coexistence to #579 with #577/#578 prerequisites. No tuner change is
needed for this evidence task.

1. **Freeze identity and scope.** Record the Pithead source revision and image identity, baked
   RigForge SHA, upstream XMRig commit, compiler, dependencies, build flags, source patches and binary
   identity. Test the baked revision, not a newer tag. A required RigForge code change needs a new
   RigForge release and Pithead re-pin before it is the baked candidate. Use one representative
   desktop and one server/NUMA
   system if making claims about both; publish each separately. Record actual sockets, CPU, RAM,
   firmware, kernel, thread allocation, ambient and thermal conditions, and measurement scope.
2. **Reserve and predeclare.** Use separate, uncontended hardware through the approved bench-ci
   reservation/restoration workflow; leave the active RC/soak host untouched. Before reading results,
   declare stabilization, measurement duration, repeat count, exclusions and the smallest effect of
   interest. Freeze each arm's selected configuration after tuning and keep search windows out of
   evaluation. A short pilot may size the run: 4–6 hours per host plus restores can be a starting point
   for hashrate/power, but accepted-share precision may need longer.
3. **Match arms and restore.** Compare upstream stock automatic configuration on a clean OS with
   the normal RigForge setup/tune workflow. Keep XMRig source/build, donation, endpoint and workload
   fixed; disclose intended tuning differences. RigForge changes XMRig's donation default/minimum;
   use a common supported nonzero donation and verify its effective value in both arms. Include a
   properly hand-tuned stock arm only for an automation-versus-expert claim. Restore a reproducible
   clean OS image/snapshot and verify the clean baseline between arms, including HugePages, MSRs,
   governor, kernel parameters and services; reboot where needed. Record the restoration result
   rather than treating a stopped service as a reset.
4. **Repeat and counterbalance.** For example, run stock → RigForge → RigForge → stock, then reverse
   that order, restoring the required starting state each time. Run a full standard RandomX benchmark
   for correctness/repeatability, retaining completion and reference-hash verification, and live
   mining for sustained operational results. A smoke pass or one favorable window is not comparative
   evidence; the existing benchmark wrapper's parsed H/s alone does not verify the reference hash.
5. **Measure and retain.** Capture local H/s, difficulty-weighted accepted work, rejects/stales,
   temperatures, clocks, throttling, wall energy and H/s per wall watt. Keep CPU-package RAPL separate;
   label unavailable wall readings unavailable. Retain all trials and exclusions, spread/uncertainty,
   material confounders and final restoration evidence. Keep raw logs, machine identities and local
   topology private; publish only sanitized evidence references and command outcomes.
6. **Publish and decide.** Produce a dated, reproducible report with tested configurations, all arms
   and a per-machine statement of what each result supports. Check that repeated arms are consistent
   and report uncertainty against the predeclared effect bound. An inconclusive result or a percentage
   that does not reproduce means qualifying/removing that launch claim, not choosing a favorable run.
   “No detected difference” does not establish “no overhead” without sufficient precision. Apply the
   same limits to README, website and organization copy: automated upstream XMRig tuning, package
   versus wall power, and historical versus current-candidate measurements must remain distinct.
