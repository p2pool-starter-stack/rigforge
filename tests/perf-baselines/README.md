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
