# Perf baselines

Legacy per-host `xmrig --bench=1M` baselines for the `e2e-real` `perf` phase — see
[tests/README.md › Performance testing](../README.md#performance-testing-standardized).

**Retiring.** The phase now emits `{"<class>":{"bench_1m_hs":<H/s>}}` on stdout and reads history from
`E2E_PERF_HISTORY` (JSON lines of earlier emitted results), so nothing needs committing. These files are
read only when `E2E_PERF_HISTORY` is unset and are no longer the way to record; delete them once every
rig's history lives in the caller's store. In report mode (the default) a regression against them is
printed, not failed; the gate (`E2E_PERF_MODE=gate`) judges against `E2E_PERF_HISTORY`, not these
files.

One `<hostname>.json` per rig: `{"bench_1m_hs": <H/s>, "cpu": "...", "recorded": "YYYY-MM-DD"}`.

Record or update one (then commit the file):

```bash
E2E_PERF_RECORD=1 sudo bash tests/e2e-real.sh perf
```

Hashrate is hardware: when a rig's hardware or BIOS tuning changes deliberately, start a new class
history or re-record in the same PR that documents the change.

## Per-release history (never lose a benchmark)

Every `E2E_PERF_RECORD=1` run also appends `{tag, recorded, bench_1m_hs}` to
`<hostname>.history.jsonl` — tag it with the release being cut:

```bash
E2E_PERF_TAG=v1.4.0 E2E_PERF_RECORD=1 sudo bash tests/e2e-real.sh perf
```

Commit both files. Recording judges a new measurement against the current baseline **and**
against the best entry in the history (same tolerance) before it writes, so refreshing the baseline
every release can never ratchet hashrate downward a few percent at a time — a slow multi-release
drift fails loudly as `perf RATCHET`.

## Optional public verification

`E2E_PERF_SUBMIT=1` makes the perf gate run `bench --submit` and verify the returned ID.
It publishes hardware and performance information; without the option the gate stays offline.
The emitted JSON gains a `benchmark_id` field inside the class object, and the legacy recordings
add it to both the baseline JSON and the history entry. Existing records remain valid, and the
performance judge still compares H/s.

```bash
sudo env E2E_PERF_SUBMIT=1 E2E_PERF_HISTORY=<history.jsonl> bash tests/e2e-real.sh perf
```

Copy the returned ID into [the published benchmarks](../../docs/benchmarks.md) with the release tag
and CPU. Use `bench --verify ID` to check it again. Missing IDs or failed verification prevent
recording; do not substitute an ID from an earlier run.
