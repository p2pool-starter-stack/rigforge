#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

check() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        printf 'PASS: %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$1" "$2" "$3" >&2
    fi
}

mkdir -p "$TMP/bin" "$TMP/node/node0"
cat >"$TMP/bin/lscpu" <<'LSCPU'
#!/usr/bin/env bash
printf '%s\n' "L3 cache: $L3_TEXT" 'Socket(s): 1' 'NUMA node(s): 1'
LSCPU
chmod +x "$TMP/bin/lscpu"
printf 'flags : aes avx2\n' >"$TMP/cpuinfo"
printf 'MemTotal:       16777216 kB\n' >"$TMP/meminfo"

grub() {
    L3_TEXT="$1" PATH="$TMP/bin:$PATH" CPUINFO="$TMP/cpuinfo" NODE_SYS="$TMP/node" MEMINFO="$TMP/meminfo" \
        RX_THREADS="" THREADS_CAP="" RESERVE_EXTRA_MB="${2:-}" "$ROOT/util/proposed-grub.sh" 2>&1
}

l3() { grub "$1" | sed -n 's/^L3 Cache: *//p'; }

check "GiB with decimal point" "$(l3 '1.1 GiB')" "1126 MB"
check "GiB whole" "$(l3 '1 GiB')" "1024 MB"
check "MiB" "$(l3 '32 MiB (1 instance)')" "32 MB"
check "KiB" "$(l3 '98304 KiB')" "96 MB"
check "bare M suffix" "$(l3 '32M')" "32 MB"
check "bare K suffix" "$(l3 '32768K')" "32 MB"
check "a size with no number falls back to 4 MB" "$(l3 '-')" "4 MB"
check "GiB thread count" "$(grub '1.1 GiB' | sed -n 's/^Max Threads: *\([0-9]*\).*/\1/p')" 563
check "oversized extra reserve names the key" "$(grub '32 MiB' 16384 | grep -c 'WARNING: hugepages_reserve_extra_mb')" 1
check "extra reserve within memory is silent" "$(grub '32 MiB' 1024 | grep -c WARNING)" 0

printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
