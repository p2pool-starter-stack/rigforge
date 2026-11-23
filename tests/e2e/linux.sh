#!/usr/bin/env bash
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

IMAGE_24="$(sed -n 's/^FROM //p' "$ROOT/tests/e2e-24/Dockerfile")"
IMAGE_26="$(sed -n 's/^FROM //p' "$ROOT/tests/e2e/Dockerfile")"
[ -n "$IMAGE_24" ] && [ -n "$IMAGE_26" ] || {
    echo "FATAL: cannot read the pinned base images from tests/e2e*/Dockerfile" >&2
    exit 1
}

run_pass() {
    local label="$1" image="$2"
    shift 2
    echo "=================== E2E ($label): $image (linux/amd64) ==================="
    docker run --rm --platform linux/amd64 "$@" \
        -v "$ROOT:/src:ro" \
        "$image" bash /src/tests/e2e/in-container.sh
}

run_suite() {
    local image="$1"
    run_pass "deploy" "$image" || STATUS=1
    echo ""
    run_pass "appliance" "$image" -e RIGFORGE_APPLIANCE=1 || STATUS=1
    echo ""
    bash "$ROOT/tests/e2e/isolation.sh" "$image" || STATUS=1
    echo ""
}

STATUS=0
run_suite "$IMAGE_24"
run_suite "$IMAGE_26"
echo ""
if [ "$STATUS" = 0 ]; then
    echo "rigforge e2e: all passes (deploy + appliance + isolation) on Ubuntu 24.04 and 26.04 passed"
else
    echo "rigforge e2e: FAILED (see the failing pass above)"
fi
exit "$STATUS"
