#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
probe() {
    env -u RIGFORGE_TEST_OVERRIDES "$@" RIGFORGE_HOME="$D" XMRIG_VERSION=vEVIL XMRIG_COMMIT=0000 \
        SYSTEMD_DIR="$D/units" BIN_DIR="$D/bin" MEMINFO="$D/meminfo" DMIDECODE="$D/x" SERVICE_NAME=../evil \
        API_CMD="touch $D/api-ran" bash -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s|%s|%s" "$XMRIG_VERSION" "$XMRIG_COMMIT" "$SYSTEMD_DIR" "$BIN_DIR" "$MEMINFO" "$DMIDECODE" "$SERVICE_NAME" "${API_CMD:-unset}"' _ "$SCRIPT" 2>/dev/null
}

echo "== without RIGFORGE_TEST_OVERRIDES the sandbox overrides are ignored =="
IFS='|' read -r ver commit units bin meminfo dmi svc api <<<"$(probe)"
check "XMRIG_VERSION keeps the pin" "v" "${ver:0:1}"
check "XMRIG_VERSION is not the override" "no" "$([ "$ver" = vEVIL ] && echo yes || echo no)"
check "XMRIG_COMMIT is not the override" "no" "$([ "$commit" = 0000 ] && echo yes || echo no)"
check "SYSTEMD_DIR is the real unit folder" "/etc/systemd/system" "$units"
check "BIN_DIR is the real bin folder" "/usr/local/bin" "$bin"
check "MEMINFO is the real file" "/proc/meminfo" "$meminfo"
check "DMIDECODE is the real command" "dmidecode" "$dmi"
check "SERVICE_NAME is the real unit name" "xmrig" "$svc"
check "API_CMD is dropped" "unset" "$api"

echo "== with RIGFORGE_TEST_OVERRIDES=1 they apply =="
IFS='|' read -r ver commit units bin meminfo dmi svc api <<<"$(probe RIGFORGE_TEST_OVERRIDES=1)"
check "XMRIG_VERSION override applies" "vEVIL" "$ver"
check "SYSTEMD_DIR override applies" "$D/units" "$units"
check "API_CMD override applies" "touch $D/api-ran" "$api"

echo "== a value other than 1 does not open them =="
IFS='|' read -r ver commit units bin meminfo dmi svc api <<<"$(probe RIGFORGE_TEST_OVERRIDES=yes)"
check "RIGFORGE_TEST_OVERRIDES=yes keeps the real unit folder" "/etc/systemd/system" "$units"
exit "$fail"
