#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

TOR_SOCKS5_LOCAL_DEFAULT="127.0.0.1:9050"

_tor_socks5() {
    local t v
    [ -f "$CONFIG_JSON" ] || return 0
    t=$(jq -r 'if has("tor_socks5") then (.tor_socks5 | type) else "unset" end' "$CONFIG_JSON" 2>/dev/null) || error "Cannot read tor_socks5 from $CONFIG_JSON (unreadable or not a JSON object) — refusing to fetch without knowing whether a proxy is required."
    case "$t" in
    unset)
        if [ "${RIGFORGE_APPLIANCE:-0}" = 1 ]; then
            printf '%s\n' "$TOR_SOCKS5_LOCAL_DEFAULT"
            return 0
        fi
        return 0
        ;;
    null) return 0 ;;
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
        env -u NO_PROXY -u no_proxy GIT_CONFIG_NOSYSTEM=1 HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent git -c "http.proxy=socks5h://$s5" -c "remote.origin.proxy=socks5h://$s5" -c protocol.allow=never -c protocol.https.allow=always "$@"
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

_tor_socks5_uri() {
    local s
    s=$(_tor_socks5 2>/dev/null) || s=""
    [ -n "$s" ] || return 0
    printf 'socks5h://%s' "$s"
}

_tor_apt_proxy_opts() {
    local u
    u=$(_tor_socks5_uri)
    [ -n "$u" ] || return 0
    printf ' -o Acquire::http::Proxy=%s -o Acquire::https::Proxy=%s' "$u" "$u"
}

_tor_dnf_proxy_opt() {
    local u
    u=$(_tor_socks5_uri)
    [ -n "$u" ] || return 0
    printf ' --setopt=proxy=%s' "$u"
}

_tor_proxy_env() {
    local u
    u=$(_tor_socks5_uri)
    [ -n "$u" ] || return 0
    printf 'env ALL_PROXY=%s' "$u"
}

_tor_staged_donation_conflict() {
    local tor
    tor=$(_tor_socks5 2>/dev/null)
    [ -n "$tor" ] || return 1
    printf '%s' "$1" | jq -e 'has("DONATION") and ((if .DONATION == null then 0 else .DONATION end | tostring) != "0")' >/dev/null 2>&1 || return 1
    echo "rejected donation-nonzero-while-tor_socks5-set (a donation pool would dial direct; set DONATION to 0 or remove tor_socks5)"
}

_seed_appliance_tor_default() {
    [ "${RIGFORGE_APPLIANCE:-0}" = 1 ] || return 0
    [ -f "$CONFIG_JSON" ] || return 0
    jq -e . "$CONFIG_JSON" >/dev/null 2>&1 || return 0
    jq -e 'has("tor_socks5")' "$CONFIG_JSON" >/dev/null 2>&1 && return 0
    local tmp owner group mode rc=0
    tmp=$(mktemp "${CONFIG_JSON}.tmp.XXXXXX") || return 1
    owner=$(stat -c '%u' "$CONFIG_JSON" 2>/dev/null || stat -f '%u' "$CONFIG_JSON" 2>/dev/null || true)
    group=$(stat -c '%g' "$CONFIG_JSON" 2>/dev/null || stat -f '%g' "$CONFIG_JSON" 2>/dev/null || true)
    mode=$(stat -c '%a' "$CONFIG_JSON" 2>/dev/null || stat -f '%Lp' "$CONFIG_JSON" 2>/dev/null || true)
    if jq --arg v "$TOR_SOCKS5_LOCAL_DEFAULT" '. + {tor_socks5: $v}' "$CONFIG_JSON" >"$tmp"; then
        [ -z "$mode" ] || chmod "$mode" "$tmp" 2>/dev/null
        [ -z "$owner" ] || chown "${owner}${group:+:$group}" "$tmp" 2>/dev/null
        if mv -f "$tmp" "$CONFIG_JSON"; then
            log "Appliance: tor_socks5 was unset — set it to $TOR_SOCKS5_LOCAL_DEFAULT in $CONFIG_JSON so RigForge's own fetches fail closed. Set the key to your own proxy, or to null for direct, to override."
        else
            rc=1
        fi
        return "$rc"
    fi
    rm -f "$tmp"
    return 1
}
