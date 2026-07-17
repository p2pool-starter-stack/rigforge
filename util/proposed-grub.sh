#!/usr/bin/env bash
#
# Kernel Boot Parameter Calculator for RandomX Mining
#
# Analyzes hardware topology (L3 Cache, Sockets) to recommend optimal
# GRUB configuration for HugePages (1GB/2MB) and MSR registers.
#
# No `set -e`: the hardware probes (lscpu/grep) intentionally fall back to safe defaults when a tool or
# field is missing, so a non-zero probe must not abort. `-u`/pipefail still catch real mistakes.
set -uo pipefail

# Parse arguments by EXACT match (a substring test would let a stray "-q" inside a path flip QUIET).
QUIET=0
RUNTIME=0
for arg in "$@"; do
    case "$arg" in
    -q | --quiet) QUIET=1 ;;
    --runtime) RUNTIME=1 ;;
    esac
done

# Hardware probe paths. Overridable so the calculation can be tested off a Linux box (the defaults
# are the real kernel locations, so normal invocation is unchanged).
CPUINFO="${CPUINFO:-/proc/cpuinfo}"
HUGEPAGES_1G_NR="${HUGEPAGES_1G_NR:-/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages}"

# --- 1. Hardware Topology Discovery ---

# Extract L3 Cache size and normalize to Megabytes
# Output format varies (e.g., "32M", "32768K"), so we strip non-numeric characters.
L3_RAW=$(lscpu | awk '/L3 cache/{print $3$4; exit}')
L3_MB="${L3_RAW//[!0-9]/}"

# Convert Kilobytes to Megabytes if necessary
if [[ "$L3_RAW" == *K* ]]; then
    L3_MB=$((L3_MB / 1024))
fi
if [[ -z "$L3_MB" ]]; then
    L3_MB=4
fi

# Detect Physical CPU Sockets (for display / NUMA fallback).
SOCKETS=$(lscpu | awk '/Socket\(s\):/{print $2; exit}')
if [[ -z "$SOCKETS" ]]; then
    SOCKETS=1
fi

# Detect NUMA nodes. RandomX fast mode (with XMRig's numa=on) keeps a NUMA-LOCAL copy of the ~2080MB
# dataset PER NODE, so the 1GB-page reservation must scale with NUMA NODES, not sockets: a single-socket
# EPYC can expose 2/4/8 NUMA nodes (NPS / L3-as-NUMA), so counting sockets reserves only one node's worth
# and starves every other node of 1GB backing after a reboot (a large RandomX hashrate hit). Prefer
# lscpu's count, then count sysfs nodes, then fall back to the socket count, then 1.
NODE_SYS="${NODE_SYS:-/sys/devices/system/node}"
NUMA_NODES=$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\):/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
if ! { [ -n "$NUMA_NODES" ] && [ "$NUMA_NODES" -gt 0 ]; } 2>/dev/null; then
    NUMA_NODES=$(find "$NODE_SYS" -maxdepth 1 -name 'node[0-9]*' 2>/dev/null | wc -l | tr -d ' ')
fi
if ! { [ -n "$NUMA_NODES" ] && [ "$NUMA_NODES" -gt 0 ]; } 2>/dev/null; then
    NUMA_NODES="$SOCKETS"
fi

# --- 2. Resource Calculation ---

# RandomX Requirement: 2MB L3 Cache per mining thread. Callers can override this estimate with RX_THREADS
# (#65): `setup` passes the tuned cpu.rx so the reservation matches the threads we actually run, and `tune`
# uses it to price a candidate thread count's huge-page need. Falls back to the L3 estimate when unset.
if [ -n "${RX_THREADS:-}" ] && [ "$RX_THREADS" -gt 0 ] 2>/dev/null; then
    THREADS="$RX_THREADS"
else
    THREADS=$((L3_MB / 2))
fi

# First-class thread cap (#305): a config `threads` ceiling, passed as THREADS_CAP, clamps the count the
# reservation is sized for — min(computed, cap). Lets a co-located miner (pithead#593) leave the stack
# cores free without RigForge over-reserving. A cap ABOVE the computed count is a no-op (it's a ceiling).
if [ -n "${THREADS_CAP:-}" ] && [ "$THREADS_CAP" -gt 0 ] 2>/dev/null && [ "$THREADS" -gt "$THREADS_CAP" ]; then
    THREADS="$THREADS_CAP"
fi

# Reservation headroom for a co-resident workload (#305): RESERVE_EXTRA_MB (from the hugepages_reserve_extra_mb
# config key) is MB the caller wants left for the rest of the box (e.g. a pithead stack's ~2874MB of 2MB pages).
# RigForge stays the sole writer of the reservation; it just sizes the pool for stack + miner. Converted
# to 2MB pages (round up) and added to every 2MB total so both the GRUB reservation and the runtime pool
# (the kernel's shared hugepage pool, which both workloads draw from) grow by the same amount.
EXTRA_2MB_PAGES=0
if [ -n "${RESERVE_EXTRA_MB:-}" ] && [ "$RESERVE_EXTRA_MB" -gt 0 ] 2>/dev/null; then
    EXTRA_2MB_PAGES=$(((RESERVE_EXTRA_MB + 1) / 2))
fi

# 1GB HugePages: 3 per NUMA node — each node holds its own ~2080MB RandomX dataset copy (rounds up to 3GB).
TOTAL_GB_PAGES=$((3 * NUMA_NODES))

# 2MB HugePages: Reserve for JIT compiler and scratchpads (128 base + 1 per thread + buffer), plus any
# co-resident headroom.
TOTAL_2MB_PAGES=$((128 + THREADS + 10 + EXTRA_2MB_PAGES))

# Fallback Strategy (Pure 2MB): Covers Dataset (2080MB) + Overhead + JIT + co-resident headroom.
# 1168 pages * 2MB = ~2336MB per NUMA node (Provides ~250MB buffer for fragmentation). Scales per node
# because, like the 1GB path, each NUMA node holds its own dataset copy.
BASE_2MB_PAGES=1168
TOTAL_2MB_FALLBACK=$(((BASE_2MB_PAGES * NUMA_NODES) + THREADS + 50 + EXTRA_2MB_PAGES))

if [ "$RUNTIME" -eq 1 ]; then
    # Check if 1GB pages are already allocated
    PAGES_1GB=0
    if [ -f "$HUGEPAGES_1G_NR" ]; then
        PAGES_1GB=$(<"$HUGEPAGES_1G_NR")
    fi

    if [ "$PAGES_1GB" -gt 0 ]; then
        echo "$TOTAL_2MB_PAGES"
    else
        echo "$TOTAL_2MB_FALLBACK"
    fi
    exit 0
fi

# --- 3. Configuration Generation ---

# Check for 1GB HugePage support (pdpe1gb flag)
if grep -q "pdpe1gb" "$CPUINFO" 2>/dev/null; then
    # Strategy: Use 1GB pages for dataset, 2MB for JIT
    NEW_GRUB="quiet splash hugepagesz=1G hugepages=$TOTAL_GB_PAGES hugepagesz=2M hugepages=$TOTAL_2MB_PAGES default_hugepagesz=2M msr.allow_writes=on"
else
    # Fallback Strategy: Use only 2MB pages
    NEW_GRUB="quiet splash default_hugepagesz=2M hugepages=$TOTAL_2MB_FALLBACK msr.allow_writes=on"
fi

# --- 4. Output ---

if [ "$QUIET" -eq 1 ]; then
    echo "$NEW_GRUB"
else
    echo "--- Hardware Analysis ---"
    echo "L3 Cache:      ${L3_MB} MB"
    echo "CPU Sockets:   $SOCKETS"
    echo "NUMA Nodes:    $NUMA_NODES (1GB dataset reservation scales with this)"
    echo "Max Threads:   $THREADS (Based on 2MB L3/thread)"
    echo "-------------------------"
    echo "Proposed GRUB Configuration:"
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_GRUB\""
fi
