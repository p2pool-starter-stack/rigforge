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
le() { if [ "$2" -le "$3" ]; then ok "$1"; else bad "$1" "$2 is above the bound $3"; fi; }

NOHW="$TMP/no-hw"
export MEMINFO="$NOHW/meminfo" MSR_MODULE_DIR="$NOHW/msr-module" GOVERNOR_FILE="$NOHW/governor" HUGEPAGES_1G_NR="$NOHW/nr_1g" HUGEPAGES_1G_DIR="$NOHW/hugepages1G" CPUFREQ_MAX="$NOHW/cpufreq_max" CPU_SYSFS="$NOHW/cpu" RAPL_DIR="$NOHW/powercap" DMI_DIR="$NOHW/dmi" SMT_CONTROL="$NOHW/smt" LOCKDOWN_FILE="$NOHW/lockdown" NODE_SYSFS="$NOHW/node" THERMAL_ZONE="$NOHW/thermal" HWMON_DIR="$NOHW/hwmon" CPUINFO="$NOHW/cpuinfo" DMIDECODE="$NOHW/dmidecode-absent" RDMSR_BIN="$NOHW/rdmsr-absent"
export RIGFORGE_MAC_FILE="$NOHW/mac" RIGFORGE_CPUINFO="$NOHW/cpuinfo-identity"
ESC="$(printf '\033')"

call_fn() {
    (
        source "$SCRIPT" >/dev/null 2>&1
        set +e
        eval "$1"
    ) 2>/dev/null
}

mkdir -p "$TMP/sd/real" "$TMP/sd/links"
: >"$TMP/sd/real/x.sh"
ln -s ../real/x.sh "$TMP/sd/links/rel"
ln -s "$TMP/sd/real/x.sh" "$TMP/sd/links/abs"
REAL="$(cd -P "$TMP/sd/real" && pwd)"
eq "script_dir: relative symlink resolves to the real folder" "$(call_fn '_script_dir "$TMP/sd/links/rel"')" "$REAL"
eq "script_dir: absolute symlink resolves to the real folder" "$(call_fn '_script_dir "$TMP/sd/links/abs"')" "$REAL"
eq "script_dir: plain path gives its folder" "$(call_fn '_script_dir "$TMP/sd/real/x.sh"')" "$REAL"
eq "script_dir: bare file name gives the current folder" "$(call_fn 'cd "$TMP/sd/real" && _script_dir x.sh')" "$REAL"
eq "script_dir: bare symlink name resolves through the link" "$(call_fn 'cd "$TMP/sd/links" && _script_dir rel')" "$REAL"
eq "script_dir: a file in the root folder gives the root" "$(call_fn '_script_dir /x.sh')" "/"

jv() {
    printf '%s' "$2" >"$TMP/jv.json"
    (
        source "$SCRIPT" >/dev/null 2>&1
        set +e
        _jvals "$1" <"$TMP/jv.json" 2>/dev/null
        printf 'rc=%s' "$?"
        for _v in "${_JV[@]}"; do printf '|%s' "$_v"; done
    ) 2>/dev/null
}
eq "jvals: trailing newlines go, inner ones stay" "$(jv '.a, .b' '{"a":"x\n\n","b":"p\nq\n"}')" "$(printf 'rc=0|x|p\nq|0')"
eq "jvals: numbers print like jq -r and containers print pretty" "$(jv '.n, .c' '{"n":1e3,"c":[1]}' | tr '\n' ' ')" "rc=0|$(jq -r '.n' <<<'{"n":1e3}')|[   1 ]|0"
eq "jvals: NUL bytes are dropped" "$(jv '.a' '{"a":"x\u0000y"}')" "rc=0|xy|0"
eq "jvals: an unreadable document fails" "$(jv '.a' '{bad')" "rc=1|1"
eq "jvals: an empty string stays a value" "$(jv '.a, .b' '{"a":"","b":"z"}')" "rc=0||z|0"

KEYCFG="$TMP/keys.json"
warns() {
    printf '%s' "$1" >"$KEYCFG"
    (
        source "$SCRIPT" >/dev/null 2>&1
        set +e
        CONFIG_JSON="$KEYCFG"
        _warn_unknown_config_keys
    ) 2>&1 | sed "s/${ESC}\[[0-9;]*m//g"
}
out="$(warns '{"Api_Port":1,"Access_Tokens":2,"ACCESS_TOKEN":"x","bogus":3,"_note":4,"pools":[]}')"
has "unknown keys: a different case names its known key" "$out" 'unknown key "Api_Port" is ignored — did you mean "api_port"?'
has "unknown keys: a late known word is found by its lower-case form" "$out" 'unknown key "Access_Tokens" is ignored — did you mean "ACCESS_TOKENS"?'
has "unknown keys: no near match gives the plain warning" "$out" 'unknown key "bogus" is ignored.'
absent "unknown keys: an exact key is silent" "$out" '"ACCESS_TOKEN"'
absent "unknown keys: an underscore key is silent" "$out" '_note'
has "unknown keys: the reference pointer follows" "$out" 'See config.reference.json for every supported key.'
out="$(warns '{"pools":[{"url":"a:1","TLS":true,"Tls-Fingerprint":"x","zzz":1,"_c":2}]}')"
has "unknown pool fields: a different case names its field" "$out" 'unknown pool field "TLS" is ignored — did you mean "tls"?'
has "unknown pool fields: a late known word is found" "$out" 'unknown pool field "Tls-Fingerprint" is ignored — did you mean "tls-fingerprint"?'
has "unknown pool fields: no near match gives the plain warning" "$out" 'unknown pool field "zzz" is ignored.'
absent "unknown pool fields: an underscore field is silent" "$out" '"_c"'
out="$(warns '{"a\nb":1,"pools":[{"url":"a:1"}]}')"
has "unknown keys: a key with a newline is read as two lines first part" "$out" 'unknown key "a" is ignored.'
has "unknown keys: a key with a newline is read as two lines second part" "$out" 'unknown key "b" is ignored.'
eq "unknown keys: a clean config prints nothing" "$(warns '{"pools":[{"url":"a:1","tls":true}],"api":"enabled"}')" ""

CTL="$TMP/ctl"
mkdir -p "$CTL/changes"
hist() { call_fn 'RIGFORGE_CONTROL_STATE="$CTL"; _api_control_history_json'; }
eq "control history: an empty ring is an empty list, whatever is on standard input" "$(hist <<<'{"change_id":"zz"}')" "[]"
printf '{"change_id":"a","status":"applied","reason":null,"extra":1}' >"$CTL/changes/1.json"
printf '{bad' >"$CTL/changes/2.json"
printf '{"change_id":"c","status":"failed","reason":"r"}' >"$CTL/changes/3.json"
eq "control history: a malformed entry drops only itself" "$(hist)" '[{"change_id":"a","status":"applied","reason":null},{"change_id":"c","status":"failed","reason":"r"}]'
rm -f "$CTL/changes/2.json"
printf '{"change_id":"d"}\n{"change_id":"e","status":"x"}' >"$CTL/changes/4.json"
printf '5' >"$CTL/changes/5.json"
printf 'null' >"$CTL/changes/6.json"
: >"$CTL/changes/7.json"
printf '[1]' >"$CTL/changes/8.json"
printf '{"change_id":"h"} garbage' >"$CTL/changes/9.json"
eq "control history: several documents, a null and a half-valid file are kept as before" "$(hist)" '[{"change_id":"a","status":"applied","reason":null},{"change_id":"c","status":"failed","reason":"r"},{"change_id":"d","status":null,"reason":null},{"change_id":"e","status":"x","reason":null},{"change_id":null,"status":null,"reason":null},{"change_id":"h","status":null,"reason":null}]'

UNITS='systemctl() { printf "%s\n" "[Unit]" "Environment=AUTOTUNE_TARGET=perf" "Environment=AUTOTUNE_TARGET=eff" "OnCalendar=*-*-* *:00/5"; printf "Last=noeol"; }'
eq "unit value: the first matching line wins and the prefix is removed" "$(call_fn "$UNITS; _unit_value u Environment=AUTOTUNE_TARGET=")" "perf"
eq "unit value: a calendar value with glob characters is kept whole" "$(call_fn "$UNITS; _unit_value u OnCalendar=")" "*-*-* *:00/5"
eq "unit value: a missing prefix gives nothing" "$(call_fn "$UNITS; _unit_value u Missing=")" ""
eq "unit value: a last line without a newline is read" "$(call_fn "$UNITS; _unit_value u Last=")" "noeol"
eq "unit value: a glob prefix is literal" "$(call_fn "$UNITS; _unit_value u '*'")" ""
eq "unit value: a failing systemctl gives nothing" "$(call_fn 'systemctl() { return 1; }; _unit_value u OnCalendar=')" ""

mkdir -p "$TMP/dmi"
printf 'Vend\nor X\n\n' >"$TMP/dmi/board_vendor"
printf 'noeol' >"$TMP/dmi/board_name"
mkdir -p "$TMP/dmi/bios_date"
eq "dmi: newlines are removed from the middle and the end" "$(call_fn 'DMI_DIR="$TMP/dmi"; _dmi board_vendor')" "Vendor X"
eq "dmi: a file without a newline is read whole" "$(call_fn 'DMI_DIR="$TMP/dmi"; _dmi board_name')" "noeol"
eq "dmi: a missing field is empty" "$(call_fn 'DMI_DIR="$TMP/dmi"; _dmi bios_version; echo "rc=$?"')" "rc=0"
eq "dmi: a folder in place of the field is empty" "$(call_fn 'DMI_DIR="$TMP/dmi"; _dmi bios_date; echo "rc=$?"')" "rc=0"

for i in 0 1 2 3 4 5 6; do mkdir -p "$TMP/cpu/cpu$i/cpufreq"; done
printf '1000\n' >"$TMP/cpu/cpu0/cpufreq/scaling_cur_freq"
printf '2000' >"$TMP/cpu/cpu1/cpufreq/scaling_cur_freq"
printf ' 3000' >"$TMP/cpu/cpu2/cpufreq/scaling_cur_freq"
printf '1000\n2000\n' >"$TMP/cpu/cpu3/cpufreq/scaling_cur_freq"
: >"$TMP/cpu/cpu4/cpufreq/scaling_cur_freq"
printf 'abc\n' >"$TMP/cpu/cpu5/cpufreq/scaling_cur_freq"
eq "cpu clock: only single numeric lines count" "$(call_fn 'CPU_SYSFS="$TMP/cpu"; _cpu_eff_khz')" "1500"

pool_msg() {
    printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "h:3333", "pass": "p" %s}] %s }\n' "$TMP" "$1" "${2:-}" >"$TMP/pc.json"
    (
        source "$SCRIPT" >/dev/null 2>&1
        set +e
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$TMP/pc.json"
        parse_config >/dev/null
        echo "parsed"
    ) 2>&1 | sed "s/${ESC}\[[0-9;]*m//g"
}
fld() { has "pool field $1" "$(pool_msg "$2")" "$3"; }
fld "nicehash must be boolean" ', "nicehash": "x"' 'Pool nicehash must be true or false.'
fld "sni must be boolean" ', "sni": 1' 'Pool sni must be true or false.'
fld "rig-id charset" ', "rig-id": "bad id"' 'Pool rig-id must be a string using only'
fld "rig-id type" ', "rig-id": 5' 'Pool rig-id must be a string using only'
fld "algo list" ', "algo": "bad"' 'Pool algo must be a supported RandomX algorithm'
fld "algo type" ', "algo": 5' 'Pool algo must be a supported RandomX algorithm'
fld "coin list" ', "coin": "bad"' 'Pool coin must be a supported RandomX coin'
fld "coin type" ', "coin": 5' 'Pool coin must be a supported RandomX coin'
fld "pass type number" ', "pass": 5' 'Pool pass must be a string (got a number)'
fld "pass type array" ', "pass": [1]' 'Pool pass must be a string (got a array)'
fld "pass spaces" ', "pass": "a b"' 'Pool pass must be non-empty with no spaces'
fld "pass tab" ', "pass": "a\tb"' 'Pool pass must be non-empty with no spaces'
fld "socks5 empty" ', "socks5": ""' 'Pool socks5 is an empty string'
fld "socks5 syntax" ', "socks5": "bad socks"' "Pool socks5 'bad socks' must include a port"
fld "tls-fingerprint empty" ', "tls-fingerprint": ""' 'Pool tls-fingerprint is an empty string'
fld "tls-fingerprint syntax" ', "tls": true, "tls-fingerprint": "zz"' 'Pool tls-fingerprint must be the cert'
fld "tls-fingerprint without tls" ', "tls-fingerprint": "'"$(printf 'ab%.0s' $(seq 1 32))"'"' 'sets tls-fingerprint but not "tls": true'
fld "keepalive type" ', "keepalive": [1]' 'Pool keepalive must be true or false (got: ['
fld "tls type" ', "tls": "yes"' 'Pool tls must be true or false (got: yes)'
fld "enabled type" ', "enabled": "no"' 'Pool enabled must be true or false (got: no)'
fld "user charset" ', "user": "bad user"' "Pool user 'bad user' has invalid characters"
fld "url empty" ', "url": ""' 'A pool entry has no url'
fld "pool without a password default" ', "pass": null' 'parsed'
fld "full valid pool" ', "socks5": "127.0.0.1:9050", "tls": true, "tls-fingerprint": "'"$(printf 'Ab%.0s' $(seq 1 32))"'", "algo": "rx/0", "coin": "XMR", "nicehash": true, "sni": false, "rig-id": "r-1", "user": "u:1", "keepalive": false, "enabled": false' 'parsed'
absent "full valid pool prints no error" "$(pool_msg ', "tls": true, "algo": "rx/0"')" 'ERROR'

cfg_msg() { has "config key $1" "$(pool_msg '' ", $2")" "$3"; }
cfg_msg "HOME_DIR" '"HOME_DIR": "bad dir"' 'HOME_DIR must be'
cfg_msg "DONATION" '"DONATION": 101' 'DONATION must be an integer between 0 and 100 (got: 101)'
cfg_msg "ACCESS_TOKEN" '"ACCESS_TOKEN": "bad tok"' 'ACCESS_TOKEN has invalid characters'
cfg_msg "api_allow_from" '"api_allow_from": "300.1.1.1"' 'api_allow_from must be a valid IPv4/IPv6'
cfg_msg "autotune" '"autotune": "typo"' 'Invalid "autotune" value'
cfg_msg "autotune array" '"autotune": ["a"]' "Invalid \"autotune\" value '["
cfg_msg "watchdog" '"watchdog": "typo"' 'Invalid "watchdog" value'
cfg_msg "watchdog_interval_min" '"watchdog_interval_min": 0' 'watchdog_interval_min must be'
cfg_msg "max_temp_c" '"max_temp_c": 30' 'max_temp_c must be'
cfg_msg "hugepages_reserve_extra_mb" '"hugepages_reserve_extra_mb": -1' 'hugepages_reserve_extra_mb must be'
cfg_msg "hugepages_pool_ceiling_mb" '"hugepages_pool_ceiling_mb": 70000' 'hugepages_pool_ceiling_mb must be'
cfg_msg "threads" '"threads": 0' 'threads must be'
cfg_msg "api" '"api": "typo"' 'Invalid "api" value'
cfg_msg "api_port" '"api_port": 8080' 'api_port 8080 collides'
cfg_msg "api_bind" '"api_bind": "bad host"' 'api_bind must be an IP address'
cfg_msg "control" '"control": "typo"' 'Invalid "control" value'
cfg_msg "control_port" '"control_port": 8080' 'control_port 8080 collides'
cfg_msg "control_bind" '"control_bind": "x"' 'control_bind must be an IP address'
cfg_msg "control_upgrade" '"control_upgrade": "typo"' 'Invalid "control_upgrade" value'
cfg_msg "miner_user" '"miner_user": "root"' 'miner_user must be a non-root'
cfg_var() {
    printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "h:3333"}] %s }\n' "$TMP" "$1" >"$TMP/pv.json"
    (
        source "$SCRIPT" >/dev/null 2>&1
        set +e
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$TMP/pv.json"
        parse_config >/dev/null 2>&1
        eval "printf '%s' \"\${$2:-}\""
    ) 2>/dev/null
}
eq "config key DONATION keeps a number" "$(cfg_var ', "DONATION": 7' DONATION)" "7"
eq "config key DONATION drops a trailing newline" "$(cfg_var ', "DONATION": "3\n"' DONATION)" "3"
eq "config key rig_id reaches RIG_ID" "$(cfg_var ', "rig_id": "r-1"' RIG_ID)" "r-1"
eq "config key rig_id of blanks is empty" "$(cfg_var ', "rig_id": " "' RIG_ID)" ""
eq "config key add_to_path reaches ADD_TO_PATH" "$(cfg_var ', "add_to_path": true' ADD_TO_PATH)" "true"
eq "config key add_to_path defaults to false" "$(cfg_var '' ADD_TO_PATH)" "false"
eq "config key threads reaches THREADS_CAP" "$(cfg_var ', "threads": 4' THREADS_CAP)" "4"
eq "config key threads defaults to empty" "$(cfg_var '' THREADS_CAP)" ""
eq "config key miner_user reaches MINER_USER" "$(cfg_var ', "miner_user": "svc"' MINER_USER)" "svc"
eq "config key api_allow_from reaches the variable" "$(cfg_var ', "api_allow_from": "10.0.0.0/24"' API_ALLOW_FROM)" "10.0.0.0/24"
eq "config key max_temp_c reaches MAX_TEMP_C" "$(cfg_var ', "max_temp_c": 85' MAX_TEMP_C)" "85"
eq "config key api_port reaches API_PORT" "$(cfg_var ', "api_port": 9000' API_PORT)" "9000"
eq "config key control_port reaches CONTROL_PORT" "$(cfg_var ', "control_port": 9001' CONTROL_PORT)" "9001"
eq "config key watchdog_interval_min reaches the variable" "$(cfg_var ', "watchdog_interval_min": 9' WATCHDOG_INTERVAL_MIN)" "9"
eq "config key hugepages_reserve_extra_mb reaches the variable" "$(cfg_var ', "hugepages_reserve_extra_mb": 11' HUGEPAGES_RESERVE_EXTRA_MB)" "11"
eq "config key hugepages_pool_ceiling_mb reaches the variable" "$(cfg_var ', "hugepages_pool_ceiling_mb": 13' HUGEPAGES_POOL_CEILING_MB)" "13"

if [ "$(uname -s)" = Linux ]; then
    BIN="$TMP/bin"
    REALBIN="$TMP/realbin"
    LOG="$TMP/spawns.log"
    mkdir -p "$BIN" "$REALBIN"
    printf '#!/bin/sh\nprintf %%s %s\n' "'{\"hashrate\":{\"total\":[1234.5,0,0]},\"connection\":{\"pool\":\"h:3333\"}}'" >"$REALBIN/curl"
    for _c in systemctl journalctl dmidecode ip lscpu; do printf '#!/bin/sh\nexit 1\n' >"$REALBIN/$_c"; done
    chmod +x "$REALBIN"/*
    for _c in jq tr cat dirname basename awk sed head tail cut grep egrep date mv rm mkdir id uname sha256sum shasum getconf wc sort uniq readlink stat touch tee cp ln mktemp sleep xargs find ls nproc hostname env flock curl systemctl journalctl dmidecode ip lscpu; do
        _real="$(PATH="$REALBIN:$PATH" command -v "$_c" 2>/dev/null)" || continue
        printf '#!/bin/sh\necho %s >>"%s"\nexec "%s" "$@"\n' "$_c" "$LOG" "$_real" >"$BIN/$_c"
        chmod +x "$BIN/$_c"
    done
    RH="$TMP/rig"
    mkdir -p "$RH/home" "$RH/ctl/changes" "$RH/data"
    printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "a.example:3333", "pass": "secret-a"}, {"url": "b.example:4444", "pass": "secret-b", "tls": true}], "autotune": "performance", "watchdog": "enabled", "max_temp_c": 85, "rig_id": "rig-1" }\n' "$RH" >"$RH/config.json"
    cp "$ROOT/VERSION" "$RH/VERSION"
    printf '{"change_id":"s","status":"applied","reason":null}' >"$RH/ctl/status.json"
    for i in $(seq 1 20); do printf '{"change_id":"c%s","status":"applied","reason":null}' "$i" >"$RH/ctl/changes/c$i.json"; done
    run_tick() {
        : >"$LOG"
        RIGFORGE_HOME="$RH" RIGFORGE_API_DATA="$RH/data" RIGFORGE_CONTROL_STATE="$RH/ctl" RIGFORGE_REVISION_KEY="$RH/revkey" RIGFORGE_CONFIG_META="$RH/meta.json" PATH="$BIN:$REALBIN:$PATH" bash "$SCRIPT" api-refresh </dev/null >"$TMP/tick.out" 2>&1
    }
    count() { grep -c "^$1\$" "$LOG" || true; }
    run_tick
    eq "tick: the feed files are all written" "$(ls "$RH/data" | tr '\n' ' ')" "health.json summary-authed.json summary.json tune.json "
    eq "tick: the history reaches the feed" "$(jq -r '.rigforge.control_history | length' "$RH/data/summary.json")" "20"
    eq "tick: the version comes from the VERSION file" "$(jq -r '.rigforge.version' "$RH/data/summary.json")" "$(cat "$ROOT/VERSION")"
    TOTAL="$(wc -l <"$LOG" | tr -d ' ')"
    le "tick: external programs per refresh stay below the bound" "$TOTAL" 100
    le "tick: jq starts per refresh stay below the bound" "$(count jq)" 55
    le "tick: tr starts per refresh stay below the bound" "$(count tr)" 5
    le "tick: dirname is started once at most" "$(count dirname)" 1
    le "tick: cat starts per refresh stay below the bound" "$(count cat)" 3
    rm -f "$RH/VERSION"
    run_tick
    eq "tick: a missing VERSION file reads as unknown" "$(jq -r '.rigforge.version' "$RH/data/summary.json")" "unknown"
    eq "tick: a missing RIGFORGE_REF reads as no stamp" "$(jq -c '.rigforge.stamp' "$RH/data/summary.json")" "null"
    printf '' >"$RH/VERSION"
    run_tick
    eq "tick: an empty VERSION file reads as empty" "$(jq -r '.rigforge.version' "$RH/data/summary.json")" ""
fi

printf 'api-refresh spawns: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
