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
# Silicon). Two passes, a fresh container each: the standard deploy, then RIGFORGE_APPLIANCE=1
# (#348) — appliance mode against a real /etc, which must stay untouched while units land in /run.
# Run: tests/e2e/linux.sh   (or: make test-e2e)
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
IMAGE_24="ubuntu:24.04@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54"
IMAGE_26="ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db"

run_pass() { # <label> <image> [docker env args...]
    local label="$1" image="$2"
    shift 2
    echo "=================== E2E ($label): $image (linux/amd64) ==================="
    docker run --rm --platform linux/amd64 "$@" \
        -v "$ROOT:/src:ro" \
        "$image" bash /src/tests/e2e/in-container.sh
}

run_suite() { # <image> — runs deploy/appliance/isolation on one image
    local image="$1"
    run_pass "deploy"      "$image"  || STATUS=1
    echo ""
    run_pass "appliance"   "$image" -e RIGFORGE_APPLIANCE=1 || STATUS=1
    echo ""
    bash "$ROOT/tests/e2e/isolation.sh" "$image" || STATUS=1
    echo ""
}

STATUS=0
run_suite "$IMAGE_24" || STATUS=1
run_suite "$IMAGE_26" || STATUS=1
echo ""
if [ "$STATUS" = 0 ]; then
    echo "rigforge e2e: all passes (deploy + appliance + isolation) on Ubuntu 24.04 and 26.04 passed"
else
    echo "rigforge e2e: FAILED (see the failing pass above)"
fi
exit "$STATUS"
