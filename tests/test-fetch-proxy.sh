# shellcheck shell=bash disable=SC1090,SC2034,SC2329
echo "== unit: tor_socks5 routes RigForge's own fetches through one SOCKS5 proxy (#668) =="
FP="$(mktemp -d "$SANDBOX/fp.XXXXXX")"
mkdir -p "$FP/bin"
FP_PROXY="127.0.0.1:9050"
fp_cfg() { printf '%s\n' "$1" >"$FP/config.json"; }
cat >"$FP/bin/curl" <<'X'
#!/usr/bin/env bash
echo "curl $*" >>"$FP_LOG"
echo "env ALL_PROXY=${ALL_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} https_proxy=${https_proxy:-} NO_PROXY=${NO_PROXY:-} no_proxy=${no_proxy:-}" >>"$FP_LOG"
case " $* " in
*" --proxy socks5h://127.0.0.1:9050 "*) [ -z "${FP_PROXY_DOWN:-}" ] || exit 7 ;;
*) echo DIRECT >>"$FP_LOG"; exit 7 ;;
esac
printf '{"tag_name":"v9.9.9"}'
X
cat >"$FP/bin/git" <<'X'
#!/usr/bin/env bash
echo "git $*" >>"$FP_LOG"
echo "gitenv ${GIT_CONFIG_NOSYSTEM:-} ${HOME:-} ${XDG_CONFIG_HOME:-}" >>"$FP_LOG"
echo "env ALL_PROXY=${ALL_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} https_proxy=${https_proxy:-} NO_PROXY=${NO_PROXY:-} no_proxy=${no_proxy:-}" >>"$FP_LOG"
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
printf '{bad' >"$FP/config.json"
out="$(fp_tor)"
assert_contains "an unparseable config is refused, never read as 'no proxy'" "$out" "rc=1"
assert_contains "an unparseable config says why" "$out" "Cannot read tor_socks5"
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
    env -i PATH="$FP/bin:$STUBS:$PATH" FP_LOG="$FP/log" NO_PROXY=api.github.com no_proxy=github.com ${2:+FP_PROXY_DOWN=1} \
        bash -c 'S=$1; D=$2; C=$3; set --; source "$S"; RIGFORGE_LIB="$D" RIGFORGE_STATE="$D"; CONFIG_JSON="$C"; set +e; _upgrade_check 2>&1; echo "rc=$?"' fp-shell "$SCRIPT" "$FP" "$FP/config.json"
}
out="$(fp_check "{\"tor_socks5\":\"$FP_PROXY\"}")"
assert_contains "upgrade --check reaches the proxy and reports the release" "$out" "9.9.9 (you have 1.4.0)"
assert_contains "upgrade --check asks the proxy to resolve the name (socks5h)" "$(cat "$FP/log")" "--proxy socks5h://$FP_PROXY"
assert_absent "upgrade --check never dials GitHub directly with the key set" "$(cat "$FP/log")" "DIRECT"
assert_contains "upgrade --check ignores NO_PROXY and proxy variables in the environment" "$(grep '^env' "$FP/log")" "ALL_PROXY= HTTPS_PROXY= https_proxy= NO_PROXY= no_proxy="
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

fp_clone() {
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
assert_contains "XMRig clone with the key set ignores system and global git config" "$(grep '^gitenv' "$FP/log" | head -1)" "1 /nonexistent /nonexistent"
out="$(fp_clone '{"pools":[{"url":"h:3333"}]}')"
assert_absent "XMRig clone with the key unset adds no proxy option" "$(grep 'clone' "$FP/log")" "http.proxy"

fp_cu() {
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
                RIGFORGE_LIB="$D" RIGFORGE_STATE="$D"
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
assert_eq "control-upgrade ran with no proxy variable exported" "$(grep '^env' "$FP/log" | sort -u)" "env ALL_PROXY= HTTPS_PROXY= https_proxy= NO_PROXY= no_proxy="
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

fp_cu_inproc() {
    fp_cfg "$(printf '%s' "$1" | jq -c '. + {pools: [{url: "h:3333"}]}')"
    : >"$FP/log"
    local d
    d="$(mktemp -d "$SANDBOX/fpi.XXXXXX")"
    mkdir -p "$d/state/spool"
    mkdir -m 700 "$d/upgrade-state"
    printf '1.0.0' >"$d/VERSION"
    printf '{"version":"v9.9.9"}\n' >"$d/state/spool/upgrade-abc123def4567890.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        RIGFORGE_LIB="$d" RIGFORGE_STATE="$d"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_CONTROL_STATE="$d/state"
        RIGFORGE_CONTROL_UPGRADE_STATE="$d/upgrade-state"
        CONTROL_UPGRADE_MIN_INTERVAL=0
        FP_LOG="$FP/log" FP_STUB_GIT="$STUBS/git" FP_ORIGIN="$2"
        export FP_LOG FP_STUB_GIT FP_ORIGIN
        _tcp_probe() { return 0; }
        _control_claim_staged() { cp "$1" "$d/staged.json" && rm -f "$1" && printf '%s' "$d/staged.json"; }
        _wait_miner_live() { return 0; }
        set +e
        PATH="$FP/bin:$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    )
    cat "$d/state/status.json" 2>/dev/null
}
s="$(fp_cu_inproc "{\"tor_socks5\":\"$FP_PROXY\"}" "git@github.com:p2pool-starter-stack/rigforge.git")"
assert_eq "control-upgrade (in-process) refuses a non-https origin with the key set" "$(printf '%s' "$s" | jq -r .status)" "failed"
assert_contains "control-upgrade (in-process) records why" "$s" "not an https URL"

fp_doctor() {
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

echo "== unit: appliance rigs default tor_socks5 to the local Tor client (#696) =="
fp_app_tor() { # <config> [appliance]
    fp_cfg "$1"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_APPLIANCE="${2:-0}"
        set +e
        _tor_socks5
    ) 2>&1
    echo "rc=$?"
}
assert_eq "appliance rig with the key unset defaults to the local Tor client" "$(fp_app_tor '{"pools":[{"url":"h:3333"}]}' 1)" "$(printf '127.0.0.1:9050\nrc=0')"
assert_eq "appliance rig with an explicit null opts out to direct" "$(fp_app_tor '{"tor_socks5":null}' 1)" "rc=0"
assert_eq "appliance rig honours its own proxy" "$(fp_app_tor '{"tor_socks5":"127.0.0.1:9150"}' 1)" "$(printf '127.0.0.1:9150\nrc=0')"
assert_eq "plain host with the key unset stays direct (unchanged)" "$(fp_app_tor '{"pools":[{"url":"h:3333"}]}' 0)" "rc=0"

fp_seed() { # <appliance> <config> -> config after
    fp_cfg "$2"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_APPLIANCE="$1"
        set +e
        _seed_appliance_tor_default >/dev/null 2>&1
    )
    if jq -e . "$FP/config.json" >/dev/null 2>&1; then jq -cS . "$FP/config.json"; else cat "$FP/config.json"; fi
}
assert_eq "appliance setup writes the Tor default into config.json" "$(fp_seed 1 '{"pools":[{"url":"h:3333"}]}')" "$(printf '%s\n' '{"pools":[{"url":"h:3333"}],"tor_socks5":"127.0.0.1:9050"}' | jq -cS .)"
assert_eq "an explicit null survives the seed (the opt-out sticks)" "$(fp_seed 1 '{"tor_socks5":null}')" "$(printf '%s\n' '{"tor_socks5":null}' | jq -cS .)"
assert_eq "an operator-set proxy survives the seed" "$(fp_seed 1 '{"tor_socks5":"127.0.0.1:9150"}')" "$(printf '%s\n' '{"tor_socks5":"127.0.0.1:9150"}' | jq -cS .)"
assert_eq "a plain host is never seeded" "$(fp_seed 0 '{"pools":[{"url":"h:3333"}]}')" "$(printf '%s\n' '{"pools":[{"url":"h:3333"}]}' | jq -cS .)"
assert_eq "an unparseable config is left for parse_config to report" "$(fp_seed 1 '{bad')" "{bad"

fp_check_app() { # <config> [down] <appliance>
    fp_cfg "$1"
    : >"$FP/log"
    printf '1.4.0\n' >"$FP/VERSION"
    env -i PATH="$FP/bin:$STUBS:$PATH" FP_LOG="$FP/log" RIGFORGE_APPLIANCE="$3" ${2:+FP_PROXY_DOWN=1} \
        bash -c 'S=$1; D=$2; C=$3; set --; source "$S"; RIGFORGE_LIB="$D" RIGFORGE_STATE="$D"; CONFIG_JSON="$C"; set +e; _upgrade_check 2>&1; echo "rc=$?"' fp-shell "$SCRIPT" "$FP" "$FP/config.json"
}
out="$(fp_check_app '{"pools":[{"url":"h:3333"}]}' "" 1)"
assert_contains "appliance default upgrade --check routes the default proxy and reports the release" "$(cat "$FP/log")" "--proxy socks5h://127.0.0.1:9050"
assert_absent "appliance default upgrade --check never goes direct" "$out" "DIRECT"
out="$(fp_check_app '{"pools":[{"url":"h:3333"}]}' down 1)"
assert_contains "appliance default upgrade --check with Tor down fails closed" "$out" "through tor_socks5 (no direct fallback)"
assert_absent "appliance default upgrade --check with Tor down never dials direct" "$(cat "$FP/log")" "DIRECT"
out="$(fp_check_app '{"pools":[{"url":"h:3333"}]}' "" 0)"
assert_absent "plain host upgrade --check is unchanged (no proxy flag)" "$(grep -c -- '--proxy' "$FP/log")" "1"

fp_cu_app() { # <config> <origin> <reachable yes|no>
    fp_cfg "$(printf '%s' "$1" | jq -c '. + {pools: [{url: "h:3333"}]}')"
    : >"$FP/log"
    local d
    d="$(mktemp -d "$SANDBOX/fpua.XXXXXX")"
    mkdir -p "$d/state/spool"
    mkdir -m 700 "$d/upgrade-state" "$d/processing"
    printf '1.0.0' >"$d/VERSION"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$d/rigforge.sh"
    chmod +x "$d/rigforge.sh"
    printf '{"version":"v9.9.9"}\n' >"$d/state/spool/upgrade-abc123def4567890.json"
    (
        env -i PATH="$FP/bin:$STUBS:$PATH" RIGFORGE_OPERATOR=nobody RIGFORGE_APPLIANCE=1 RIGFORGE_CONTROL_PROCESSING="$d/processing" RIGFORGE_CONTROL_LOCK="$d/control.lock" \
            FP_LOG="$FP/log" FP_STUB_GIT="$STUBS/git" FP_ORIGIN="$2" \
            bash -c '
                S=$1
                D=$2
                C=$3
                R=$4
                set --
                source "$S"
                OS_TYPE=Linux
                RIGFORGE_LIB="$D" RIGFORGE_STATE="$D"
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
s="$(fp_cu_app '{}' "https://github.com/p2pool-starter-stack/rigforge.git" yes)"
assert_eq "appliance-default control-upgrade applies through the default proxy" "$(printf '%s' "$s" | jq -r .status)" "applied"
assert_contains "appliance-default control-upgrade fetch carries the default proxy" "$(grep ' fetch ' "$FP/log")" "http.proxy=socks5h://127.0.0.1:9050"
assert_absent "appliance-default control-upgrade never goes direct" "$(cat "$FP/log")" "DIRECT"
s="$(fp_cu_app '{}' "https://github.com/p2pool-starter-stack/rigforge.git" no)"
assert_eq "appliance-default control-upgrade with Tor down fails closed" "$(printf '%s' "$s" | jq -r .status)" "failed"
assert_contains "appliance-default control-upgrade with Tor down names the fallback rule" "$s" "unreachable — refusing to fetch (no direct fallback)"
assert_eq "appliance-default control-upgrade with Tor down fetches nothing" "$(grep -c ' fetch ' "$FP/log")" "0"

fp_doctor_app() {
    fp_cfg "$1"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_APPLIANCE=1
        if [ "$2" = yes ]; then _tcp_probe() { return 0; }; else _tcp_probe() { return 1; }; fi
        set +e
        _doctor_tor_socks5 2>&1
    )
}
assert_contains "doctor reports the appliance default as ok when Tor answers" "$(fp_doctor_app '{"pools":[]}' yes)" "127.0.0.1:9050 accepts TCP connections"
assert_contains "doctor warns when the appliance default proxy is down" "$(fp_doctor_app '{"pools":[]}' no)" "unreachable (TCP connect failed)"
assert_contains "doctor on an appliance never claims unset" "$(fp_doctor_app '{"pools":[]}' yes)" "accepts TCP"

fp_don() { # <config> [appliance]
    fp_cfg "$1"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_APPLIANCE="${2:-0}"
        OS_TYPE=Linux
        set +e
        parse_config
    ) 2>&1
    echo "rc=$?"
}
out="$(fp_don '{"pools":[{"url":"h:3333"}],"tor_socks5":"127.0.0.1:9050","DONATION":5}')"
assert_contains "setup/apply/upgrade refuse DONATION above 0 while tor_socks5 is set" "$out" "DONATION must be 0 while tor_socks5 is set"
assert_contains "the refusal names both settings and exits non-zero" "$out" "rc=1"
out="$(fp_don '{"pools":[{"url":"h:3333"}],"tor_socks5":"127.0.0.1:9050","DONATION":0}')"
assert_contains "DONATION 0 with the key set parses fine" "$out" "rc=0"
out="$(fp_don '{"pools":[{"url":"h:3333"}],"DONATION":5}')"
assert_contains "a plain host keeps its donation (unchanged)" "$out" "rc=0"
out="$(fp_don '{"pools":[{"url":"h:3333"}],"DONATION":5}' 1)"
assert_contains "the appliance default counts for the donation guard too" "$out" "DONATION must be 0 while tor_socks5 is set"
out="$(fp_don '{"pools":[{"url":"h:3333"}],"tor_socks5":null,"DONATION":5}' 1)"
assert_contains "the explicit appliance opt-out keeps its donation" "$out" "rc=0"

fp_opts() { # <config> <appliance> <fn>
    fp_cfg "$1"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_APPLIANCE="$2"
        set +e
        "$3"
    ) 2>/dev/null
}
assert_contains "tor-routed apt routes http through the proxy" "$(fp_opts "{\"tor_socks5\":\"$FP_PROXY\"}" 0 _tor_apt_proxy_opts)" "-o Acquire::http::Proxy=socks5h://$FP_PROXY"
assert_contains "tor-routed apt routes https through the proxy" "$(fp_opts "{\"tor_socks5\":\"$FP_PROXY\"}" 0 _tor_apt_proxy_opts)" "-o Acquire::https::Proxy=socks5h://$FP_PROXY"
assert_eq "unset key adds no apt proxy options on a plain host" "$(fp_opts '{"pools":[]}' 0 _tor_apt_proxy_opts)" ""
assert_contains "the appliance default routes apt too" "$(fp_opts '{"pools":[]}' 1 _tor_apt_proxy_opts)" "-o Acquire::http::Proxy=socks5h://127.0.0.1:9050"
assert_contains "tor-routed dnf sets its proxy option" "$(fp_opts "{\"tor_socks5\":\"$FP_PROXY\"}" 0 _tor_dnf_proxy_opt)" "--setopt=proxy=socks5h://$FP_PROXY"
assert_contains "tor-routed pacman and brew get ALL_PROXY" "$(fp_opts "{\"tor_socks5\":\"$FP_PROXY\"}" 0 _tor_proxy_env)" "env ALL_PROXY=socks5h://$FP_PROXY"

fp_conflict() { # <config> <staged-json> [appliance]
    fp_cfg "$1"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_APPLIANCE="${3:-0}"
        set +e
        _tor_staged_donation_conflict "$2"
    ) 2>&1
}
assert_contains "the applier backstop rejects a staged donation above zero while the key is set" "$(fp_conflict "{\"tor_socks5\":\"$FP_PROXY\"}" '{"DONATION":5}')" "rejected donation-nonzero-while-tor_socks5-set"
assert_eq "the applier backstop allows a staged zero donation" "$(fp_conflict "{\"tor_socks5\":\"$FP_PROXY\"}" '{"DONATION":0}')" ""
assert_eq "the applier backstop leaves plain-host donations alone" "$(fp_conflict '{"pools":[{"url":"h:3333"}]}' '{"DONATION":5}')" ""
assert_contains "the appliance default counts for the staged guard too" "$(fp_conflict '{"pools":[{"url":"h:3333"}]}' '{"DONATION":5}' 1)" "rejected donation-nonzero-while-tor_socks5-set"
fp_commit_reject() { # <appliance> <staged-json> <config>
    fp_cfg "$3"
    local d
    d="$(mktemp -d "$SANDBOX/fpcmt.XXXXXX")"
    printf '%s' "$2" >"$d/staged.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$FP/config.json"
        RIGFORGE_APPLIANCE="$1"
        set +e
        _control_commit "$d/staged.json" "$d/backups" 2>&1
        echo "rc=$?"
    )
    rm -rf "$d"
}
out="$(fp_commit_reject 0 '{"DONATION":5}' "{\"tor_socks5\":\"$FP_PROXY\",\"pools\":[{\"url\":\"h:3333\"}]}")"
assert_contains "control-apply refuses a staged DONATION above 0 while tor_socks5 is set" "$out" "rejected donation-nonzero-while-tor_socks5-set"
assert_contains "control-apply refusal ends non-zero" "$out" "rc=1"
out="$(fp_commit_reject 1 '{"DONATION":5}' '{"pools":[{"url":"h:3333"}]}')"
assert_contains "control-apply refuses it on the appliance default as well" "$out" "rejected donation-nonzero-while-tor_socks5-set"
