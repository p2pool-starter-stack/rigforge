#!/usr/bin/env bash
# shellcheck shell=bash

_upgrade_check() {
    local local_v remote_v url body highest via=""
    local_v=$(tr -d '[:space:]' <"$SCRIPT_DIR/VERSION" 2>/dev/null || true)
    if [ -z "$local_v" ]; then
        warn "No VERSION file at $SCRIPT_DIR/VERSION — can't compare against the latest release."
        return 0
    fi
    via=$(_tor_socks5) || return 0
    [ -z "$via" ] || via=" through tor_socks5 (no direct fallback)"
    body=$(_fetch_curl -fsS --max-time 5 "https://api.github.com/repos/p2pool-starter-stack/rigforge/releases/latest" 2>/dev/null || true)
    if [ -z "$body" ]; then
        warn "Couldn't reach GitHub$via to check for a newer release — try again later."
        return 0
    fi
    remote_v=$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null || true)
    url=$(printf '%s' "$body" | jq -r '.html_url // empty' 2>/dev/null || true)
    remote_v="${remote_v#v}"
    if [ -z "$remote_v" ]; then
        warn "Couldn't reach GitHub$via to check for a newer release — try again later."
        return 0
    fi
    if [ "$local_v" = "$remote_v" ]; then
        log "RigForge $local_v is the latest release."
        return 0
    fi
    highest=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -n1)
    if [ "$highest" = "$remote_v" ]; then
        log "A newer RigForge is available: $remote_v (you have $local_v)."
        if [ -n "$url" ]; then
            log "Release notes: $url"
        fi
        if _package_install; then
            log "Update: $(_package_upgrade_cmd)"
        else
            log "Update: cd $SCRIPT_DIR && git fetch --tags && git checkout v$remote_v && sudo $0 upgrade  (development checkouts on a branch: git pull && sudo $0 upgrade)"
        fi
    else
        log "RigForge $local_v is ahead of the latest release ($remote_v) — development build."
    fi
    return 0
}
