#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
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
cat >"$TMP/bin/lscpu" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'L3 cache: 32 MiB' 'Socket(s): 1' 'NUMA node(s): 1'
EOF
chmod +x "$TMP/bin/lscpu"
printf 'flags : aes avx2\n' >"$TMP/cpuinfo-2m"
printf 'flags : aes avx2 pdpe1gb\n' >"$TMP/cpuinfo-1g"
printf '0\n' >"$TMP/nr-1g-zero"
printf '3\n' >"$TMP/nr-1g-three"

run_case() { # <current> <headroom MB> <ceiling MB|unset> <cpuinfo> <1G pages>
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$1" >"$TMP/grub"
    (
        export PATH="$TMP/bin:$PATH"
        export CPUINFO="$4" HUGEPAGES_1G_NR="$5" NODE_SYS="$TMP/node"
        source "$ROOT/rigforge.sh"
        SCRIPT_DIR="$ROOT"
        GRUB_DEFAULT="$TMP/grub"
        RX_SETUP_THREADS=""
        THREADS_CAP=""
        HUGEPAGES_RESERVE_EXTRA_MB="$2"
        if [ "$3" = unset ]; then
            unset HUGEPAGES_POOL_CEILING_MB
        else
            HUGEPAGES_POOL_CEILING_MB="$3"
        fi
        _grub_proposed 2>/dev/null
        printf '%s|%s\n' "$CURRENT" "$MERGED"
    )
}

runtime_need() { # <headroom MB> <1G pages>
    PATH="$TMP/bin:$PATH" CPUINFO="$TMP/cpuinfo-2m" HUGEPAGES_1G_NR="$2" NODE_SYS="$TMP/node" \
        RX_THREADS="" THREADS_CAP="" RESERVE_EXTRA_MB="$1" "$ROOT/util/proposed-grub.sh" --runtime
}

check "real calculator includes nonzero headroom" "$(runtime_need 100 "$TMP/nr-1g-zero")" 1284
check "real calculator excludes the existing 1GB pool" "$(runtime_need 100 "$TMP/nr-1g-three")" 204

current='quiet hugepagesz=2M hugepages=4096 transparent_hugepage=never'
check "nonzero headroom cannot preserve small pages above the ceiling" \
    "$(run_case "$current" 100 2000 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" \
    "$current|quiet transparent_hugepage=never default_hugepagesz=2M hugepages=1000 msr.allow_writes=on"
check "zero headroom also applies the persisted ceiling" \
    "$(run_case "$current" 0 2000 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" \
    "$current|quiet transparent_hugepage=never default_hugepagesz=2M hugepages=1000 msr.allow_writes=on"

current='quiet splash hugepagesz=2M hugepages=1400 audit=1'
check "sufficient small pages below the ceiling stay unchanged" \
    "$(run_case "$current" 100 3000 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" "$current|$current"
check "sufficient small pages at the exact ceiling stay unchanged" \
    "$(run_case "$current" 100 2800 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" "$current|$current"
current='quiet hugepagesz=2M hugepages=1200 audit=1'
check "small pages below runtime need are replaced" \
    "$(run_case "$current" 100 3000 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" \
    "$current|quiet audit=1 default_hugepagesz=2M hugepages=1284 msr.allow_writes=on"

current='quiet hugepagesz=2M hugepages=4096 audit=1'
check "zero ceiling preserves a sufficient reservation" \
    "$(run_case "$current" 100 0 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" "$current|$current"
check "unset ceiling preserves a sufficient reservation" \
    "$(run_case "$current" 100 unset "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" "$current|$current"
check "odd MB ceilings floor to whole 2MB pages" \
    "$(run_case "$current" 100 2001 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" \
    "$current|quiet audit=1 default_hugepagesz=2M hugepages=1000 msr.allow_writes=on"
check "a 1MB ceiling persists zero 2MB pages" \
    "$(run_case "$current" 100 1 "$TMP/cpuinfo-2m" "$TMP/nr-1g-zero")" \
    "$current|quiet audit=1 default_hugepagesz=2M hugepages=0 msr.allow_writes=on"

current='quiet hugepagesz=1G hugepages=6 hugepagesz=2M hugepages=4096 audit=1'
check "mixed reservations cap only their small-page component" \
    "$(run_case "$current" 100 300 "$TMP/cpuinfo-1g" "$TMP/nr-1g-three")" \
    "$current|quiet audit=1 hugepagesz=1G hugepages=3 hugepagesz=2M hugepages=150 default_hugepagesz=2M msr.allow_writes=on"
current='quiet hugepagesz=1G hugepages=6 hugepagesz=2M hugepages=250 audit=1'
check "mixed reservations preserve sufficient bounded small pages" \
    "$(run_case "$current" 100 600 "$TMP/cpuinfo-1g" "$TMP/nr-1g-three")" "$current|$current"

for current in \
    'quiet hugepagesz=1G hugepages=6 audit=1' \
    'quiet hugepagesz=1073741824 hugepages=6 audit=1' \
    'quiet hugepagesz=1048576K hugepages=6 audit=1' \
    'quiet default_hugepagesz=1G hugepages=6 audit=1'; do
    check "1GB-only reservation remains outside the small-page ceiling ($current)" \
        "$(run_case "$current" 100 600 "$TMP/cpuinfo-1g" "$TMP/nr-1g-three")" \
        "$current|$current"
done

if [ "$(uname -s)" = Linux ]; then
    for headroom in 0 100; do
        current='quiet hugepagesz=2M hugepages=4096 audit=1'
        printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$current" >"$TMP/grub"
        persisted=$(
            export PATH="$TMP/bin:$PATH" CPUINFO="$TMP/cpuinfo-2m"
            export HUGEPAGES_1G_NR="$TMP/nr-1g-zero" NODE_SYS="$TMP/node"
            source "$ROOT/rigforge.sh"
            SCRIPT_DIR="$ROOT"
            GRUB_DEFAULT="$TMP/grub"
            WORKER_ROOT="$TMP"
            MODULES_LOAD_DIR="$TMP/absent"
            MODULES_FILE="$TMP/absent"
            RIGFORGE_APPLIANCE=0
            RIGFORGE_THREADS=""
            THREADS_CAP=""
            HUGEPAGES_RESERVE_EXTRA_MB="$headroom"
            HUGEPAGES_POOL_CEILING_MB=2000
            _ensure_hugepages() { :; }
            update-grub() { :; }
            sudo() {
                case "$1" in
                cp | sed | update-grub) "$@" ;;
                modprobe) : ;;
                *) return 1 ;;
                esac
            }
            tune_kernel >/dev/null 2>&1
            printf '%s|%s\n' "$(cat "$GRUB_DEFAULT")" "$REBOOT_REQUIRED"
        )
        check "tune_kernel persists the ceiling with headroom=$headroom and requests reboot" "$persisted" \
            'GRUB_CMDLINE_LINUX_DEFAULT="quiet audit=1 default_hugepagesz=2M hugepages=1000 msr.allow_writes=on"|true'
    done
else
    printf 'SKIP: tune_kernel persistence requires Linux sed\n'
fi

printf 'HugePages ceiling tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
