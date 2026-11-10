#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

_tor_socks5() {
    local t v
    [ -f "$CONFIG_JSON" ] || return 0
    t=$(jq -r 'if has("tor_socks5") then (.tor_socks5 | type) else "unset" end' "$CONFIG_JSON" 2>/dev/null) || error "Cannot read tor_socks5 from $CONFIG_JSON (unreadable or not a JSON object) — refusing to fetch without knowing whether a proxy is required."
    case "$t" in
    unset | null) return 0 ;;
    string) ;;
    *) error "tor_socks5 must be a host:port string such as 127.0.0.1:9050." ;;
    esac
    v=$(jq -r '.tor_socks5' "$CONFIG_JSON")
    [ -n "$v" ] || error "tor_socks5 is an empty string — remove the key, or give it a host:port such as 127.0.0.1:9050."
    _validate_host_port "$v" "tor_socks5" 9050
    printf '%s\n' "$v"
}

_fetch_curl() {
    local s5
    s5=$(_tor_socks5) || return 1
    if [ -n "$s5" ]; then
        env -u NO_PROXY -u no_proxy curl -q --proxy "socks5h://$s5" "$@"
    else
        curl "$@"
    fi
}

_fetch_git() {
    local s5
    s5=$(_tor_socks5) || return 1
    if [ -n "$s5" ]; then
        env -u NO_PROXY -u no_proxy GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c "http.proxy=socks5h://$s5" -c "remote.origin.proxy=socks5h://$s5" -c protocol.allow=never -c protocol.https.allow=always "$@"
    else
        git "$@"
    fi
}

_fetch_preflight() {
    local s5 url
    FETCH_PREFLIGHT_REASON=""
    s5=$(_tor_socks5 2>/dev/null) || {
        FETCH_PREFLIGHT_REASON="tor_socks5 in config.json is invalid — refusing to fetch"
        return 1
    }
    [ -n "$s5" ] || return 0
    url=$(git "$@" remote get-url origin 2>/dev/null) || url=""
    case "$url" in
    https://*) ;;
    *)
        FETCH_PREFLIGHT_REASON="tor_socks5 is set but the checkout's origin is not an https URL — refusing to fetch without the proxy"
        return 1
        ;;
    esac
    _fetch_proxy_reachable "$s5" || {
        FETCH_PREFLIGHT_REASON="tor_socks5 proxy is unreachable — refusing to fetch (no direct fallback)"
        return 1
    }
}

_fetch_proxy_reachable() {
    local h=${1%:*}
    h=${h#\[}
    h=${h%\]}
    _tcp_probe "$h" "${1##*:}"
}

_doctor_tor_socks5() {
    local s5
    s5=$(_tor_socks5 2>/dev/null) || {
        _ck_warn "tor_socks5 in config.json is invalid — RigForge's own fetches will refuse to run until it is a host:port" tor-socks5
        return 0
    }
    if [ -z "$s5" ]; then
        _ck_info "tor_socks5 is not set — RigForge's own fetches (upgrade --check, the XMRig clone, remote upgrade) connect directly" tor-socks5
        return 0
    fi
    if _fetch_proxy_reachable "$s5"; then
        _ck_ok "tor_socks5 $s5 accepts TCP connections — RigForge's own fetches route through it" tor-socks5
    else
        _ck_warn "tor_socks5 $s5 is unreachable (TCP connect failed) — upgrade --check, the XMRig clone and remote upgrades fail closed until it is up" tor-socks5
    fi
}
