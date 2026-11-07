#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail
SCRIPT="$1"
FEED="$2"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
FAIL=0
pass() { printf '  ok: %s\n' "$1"; }
fail() {
    printf '  FAIL: %s%s\n' "$1" "${2:+ — $2}" >&2
    FAIL=$((FAIL + 1))
}
eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3], got [$2]"; fi
}
BASE_POOL=$(jq -c '.rigforge.config.pools[0] | del(.pass)' "$FEED")
FIXTURE_ID=$(jq -r '.rigforge.control.change_id' "$FEED")
write_config() { jq -n --argjson pools "$2" '{pools: $pools}' >"$1"; }
parse() {
    write_config "$D/input.json" "$1"
    (
        source "$SCRIPT"
        CONFIG_JSON="$D/input.json" SCRIPT_DIR=$(dirname "$SCRIPT")
        parse_config
    ) 2>&1
}
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3]" ;; esac }
absent() { case "$2" in *"$3"*) fail "$1" "unexpected [$3]" ;; *) pass "$1" ;; esac }
rejects() {
    local label="$1" key="$2" value="$3" fragment="$4" pools out rc
    pools=$(jq -cn --argjson base "$BASE_POOL" --argjson value "$value" --arg key "$key" '[($base + {($key): $value})]')
    out=$(parse "$pools")
    rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "$label" "accepted invalid value"
        return
    fi
    has "$label names the reason" "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" "$(printf '%s' "$fragment" | tr '[:upper:]' '[:lower:]')"
}
render() {
    local rc
    write_config "$D/input.json" "$1"
    rm -rf "$D/worker"
    mkdir -p "$D/logrotate"
    (
        RIGFORGE_HOME=$(dirname "$SCRIPT") LOGROTATE_DIR="$D/logrotate" source "$SCRIPT"
        CONFIG_JSON="$D/input.json" SCRIPT_DIR=$(dirname "$SCRIPT") OS_TYPE=Linux LOGROTATE_DIR="$D/logrotate"
        parse_config >/dev/null
        WORKER_ROOT="$D/worker" CPUINFO="$D/no-cpuinfo"
        mkdir -p "$WORKER_ROOT/xmrig/build"
        lscpu() { printf 'Model name: fixture cpu\n'; }
        hostname() { printf '%s\n' "$FIXTURE_ID"; }
        sudo() { "$@"; }
        cd "$WORKER_ROOT/xmrig/build" || exit
        generate_xmrig_config >/dev/null
    ) 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "generated config render" "exited $rc"
        return "$rc"
    fi
    cp "$D/worker/xmrig/build/config.json" "$2"
}
echo "== pool schema fields (#527) =="
FP=$(printf '%064d' 0)
POOLS=$(jq -cn --argjson base "$BASE_POOL" --arg fp "$FP" '[
    ($base + {"rig-id":"Rig_One.:@+-","nicehash":false,"sni":true,"algo":"rx/wow","coin":"WOW","tls":true,"tls-fingerprint":$fp}),
    ($base + {"rig-id":"","nicehash":true,"sni":false,"algo":"rx/arq","coin":"arqma","keepalive":false,"enabled":false})
]')
render "$POOLS" "$D/all.json"
eq "new pool fields stay on their source index" "$(jq -c '[.pools[] | [."rig-id",.nicehash,.sni,.algo,.coin]]' "$D/all.json")" '[["Rig_One.:@+-",false,true,"rx/wow","WOW"],["",true,false,"rx/arq","arqma"]]'
eq "new fields coexist with older optional fields" "$(jq -r '.pools[0]."tls-fingerprint"' "$D/all.json")" "$FP"
eq "explicit false values survive generation" "$(jq -c '[.pools[0].nicehash,.pools[1].sni,.pools[1].keepalive,.pools[1].enabled]' "$D/all.json")" '[false,false,false,false]'
eq "rig-id coexists with the unchanged default user" "$(jq -r '.pools[0].user' "$D/all.json")" "$FIXTURE_ID"
out=$(parse "$POOLS")
absent "new fields do not trigger unknown-field warnings" "$out" "unknown pool field"
LEGACY=$(jq -cn --argjson base "$BASE_POOL" '[$base]')
NULLS=$(jq -cn --argjson base "$BASE_POOL" '[($base + {"rig-id":null,nicehash:null,sni:null,algo:null,coin:null})]')
render "$LEGACY" "$D/legacy.json"
render "$NULLS" "$D/nulls.json"
if cmp -s "$D/legacy.json" "$D/nulls.json"; then pass "null fields leave generated config byte-identical"; else fail "null fields leave generated config byte-identical"; fi
eq "absent fields remain absent" "$(jq -c '[.pools[0] | has("rig-id"),has("nicehash"),has("sni"),has("algo"),has("coin")]' "$D/legacy.json")" '[false,false,false,false,false]'

for value in true 7 '{}' '[]'; do rejects "rig-id rejects non-string $value" rig-id "$value" string; done
rejects "rig-id rejects whitespace" rig-id '"bad value"' characters
rejects "rig-id rejects a slash" rig-id '"bad/value"' characters
for key in nicehash sni; do
    rejects "$key rejects string false" "$key" '"false"' "$key"
    rejects "$key rejects string true" "$key" '"true"' "$key"
    rejects "$key rejects a number" "$key" 1 "$key"
done

for algo in rx/0 rx/2 rx/wow rx/arq rx/graft rx/sfx rx/yada; do
    pools=$(jq -cn --argjson base "$BASE_POOL" --arg algo "$algo" '[($base + {algo:$algo})]')
    if parse "$pools" >/dev/null; then pass "algo $algo accepted"; else fail "algo $algo accepted"; fi
done
rejects "non-RandomX algo rejected" algo '"kawpow"' RandomX
pools=$(jq -cn --argjson base "$BASE_POOL" '[($base + {algo:"kawpow"})]')
out=$(parse "$pools")
has "algo diagnostic explains the HugePages constraint" "$out" HugePages
has "algo diagnostic explains the tune constraint" "$out" tune
has "algo diagnostic explains the scratchpad constraint" "$out" scratchpad
rejects "unknown RandomX algo rejected" algo '"rx/future"' supported

for coin in monero XMR arqma ARQ graft GRFT wownero WOW zephyr ZEPH townforge yadacoin YDA; do
    pools=$(jq -cn --argjson base "$BASE_POOL" --arg coin "$coin" '[($base + {coin:$coin})]')
    if parse "$pools" >/dev/null; then pass "coin $coin accepted"; else fail "coin $coin accepted"; fi
done
for coin in ravencoin RVN sumokoin SUMO unknown; do rejects "coin $coin rejected" coin "\"$coin\"" coin; done

summary_output() {
    local algo="$1" entrypoint="$2" body="$D/summary.json"
    jq --arg algo "$algo" '.algo = $algo' "$FEED" >"$body"
    (
        source "$SCRIPT"
        API_CMD="cat '$body'" ACCESS_TOKEN=""
        if [ "$entrypoint" = status ]; then
            _status_api_summary
        else
            OS_TYPE=Linux CONFIG_JSON="$D/doctor.json" SERVICE_NAME=fixture-service
            MEMINFO="$D/none/meminfo" MSR_MODULE_DIR="$D/none/msr" GOVERNOR_FILE="$D/none/governor"
            HUGEPAGES_1G_NR="$D/none/huge1g" CPUINFO="$D/none/cpuinfo" CPUFREQ_MAX="$D/none/freq"
            LOCKDOWN_FILE="$D/none/lockdown" DMI_DIR="$D/none/dmi" NODE_SYSFS="$D/none/node"
            THERMAL_ZONE="$D/none/thermal" HWMON_DIR="$D/none/hwmon" RDMSR_BIN="$D/none/rdmsr"
            systemctl() { [ "${1:-}" = is-active ]; }
            lscpu() { printf 'Model name: fixture cpu\n'; }
            _check_donation() { return 0; }
            doctor || true
        fi
    ) 2>&1
}

write_config "$D/doctor.json" "$LEGACY"
for entrypoint in status doctor; do
    out=$(summary_output rx/wow "$entrypoint")
    has "$entrypoint shows a live non-default algorithm" "$out" "Algorithm:"
    has "$entrypoint names the live non-default algorithm" "$out" "rx/wow"
    out=$(summary_output rx/0 "$entrypoint")
    absent "$entrypoint omits the default algorithm" "$out" "Algorithm:"
done
jq 'del(.algo)' "$FEED" >"$D/summary.json"
out=$( (
    source "$SCRIPT"
    API_CMD="cat '$D/summary.json'" ACCESS_TOKEN=""
    _status_api_summary
) 2>&1)
absent "status is silent when the live algorithm is missing" "$out" "Algorithm:"
jq '.algo = 7' "$FEED" >"$D/summary.json"
out=$( (
    source "$SCRIPT"
    API_CMD="cat '$D/summary.json'" ACCESS_TOKEN=""
    _status_api_summary
) 2>&1)
absent "status is silent when the live algorithm is invalid" "$out" "Algorithm:"

CHANGE=$(jq -cn --argjson pools "$POOLS" '{pools:$pools}')
mkdir -p "$D/state/spool" "$D/backups"
printf '%s' "$CHANGE" >"$D/change.json"
STAGED="$D/change.json"
if command -v python3 >/dev/null 2>&1; then
    PYTHONDONTWRITEBYTECODE=1 python3 - "$SCRIPT" "$D/state/spool" "$D/change.json" <<'PY'
import importlib.util, json, pathlib, sys
path = pathlib.Path(sys.argv[1]).parent / "util/control-server.py"
spec = importlib.util.spec_from_file_location("control_server", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
payload = pathlib.Path(sys.argv[3]).read_bytes()
cid = module.stage_change(sys.argv[2], payload)
staged = pathlib.Path(sys.argv[2], "pending-" + cid + ".json").read_bytes()
assert json.loads(staged) == json.loads(payload)
PY
    eq "control receiver stages every pool field" "$?" 0
    STAGED=$(find "$D/state/spool" -name 'pending-*.json' -print -quit)
else
    printf '  SKIP: python3 unavailable; control receiver staging not run\n'
fi
write_config "$D/control.json" "$LEGACY"
(
    source "$SCRIPT"
    CONFIG_JSON="$D/control.json" SCRIPT_DIR=$(dirname "$SCRIPT") RIGFORGE_APPLIANCE=0
    _fsync_paths() { :; }
    _control_commit "$STAGED" "$D/backups" >/dev/null
)
eq "control apply accepts the same valid pool fields" "$?" 0
eq "control apply preserves all staged fields" "$(jq -c '.pools | map({"rig-id",nicehash,sni,algo,coin})' "$D/control.json")" '[{"rig-id":"Rig_One.:@+-","nicehash":false,"sni":true,"algo":"rx/wow","coin":"WOW"},{"rig-id":"","nicehash":true,"sni":false,"algo":"rx/arq","coin":"arqma"}]'

BAD_CHANGE=$(jq -cn --argjson base "$BASE_POOL" '{pools:[($base + {algo:"kawpow"})]}')
printf '%s' "$BAD_CHANGE" >"$D/bad-change.json"
before=$(jq -cS . "$D/control.json")
out=$( (
    source "$SCRIPT"
    CONFIG_JSON="$D/control.json" SCRIPT_DIR=$(dirname "$SCRIPT") RIGFORGE_APPLIANCE=0
    _fsync_paths() { :; }
    _control_commit "$D/bad-change.json" "$D/backups"
) 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then pass "control apply uses shared pool validation"; else fail "control apply uses shared pool validation"; fi
has "control rejection reports invalid config" "$out" "rejected invalid-config"
eq "rejected control apply leaves config unchanged" "$(jq -cS . "$D/control.json")" "$before"
[ "$FAIL" -eq 0 ] || exit 1
printf 'pool schema fields: PASS\n'
