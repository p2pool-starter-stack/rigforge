#!/usr/bin/env bash
# Sourced by run.sh: reuse its setup and doctor fixtures.
# shellcheck disable=SC2034,SC2154,SC1090

echo "== unit: onion setup and SOCKS diagnostics (#520) =="
onion_setup() {
    (
        source "$SCRIPT"
        CONFIG_JSON="$onion_dir/config.json"
        set +eu
        printf 'y\n%s\n%s\n%s\n' "$1" "$2" "$3" | PATH="$STUBS:$PATH" ensure_config_exists 2>&1
    )
}
for proxy in '' 'proxy.example:9150' '[::1]:9050'; do
    onion_dir="$(mktemp -d "$SANDBOX/onion.XXXXXX")"
    out="$(onion_setup 'pool.onion:3333' 'secret.pass' "$proxy")"
    assert_eq "onion setup persists inferred/overridden proxy '$proxy'" "$(jq -r '.pools[0].socks5' "$onion_dir/config.json")" "${proxy:-127.0.0.1:9050}"
    assert_eq "onion setup preserves password" "$(jq -r '.pools[0].pass' "$onion_dir/config.json")" "secret.pass"
    assert_contains "onion setup explains operator-managed Tor" "$out" "install and run Tor yourself"
    assert_absent "onion setup does not log the password" "$out" "secret.pass"
done
onion_dir="$(mktemp -d "$SANDBOX/onion.XXXXXX")"
out="$(onion_setup 'POOL.ONION:3333' '' '')"
assert_eq "onion suffix is case-insensitive" "$(jq -r '.pools[0].socks5' "$onion_dir/config.json")" "127.0.0.1:9050"
for proxy in 'proxy' 'user:secret@proxy:9050' ':9050' 'proxy:0' 'proxy:65536' 'proxy:99999999999999999' '[zz]:9050' 'proxy;false:9050'; do
    onion_dir="$(mktemp -d "$SANDBOX/onion.XXXXXX")"
    out="$(onion_setup 'pool.onion:3333' '' "$proxy")"
    assert_rc "invalid SOCKS override is rejected" "$?" 1
    assert_eq "invalid SOCKS override writes nothing" "$([ -f "$onion_dir/config.json" ] && echo yes || echo no)" no
    assert_absent "invalid override does not leak supplied credentials" "$out" 'user:secret'
done
onion_dir="$(mktemp -d "$SANDBOX/onion.XXXXXX")"
out="$(onion_setup 'pool.onion.example:3333' '' '')"
assert_eq "clearnet suffix lookalike keeps minimal shape" "$(jq -c . "$onion_dir/config.json")" '{"pools":[{"url":"pool.onion.example:3333"}]}'
assert_absent "LAN setup does not mention Tor" "$out" "Tor"
# EOF at both optional prompts must retain the onion default.
onion_dir="$(mktemp -d "$SANDBOX/onion.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$onion_dir/config.json"
    set +eu
    printf 'y\npool.onion:3333\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "onion setup defaults on EOF" "$(jq -r '.pools[0].socks5' "$onion_dir/config.json")" "127.0.0.1:9050"

proxy_config="$SANDBOX/proxy-doctor.json"
printf '%s\n' '{"pools":[{"url":"pool.onion:3333","socks5":"127.0.0.1:9050"}]}' >"$proxy_config"
proxy_extra='CONFIG_JSON="$proxy_config"; _tcp_probe() { return 1; }'
out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" "$proxy_extra")"
assert_rc "missing proxy does not fail otherwise connected mining" "$?" 0
assert_contains "missing proxy is an explicit warning" "$out" "configured SOCKS proxy is unreachable"
assert_contains "missing proxy preserves miner's connected verdict" "$out" "pool connection live"
out="$(run_pool_doctor y "cat \"$DOC/api_disconnected.json\"" "$proxy_extra")"
assert_rc "missing proxy preserves existing disconnected failure" "$?" 1
assert_contains "disconnected miner remains a hard finding" "$out" "NO live pool connection"
out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" 'CONFIG_JSON="$proxy_config"; _tcp_probe() { [ "$1:$2" = "127.0.0.1:9050" ]; }')"
assert_absent "listening proxy produces no SOCKS warning or health claim" "$out" "SOCKS"
out="$(run_pool_doctor n '' "$proxy_extra")"
assert_rc "stopped service remains a failure" "$?" 1
assert_contains "stopped proxied miner gets an honest limitation" "$out" "can't verify the pool connection through SOCKS"
assert_absent "onion is not incorrectly dialled directly" "$out" "pool pool.onion:3333 is unreachable"
printf '%s\n' '{"pools":[{"url":"h:3333"},{"url":"pool.onion:3333","socks5":"[::1]:9050"}]}' >"$proxy_config"
out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" 'CONFIG_JSON="$proxy_config"; _tcp_probe() { [ "$1:$2" = "::1:9050" ]; }')"
assert_absent "secondary pool and bracketed IPv6 proxy are probed correctly" "$out" "SOCKS"
out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" "$proxy_extra")"
assert_contains "secondary pool's missing proxy is diagnosed" "$out" "configured SOCKS proxy is unreachable"
printf '%s\n' '{"pools":[{"url":"pool.onion:3333","socks5":"127.0.0.1:9050","enabled":false}]}' >"$proxy_config"
out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" "$proxy_extra")"
assert_absent "disabled pool's proxy is not diagnosed" "$out" "SOCKS"
printf '%s\n' '{"pools":[{"url":"pool.onion:3333","socks5":"user:secret@proxy:9050"}]}' >"$proxy_config"
out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" 'CONFIG_JSON="$proxy_config"; _tcp_probe() { echo unexpected-dial; }')"
assert_contains "doctor validates before dialing untrusted proxy input" "$out" "invalid host:port"
assert_absent "doctor does not dial malformed proxy" "$out" "unexpected-dial"
assert_absent "doctor does not log malformed proxy credentials" "$out" "secret"

# Called by run.sh against its existing loopback API listener: TCP reachability only.
proxy_listener_checks() {
    printf '{"pools":[{"url":"pool.onion:3333","socks5":"127.0.0.1:%s"}]}\n' "$APIPORT" >"$proxy_config"
    out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" 'CONFIG_JSON="$proxy_config"')"
    assert_rc "real loopback listener preserves doctor's connected exit status" "$?" 0
    assert_absent "real listening socket produces no SOCKS warning or health claim" "$out" "SOCKS"
    printf '%s\n' '{"pools":[{"url":"pool.onion:3333","socks5":"127.0.0.1:1"}]}' >"$proxy_config"
    out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"" 'CONFIG_JSON="$proxy_config"')"
    assert_rc "real closed loopback socket stays advisory" "$?" 0
    assert_contains "real closed loopback socket produces the explicit warning" "$out" "configured SOCKS proxy is unreachable"
}
