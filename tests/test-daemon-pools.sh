#!/usr/bin/env bash
# shellcheck disable=SC1090
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
PASS=0
FAIL=0
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"
}
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac }
assert_absent() { case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac }
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
NOHW="$SANDBOX/no-hardware"
export MEMINFO="$NOHW/meminfo" MSR_MODULE_DIR="$NOHW/msr-module"
export GOVERNOR_FILE="$NOHW/governor" HUGEPAGES_1G_NR="$NOHW/nr-1g"
export HUGEPAGES_1G_DIR="$NOHW/hugepages-1g" CPUFREQ_MAX="$NOHW/cpufreq-max"
export CPU_SYSFS="$NOHW/cpu" RAPL_DIR="$NOHW/powercap" DMI_DIR="$NOHW/dmi"
export SMT_CONTROL="$NOHW/smt" LOCKDOWN_FILE="$NOHW/lockdown" NODE_SYSFS="$NOHW/node"
export THERMAL_ZONE="$NOHW/thermal" HWMON_DIR="$NOHW/hwmon" CPUINFO="$NOHW/cpuinfo"
export DMIDECODE="$NOHW/dmidecode" RDMSR_BIN="$NOHW/rdmsr"
export BIN_DIR="$SANDBOX/bin-dir"
mkdir -p "$BIN_DIR"

eval "$(awk '/^make_stubs\(\) \{/{copy=1} /^STUBS=/{exit} copy{print}' "$ROOT/tests/run.sh")"
STUBS="$SANDBOX/stubs"
make_stubs "$STUBS"

eval "$(awk '/^parse_and_print\(\) \{/{copy=1} copy{print} copy && /^POOL=/{exit}' "$ROOT/tests/run.sh")"

source "$SCRIPT"
set +e
parse_and_print() {
    (
        CONFIG_JSON="$1"
        SCRIPT_DIR="$2"
        local var="$3"
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        printf '%s' "${!var}"
    )
}
parse_rc() {
    (
        CONFIG_JSON="$1"
        SCRIPT_DIR="$2"
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
    )
}

DOC="$SANDBOX/doctor"
mkdir -p "$DOC/msrmod"
printf '%s\n' 'HugePages_Total: 1' >"$DOC/meminfo_ok"
printf '%s\n' performance >"$DOC/gov_perf"
printf '%s\n' 1 >"$DOC/nr1g"

source "$ROOT/tests/daemon-pools.sh"

printf 'daemon pool tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
