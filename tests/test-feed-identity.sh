#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s — %s\n' "$1" "$2" >&2
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in [$2]" ;; esac }
absent() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in [$2]" ;; *) ok "$1" ;; esac }

NOHW="$TMP/no-hw"
export MEMINFO="$NOHW/meminfo" MSR_MODULE_DIR="$NOHW/msr-module" GOVERNOR_FILE="$NOHW/governor" HUGEPAGES_1G_NR="$NOHW/nr_1g" HUGEPAGES_1G_DIR="$NOHW/hugepages1G" CPUFREQ_MAX="$NOHW/cpufreq_max" CPU_SYSFS="$NOHW/cpu" RAPL_DIR="$NOHW/powercap" DMI_DIR="$NOHW/dmi" SMT_CONTROL="$NOHW/smt" LOCKDOWN_FILE="$NOHW/lockdown" NODE_SYSFS="$NOHW/node" THERMAL_ZONE="$NOHW/thermal" HWMON_DIR="$NOHW/hwmon" CPUINFO="$NOHW/cpuinfo" DMIDECODE="$NOHW/dmidecode-absent" RDMSR_BIN="$NOHW/rdmsr-absent"
export RIGFORGE_MAC_FILE="$NOHW/mac" RIGFORGE_CPUINFO="$NOHW/cpuinfo-identity"

call_fn() {
    (
        source "$SCRIPT" >/dev/null 2>&1
        set +e
        eval "$1"
    ) 2>/dev/null
}

printf '2.1.0-rc.3\n' >"$TMP/osv"
mkdir -p "$TMP/osdir"
eq "os_version: appliance marker read and trimmed" "$(call_fn 'RIGFORGE_APPLIANCE=1 RIGFORGE_OS_VERSION_FILE="$TMP/osv"; _feed_os_version' x)" "2.1.0-rc.3"
eq "os_version: standalone never reads the marker" "$(call_fn 'RIGFORGE_APPLIANCE=0 RIGFORGE_OS_VERSION_FILE="$TMP/osv"; _feed_os_version' x)" ""
eq "os_version: missing marker -> empty" "$(call_fn 'RIGFORGE_APPLIANCE=1 RIGFORGE_OS_VERSION_FILE="$TMP/absent"; _feed_os_version' x)" ""
eq "os_version: unreadable marker -> empty" "$(call_fn 'RIGFORGE_APPLIANCE=1 RIGFORGE_OS_VERSION_FILE="$TMP/osdir"; _feed_os_version' x)" ""
printf '   \n\n' >"$TMP/osblank"
eq "os_version: blank marker -> empty" "$(call_fn 'RIGFORGE_APPLIANCE=1 RIGFORGE_OS_VERSION_FILE="$TMP/osblank"; _feed_os_version' x)" ""
printf '9.9.9 %0100d\n' 1 >"$TMP/oslong"
eq "os_version: capped at 64 chars" "$(call_fn 'RIGFORGE_APPLIANCE=1 RIGFORGE_OS_VERSION_FILE="$TMP/oslong"; _feed_os_version' x | wc -m | tr -d ' ')" "64"

feed_case_config() { printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "h:3333", "pass": "secret"}], "watchdog": "enabled", "max_temp_c": 85 %s }\n' "$1" "$2"; }
parse_rig_id() {
    local cfg="$TMP/rigid.json" extra="${2:-}"
    printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "h:3333"}] %s }\n' "$TMP" "$extra" >"$cfg"
    (
        source "$SCRIPT" >/dev/null 2>&1
        set +e
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$cfg"
        parse_config >/dev/null 2>&1
        printf '%s' "${RIG_ID:-}"
    ) 2>/dev/null
}
eq "rig_id: config value passed through" "$(parse_rig_id x ', "rig_id": "rig-a"')" "rig-a"
eq "rig_id: absent -> empty, never invented" "$(parse_rig_id x '')" ""
eq "rig_id: empty string -> empty" "$(parse_rig_id x ', "rig_id": ""')" ""
eq "rig_id: whitespace -> empty" "$(parse_rig_id x ', "rig_id": "  "')" ""
eq "rig_id: non-string -> empty" "$(parse_rig_id x ', "rig_id": 7')" ""

eq "mac: uppercase normalized and truncated" "$(call_fn 'RIGFORGE_MAC_FILE=/dev/stdin; printf %s "AA:BB:CC:DD:EE:FF" | _feed_primary_mac' x)" "aa:bb:cc"
eq "mac: malformed -> empty" "$(call_fn 'RIGFORGE_MAC_FILE="$TMP/badmac"; printf %s "not-a-mac" >"$TMP/badmac"; _feed_primary_mac' x)" ""
eq "mac: short mac -> empty" "$(call_fn 'RIGFORGE_MAC_FILE="$TMP/shortmac"; printf %s "aa:bb:cc:dd:ee" >"$TMP/shortmac"; _feed_primary_mac' x)" ""
eq "mac: missing -> empty" "$(call_fn 'RIGFORGE_MAC_FILE="$TMP/nomac"; _feed_primary_mac' x)" ""

mkdir -p "$TMP/dmi"
printf '01234567-89AB-CDEF-0123-456789ABCDEF' >"$TMP/dmi/product_uuid"
eq "board_uuid: lowercased first 13 chars" "$(call_fn 'DMI_DIR="$TMP/dmi"; _feed_board_uuid' x)" "01234567-89ab"
printf 'Not Present' >"$TMP/dmi/product_uuid"
eq "board_uuid: placeholder -> empty" "$(call_fn 'DMI_DIR="$TMP/dmi"; _feed_board_uuid' x)" ""
rm -f "$TMP/dmi/product_uuid"
eq "board_uuid: absent -> empty" "$(call_fn 'DMI_DIR="$TMP/dmi"; _feed_board_uuid' x)" ""
mkdir -p "$TMP/dmidir/product_uuid"
eq "board_uuid: unreadable -> empty" "$(call_fn 'DMI_DIR="$TMP/dmidir"; _feed_board_uuid' x)" ""

printf 'processor : 0\nmodel name\t: AMD Ryzen 9 7950X 16-Core Processor\nmodel name\t: second\n' >"$TMP/cpuinfo"
eq "cpu_model: first model name wins" "$(call_fn 'RIGFORGE_CPUINFO="$TMP/cpuinfo"; _feed_cpu_model' x)" "AMD Ryzen 9 7950X 16-Core Processor"
eq "cpu_model: missing -> empty" "$(call_fn 'RIGFORGE_CPUINFO="$TMP/nocpuinfo"; _feed_cpu_model' x)" ""
eq "identity: all probes absent -> three nulls" "$(call_fn '_api_identity_json | jq -cS .' x)" '{"board_uuid":null,"cpu_model":null,"mac":null}'

FX="$TMP/fixture"
mkdir -p "$FX/home" "$FX/data" "$FX/control" "$FX/dmi"
printf 'v0.0.0-fixture\n' >"$FX/VERSION"
printf 'ref=0000000000000000000000000000000000000000 version=0.0.0-fixture\n' >"$FX/RIGFORGE_REF"
printf 'fixture-revision-key' >"$FX/revkey"
feed_case_config "$FX" '' >"$FX/config.json"
printf '%s' '{"status":"rolled_back","change_id":"7777777777777777","source":"control","applied_at":"2026-01-01T00:00:00Z","changed_keys":["watchdog","DONATION"],"reason":"miner did not return to a live hashrate; rolled back and live","backup":"/b","warnings":["thermal protection changed: watchdog"]}' >"$FX/control/status.json"
printf '%s' '{"hashrate":{"total":[1234.5,0,0]},"connection":{"pool":"poolbox.lan:3333","uptime":93700,"failures":0,"accepted":42,"rejected":1},"uptime":93780,"hugepages":[1248,1248]}' >"$FX/xmrig-body.json"
printf '01234567-89AB-CDEF-0123-456789ABCDEF' >"$FX/dmi/product_uuid"
printf 'AA:BB:CC:DD:EE:FF' >"$FX/mac"
printf 'model name\t: AMD Ryzen 9 7950X 16-Core Processor\n' >"$FX/cpuinfo-identity"
run_fixture() {
    (
        source "$SCRIPT" >/dev/null 2>&1
        OS_TYPE=Linux RIGFORGE_APPLIANCE=1
        SCRIPT_DIR="$FX"
        CONFIG_JSON="$FX/config.json"
        CONFIG_META_FILE="$FX/meta.json"
        RIGFORGE_REVISION_KEY="$FX/revkey"
        RIGFORGE_API_DATA="$FX/data"
        RIGFORGE_CONTROL_STATE="$FX/control"
        RIGFORGE_OS_VERSION_FILE="$FX/no-os-marker"
        RIGFORGE_MAC_FILE="$FX/mac"
        RIGFORGE_CPUINFO="$FX/cpuinfo-identity"
        DMI_DIR="$FX/dmi"
        API_CMD="cat '$FX/xmrig-body.json'"
        SERVICE_NAME="rigforge-feed-identity-nonexistent"
        set +e
        eval "${1:-true}"
        api_refresh 2>/dev/null
    )
}
normalize_feed() { jq -S '.generated_at = "NORMALIZED" | .rigforge.version = "NORMALIZED" | .rigforge.xmrig_version = "NORMALIZED" | .rigforge.xmrig_commit = "NORMALIZED"' "$1"; }
run_fixture
eq "feed: public summary.json matches the contract fixture" "$(diff <(normalize_feed "$FX/data/summary.json") <(jq -S . "$ROOT/tests/contract/v1/feed.json") >/dev/null 2>&1 && echo same || echo diff)" "same"
eq "feed: authed summary matches its contract fixture" "$(diff <(normalize_feed "$FX/data/summary-authed.json") <(jq -S . "$ROOT/tests/contract/v1/feed-authed.json") >/dev/null 2>&1 && echo same || echo diff)" "same"
eq "feed: open payload carries no identity" "$(jq -c '.rigforge | has("identity")' "$FX/data/summary.json")" "false"
eq "feed: identity in the authed payload only" "$(jq -cS '.rigforge.identity' "$FX/data/summary-authed.json")" '{"board_uuid":"01234567-89ab","cpu_model":"AMD Ryzen 9 7950X 16-Core Processor","mac":"aa:bb:cc"}'
eq "feed: authed payload otherwise identical to the open one" "$(diff <(jq -S 'del(.rigforge.identity) | .generated_at = "NORMALIZED" | .rigforge.version = "NORMALIZED" | .rigforge.xmrig_version = "NORMALIZED" | .rigforge.xmrig_commit = "NORMALIZED"' "$FX/data/summary-authed.json") <(normalize_feed "$FX/data/summary.json") >/dev/null 2>&1 && echo same || echo diff)" "same"
printf '9.9.9\n' >"$FX/osmarker"
feed_case_config "$FX" ', "rig_id": "rig-a"' >"$FX/config.json"
run_fixture "RIGFORGE_OS_VERSION_FILE=\"$FX/osmarker\""
eq "feed: os_version reaches both payloads" "$(jq -c '[.rigforge.os_version, .rigforge.rig_id]' "$FX/data/summary.json" | tr -d ' ')$(jq -c '[.rigforge.os_version, .rigforge.rig_id]' "$FX/data/summary-authed.json" | tr -d ' ')" '["9.9.9","rig-a"]["9.9.9","rig-a"]'
feed_case_config "$FX" '' >"$FX/config.json"
run_fixture "API_CMD=\"printf %s ''\""
eq "feed: xmrig down keeps identity on the authed payload" "$(jq -c '[.rigforge.xmrig_api, (.rigforge.identity != null)]' "$FX/data/summary-authed.json")" '["unreachable",true]'

if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not present — the api-server identity-gate cases run in the other CI jobs"
else
    SRV="$TMP/srv"
    mkdir -p "$SRV"
    printf '%s' '{"hashrate":{"total":[1.0]},"rigforge":{"stamp":null}}' >"$SRV/summary.json"
    printf '%s' '{"hashrate":{"total":[1.0]},"rigforge":{"stamp":null,"identity":{"mac":"aa:bb:cc"}}}' >"$SRV/summary-authed.json"
    printf '%s' '{"service_active":true}' >"$SRV/health.json"
    printf '%s' '{"applied":null}' >"$SRV/tune.json"
    TOK="0123456789abcdef0123456789abcdef"
    READ="79432528d7ae32abcc791e8c3f86e100f01d7d535956b58b876da3c7660749b8"
    poll_up() {
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            curl -s -o /dev/null --max-time 2 "$@" 2>/dev/null && return 0
            sleep 0.3
        done
        return 1
    }
    printf '{ "pools": [{"url": "h:3333"}] }\n' >"$SRV/config-open.json"
    OPENPORT=$((20000 + RANDOM % 20000))
    python3 "$ROOT/util/api-server.py" 127.0.0.1 "$OPENPORT" "$SRV" "$SRV/config-open.json" &
    OPENPID=$!
    poll_up "http://127.0.0.1:$OPENPORT/health" || true
    eq "open API: serves the public payload even with an identity file on disk" "$(curl -fsS --max-time 5 "http://127.0.0.1:$OPENPORT/2/summary" 2>/dev/null | jq -c '.rigforge | has("identity")')" "false"
    kill "$OPENPID" 2>/dev/null || true
    wait "$OPENPID" 2>/dev/null || true
    printf '{ "pools": [{"url": "h:3333"}], "ACCESS_TOKEN": "%s" }\n' "$TOK" >"$SRV/config.json"
    GPORT=$((20000 + RANDOM % 20000))
    python3 "$ROOT/util/api-server.py" 127.0.0.1 "$GPORT" "$SRV" "$SRV/config.json" &
    GPID=$!
    poll_up -H "Authorization: Bearer $TOK" "http://127.0.0.1:$GPORT/health" || true
    eq "authed API: raw bearer gets the identity" "$(curl -fsS --max-time 5 -H "Authorization: Bearer $TOK" "http://127.0.0.1:$GPORT/1/summary" 2>/dev/null | jq -r '.rigforge.identity.mac')" "aa:bb:cc"
    eq "authed API: derived read bearer gets the identity" "$(curl -fsS --max-time 5 -H "Authorization: Bearer $READ" "http://127.0.0.1:$GPORT/2/summary" 2>/dev/null | jq -r '.rigforge.identity.mac')" "aa:bb:cc"
    eq "authed API: /health keeps its own body" "$(curl -fsS --max-time 5 -H "Authorization: Bearer $TOK" "http://127.0.0.1:$GPORT/health" 2>/dev/null | jq -r '.service_active')" "true"
    rm -f "$SRV/summary-authed.json"
    eq "authed API: missing identity file falls back to the public payload" "$(curl -fsS --max-time 5 -H "Authorization: Bearer $TOK" "http://127.0.0.1:$GPORT/1/summary" 2>/dev/null | jq -c '.rigforge | has("identity")')" "false"
    printf '%s' '{"hashrate":{"total":[1.0]},"rigforge":{"stamp":null,"identity":{"mac":"aa:bb:cc"}}}' >"$SRV/summary-authed.json"
    kill "$GPID" 2>/dev/null || true
    wait "$GPID" 2>/dev/null || true
fi

printf 'feed-identity: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
