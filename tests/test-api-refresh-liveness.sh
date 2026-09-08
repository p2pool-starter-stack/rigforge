# shellcheck shell=bash disable=SC1090,SC2034,SC2329
# #454: doctor's diagnosis stays deterministic here. Real transient-systemd timing was checked
# separately because this dependency-free suite must also run on macOS.
RFS="$(mktemp -d "$SANDBOX/refresh-status.XXXXXX")"
printf '%s' '{"generated_at":"2026-09-07T04:00:00Z"}' >"$RFS/summary.json"
refresh_status() { # <next> <mtime> <now> [refresh state]
    (
        _next="$1" _mtime="$2" _now="$3" _refresh_state="${4:-inactive}"
        source "$SCRIPT"
        RIGFORGE_API_DATA="$RFS"
        systemctl() { case "$*" in *NextElapse*) printf '%s\n' "$_next" ;; *LastTrigger*) echo 'Sun 2026-09-06 23:59:45 CDT' ;; *ActiveState*) echo "$_refresh_state" ;; esac }
        stat() { echo "$_mtime"; }
        date() { if [ "$1" = -d ]; then echo "$_mtime"; else echo "$_now"; fi; }
        sleep() { :; }
        _api_refresh_status
    )
}
out="$(refresh_status 'Sun 2026-09-06 23:59:45 CDT' 1000 1030)"
assert_contains "doctor: scheduled refresh reports NEXT and payload age (#454)" "$out" "next: Sun 2026-09-06 23:59:45 CDT"
assert_contains "doctor: fresh payload reports its age (#454)" "$out" "payload age: 30s"
printf '0\n' >"$RFS/systemctl.calls"
out="$({
    source "$SCRIPT"
    RIGFORGE_API_DATA="$RFS"
    systemctl() {
        case "$*" in
        *NextElapse*)
            n=$(cat "$RFS/systemctl.calls")
            printf '%s\n' "$((n + 1))" >"$RFS/systemctl.calls"
            [ "$n" -lt 2 ] && echo n/a || echo 'Sun 2026-09-06 23:59:45 CDT'
            ;;
        *LastTrigger*) echo 'Sun 2026-09-06 23:59:30 CDT' ;;
        esac
    }
    stat() { echo 1000; }
    date() { [ "$1" = -d ] && echo 1000 || echo 1030; }
    sleep() { :; }
    _api_refresh_status
} 2>&1)"
assert_contains "doctor: timer activation is retried (#460)" "$out" "refresh scheduled"
assert_eq "doctor: delayed timer schedule took three reads (#460)" "$(cat "$RFS/systemctl.calls")" "3"
printf '0\n' >"$RFS/systemctl.calls"
out="$({
    source "$SCRIPT"
    RIGFORGE_API_DATA="$RFS"
    systemctl() {
        case "$*" in
        *NextElapse*)
            n=$(cat "$RFS/systemctl.calls")
            printf '%s\n' "$((n + 1))" >"$RFS/systemctl.calls"
            [ "$n" -lt 5 ] && echo n/a || echo 'Sun 2026-09-06 23:59:45 CDT'
            ;;
        *LastTrigger*) echo never ;;
        *ActiveState*) echo inactive ;;
        esac
    }
    stat() { echo 1000; }
    date() { [ "$1" = -d ] && echo 1000 || echo 1030; }
    sleep() { :; }
    _api_refresh_status
} 2>&1)"
assert_contains "doctor re-reads NEXT after a refresh completes (#476)" "$out" "refresh scheduled"
assert_eq "doctor completion race takes the final timer read (#476)" "$(cat "$RFS/systemctl.calls")" "6"
out="$(refresh_status n/a 1000 1030 || true)"
assert_contains "doctor: missing timer schedule is an issue (#454)" "$out" "has no next refresh"
out="$(refresh_status n/a 1000 1030 active)"
assert_contains "doctor: active refresh needs no NEXT (#476)" "$out" "refresh in progress"
out="$(refresh_status n/a 1000 1030 activating)"
assert_contains "doctor: activating refresh needs no NEXT (#476)" "$out" "refresh in progress"
out="$(refresh_status n/a 1000 1061 active)"
assert_contains "doctor: active refresh may retain an old payload (#476)" "$out" "refresh in progress"
out="$(refresh_status 'Sun 2026-09-06 23:59:45 CDT' 1000 1061 || true)"
assert_contains "doctor: old payload is called stale with its stamp (#454)" "$out" "sister feed is stale since 2026-09-07T04:00:00Z"
mv "$RFS/summary.json" "$RFS/summary.saved"
out="$(refresh_status 'Sun 2026-09-06 23:59:45 CDT' 1000 1030 || true)"
assert_contains "doctor: missing payload is stale, not healthy (#454)" "$out" "payload missing"
out="$(refresh_status n/a 1000 1030 active || true)"
assert_contains "doctor: active refresh does not mask missing payload (#476)" "$out" "payload missing"
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

echo "== unit: e2e-real retries NEXT through timer activation (#458) =="
E2E_REFRESH_SRC="$(sed -n '/^check_api_refresh()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
assert_contains "e2e refresh check is extractable (#458)" "$E2E_REFRESH_SRC" "check_api_refresh()"
EFR="$(mktemp -d "$SANDBOX/e2e-refresh.XXXXXX")"
printf '{"api":"enabled"}\n' >"$EFR/config.json"
: >"$EFR/systemctl.calls"
out="$({
    eval "$E2E_REFRESH_SRC"
    HERE="$EFR"
    ok() { printf 'ok: %s\n' "$1"; }
    bad() { printf 'bad: %s\n' "$1"; }
    systemctl() {
        local n
        n=$(wc -l <"$EFR/systemctl.calls")
        printf 'x\n' >>"$EFR/systemctl.calls"
        [ "$n" -lt 2 ] || printf 'Mon 2099-01-01 00:00:00 UTC\n'
    }
    curl() { printf '{"generated_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
    sleep() { :; }
    check_api_refresh
} 2>&1)"
assert_contains "e2e refresh accepts NEXT after the activation window (#458)" "$out" "timer has a NEXT trigger"
assert_absent "e2e refresh does not false-red the activation window (#458)" "$out" "timer has no NEXT trigger"
assert_eq "e2e refresh retried twice before NEXT appeared (#458)" "$(wc -l <"$EFR/systemctl.calls" | tr -d ' ')" "3"
out="$({
    eval "$E2E_REFRESH_SRC"
    HERE="$EFR"
    ok() { printf 'ok: %s\n' "$1"; }
    bad() { printf 'bad: %s\n' "$1"; }
    systemctl() { printf 'n/a\n'; }
    curl() { printf '{"generated_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
    sleep() { :; }
    check_api_refresh
} 2>&1)"
assert_contains "e2e refresh still rejects a persistently absent NEXT (#458)" "$out" "timer has no NEXT trigger"
out="$({
    eval "$E2E_REFRESH_SRC"
    HERE="$EFR"
    ok() { printf 'ok: %s\n' "$1"; }
    bad() { printf 'bad: %s\n' "$1"; }
    systemctl() {
        case "$*" in *ActiveState*) echo active ;; *) echo n/a ;; esac
    }
    curl() { printf '{"generated_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
    sleep() { :; }
    check_api_refresh
} 2>&1)"
assert_contains "e2e refresh accepts an active refresh without NEXT (#476)" "$out" "refresh is in progress (active)"
assert_absent "e2e active refresh does not false-red missing NEXT (#476)" "$out" "timer has no NEXT trigger"
out="$({
    eval "$E2E_REFRESH_SRC"
    HERE="$EFR"
    ok() { printf 'ok: %s\n' "$1"; }
    bad() { printf 'bad: %s\n' "$1"; }
    systemctl() { case "$*" in *ActiveState*) echo active ;; *) echo n/a ;; esac }
    curl() { printf '{"generated_at":"2000-01-01T00:00:00Z"}\n'; }
    date() { [ "$1" = -d ] && echo 1000 || echo 1061; }
    sleep() { :; }
    check_api_refresh
} 2>&1)"
assert_contains "e2e active refresh may retain an old payload (#476)" "$out" "retained payload is available"
assert_absent "e2e active refresh does not false-red its retained payload (#476)" "$out" "no fresh generated_at"
printf '0\n' >"$EFR/systemctl.calls"
out="$({
    eval "$E2E_REFRESH_SRC"
    HERE="$EFR"
    ok() { printf 'ok: %s\n' "$1"; }
    bad() { printf 'bad: %s\n' "$1"; }
    systemctl() {
        case "$*" in
        *NextElapse*)
            n=$(cat "$EFR/systemctl.calls")
            printf '%s\n' "$((n + 1))" >"$EFR/systemctl.calls"
            [ "$n" -lt 5 ] && echo n/a || echo 'Mon 2099-01-01 00:00:00 UTC'
            ;;
        *ActiveState*) echo inactive ;;
        esac
    }
    curl() { printf '{"generated_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
    sleep() { :; }
    check_api_refresh
} 2>&1)"
assert_contains "e2e refresh re-reads NEXT after completion (#476)" "$out" "timer has a NEXT trigger"
assert_absent "e2e completion race does not false-red (#476)" "$out" "timer has no NEXT trigger"

MINER_LOG_SRC="$(sed -n '/^miner_log()/,/^fresh_share()/p' "$ROOT/tests/e2e-real.sh")"
eval "$MINER_LOG_SRC"
printf 'accepted (1/0)\n' >"$EFR/large.log"
awk 'BEGIN { for (i=0; i<200000; i++) print "long trailing log row" }' >>"$EFR/large.log"
if miner_log_has 'accepted (' "$EFR/large.log"; then ok "e2e large-log match cannot false-fail from producer SIGPIPE (#481/#484)"; else bad "e2e large-log match cannot false-fail from producer SIGPIPE (#481/#484)" "accepted line not found"; fi
RIGFORGE_APPLIANCE=1
journalctl() { printf '\033[1;32mnew job from pithead:3333\033[0m\n'; }
if miner_log_has 'new job from' /nonexistent; then ok "e2e appliance journal matching ignores ANSI color (#483/#484)"; else bad "e2e appliance journal matching ignores ANSI color (#483/#484)" "colored job line not found"; fi
unset RIGFORGE_APPLIANCE
if fresh_share 2 1; then ok "fresh-share proof accepts a counter increase (#472/#484)"; else bad "fresh-share proof accepts a counter increase (#472/#484)" "counter did not increase"; fi
fresh_share 1 1 && bad "fresh-share proof accepted retained history (#472)" "counter did not increase" || ok "fresh-share proof rejects retained history (#472/#484)"

echo "== unit: e2e-real watchdog cleanup restores prior service state (#462) =="
WD_CLEANUP_SRC="$(sed -n '/^_watchdog_cleanup()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
watchdog_cleanup_case() { # <was active> <start succeeds> [cleanup state]
    local was_active="$1" start_ok="$2" state="${3:-inactive}" w
    w="$(mktemp -d "$SANDBOX/watchdog-cleanup.XXXXXX")"
    printf '{}\n' >"$w/config.json"
    printf '{}\n' >"$w/saved.json"
    mkdir "$w/worker"
    (
        eval "$WD_CLEANUP_SRC"
        HERE="$w" WD_CLEANUP_DONE=0 WD_SAVED_CFG="$w/saved.json" WD_WORKER_ROOT="$w/worker" WD_WAS_ACTIVE="$was_active"
        RIGFORGE=rigforge_stub
        rigforge_stub() {
            case "$1" in
            start)
                [ "$start_ok" = 1 ] || return 1
                state=active
                ;;
            stop) state=inactive ;;
            esac
        }
        systemctl() { [ "$state" = active ]; }
        _watchdog_cleanup >/dev/null 2>&1
        rc=$?
        printf '%s:%s\n' "$rc" "$state"
    )
}
assert_eq "watchdog cleanup restarts a previously active miner (#462)" "$(watchdog_cleanup_case 1 1)" "0:active"
assert_eq "watchdog cleanup preserves a previously stopped miner (#462)" "$(watchdog_cleanup_case 0 1)" "0:inactive"
assert_eq "watchdog cleanup stops a previously stopped miner that became active (#462)" "$(watchdog_cleanup_case 0 1 active)" "0:inactive"
assert_eq "watchdog cleanup fails when prior active state cannot be restored (#462)" "$(watchdog_cleanup_case 1 0)" "1:inactive"
