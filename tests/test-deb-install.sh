#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=ubuntu:24.04

guest() {
    local a=$1 b=$2 out rc
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "/debs/rigforge_${a}_all.deb" >/dev/null
    [ "$(rigforge --version)" = "RigForge $a" ] || {
        echo "FAIL: rigforge --version after install"
        return 1
    }
    echo "ok: apt install ./rigforge_${a}_all.deb, rigforge --version is $a"
    [ "$(cat /usr/lib/rigforge/.rigforge-package)" = apt ] || {
        echo "FAIL: package marker"
        return 1
    }
    echo "ok: package marker reads apt"
    set +e
    out=$(rigforge doctor 2>&1)
    rc=$?
    set -e
    printf '%s\n' "$out" | sed 's/^/  doctor| /'
    case "$rc" in
    0 | 1) ;;
    *)
        echo "FAIL: doctor exited $rc"
        return 1
        ;;
    esac
    grep -q "Checking the worker" <<<"$out" || {
        echo "FAIL: doctor did not run its checks"
        return 1
    }
    echo "ok: doctor runs its checks from the packaged tree (exit $rc: no miner is provisioned)"
    echo '{}' >/usr/lib/rigforge/config.json
    echo kept >/var/lib/rigforge/state-probe
    apt-get install -y -qq "/debs/rigforge_${b}_all.deb" >/dev/null
    [ "$(rigforge --version)" = "RigForge $b" ] || {
        echo "FAIL: rigforge --version after upgrade"
        return 1
    }
    [ -f /usr/lib/rigforge/config.json ] && [ -f /var/lib/rigforge/state-probe ] || {
        echo "FAIL: upgrade lost config or state"
        return 1
    }
    echo "ok: upgrade to $b keeps config and state"
    apt-get remove -y -qq rigforge >/dev/null
    [ ! -e /usr/bin/rigforge ] && [ ! -e /usr/lib/rigforge/rigforge.sh ] || {
        echo "FAIL: remove left the code"
        return 1
    }
    [ -f /usr/lib/rigforge/config.json ] && [ -f /var/lib/rigforge/state-probe ] || {
        echo "FAIL: remove dropped config or state"
        return 1
    }
    echo "ok: remove deletes the code and keeps config and state"
    apt-get purge -y -qq rigforge >/dev/null
    [ ! -e /usr/lib/rigforge ] && [ ! -e /var/lib/rigforge ] && [ ! -e /etc/rigforge ] || {
        echo "FAIL: purge left residue"
        return 1
    }
    if dpkg -s rigforge >/dev/null 2>&1; then
        echo "FAIL: dpkg still knows rigforge after purge"
        return 1
    fi
    echo "ok: purge leaves no rigforge residue"
}

if [ "${1:-}" = --guest ]; then
    guest "$2" "$3"
    exit
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v dpkg-deb >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
        echo "FAIL: CI needs docker and dpkg-deb for the package install test"
        exit 1
    fi
    echo "SKIP: package install test needs docker and dpkg-deb"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
A=$(tr -d '[:space:]' <"$ROOT/VERSION")
B="${A%.*}.$((${A##*.} + 1))"
mkdir -p "$WORK/debs"
for v in "$A" "$B"; do
    stage="$WORK/rigforge-v$v"
    mkdir -p "$stage"
    (cd "$ROOT" && cp -a rigforge.sh util systemd config.minimal.json config.reference.json README.md docs images LICENSE VERSION "$stage/")
    printf '%s\n' "$v" >"$stage/VERSION"
    tar -czf "$WORK/rigforge-v$v.tar.gz" -C "$WORK" "rigforge-v$v"
    (cd "$WORK/debs" && bash "$ROOT/scripts/build-deb.sh" "$WORK/rigforge-v$v.tar.gz" "v$v" >/dev/null)
done
docker run --rm -v "$WORK/debs:/debs:ro" -v "$ROOT/tests/test-deb-install.sh:/t.sh:ro" "$IMAGE" bash /t.sh --guest "$A" "$B"
echo "deb install: all checks passed"
