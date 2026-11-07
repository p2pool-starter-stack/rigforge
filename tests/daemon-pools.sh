#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329

if ! declare -F parse_config >/dev/null; then
    source "$SCRIPT"
    set +e
fi

echo "== unit: daemon pool parsing and validation (#528) =="

daemon_target=$(jq -cnr --argjson config "{ $POOL }" '$config.pools[0].url')
daemon_ipv4=$(grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+' "$ROOT/tests/run.sh" | head -n 1)
daemon_ipv6=$(sed -n 's/.*"url":"\(\[[0-9A-Fa-f:]*\]:[0-9]*\)".*/\1/p' "$ROOT/tests/run.sh" | head -n 1)
daemon_proxy=$(sed -n 's/.*socks5[^0-9]*\([0-9][0-9.]*:[0-9][0-9]*\).*/\1/p' "$ROOT/tests/run.sh" | head -n 1)
daemon_pin=$(grep -Eo '[A-Fa-f0-9]{64}' "$ROOT/tests/run.sh" | head -n 1)

daemon_conf() {
    local body
    body=$(jq -cn --arg url "$2" --argjson extra "$3" '{pools: [({url: $url} + $extra)]}')
    mkconf "$1" "$body"
}

daemon_parse() {
    (
        CONFIG_JSON="$1"
        SCRIPT_DIR="$ROOT"
        set +e
        if [ "$#" -gt 1 ]; then
            PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1 || exit $?
            eval "printf '%s' \"\${$2}\""
        else
            PATH="$STUBS:$PATH" parse_config 2>&1
        fi
    )
}

daemon_parse_rc() {
    daemon_parse "$1" >/dev/null 2>&1
}
for scheme in daemon+http daemon+https; do
    c=$(daemon_conf daemon_scheme "$scheme://$daemon_target" '{"daemon":true}')
    daemon_parse_rc "$c" "$ROOT"
    assert_rc "$scheme URL accepted (#528)" "$?" "0"
done

c=$(daemon_conf daemon_inferred "daemon+http://$daemon_target" '{}')
daemon_parse_rc "$c" "$ROOT"
assert_rc "daemon scheme infers daemon mode (#528)" "$?" "0"
assert_eq "inferred daemon mode reaches the miner pool (#528)" \
    "$(daemon_parse "$c" POOLS_JSON | jq -r '.[0].daemon')" "true"

c=$(daemon_conf daemon_false_bare "$daemon_target" '{"daemon":false}')
daemon_parse_rc "$c" "$ROOT"
assert_rc "explicit daemon:false stays valid for Stratum (#528)" "$?" "0"
assert_eq "explicit daemon:false is preserved (#528)" \
    "$(daemon_parse "$c" POOLS_JSON | jq -r '.[0].daemon')" "false"

for target in "$daemon_ipv4" "$daemon_ipv6"; do
    c=$(daemon_conf daemon_host "daemon+http://$target" '{"daemon":true}')
    daemon_parse_rc "$c" "$ROOT"
    assert_rc "daemon URL reuses host validation for $target (#528)" "$?" "0"
done

c=$(daemon_conf daemon_bare "$daemon_target" '{"daemon":true}')
daemon_parse_rc "$c" "$ROOT"
assert_rc "bare host and daemon:true accepted (#528)" "$?" "0"

credential_marker=daemon-credential-marker
c=$(daemon_conf daemon_credentials "daemon+http://$credential_marker@$daemon_target" '{"daemon":true}')
out=$(daemon_parse "$c")
assert_rc "daemon URL credentials rejected (#528)" "$?" "1"
assert_absent "daemon URL rejection does not echo credentials (#528)" "$out" "$credential_marker"

c=$(daemon_conf daemon_bare_credentials "$credential_marker@$daemon_target" '{"daemon":true}')
out=$(daemon_parse "$c")
assert_rc "bare daemon URL credentials rejected (#528)" "$?" "1"
assert_absent "bare daemon credential rejection stays redacted (#528)" "$out" "$credential_marker"

for suffix in /rpc '?rpc=true'; do
    c=$(daemon_conf daemon_url_suffix "daemon+http://$daemon_target$suffix" '{"daemon":true}')
    daemon_parse "$c" >/dev/null
    assert_rc "daemon URL suffix '$suffix' rejected (#528)" "$?" "1"
done

daemon_host=${daemon_target%:*}
for port in 0 65536; do
    c=$(daemon_conf daemon_bad_port "daemon+http://$daemon_host:$port" '{"daemon":true}')
    daemon_parse "$c" >/dev/null
    assert_rc "daemon URL rejects port bound $port (#528)" "$?" "1"
done

c=$(daemon_conf daemon_false "daemon+http://$daemon_target" '{"daemon":false}')
out=$(daemon_parse "$c")
assert_rc "daemon scheme with daemon:false rejected (#528)" "$?" "1"
assert_contains "daemon:false rejection names daemon (#528)" "$out" "daemon"

for value in '"true"' '1' 'null' '{}'; do
    c=$(daemon_conf daemon_type "$daemon_target" "{\"daemon\":$value}")
    out=$(daemon_parse "$c")
    assert_rc "daemon rejects non-boolean $value (#528)" "$?" "1"
    assert_contains "daemon type rejection names daemon (#528)" "$out" "daemon"
done

for key in daemon-poll-interval daemon-job-timeout; do
    c=$(daemon_conf daemon_positive "$daemon_target" "{\"daemon\":true,\"$key\":1}")
    daemon_parse_rc "$c" "$ROOT"
    assert_rc "$key accepts a positive integer (#528)" "$?" "0"
    for value in 0 -1 1.5 '"1"' 'null' 'true'; do
        c=$(daemon_conf daemon_bad_number "$daemon_target" "{\"daemon\":true,\"$key\":$value}")
        out=$(daemon_parse "$c")
        assert_rc "$key rejects $value (#528)" "$?" "1"
        assert_contains "$key rejection names the key (#528)" "$out" "$key"
    done
    c=$(daemon_conf daemon_safe_integer "$daemon_target" "{\"daemon\":true,\"$key\":9007199254740991}")
    parsed=$(daemon_parse "$c" POOLS_JSON)
    assert_rc "$key accepts the exact JSON integer maximum (#528)" "$?" "0"
    assert_eq "$key preserves the exact JSON integer maximum (#528)" "$(sed -n "s/.*\"$key\":\([^,}]*\).*/\1/p" <<<"$parsed")" "9007199254740991"
    for value in 1.0 1e3; do
        c=$(mkconf daemon_integral_number "{\"pools\":[{\"url\":\"$daemon_target\",\"daemon\":true,\"$key\":$value}]}")
        parsed=$(daemon_parse "$c" POOLS_JSON)
        assert_eq "$key canonicalizes integral JSON number $value (#528)" "$(sed -n "s/.*\"$key\":\([^,}]*\).*/\1/p" <<<"$parsed")" "$([ "$value" = 1.0 ] && echo 1 || echo 1000)"
    done
    for value in 1e100 9007199254740992; do
        c=$(mkconf daemon_bad_range "{\"pools\":[{\"url\":\"$daemon_target\",\"daemon\":true,\"$key\":$value}]}")
        out=$(daemon_parse "$c")
        assert_rc "$key rejects JSON number $value (#528)" "$?" "1"
        assert_contains "$key JSON number rejection names the key (#528)" "$out" "$key"
    done
done
for field in socks5 tls-fingerprint; do
    if [ "$field" = socks5 ]; then value=$daemon_proxy; else value=$daemon_pin; fi
    c=$(daemon_conf daemon_unsupported_transport "$daemon_target" \
        "{\"daemon\":true,\"tls\":true,\"$field\":\"$value\"}")
    out=$(daemon_parse "$c")
    assert_rc "daemon mining rejects unsupported $field (#528)" "$?" "1"
    assert_contains "unsupported daemon $field rejection names the key (#528)" "$out" "$field"
done

for value in 1 65535; do
    c=$(daemon_conf daemon_zmq "$daemon_target" "{\"daemon\":true,\"daemon-zmq-port\":$value}")
    daemon_parse_rc "$c" "$ROOT"
    assert_rc "daemon-zmq-port accepts bound $value (#528)" "$?" "0"
done
for value in 0 65536 -1 1.5 '"1"' 'null' 'true'; do
    c=$(daemon_conf daemon_bad_zmq "$daemon_target" "{\"daemon\":true,\"daemon-zmq-port\":$value}")
    out=$(daemon_parse "$c")
    assert_rc "daemon-zmq-port rejects $value (#528)" "$?" "1"
    assert_contains "daemon-zmq-port rejection names the key (#528)" "$out" "daemon-zmq-port"
done

for key in daemon-poll-interval daemon-job-timeout daemon-zmq-port; do
    c=$(daemon_conf daemon_stratum_key "$daemon_target" "{\"$key\":1}")
    out=$(daemon_parse "$c")
    assert_rc "$key rejected on a Stratum pool (#528)" "$?" "1"
    assert_contains "$key Stratum rejection names the key (#528)" "$out" "$key"
done

echo "== unit: daemon pool rendering and scope boundary (#528) =="

all_daemon_input='{"daemon":true,"daemon-poll-interval":1.0,"daemon-job-timeout":1e3,"daemon-zmq-port":65535}'
all_daemon_fields='{"daemon":true,"daemon-poll-interval":1,"daemon-job-timeout":1000,"daemon-zmq-port":65535}'
c=$(mkconf daemon_render "{\"pools\":[{\"url\":\"daemon+https://$daemon_target\",${all_daemon_input#\{}]}")
daemon_render_dir=$(mktemp -d "$SANDBOX/daemon-render.XXXXXX")
(
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
    OS_TYPE=Linux
    WORKER_ROOT="$daemon_render_dir"
    LOGROTATE_DIR="$daemon_render_dir"
    cd "$daemon_render_dir" || exit 1
    PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
)
rendered_pool=$(jq -c '.pools[0]' "$daemon_render_dir/config.json")
assert_eq "daemon fields survive into generated miner config (#528)" \
    "$(printf '%s' "$rendered_pool" | jq -c '{daemon, "daemon-poll-interval", "daemon-job-timeout", "daemon-zmq-port"}')" \
    "$all_daemon_fields"

c=$(daemon_conf daemon_render_absent "$daemon_target" '{}')
daemon_absent_dir=$(mktemp -d "$SANDBOX/daemon-absent.XXXXXX")
(
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
    OS_TYPE=Linux
    WORKER_ROOT="$daemon_absent_dir"
    LOGROTATE_DIR="$daemon_absent_dir"
    cd "$daemon_absent_dir" || exit 1
    PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
)
assert_eq "unset daemon fields stay absent from generated Stratum config (#528)" \
    "$(jq -c '[.pools[0] | has("daemon"), has("daemon-poll-interval"), has("daemon-job-timeout"), has("daemon-zmq-port")]' "$daemon_absent_dir/config.json")" \
    '[false,false,false,false]'

unsupported='{"daemon":true,"self-select":"ignored","submit-to-origin":true,"spend-secret-key":"ignored"}'
c=$(daemon_conf daemon_unsupported "$daemon_target" "$unsupported")
out=$(daemon_parse "$c")
assert_rc "out-of-scope daemon fields do not reject the supported pool (#528)" "$?" "0"
for key in self-select submit-to-origin spend-secret-key; do
    assert_contains "$key still warns as unsupported (#528)" "$out" "unknown pool field \"$key\""
done
parsed=$(daemon_parse "$c" POOLS_JSON)
assert_eq "out-of-scope daemon fields remain dropped (#528)" \
    "$(printf '%s' "$parsed" | jq -c '[.[0] | has("self-select"), has("submit-to-origin"), has("spend-secret-key")]')" \
    '[false,false,false]'

echo "== unit: invalid daemon apply fails before side effects (#528) =="

c=$(daemon_conf daemon_apply_reject "daemon+http://$daemon_target" '{"daemon":false}')
daemon_apply_dir=$(mktemp -d "$SANDBOX/daemon-apply.XXXXXX")
mkdir -p "$daemon_apply_dir/xmrig/build" "$daemon_apply_dir/systemd"
(
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    WORKER_ROOT="$daemon_apply_dir"
    SYSTEMD_DIR="$daemon_apply_dir/systemd"
    LOGROTATE_DIR="$daemon_apply_dir/logrotate"
    OS_TYPE=Linux
    set +e
    CALL_LOG="$daemon_apply_dir/calls" PATH="$STUBS:$PATH" apply >/dev/null 2>&1
)
assert_rc "apply rejects a bad daemon mode combination (#528)" "$?" "1"
assert_eq "bad daemon apply writes no miner config (#528)" "$([ -e "$daemon_apply_dir/xmrig/build/config.json" ] && echo yes || echo no)" "no"
assert_absent "bad daemon apply does not restart the miner (#528)" "$(cat "$daemon_apply_dir/calls" 2>/dev/null)" "[systemctl] restart"
assert_eq "bad daemon apply does not render a service unit (#528)" "$(find "$daemon_apply_dir/systemd" -type f | wc -l | tr -d ' ')" "0"

echo "== unit: daemon node health and miner summary (#528) =="

daemon_summary=$(mktemp "$SANDBOX/daemon-summary.XXXXXX")
jq -cn --arg pool "daemon+http://$daemon_target" '{connection:{pool:$pool,uptime:0,failures:0},uptime:0}' >"$daemon_summary"

daemon_pool_status() { # <healthy|syncing|down|slow|malformed|rpc-error> <config> [summary]
    (
        CONFIG_JSON="$2"
        SCRIPT_DIR="$ROOT"
        API_CMD="cat '${3:-$daemon_summary}'"
        DAEMON_CURL_CASE="$1"
        curl() {
            printf '<%s>\n' "$@" >>"$SANDBOX/daemon-curl.log"
            case "$DAEMON_CURL_CASE" in
            healthy) printf '%s' '{"result":{"status":"OK","height":42,"synchronized":true}}' ;;
            syncing) printf '%s' '{"result":{"status":"OK","height":41,"synchronized":false}}' ;;
            down) return 7 ;;
            slow) return 28 ;;
            malformed) printf '%s' '{broken' ;;
            rpc-error) printf '%s' '{"error":{"code":-1}}' ;;
            two-json) printf '%s\n%s' '{"result":{"status":"OK","height":42,"synchronized":true}}' '{"result":{"status":"OK","height":43,"synchronized":true}}' ;;
            esac
        }
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        _pool_conn_status
    )
}

c=$(daemon_conf daemon_health "daemon+http://$daemon_target" '{"daemon":true}')
healthy_status=$(daemon_pool_status healthy "$c")
assert_eq "healthy daemon summary reports height and sync (#528)" \
    "$(printf '%s' "$healthy_status" | cut -f1,3,4)" "$(printf 'daemon\t42\tsynced')"
syncing_status=$(daemon_pool_status syncing "$c")
assert_eq "syncing daemon summary reports height and state (#528)" \
    "$(printf '%s' "$syncing_status" | cut -f1,3,4)" "$(printf 'daemon\t41\tsyncing')"
for state in down slow malformed rpc-error two-json; do
    assert_eq "$state daemon response becomes a warning state (#528)" "$(daemon_pool_status "$state" "$c")" "daemon-down"
done
assert_contains "daemon RPC uses a bounded total timeout (#528)" "$(cat "$SANDBOX/daemon-curl.log")" \
    "$(printf '<--max-time>\n<5>')"
assert_contains "daemon RPC uses a bounded connect timeout (#528)" "$(cat "$SANDBOX/daemon-curl.log")" \
    "$(printf '<--connect-timeout>\n<2>')"
assert_contains "direct daemon RPC bypasses ambient proxies (#528)" "$(cat "$SANDBOX/daemon-curl.log")" \
    "$(printf '<--noproxy>\n<*>')"

mixed_body=$(jq -cn --arg stratum "$daemon_target" --arg daemon "daemon+http://$daemon_ipv4" \
    '{pools:[{url:$stratum},{url:$daemon,daemon:true}]}')
mixed_c=$(mkconf daemon_mixed "$mixed_body")
mixed_summary=$(mktemp "$SANDBOX/daemon-mixed-summary.XXXXXX")
jq -cn --arg pool "$daemon_ipv4" '{connection:{pool:$pool,uptime:0}}' >"$mixed_summary"
mixed_status=$(daemon_pool_status healthy "$mixed_c" "$mixed_summary")
assert_eq "mixed failover selects the active daemon pool (#528)" \
    "$(printf '%s' "$mixed_status" | cut -f1,3,4)" "$(printf 'daemon\t42\tsynced')"

native_stratum_summary=$(mktemp "$SANDBOX/native-stratum-summary.XXXXXX")
jq -cn --arg pool "$daemon_target" '{connection:{pool:$pool,mode:"stratum",uptime:1,accepted:0}}' >"$native_stratum_summary"
native_status=$(daemon_pool_status healthy "$c" "$native_stratum_summary")
assert_eq "native Stratum mode overrides daemon config fallback (#528)" "${native_status%%$'\t'*}" "connected"

unmatched_summary=$(mktemp "$SANDBOX/unmatched-summary.XXXXXX")
jq -cn --arg pool "$daemon_ipv6" '{connection:{pool:$pool,uptime:1,accepted:0}}' >"$unmatched_summary"
unmatched_status=$(daemon_pool_status healthy "$c" "$unmatched_summary")
assert_eq "an unmatched active endpoint is not mislabeled daemon (#528)" "${unmatched_status%%$'\t'*}" "connected"

schema_summary=$(mktemp "$SANDBOX/schema-summary.XXXXXX")
jq -cn '{connection:{uptime:0}}' >"$schema_summary"
schema_status=$(daemon_pool_status healthy "$c" "$schema_summary")
assert_eq "summary without mode or pool falls back to the first enabled daemon (#528)" "${schema_status%%$'\t'*}" "daemon"

disabled_body=$(jq -cn --arg daemon "daemon+http://$daemon_ipv4" --arg stratum "$daemon_target" \
    '{pools:[{url:$daemon,daemon:true,enabled:false},{url:$stratum}]}')
disabled_c=$(mkconf daemon_disabled_failover "$disabled_body")
disabled_summary=$(mktemp "$SANDBOX/disabled-summary.XXXXXX")
jq -cn --arg pool "$daemon_target" '{connection:{pool:$pool,uptime:1,accepted:0}}' >"$disabled_summary"
disabled_status=$(daemon_pool_status healthy "$disabled_c" "$disabled_summary")
assert_eq "disabled daemon failover does not override active Stratum (#528)" "${disabled_status%%$'\t'*}" "connected"

daemon_doctor() { # <healthy|syncing|down|slow|malformed>
    (
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$c"
        MEMINFO="$DOC/meminfo_ok"
        MSR_MODULE_DIR="$DOC/msrmod"
        GOVERNOR_FILE="$DOC/gov_perf"
        HUGEPAGES_1G_NR="$DOC/nr1g"
        DMIDECODE="$NOHW/dmidecode"
        CPUFREQ_MAX="$NOHW/cpufreq"
        CPU_SYSFS="$NOHW/cpu"
        API_CMD="cat '$daemon_summary'"
        DAEMON_CURL_CASE="$1"
        systemctl() { case "$*" in *"is-active --quiet $SERVICE_NAME"*) return "${DAEMON_SVC_RC:-0}" ;; *) return 0 ;; esac }
        curl() {
            case "$DAEMON_CURL_CASE" in
            healthy) printf '%s' '{"result":{"status":"OK","height":42,"synchronized":true}}' ;;
            syncing) printf '%s' '{"result":{"status":"OK","height":41,"synchronized":false}}' ;;
            down) return 7 ;;
            slow) return 28 ;;
            malformed) printf '%s' '{broken' ;;
            esac
        }
        set +e
        PATH="$STUBS:$PATH" doctor 2>&1
    )
}

out=$(daemon_doctor healthy)
assert_contains "doctor reports daemon node height (#528)" "$out" "height 42"
assert_contains "doctor reports a synchronized daemon node (#528)" "$out" "synced"
assert_absent "daemon doctor does not report accepted shares (#528)" "$out" "share(s) accepted"
assert_absent "healthy daemon avoids a false live-pool warning (#528)" "$out" "NO live pool connection"
out=$(daemon_doctor syncing)
assert_contains "doctor reports a syncing daemon node (#528)" "$out" "syncing"
for state in down slow malformed; do
    out=$(daemon_doctor "$state")
    assert_contains "doctor warns when daemon response is $state (#528)" "$out" "node"
    assert_contains "$state daemon response counts as a doctor issue (#528)" "$out" "issue(s) found"
done

out=$(DAEMON_SVC_RC=1 daemon_doctor healthy)
assert_contains "doctor checks the daemon node while the miner is stopped (#528)" "$out" "height 42"
out=$(DAEMON_SVC_RC=1 daemon_doctor down)
assert_contains "stopped-miner doctor flags an unreachable node (#528)" "$out" "issue(s) found"

daemon_apply_check() {
    (
        CONFIG_JSON="$c"
        SCRIPT_DIR="$ROOT"
        OS_TYPE=Linux
        API_CMD="cat '$daemon_summary'"
        systemctl() { return 0; }
        curl() {
            [ "${DAEMON_APPLY_CASE:-healthy}" = down ] && return 7
            printf '%s' '{"result":{"status":"OK","height":42,"synchronized":true}}'
        }
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        APPLY_POOL_TRIES=1 APPLY_POOL_IVL=0 _apply_pool_check 2>&1
    )
}
out=$(daemon_apply_check)
assert_contains "apply reports daemon node health (#528)" "$out" "height 42"
assert_absent "daemon apply does not use live-pool wording (#528)" "$out" "live pool connection"
assert_absent "daemon apply does not use share wording (#528)" "$out" "share(s) accepted"
out=$(DAEMON_APPLY_CASE=down daemon_apply_check)
assert_contains "apply warns when the daemon node is unavailable (#528)" "$out" "Node get_info is unavailable"

echo "== unit: daemon sister-feed mode (#528) =="

daemon_feed() { # <config> <output-dir>
    local config="$1" output="$2"
    mkdir -p "$output"
    (
        CONFIG_JSON="$config"
        SCRIPT_DIR="$ROOT"
        CONFIG_META_FILE="$output/meta.json"
        RIGFORGE_API_DATA="$output"
        RIGFORGE_CONTROL_STATE="$output/control"
        OS_TYPE=Linux
        API_CMD="cat '$daemon_summary'"
        systemctl() { return 1; }
        set +e
        PATH="$STUBS:$PATH" api_refresh >/dev/null 2>&1
    )
}

daemon_feed_dir=$(mktemp -d "$SANDBOX/daemon-feed.XXXXXX")
daemon_feed "$c" "$daemon_feed_dir"
assert_eq "daemon feed labels the active connection mode (#528)" \
    "$(jq -r '.connection.mode' "$daemon_feed_dir/summary.json")" "daemon"
assert_eq "daemon feed preserves a zero miner uptime (#528)" \
    "$(jq -r '.connection.uptime' "$daemon_feed_dir/summary.json")" "0"

stratum_summary=$(mktemp "$SANDBOX/stratum-summary.XXXXXX")
jq -cn --arg pool "$daemon_target" '{connection:{pool:$pool,uptime:1,failures:0,accepted:1},uptime:1}' >"$stratum_summary"
stratum_c=$(daemon_conf daemon_feed_stratum "$daemon_target" '{}')
stratum_feed_dir=$(mktemp -d "$SANDBOX/stratum-feed.XXXXXX")
daemon_summary="$stratum_summary" daemon_feed "$stratum_c" "$stratum_feed_dir"
assert_eq "Stratum feed omits the daemon mode field (#528)" \
    "$(jq -r '.connection | has("mode")' "$stratum_feed_dir/summary.json")" "false"
