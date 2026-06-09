#!/usr/bin/env bash
#
# Release smoke check (#61): build + bench a worker to prove the COMPILED binary actually starts and
# hashes. The unit suite (tests/run.sh) and the container e2e (tests/e2e/in-container.sh) both stub
# out git/cmake/xmrig, so they verify config generation and system changes but never prove the binary
# we ship will start and produce H/s without erroring on dataset init, HugePages, MSR, or a malformed
# generated config.json.
#
# This runs the real `rigforge.sh bench` (xmrig --bench), which is fully offline — no pool, no wallet,
# no network — and passes only if a hashrate is reported and the run is clean. It is a MANUAL,
# real-hardware PRE-TAG gate, deliberately kept OUT of CI: a real build + HugePages are flaky-by-nature
# and live mining is against GitHub Actions' ToS. See RELEASING.md.
#
# Full effect is Linux-only: macOS builds and configures but does no kernel tuning, so a mac bench
# won't exercise HugePages/MSR (it still validates build -> config -> hash).
#
# Usage:
#   make smoke                       # bench an already-built worker (run `setup` first)
#   SMOKE_RUN_SETUP=1 make smoke     # run `setup` (build + tune) first, then bench  [root on Linux]
#   BENCH=10M make smoke             # longer, steadier bench window
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIGFORGE="$ROOT/rigforge.sh"
[ -x "$RIGFORGE" ] || {
    echo "smoke: $RIGFORGE not found or not executable" >&2
    exit 2
}

banner() { printf '\n== smoke: %s ==\n' "$1"; }

if [ "$(uname -s)" != "Linux" ]; then
    printf 'smoke: note — kernel tuning (HugePages/MSR) is Linux-only; on %s this validates build -> config -> hash only.\n' \
        "$(uname -s)" >&2
fi

if [ "${SMOKE_RUN_SETUP:-0}" = "1" ]; then
    banner "setup (build + tune)"
    "$RIGFORGE" setup
fi

banner "bench (real xmrig --bench, offline)"
rc=0
"$RIGFORGE" bench || rc=$?

echo ""
if [ "$rc" -eq 0 ]; then
    echo "SMOKE CHECK: PASS — the built worker starts and hashes cleanly."
else
    echo "SMOKE CHECK: FAIL — see the XMRig output above (broken build or invalid config)." >&2
    exit "$rc"
fi
