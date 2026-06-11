#!/usr/bin/env bash
#
# End-to-end test: run the REAL rigforge.sh, twice, inside a disposable Ubuntu container.
#
# Ubuntu/Debian is RigForge's documented Linux target (see README), so that's what we exercise here.
# Unlike tests/run.sh (which stubs everything and runs on any host), this runs the genuine Linux
# deploy path with REAL tools — GNU `sed -i`, `tee`, `envsubst`, and a real (disposable) /etc — which
# cannot run natively on a macOS host. Only the heavy/privileged operations are stubbed: the XMRig
# compile (git/cmake/make), the package install (dpkg reports "already present"), and the host-only
# bits (systemctl/modprobe/mount/sysctl). Hardware detection is stubbed so the CPU profile is
# deterministic. We force linux/amd64 so the x86-only MSR path actually fires (emulated on Apple
# Silicon). Run: tests/e2e/linux.sh   (or: make test-e2e)
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not found — the dependency-free suite (tests/run.sh) covers the rest."
    exit 0
fi
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker daemon not reachable."
    exit 0
fi

# Pinned by digest for a reproducible base image (supply-chain hardening, cf. issue #2). This is the
# multi-arch index digest; --platform below selects linux/amd64 from it. Refresh with:
#   docker buildx imagetools inspect ubuntu:24.04 --format '{{.Manifest.Digest}}'
IMAGE="ubuntu:24.04@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54"
echo "=================== E2E: $IMAGE (linux/amd64) ==================="
if docker run --rm --platform linux/amd64 \
    -v "$ROOT:/src:ro" \
    "$IMAGE" bash /src/tests/e2e/in-container.sh; then
    echo ""
    echo "rigforge e2e: $IMAGE passed"
else
    echo ""
    echo "rigforge e2e: $IMAGE failed"
    exit 1
fi
