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

mkdir -p "$TMP/bin" "$TMP/node/node0" "$TMP/glob"
touch "$TMP/glob/file-a" "$TMP/glob/file-b"
cat >"$TMP/bin/lscpu" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' 'L3 cache: 32 MiB' 'Socket(s): 1' 'NUMA node(s): 1'
EOF2
chmod +x "$TMP/bin/lscpu"
if sed --version >/dev/null 2>&1; then SED="sed"; else SED=$(command -v gsed || true); fi
[ -z "$SED" ] || ln -s "$(command -v "$SED")" "$TMP/bin/sed"
printf 'flags : aes avx2\n' >"$TMP/cpuinfo-2m"
printf '0\n' >"$TMP/nr-1g-zero"

edit() {
    (
        export PATH="$TMP/bin:$PATH" CPUINFO="$TMP/cpuinfo-2m"
        export HUGEPAGES_1G_NR="$TMP/nr-1g-zero" NODE_SYS="$TMP/node"
        source "$ROOT/rigforge.sh"
        SCRIPT_DIR="$ROOT"
        GRUB_DEFAULT="$TMP/grub"
        WORKER_ROOT="$TMP"
        MODULES_LOAD_DIR="$TMP/absent"
        MODULES_FILE="$TMP/absent"
        OS_TYPE=Linux
        RIGFORGE_APPLIANCE=0
        RIGFORGE_THREADS=""
        THREADS_CAP=""
        HUGEPAGES_RESERVE_EXTRA_MB=0
        HUGEPAGES_POOL_CEILING_MB=0
        _ensure_hugepages() { :; }
        update-grub() { :; }
        uname() { if [ "${1:-}" = -m ]; then echo x86_64; else command uname "$@"; fi; }
        sudo() {
            case "$1" in cp | sed | update-grub) "$@" ;; modprobe) : ;; *) return 1 ;; esac
        }
        tune_kernel >"$TMP/out" 2>&1
    )
}

if [ -n "$SED" ]; then
    for line in \
        "GRUB_CMDLINE_LINUX_DEFAULT='quiet splash console=ttyS0,115200 iommu=pt'" \
        'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0" # serial console' \
        'GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=ttyS0"'; do
        printf '%s\nGRUB_TIMEOUT=5\n' "$line" >"$TMP/grub"
        cp "$TMP/grub" "$TMP/orig"
        rm -f "$TMP/grub.bak"
        edit
        check "unparseable line is left byte-identical: $line" "$(cmp "$TMP/orig" "$TMP/grub" && echo same)" same
        check "no backup is made when nothing is edited" "$([ -e "$TMP/grub.bak" ] && echo made || echo none)" none
        check "the refusal names the parameters to set by hand" "$(grep -c 'would have set: .*msr.allow_writes=on' "$TMP/out")" 1
    done

    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0"\n' >"$TMP/grub"
    rm -f "$TMP/grub.bak"
    edit
    check "a plain double-quoted line still merges" \
        "$(sed 's/hugepages=[0-9]*/hugepages=N/' "$TMP/grub")" \
        'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0 default_hugepagesz=2M hugepages=N msr.allow_writes=on"'
    check "first edit backs up the original" "$(cat "$TMP/grub.bak")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0"'
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0 hugepages=1"\n' >"$TMP/grub"
    edit
    check "a second edit keeps the first backup" "$(cat "$TMP/grub.bak")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0"'
else
    printf 'SKIP: tune_kernel edit tests need GNU sed\n'
fi

(
    source "$ROOT/rigforge.sh"
    cd "$TMP/glob" || exit 1
    check "merge does not expand a glob token" "$(grub_merge_cmdline 'hugepages=1' 'quiet *')" 'quiet * hugepages=1'
    check "strip does not expand a glob token" "$(grub_strip_managed 'quiet * hugepages=1')" 'quiet *'
    printf 'GRUB_CMDLINE_LINUX_DEFAULT=%s\n' "'a b'" >"$TMP/g1"
    check "editable check refuses a single-quoted line" "$(grub_cmdline_editable "$TMP/g1" 2>/dev/null && echo yes || echo no)" no
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="a b"\n' >"$TMP/g1"
    check "editable check accepts a double-quoted line" "$(grub_cmdline_editable "$TMP/g1" && echo yes || echo no)" yes
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="a"\nGRUB_CMDLINE_LINUX_DEFAULT="b"\n' >"$TMP/g1"
    check "editable check refuses two assignment lines" "$(grub_cmdline_editable "$TMP/g1" 2>/dev/null && echo yes || echo no)" no
    printf 'GRUB_TIMEOUT=5\n' >"$TMP/g1"
    check "editable check accepts a file without the line" "$(grub_cmdline_editable "$TMP/g1" && echo yes || echo no)" yes
) 2>&1 | while IFS= read -r l; do
    case "$l" in PASS:*) echo "$l" ;; FAIL:*) echo "$l" ;; esac
done | tee "$TMP/sub.out"
PASS=$((PASS + $(grep -c '^PASS' "$TMP/sub.out")))
FAIL=$((FAIL + $(grep -c '^FAIL' "$TMP/sub.out")))

printf 'GRUB edit tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
