#!/usr/bin/env bash

_feed_os_version() {
    [ "${RIGFORGE_APPLIANCE:-0}" = 1 ] || return 0
    local f="${RIGFORGE_OS_VERSION_FILE:-/opt/pithead/VERSION}" v
    [ -r "$f" ] || return 0
    v=$(tr -d '[:space:]' <"$f" 2>/dev/null) || return 0
    v="${v:0:64}"
    [ -n "$v" ] || return 0
    printf '%s' "$v"
}

_feed_primary_mac() {
    local f="${RIGFORGE_MAC_FILE:-}" d m
    if [ -z "$f" ]; then
        d=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
        [ -n "$d" ] && f="${RIGFORGE_NET_SYSFS:-/sys/class/net}/$d/address"
    fi
    [ -n "$f" ] && [ -r "$f" ] || return 0
    m=$(tr -d '[:space:]' <"$f" 2>/dev/null | tr 'A-F' 'a-f')
    [[ "$m" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 0
    printf '%s' "${m:0:8}"
}

_feed_board_uuid() {
    local u
    u=$(_dmi product_uuid 2>/dev/null | tr 'A-Z' 'a-z')
    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 0
    printf '%s' "${u:0:13}"
}

_feed_cpu_model() {
    sed -n 's/^model name[[:space:]]*:[[:space:]]*\(.*\)$/\1/p' "${RIGFORGE_CPUINFO:-/proc/cpuinfo}" 2>/dev/null | head -1 | cut -c1-128
}

_api_identity_json() {
    local mac uuid cpu
    mac=$(_feed_primary_mac)
    uuid=$(_feed_board_uuid)
    cpu=$(_feed_cpu_model)
    jq -n --arg mac "$mac" --arg uuid "$uuid" --arg cpu "$cpu" '{mac: (if $mac == "" then null else $mac end), board_uuid: (if $uuid == "" then null else $uuid end), cpu_model: (if $cpu == "" then null else $cpu end)}'
}
