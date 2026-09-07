# shellcheck shell=bash disable=SC1090,SC2034,SC2329
# #454: doctor's diagnosis stays deterministic here. Real transient-systemd timing was checked
# separately because this dependency-free suite must also run on macOS.
RFS="$(mktemp -d "$SANDBOX/refresh-status.XXXXXX")"
printf '%s' '{"generated_at":"2026-09-07T04:00:00Z"}' >"$RFS/summary.json"
refresh_status() { # <next> <mtime> <now>
    (
        _next="$1" _mtime="$2" _now="$3"
        source "$SCRIPT"
        RIGFORGE_API_DATA="$RFS"
        systemctl() { case "$*" in *NextElapse*) printf '%s\n' "$_next" ;; *LastTrigger*) echo 'Sun 2026-09-06 23:59:45 CDT' ;; esac }
        stat() { echo "$_mtime"; }
        date() { if [ "$1" = -d ]; then echo "$_mtime"; else echo "$_now"; fi; }
        _api_refresh_status
    )
}
out="$(refresh_status 'Sun 2026-09-06 23:59:45 CDT' 1000 1030)"
assert_contains "doctor: scheduled refresh reports NEXT and payload age (#454)" "$out" "next: Sun 2026-09-06 23:59:45 CDT"
assert_contains "doctor: fresh payload reports its age (#454)" "$out" "payload age: 30s"
out="$(refresh_status n/a 1000 1030 || true)"
assert_contains "doctor: missing timer schedule is an issue (#454)" "$out" "has no next refresh"
out="$(refresh_status 'Sun 2026-09-06 23:59:45 CDT' 1000 1061 || true)"
assert_contains "doctor: old payload is called stale with its stamp (#454)" "$out" "sister feed is stale since 2026-09-07T04:00:00Z"
mv "$RFS/summary.json" "$RFS/summary.saved"
out="$(refresh_status 'Sun 2026-09-06 23:59:45 CDT' 1000 1030 || true)"
assert_contains "doctor: missing payload is stale, not healthy (#454)" "$out" "payload missing"
mv "$RFS/summary.saved" "$RFS/summary.json"

printf '{ "api": "enabled", "HOME_DIR": "%s/home", "pools": [{"url": "h:3333"}] }\n' "$DOC" >"$RFS/config.json"
run_refresh_doctor() { # <refresh status rc> <message>
    local refresh_rc="$1" refresh_message="$2"
    (
        source "$SCRIPT"
        OS_TYPE=Linux SCRIPT_DIR="$ROOT" CONFIG_JSON="$RFS/config.json"
        MEMINFO="$DOC/meminfo_ok" MSR_MODULE_DIR="$DOC/msrmod" GOVERNOR_FILE="$DOC/gov_perf" HUGEPAGES_1G_NR="$DOC/nr1g"
        DMIDECODE=/nonexistent CPUFREQ_MAX=/nonexistent CPU_SYSFS=/nonexistent
        _api_refresh_status() {
            printf '%s' "$refresh_message"
            return "$refresh_rc"
        }
        set +e
        PATH="$STUBS:$PATH" doctor 2>&1
    )
}
out="$(run_refresh_doctor 0 'sister feed refresh scheduled')"
assert_contains "doctor: healthy refresh status is reported (#454)" "$out" "sister feed refresh scheduled"
out="$(run_refresh_doctor 1 'sister feed is stale')"
assert_contains "doctor: failed refresh status is warned (#454)" "$out" "sister feed is stale"
assert_contains "doctor: failed refresh status counts as an issue (#454)" "$out" "issue(s) found"
