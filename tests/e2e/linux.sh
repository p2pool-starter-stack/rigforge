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
    echo "FATAL: docker not found — the dependency-free suite (tests/run.sh) covers unit logic, but the full deploy+appliance contract requires a container runtime." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "FATAL: docker daemon not reachable — the deploy+appliance contract requires a running container runtime." >&2
    exit 1
fi

IMAGE="$(sed -n 's/^FROM //p' "$ROOT/tests/e2e/Dockerfile")"
[ -n "$IMAGE" ] || {
    echo "FATAL: cannot read the pinned base image from tests/e2e/Dockerfile" >&2
    exit 1
}

run_pass() { # <label> [docker env args...] — one disposable container per pass
    local label="$1"
    shift
    echo "=================== E2E ($label): $IMAGE (linux/amd64) ==================="
    docker run --rm --platform linux/amd64 "$@" \
        -v "$ROOT:/src:ro" \
        "$IMAGE" bash /src/tests/e2e/in-container.sh
}

STATUS=0

LOGA="$(mktemp)"
LOGB="$(mktemp)"
trap 'rm -f "$LOGA" "$LOGB"' EXIT

run_pass "deploy" >"$LOGA" 2>&1 &
PID_A=$!
run_pass "appliance" -e RIGFORGE_APPLIANCE=1 >"$LOGB" 2>&1 &
PID_B=$!

wait "$PID_A"
rc_a=$?
wait "$PID_B"
rc_b=$?

[ "$rc_a" != 0 ] && {
    cat "$LOGA"
    STATUS=1
}
[ "$rc_b" != 0 ] && {
    cat "$LOGB"
    STATUS=1
}

echo ""
bash "$ROOT/tests/e2e/isolation.sh" || STATUS=1
echo ""
if [ "$STATUS" = 0 ]; then
    echo "rigforge e2e: all passes (deploy + appliance + isolation) passed"
else
    echo "rigforge e2e: FAILED (see the failing pass above)"
fi
exit "$STATUS"
