# Perf baselines

Per-host `xmrig --bench=1M` baselines for the `e2e-real` `perf` phase — see
[tests/README.md › Performance testing](../README.md#performance-testing-standardized).

One `<hostname>.json` per rig: `{"bench_1m_hs": <H/s>, "cpu": "...", "recorded": "YYYY-MM-DD"}`.

Record or update one (then commit the file):

```bash
E2E_PERF_RECORD=1 sudo bash tests/e2e-real.sh perf
```

Baselines are per-host on purpose — hashrate is hardware. When a rig's hardware or BIOS tuning
changes deliberately, re-record its baseline in the same PR that documents the change.

## Per-release history (never lose a benchmark)

Every `E2E_PERF_RECORD=1` run also appends `{tag, recorded, bench_1m_hs}` to
`<hostname>.history.jsonl` — tag it with the release being cut:

```bash
E2E_PERF_TAG=v1.4.0 E2E_PERF_RECORD=1 sudo bash tests/e2e-real.sh perf
```

Commit both files. The perf gate checks new measurements against the current baseline **and**
against the best entry in the history (same tolerance), so refreshing the baseline every release
can never ratchet hashrate downward a few percent at a time — a slow multi-release drift fails
loudly as `perf RATCHET`.

## Optional public verification

`E2E_PERF_SUBMIT=1` makes the perf gate run `bench --submit` and verify the returned ID.
It publishes hardware and performance information; without the option the gate stays offline.
Successful recordings add an optional `benchmark_id` field to both the baseline JSON and the
history entry. Existing records remain valid, and the performance judge still compares H/s.

```bash
sudo env E2E_PERF_SUBMIT=1 E2E_PERF_RECORD=1 E2E_PERF_TAG=vX.Y.Z bash tests/e2e-real.sh perf
```

Copy the returned ID into [the published benchmarks](../../docs/benchmarks.md) with the release tag
and CPU. Use `bench --verify ID` to check it again. Missing IDs or failed verification prevent
recording; do not substitute an ID from an earlier run.
