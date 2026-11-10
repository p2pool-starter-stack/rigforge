# shellcheck shell=bash disable=SC1090,SC2034,SC2329
echo "== unit: tor_socks5 routes RigForge's own fetches through one SOCKS5 proxy (#668) =="
FP="$(mktemp -d "$SANDBOX/fp.XXXXXX")"
mkdir -p "$FP/bin"
FP_PROXY="127.0.0.1:9050"
fp_cfg() { printf '%s\n' "$1" >"$FP/config.json"; }
cat >"$FP/bin/curl" <<'X'
#!/usr/bin/env bash
echo "curl $*" >>"$FP_LOG"
echo "env ALL_PROXY=${ALL_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} https_proxy=${https_proxy:-}" >>"$FP_LOG"
case " $* " in
*" --proxy socks5h://127.0.0.1:9050 "*) [ -z "${FP_PROXY_DOWN:-}" ] || exit 7 ;;
*) echo DIRECT >>"$FP_LOG"; exit 7 ;;
esac
printf '{"tag_name":"v9.9.9"}'
X
cat >"$FP/bin/git" <<'X'
#!/usr/bin/env bash
echo "git $*" >>"$FP_LOG"
echo "env ALL_PROXY=${ALL_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} https_proxy=${https_proxy:-}" >>"$FP_LOG"
case "$*" in
*"remote get-url origin"*) echo "${FP_ORIGIN:-https://github.com/p2pool-starter-stack/rigforge.git}"; exit 0 ;;
*" fetch "* | *" clone "*)
    case "$*" in
    *"http.proxy=socks5h://127.0.0.1:9050"*"protocol.allow=never"*"protocol.https.allow=always"*) ;;
    *) [ -n "${FP_ALLOW_DIRECT:-}" ] || { echo DIRECT >>"$FP_LOG"; exit 128; } ;;
    esac
    ;;
esac
exec "$FP_STUB_GIT" "$@"
X
chmod +x "$FP/bin/curl" "$FP/bin/git"

fp_tor() {
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        _tor_socks5
    ) 2>&1
    echo "rc=$?"
}
fp_cfg '{"pools":[{"url":"h:3333"}]}'
assert_eq "tor_socks5 unset -> no proxy, rc 0" "$(fp_tor)" "rc=0"
fp_cfg '{"tor_socks5":null}'
assert_eq "tor_socks5 null counts as unset" "$(fp_tor)" "rc=0"
fp_cfg "{\"tor_socks5\":\"$FP_PROXY\"}"
assert_eq "tor_socks5 host:port accepted" "$(fp_tor)" "$(printf '%s\nrc=0' "$FP_PROXY")"
fp_cfg '{"tor_socks5":"[::1]:9050"}'
assert_eq "tor_socks5 bracketed IPv6 accepted" "$(fp_tor)" "$(printf '[::1]:9050\nrc=0')"
for bad in '"socks5://127.0.0.1:9050"' '""' '9050' '"127.0.0.1"' '"h:99999"' '"<proxy>:9050"' '["127.0.0.1:9050"]'; do
    fp_cfg "{\"tor_socks5\":$bad}"
    out="$(fp_tor)"
    assert_contains "tor_socks5 $bad is refused" "$out" "rc=1"
    assert_contains "tor_socks5 $bad names the key" "$out" "tor_socks5"
done

fp_cfg '{"pools":[{"url":"h:3333"}],"tor_socks5":"socks5://x:9050"}'
out="$(
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        OS_TYPE=Linux
        parse_config
    ) 2>&1
    echo "rc=$?"
)"
assert_contains "parse_config refuses an invalid tor_socks5 (setup/apply/upgrade stop early)" "$out" "rc=1"
fp_cfg "{\"pools\":[{\"url\":\"h:3333\"}],\"tor_socks5\":\"$FP_PROXY\"}"
out="$( (
    source "$SCRIPT"
    CONFIG_JSON="$FP/config.json"
    set +e
    _warn_unknown_config_keys 2>&1
))"
assert_absent "tor_socks5 is a known config key" "$out" "tor_socks5"

fp_check() {
    fp_cfg "$1"
    : >"$FP/log"
    printf '1.4.0\n' >"$FP/VERSION"
    env -u ALL_PROXY -u HTTPS_PROXY -u https_proxy FP_LOG="$FP/log" ${2:+FP_PROXY_DOWN=1} PATH="$FP/bin:$STUBS:$PATH" \
        bash -c 'S=$1; D=$2; C=$3; set --; source "$S"; SCRIPT_DIR="$D"; CONFIG_JSON="$C"; set +e; _upgrade_check 2>&1; echo "rc=$?"' fp-shell "$SCRIPT" "$FP" "$FP/config.json"
}
out="$(fp_check "{\"tor_socks5\":\"$FP_PROXY\"}")"
assert_contains "upgrade --check reaches the proxy and reports the release" "$out" "9.9.9 (you have 1.4.0)"
assert_contains "upgrade --check asks the proxy to resolve the name (socks5h)" "$(cat "$FP/log")" "--proxy socks5h://$FP_PROXY"
assert_absent "upgrade --check never dials GitHub directly with the key set" "$(cat "$FP/log")" "DIRECT"
assert_contains "upgrade --check needs no proxy variable in the environment" "$(grep '^env' "$FP/log")" "ALL_PROXY= HTTPS_PROXY= https_proxy="
out="$(fp_check "{\"tor_socks5\":\"$FP_PROXY\"}" down)"
assert_contains "upgrade --check with the proxy down fails closed with a clear message" "$out" "Couldn't reach GitHub through tor_socks5 (no direct fallback)"
assert_contains "upgrade --check with the proxy down still exits 0" "$out" "rc=0"
assert_eq "upgrade --check with the proxy down makes exactly one attempt, no direct retry" "$(grep -c '^curl' "$FP/log")" "1"
assert_absent "upgrade --check with the proxy down never goes direct" "$(cat "$FP/log")" "DIRECT"
out="$(fp_check '{"tor_socks5":"socks5://x:9050"}')"
assert_contains "upgrade --check with an invalid key says why and does not fetch" "$out" "tor_socks5"
assert_eq "upgrade --check with an invalid key makes no curl call" "$(grep -c '^curl' "$FP/log")" "0"
out="$(fp_check '{"pools":[{"url":"h:3333"}]}')"
assert_contains "upgrade --check with the key unset is unchanged: direct curl" "$out" "Couldn't reach GitHub to check"
assert_eq "upgrade --check with the key unset adds no proxy flag" "$(grep -c -e '--proxy' "$FP/log")" "0"

fp_clone() { # <config-json>
    fp_cfg "$1"
    : >"$FP/log"
    local d
    d="$(mktemp -d "$SANDBOX/fpc.XXXXXX")"
    (
        cd "$d" || exit 1
        source "$SCRIPT"
        OS_TYPE="$(uname -s)"
        DONATION=1
        WORKER_ROOT="$d"
        CONFIG_JSON="$FP/config.json"
        export XMRIG_COMMIT="" FP_LOG="$FP/log" FP_STUB_GIT="$STUBS/git"
        set +e
        PATH="$FP/bin:$STUBS:$PATH" compile_xmrig 2>&1
        echo "rc=$?"
    )
}
out="$(fp_clone "{\"tor_socks5\":\"$FP_PROXY\"}")"
assert_contains "XMRig clone with the key set goes through the SOCKS5h proxy" "$(grep 'clone' "$FP/log")" "http.proxy=socks5h://$FP_PROXY"
assert_contains "XMRig clone with the key set allows only https" "$(grep 'clone' "$FP/log")" "protocol.allow=never"
assert_absent "XMRig clone with the key set never goes direct" "$(cat "$FP/log")" "DIRECT"
out="$(fp_clone '{"pools":[{"url":"h:3333"}]}')"
assert_absent "XMRig clone with the key unset adds no proxy option" "$(grep 'clone' "$FP/log")" "http.proxy"

fp_cu() { # <config-json> <origin> <proxy-reachable:yes|no> -> status.json
    fp_cfg "$(printf '%s' "$1" | jq -c '. + {pools: [{url: "h:3333"}]}')"
    : >"$FP/log"
    local d
    d="$(mktemp -d "$SANDBOX/fpu.XXXXXX")"
    mkdir -p "$d/state/spool"
    mkdir -m 700 "$d/upgrade-state" "$d/processing"
    printf '1.0.0' >"$d/VERSION"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$d/rigforge.sh"
    chmod +x "$d/rigforge.sh"
    printf '{"version":"v9.9.9"}\n' >"$d/state/spool/upgrade-abc123def4567890.json"
    (
        env -i PATH="$FP/bin:$STUBS:$PATH" RIGFORGE_OPERATOR=nobody RIGFORGE_APPLIANCE=0 RIGFORGE_CONTROL_PROCESSING="$d/processing" RIGFORGE_CONTROL_LOCK="$d/control.lock" \
            FP_LOG="$FP/log" FP_STUB_GIT="$STUBS/git" FP_ORIGIN="$2" FP_ALLOW_DIRECT="${4:-}" \
            bash -c '
                S=$1
                D=$2
                C=$3
                R=$4
                set --
                source "$S"
                OS_TYPE=Linux
                SCRIPT_DIR="$D"
                CONFIG_JSON="$C"
                RIGFORGE_CONTROL_STATE="$D/state"
                RIGFORGE_CONTROL_UPGRADE_STATE="$D/upgrade-state"
                CONTROL_UPGRADE_MIN_INTERVAL=0
                if [ "$R" = yes ]; then _tcp_probe() { return 0; }; else _tcp_probe() { return 1; }; fi
                _wait_miner_live() { return 0; }
                set +e
                control_upgrade >"$D/out.log" 2>&1
            ' fp-shell "$SCRIPT" "$d" "$FP/config.json" "$3"
    )
    cat "$d/state/status.json" 2>/dev/null || cat "$d/out.log" >&2
}
s="$(fp_cu "{\"tor_socks5\":\"$FP_PROXY\"}" "https://github.com/p2pool-starter-stack/rigforge.git" yes)"
assert_eq "control-upgrade oneshot with the key set applies through the proxy" "$(printf '%s' "$s" | jq -r .status)" "applied"
assert_contains "control-upgrade's git fetch carries the proxy under the unit's own environment" "$(grep ' fetch ' "$FP/log")" "http.proxy=socks5h://$FP_PROXY"
assert_contains "control-upgrade's git fetch pins the remote's proxy too" "$(grep ' fetch ' "$FP/log")" "remote.origin.proxy=socks5h://$FP_PROXY"
assert_absent "control-upgrade never goes direct with the key set" "$(cat "$FP/log")" "DIRECT"
assert_eq "control-upgrade ran with no proxy variable exported" "$(grep '^env' "$FP/log" | sort -u)" "env ALL_PROXY= HTTPS_PROXY= https_proxy="
s="$(fp_cu "{\"tor_socks5\":\"$FP_PROXY\"}" "git@github.com:p2pool-starter-stack/rigforge.git" yes)"
assert_eq "control-upgrade refuses a non-https origin when the key is set" "$(printf '%s' "$s" | jq -r .status)" "failed"
assert_contains "control-upgrade names the non-https origin" "$s" "not an https URL"
assert_eq "control-upgrade fetches nothing after refusing the origin" "$(grep -c ' fetch ' "$FP/log")" "0"
s="$(fp_cu "{\"tor_socks5\":\"$FP_PROXY\"}" "https://github.com/p2pool-starter-stack/rigforge.git" no)"
assert_eq "control-upgrade with the proxy unreachable fails closed" "$(printf '%s' "$s" | jq -r .status)" "failed"
assert_contains "control-upgrade names the unreachable proxy and no fallback" "$s" "unreachable — refusing to fetch (no direct fallback)"
assert_eq "control-upgrade fetches nothing when the proxy is unreachable" "$(grep -c ' fetch ' "$FP/log")" "0"
s="$(fp_cu '{"tor_socks5":"socks5://x:9050"}' "https://github.com/p2pool-starter-stack/rigforge.git" yes)"
assert_eq "control-upgrade with an invalid key is refused by parse_config before any fetch" "$(grep -c ' fetch ' "$FP/log")" "0"
s="$(fp_cu '{"pools":[{"url":"h:3333"}]}' "git@github.com:p2pool-starter-stack/rigforge.git" no direct)"
assert_eq "control-upgrade with the key unset is unchanged (ssh origin, no probe)" "$(printf '%s' "$s" | jq -r .status)" "applied"
assert_absent "control-upgrade with the key unset adds no proxy option" "$(grep ' fetch ' "$FP/log")" "http.proxy"

fp_doctor() { # <config-json> <reachable:yes|no>
    fp_cfg "$1"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        if [ "$2" = yes ]; then _tcp_probe() { return 0; }; else _tcp_probe() { return 1; }; fi
        set +e
        _doctor_tor_socks5 2>&1
    )
}
assert_contains "doctor reports the key unset" "$(fp_doctor '{"pools":[]}' yes)" "tor_socks5 is not set"
assert_contains "doctor reports a reachable proxy" "$(fp_doctor "{\"tor_socks5\":\"$FP_PROXY\"}" yes)" "accepts TCP connections"
assert_contains "doctor warns about an unreachable proxy" "$(fp_doctor "{\"tor_socks5\":\"$FP_PROXY\"}" no)" "unreachable (TCP connect failed)"
assert_contains "doctor warns about an invalid key" "$(fp_doctor '{"tor_socks5":"nope"}' yes)" "is invalid"
