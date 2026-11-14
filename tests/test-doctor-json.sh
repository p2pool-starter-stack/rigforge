#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2329
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$ROOT/rigforge.sh}"
TMP="$(mktemp -d)"
PASS=0
FAIL=0
trap 'rm -rf "$TMP"' EXIT

PROBES="$TMP/probes"
BIN="$TMP/bin"
mkdir -p "$PROBES/msr" "$BIN" "$TMP/state" "$TMP/no-config" "$TMP/report-tmp-success" "$TMP/report-tmp-failure"
chmod 700 "$TMP/report-tmp-success" "$TMP/report-tmp-failure"
printf 'HugePages_Total: 8\n' >"$PROBES/mem-ok"
printf 'HugePages_Total: 0\n' >"$PROBES/mem-bad"
printf 'flags : aes avx2 pdpe1gb\n' >"$PROBES/cpuinfo"
printf 'performance\n' >"$PROBES/governor-ok"
printf 'powersave\n' >"$PROBES/governor-warn"
printf '2\n' >"$PROBES/1gb-ok"
printf '0\n' >"$PROBES/1gb-warn"
printf '[none] integrity confidentiality\n' >"$PROBES/lockdown-ok"
printf 'none [integrity] confidentiality\n' >"$PROBES/lockdown-bad"
printf '{"api":"enabled","control":"enabled","DONATION":0,"pools":[]}' >"$TMP/state/config.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${STUB_OS:-Linux}"\n' >"$BIN/uname"
printf '#!/usr/bin/env bash\n[ "${STUB_SERVICE_ACTIVE:-yes}" = yes ]\n' >"$BIN/systemctl"
printf '#!/usr/bin/env bash\nprintf "Model name: Synthetic CPU\\n"\n' >"$BIN/lscpu"
chmod +x "$BIN/uname" "$BIN/systemctl" "$BIN/lscpu"

ok() {
    PASS=$((PASS + 1))
    printf '  ok - %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  not ok - %s: %s\n' "$1" "$2"
}
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_jq() { if jq -e "$2" "$1" >/dev/null 2>&1; then ok "$3"; else bad "$3" "filter failed: $2"; fi; }
assert_has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3]" ;; esac }
assert_lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3]" ;; *) ok "$1" ;; esac }

run_report() {
    local scenario="$1" out err rc=0
    out="$TMP/$scenario.json"
    err="$TMP/$scenario.err"
    (
        TMPDIR="$TMP/report-tmp-success"
        export TMPDIR
        source "$SCRIPT"
        doctor() {
            case "$scenario" in
            healthy)
                _ck_ok "service ready" service
                _ck_ok "pages ready" hugepages
                _ck_ok "large pages ready" hugepages-1gb
                _ck_ok "governor ready" cpu-governor
                _ck_ok "module ready" msr-module
                _ck_ok "lockdown clear" kernel-lockdown
                ;;
            critical)
                _ck_warn "service unavailable" service
                return 1
                ;;
            advisory)
                _ck_warn "large pages unavailable" hugepages-1gb
                ;;
            serialization)
                local message
                printf -v message 'line one\nline\ttwo "quoted" \\slash — snowman ☃'
                _ck_info "$message" service
                ;;
            esac
        }
        doctor_json
    ) >"$out" 2>"$err" || rc=$?
    printf '%s' "$rc"
}

run_actual() {
    local scenario="$1" mem msr gov onegb lockdown active out err rc=0 plain_rc=0
    out="$TMP/actual-$scenario.json"
    err="$TMP/actual-$scenario.err"
    case "$scenario" in
    healthy)
        mem="$PROBES/mem-ok" msr="$PROBES/msr" gov="$PROBES/governor-ok"
        onegb="$PROBES/1gb-ok" lockdown="$PROBES/lockdown-ok" active=yes
        ;;
    advisory)
        mem="$PROBES/mem-ok" msr="$PROBES/msr" gov="$PROBES/governor-warn"
        onegb="$PROBES/1gb-warn" lockdown="$PROBES/lockdown-ok" active=yes
        ;;
    critical)
        mem="$PROBES/mem-bad" msr="$PROBES/missing-msr" gov="$PROBES/governor-ok"
        onegb="$PROBES/1gb-ok" lockdown="$PROBES/lockdown-bad" active=no
        ;;
    esac
    run_actual_cli() {
        PATH="$BIN:$PATH" STUB_OS=Linux STUB_SERVICE_ACTIVE="$active" RIGFORGE_HOME="$TMP/no-config" \
            MEMINFO="$mem" CPUINFO="$PROBES/cpuinfo" MSR_MODULE_DIR="$msr" GOVERNOR_FILE="$gov" \
            HUGEPAGES_1G_NR="$onegb" LOCKDOWN_FILE="$lockdown" DMIDECODE="$PROBES/missing-dmidecode" \
            CPUFREQ_MAX="$PROBES/missing-frequency" CPU_SYSFS="$PROBES/missing-cpus" \
            DMI_DIR="$PROBES/missing-dmi" SMT_CONTROL="$PROBES/missing-smt" NODE_SYSFS="$PROBES/missing-nodes" \
            bash "$SCRIPT" "$@"
    }
    run_actual_cli doctor --json >"$out" 2>"$err" || rc=$?
    run_actual_cli doctor >"$TMP/actual-$scenario.plain" 2>&1 || plain_rc=$?
    printf '%s' "$plain_rc" >"$TMP/actual-$scenario.plain.rc"
    printf '%s' "$rc"
}

assert_human_matches_json() {
    local json="$1" err="$2" message
    if ! jq -e '.checks | type == "array" and length > 0' "$json" >/dev/null 2>&1; then
        bad "$3" "JSON has no checks"
        return
    fi
    while IFS= read -r message; do
        case "$(cat "$err")" in
        *"$message"*) ;;
        *)
            bad "$3" "human report missing JSON message [$message]"
            return
            ;;
        esac
    done < <(jq -r '.checks[].message' "$json")
    ok "$3"
}

run_connected() {
    local name="${1:-connected}" pool_status="${2:-connected	synthetic-pool	4	2}" config="${3:-$TMP/state/config.json}" rc=0
    (
        PATH="$BIN:$PATH"
        source "$SCRIPT"
        OS_TYPE=Linux
        CONFIG_JSON="$config"
        MEMINFO="$PROBES/mem-ok"
        CPUINFO="$PROBES/cpuinfo"
        MSR_MODULE_DIR="$PROBES/msr"
        GOVERNOR_FILE="$PROBES/governor-ok"
        HUGEPAGES_1G_NR="$PROBES/1gb-ok"
        LOCKDOWN_FILE="$PROBES/lockdown-ok"
        DMIDECODE="$PROBES/missing-dmidecode"
        CPUFREQ_MAX="$PROBES/missing-frequency"
        CPU_SYSFS="$PROBES/missing-cpus"
        DMI_DIR="$PROBES/missing-dmi"
        SMT_CONTROL="$PROBES/missing-smt"
        NODE_SYSFS="$PROBES/missing-nodes"
        systemctl() { [ "${STUB_SERVICE_ACTIVE:-yes}" = yes ]; }
        curl() { printf '%s' "${STUB_CURL_BODY:-}"; }
        _api_refresh_status() { printf 'refresh current\n'; }
        _read_api_summary() { printf '{"donate_level":0}\n'; }
        _msr_log_status() { printf 'none\t'; }
        _pool_conn_status() { printf '%s\n' "$pool_status"; }
        _bearer_curl() { printf '200\n'; }
        _worker_root_from_config() { printf '%s\n' "$PROBES/missing-worker"; }
        doctor_json
    ) >"$TMP/$name.json" 2>"$TMP/$name.err" || rc=$?
    printf '%s' "$rc"
}

run_record_failure() {
    local rc=0
    (
        TMPDIR="$TMP/report-tmp-failure"
        export TMPDIR
        source "$SCRIPT"
        jq() {
            if [ "${1:-}" = -cn ]; then return 1; fi
            command jq "$@"
        }
        doctor() {
            _ck_ok "record must persist" service
            return 0
        }
        doctor_json
    ) >"$TMP/record-failure.json" 2>"$TMP/record-failure.err" || rc=$?
    printf '%s' "$rc"
}

echo "== doctor --json focused regression =="

rc="$(run_report healthy)"
assert_eq "healthy report exits zero" "$rc" 0
assert_jq "$TMP/healthy.json" 'type == "object" and (.version | type == "string" and length > 0) and .exit == 0 and .summary == {ok:6,warn:0,fail:0,info:0} and ([.checks[].id] == ["service","hugepages","hugepages-1gb","cpu-governor","msr-module","kernel-lockdown"]) and all(.checks[]; (.status == "ok") and (.message | type == "string"))' "healthy JSON has the documented shape and stable IDs"
assert_has "healthy human report stays on stderr" "$(cat "$TMP/healthy.err")" "service ready"
assert_jq "$TMP/healthy.json" '[., inputs] | length == 1' "healthy stdout contains exactly one JSON document"
assert_lacks "healthy stdout contains no human glyphs" "$(cat "$TMP/healthy.json")" "✓"

rc="$(run_report critical)"
assert_eq "critical report preserves doctor exit" "$rc" 1
assert_jq "$TMP/critical.json" '.exit == 1 and .summary == {ok:0,warn:1,fail:0,info:0} and .checks == [{id:"service",status:"warn",message:"service unavailable"}]' "critical health uses exit as authority and keeps warning status"
assert_has "critical human report stays on stderr" "$(cat "$TMP/critical.err")" "service unavailable"

rc="$(run_report advisory)"
assert_eq "advisory-only report exits zero" "$rc" 0
assert_jq "$TMP/advisory.json" '.exit == 0 and .summary == {ok:0,warn:1,fail:0,info:0} and .checks[0].id == "hugepages-1gb"' "advisory warning does not manufacture failure"

rc="$(run_report serialization)"
assert_eq "serialization report exits zero" "$rc" 0
expected="$(printf 'line one\nline\ttwo "quoted" \\slash — snowman ☃')"
actual="$(jq -r '.checks[0].message' "$TMP/serialization.json" 2>/dev/null)"
assert_eq "JSON safely round-trips multiline, tabs, quotes, slashes, and Unicode" "$actual" "$expected"
assert_jq "$TMP/serialization.json" '.summary == {ok:0,warn:0,fail:0,info:1} and .checks[0].status == "info"' "serialization row keeps info status"

rc="$(run_record_failure)"
assert_eq "record encoding failure makes doctor JSON fail" "$rc" 1
assert_jq "$TMP/record-failure.json" '.exit == 1' "record encoding failure is authoritative in the report"
assert_eq "successful reports remove recorder temp files" "$(find "$TMP/report-tmp-success" -mindepth 1 -print -quit)" ""
assert_eq "failed reports remove recorder temp files" "$(find "$TMP/report-tmp-failure" -mindepth 1 -print -quit)" ""

rc="$(run_actual healthy)"
assert_eq "actual healthy Linux doctor exits zero" "$rc" 0
assert_jq "$TMP/actual-healthy.json" '.exit == 0 and .summary.fail == 0 and ([.checks[] | select(.id == "service" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "hugepages" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "hugepages-1gb" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "cpu-governor" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "msr-module" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "kernel-lockdown" and .status == "ok")] | length == 1)' "actual healthy doctor assigns all six stable core IDs"
assert_human_matches_json "$TMP/actual-healthy.json" "$TMP/actual-healthy.err" "actual healthy JSON and human reports contain the same checks"
assert_eq "actual healthy JSON preserves plain doctor's exit" "$rc" "$(cat "$TMP/actual-healthy.plain.rc")"
assert_eq "actual healthy JSON preserves plain doctor's human report" "$(cat "$TMP/actual-healthy.err")" "$(cat "$TMP/actual-healthy.plain")"

rc="$(run_actual advisory)"
assert_eq "actual advisory-only Linux doctor exits zero" "$rc" 0
assert_jq "$TMP/actual-advisory.json" '.exit == 0 and .summary.fail == 0 and ([.checks[] | select(.id == "hugepages-1gb" and .status == "warn")] | length == 1) and ([.checks[] | select(.id == "cpu-governor" and .status == "warn")] | length == 1)' "actual advisory outcomes keep stable IDs and warning status"
assert_human_matches_json "$TMP/actual-advisory.json" "$TMP/actual-advisory.err" "actual advisory JSON and human reports contain the same checks"
assert_eq "actual advisory JSON preserves plain doctor's exit" "$rc" "$(cat "$TMP/actual-advisory.plain.rc")"
assert_eq "actual advisory JSON preserves plain doctor's human report" "$(cat "$TMP/actual-advisory.err")" "$(cat "$TMP/actual-advisory.plain")"

rc="$(run_actual critical)"
assert_eq "actual critical Linux doctor preserves exit one" "$rc" 1
assert_jq "$TMP/actual-critical.json" '.exit == 1 and .summary.fail == 0 and ([.checks[] | select(.id == "service" and .status == "warn")] | length == 1) and ([.checks[] | select(.id == "hugepages" and .status == "warn")] | length == 1) and ([.checks[] | select(.id == "msr-module" and .status == "warn")] | length == 1) and ([.checks[] | select(.id == "kernel-lockdown" and .status == "warn")] | length == 1)' "actual critical outcomes use exit as authority and retain warning status"
assert_human_matches_json "$TMP/actual-critical.json" "$TMP/actual-critical.err" "actual critical JSON and human reports contain the same checks"
assert_eq "actual critical JSON preserves plain doctor's exit" "$rc" "$(cat "$TMP/actual-critical.plain.rc")"
assert_eq "actual critical JSON preserves plain doctor's human report" "$(cat "$TMP/actual-critical.err")" "$(cat "$TMP/actual-critical.plain")"

rc="$(run_connected)"
assert_eq "mocked connected doctor exits zero without network access" "$rc" 0
assert_jq "$TMP/connected.json" '.exit == 0 and ([.checks[] | select(.id == "api-refresh" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "donation" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "pool-connection" and .status == "ok")] | length == 1) and ([.checks[] | select(.id == "control" and .status == "ok")] | length == 1)' "mocked API, donation, pool, and control probes keep explicit IDs"
assert_human_matches_json "$TMP/connected.json" "$TMP/connected.err" "mocked connected JSON and human reports contain the same checks"

rc="$(run_connected daemon-synced "$(printf 'daemon\tdaemon+http://node:18081\t123\tsynced')")"
assert_eq "synced daemon-pool doctor exits zero" "$rc" 0
assert_jq "$TMP/daemon-synced.json" '.exit == 0 and all(.checks[]; .id != "") and ([.checks[] | select(.id == "pool-connection" and .status == "ok")] | length == 1)' "synced daemon-pool node health keeps the pool-connection ID"
rc="$(run_connected daemon-syncing "$(printf 'daemon\tdaemon+http://node:18081\t123\tsyncing')")"
assert_jq "$TMP/daemon-syncing.json" '.exit == 1 and all(.checks[]; .id != "") and ([.checks[] | select(.id == "pool-connection" and .status == "warn")] | length == 1)' "syncing daemon-pool node health keeps the pool-connection ID"
rc="$(run_connected daemon-down daemon-down)"
assert_jq "$TMP/daemon-down.json" '.exit == 1 and all(.checks[]; .id != "") and ([.checks[] | select(.id == "pool-connection" and .status == "warn")] | length == 1)' "unavailable daemon-pool node keeps the pool-connection ID"
printf '{"api":"enabled","DONATION":0,"pools":[{"url":"daemon+http://node.invalid:18081","user":"4synthetic"}]}' >"$TMP/state/daemon-config.json"
rc="$(STUB_SERVICE_ACTIVE=no STUB_CURL_BODY='{"jsonrpc":"2.0","id":"rigforge","result":{"status":"OK","height":321,"synchronized":true}}' run_connected daemon-stopped "" "$TMP/state/daemon-config.json")"
assert_jq "$TMP/daemon-stopped.json" 'all(.checks[]; .id != "") and ([.checks[] | select(.id == "pool-connection" and .status == "ok" and (.message | contains("height 321")))] | length == 1)' "stopped daemon-pool doctor reads get_info under the pool-connection ID"

unsupported_rc=0
PATH="$BIN:$PATH" STUB_OS=Unsupported RIGFORGE_HOME="$TMP/no-config" bash "$SCRIPT" doctor --json >"$TMP/unsupported.json" 2>"$TMP/unsupported.err" || unsupported_rc=$?
assert_eq "unsupported OS report exits zero" "$unsupported_rc" 0
assert_jq "$TMP/unsupported.json" '.exit == 0 and .summary == {ok:0,warn:0,fail:0,info:0} and .checks == []' "unsupported OS still emits a complete report"
assert_has "unsupported OS human warning stays on stderr" "$(cat "$TMP/unsupported.err")" "Linux-only"

extra_rc=0
bash "$SCRIPT" doctor --json extra >"$TMP/extra.out" 2>"$TMP/extra.err" || extra_rc=$?
assert_eq "doctor --json rejects extra arguments" "$extra_rc" 1
assert_has "extra argument failure is explicit" "$(cat "$TMP/extra.err")" "Unexpected argument"
assert_eq "invalid invocation emits no JSON" "$(cat "$TMP/extra.out")" ""

help_out="$(bash "$SCRIPT" help 2>&1)"
assert_has "help advertises doctor --json" "$help_out" "doctor --json"
completion_out="$(bash "$SCRIPT" completion bash 2>&1)"
assert_has "bash completion offers doctor JSON flag" "$completion_out" "doctor) COMPREPLY"
assert_has "bash completion contains JSON flag" "$completion_out" "--json"

assert_lacks "JSON stdout has no ANSI escapes" "$(cat "$TMP/healthy.json")" "$(printf '\033')"
assert_lacks "JSON-mode human stderr has no ANSI escapes when captured" "$(cat "$TMP/healthy.err")" "$(printf '\033')"

printf '\ndoctor JSON tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
