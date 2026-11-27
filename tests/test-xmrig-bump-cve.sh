#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/xmrig-bump.yml"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

sed -n '/scan_cves() {/,/^ \{10\}}/p' "$WF" >"$SCRATCH/scan_cves.sh"
[ -s "$SCRATCH/scan_cves.sh" ] || fail "xmrig-bump.yml lost the scan_cves function the daily monitor depends on"
source "$SCRATCH/scan_cves.sh"

[ "$(printf 'Fixes CVE-2024-1234 and cve-2024-1234 plus CVE-2023-99.\n' | scan_cves)" = "$(printf 'CVE-2023-99\nCVE-2024-1234')" ] ||
    fail "scan_cves must return unique uppercase CVE ids sorted one per line"
[ "$(printf 'see https://nvd.nist.gov/vuln/detail/CVE-2025-31337 for detail\n' | scan_cves)" = "CVE-2025-31337" ] ||
    fail "scan_cves must find CVE ids embedded in prose and urls"
[ -z "$(printf 'maintenance release, no advisories here\n' | scan_cves)" ] ||
    fail "scan_cves must return nothing for release notes without CVE ids"
[ -z "$(printf 'CVE-20-1 CVE-2024- CVE-20241-5\n' | scan_cves)" ] ||
    fail "scan_cves must reject malformed CVE-shaped strings"
[ "$(printf 'not-a-CVE-2024-5\n' | scan_cves)" = "CVE-2024-5" ] ||
    fail "scan_cves must report the CVE id found inside a longer token"
[ "$(printf 'x\0y CVE-2024-777 z\n' | scan_cves)" = "CVE-2024-777" ] ||
    fail "a NUL byte in the release body must not suppress later CVE ids"
[ "$(printf 'CVE-2024-1\nCVE-2024-2\nCVE-2024-3\nCVE-2024-4\nCVE-2024-5\nCVE-2024-6\nCVE-2024-7\n' | scan_cves | wc -l | tr -d ' ')" = "5" ] ||
    fail "scan_cves must cap the reported id count so the tracking issue title stays within GitHub limits"

grep -qE 'cron: "[0-9*]+ [0-9*]+ \* \* \*"' "$WF" ||
    fail "xmrig-bump.yml must fire every day (month, day-of-month and day-of-week fields of the cron must be *)"
grep -q 'sort -V' "$WF" ||
    fail "the workflow must order versions before bumping so a pulled release cannot open a downgrade PR"
grep -q 'refs/heads/' "$WF" ||
    fail "the bump step must detect a branch left by an interrupted run and reuse it instead of re-pushing"
grep -q -- '--add-label security' "$WF" ||
    fail "a bump whose release notes mention CVEs must carry the security label"
grep -q 'release notes mention' "$WF" ||
    fail "the tracking issue title/dedup key must name the release notes"
grep -q 'gh issue create' "$WF" ||
    fail "a CVE-mentioning release must open a tracking issue"

printf 'PASS: xmrig-bump scans release notes for CVEs daily and escalates via labelled PR and issue\n'
