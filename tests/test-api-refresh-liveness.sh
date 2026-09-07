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
