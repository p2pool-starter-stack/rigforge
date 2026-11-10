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

IMAGE="$(sed -n 's/^IMAGE="\(.*\)"$/\1/p' "$ROOT/tests/e2e/linux.sh")"
[ -n "$IMAGE" ] || {
    echo "FATAL: cannot read the pinned IMAGE from tests/e2e/linux.sh"
    exit 1
}

SUFFIX="$$"
NET="rf-iso-net-$SUFFIX"
UP="rf-iso-up-$SUFFIX"
RIG="rf-iso-rig-$SUFFIX"
PREP="rf-iso-prep-$SUFFIX"
PREP_IMAGE="rf-iso-image-$SUFFIX"
PKI="$(mktemp -d)"
chmod 755 "$PKI"

cleanup() {
    docker rm -f "$UP" "$RIG" "$PREP" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    docker rmi -f "$PREP_IMAGE" >/dev/null 2>&1
    rm -rf "$PKI" 2>/dev/null
}
trap cleanup EXIT

echo "=================== E2E (isolation): $IMAGE (linux/amd64) ==================="
prepared=0
for attempt in 1 2 3; do
    docker rm -f "$PREP" >/dev/null 2>&1
    if docker run --name "$PREP" --platform linux/amd64 -e DEBIAN_FRONTEND=noninteractive "$IMAGE" \
        bash -c 'apt-get update -qq && apt-get install -y -qq jq gettext-base python3 git curl ca-certificates openssl >/dev/null'; then
        prepared=1
        break
    fi
    echo "apt prerequisites failed (attempt $attempt/3) — retrying in $((attempt * 5))s." >&2
    sleep $((attempt * 5))
done
[ "$prepared" = 1 ] || {
    echo "FATAL: could not build the isolation image after 3 attempts."
    exit 1
}
docker commit "$PREP" "$PREP_IMAGE" >/dev/null

docker network create --internal "$NET" >/dev/null || exit 1
docker run -d --name "$UP" --platform linux/amd64 --network "$NET" -v "$ROOT:/src:ro" -v "$PKI:/pki" "$PREP_IMAGE" \
    bash /src/tests/e2e/isolation-upstream.sh >/dev/null || exit 1
for _ in $(seq 1 90); do
    [ -f "$PKI/ready" ] && break
    sleep 1
done
if [ ! -f "$PKI/ready" ]; then
    echo "FATAL: the stand-in origin and SOCKS5 proxy did not come up."
    docker logs "$UP" 2>&1 | tail -30
    exit 1
fi
docker run -d --name "$RIG" --platform linux/amd64 --network "$NET" -v "$ROOT:/src:ro" -v "$PKI:/pki" "$PREP_IMAGE" sleep infinity >/dev/null || exit 1

docker exec -e RF_PROXY="$UP:1080" "$RIG" bash /src/tests/e2e/isolation-rig.sh
rc=$?
if [ "$rc" != 0 ]; then
    echo "--- proxy log ---"
    tail -30 "$PKI/socks.log" 2>/dev/null
    echo "--- stand-in origin log ---"
    tail -20 "$PKI/https.log" 2>/dev/null
fi
exit "$rc"
