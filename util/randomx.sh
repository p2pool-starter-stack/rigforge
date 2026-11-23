#!/usr/bin/env bash

_read_randomx_config() {
    jq -ce 'if has("xmrig") then .xmrig | select(type == "object") | if has("randomx") then .randomx else {} end else {} end | select(type == "object") | {mode: "fast", init: -1, "init-avx2": -1} + with_entries(select(.key == "mode" or .key == "init" or .key == "init-avx2")) | select(.mode == "auto" or .mode == "fast" or .mode == "light") | select(.init | type == "number" and floor == . and (. == -1 or (. >= 1 and . <= 2147483647))) | select(."init-avx2" == -1 or ."init-avx2" == 0 or ."init-avx2" == 1)' "$CONFIG_JSON"
}

_apply_randomx_config() {
    local settings="${RANDOMX_JSON:-}" rendered
    [ -n "$settings" ] || settings='{}'
    rendered=$(jq --argjson settings "$settings" --arg rx_mode "${RX_MODE:-fast}" '.randomx *= $settings | if $rx_mode == "light" then .randomx.mode = "light" else . end | if .randomx.mode == "light" then .randomx."1gb-pages" = false else . end' "$1") || return 1
    printf '%s\n' "$rendered" >"$1"
}

_randomx_available_kib() {
    local available page_size free_1g=0 reserved_1g=0
    available=$(awk '/^MemAvailable:/ { available=$2; seen=1 } /^MemFree:/ { free=$2; seen_free=1 } /^HugePages_Free:/ { pages=$2 } /^HugePages_Rsvd:/ { reserved=$2 } /^Hugepagesize:/ { size=$2 } END { if (!seen && !seen_free) exit; if (pages < reserved) pages=reserved; printf "%.0f", (seen ? available : free) + (pages-reserved)*(size ? size : 2048) }' "$MEMINFO" 2>/dev/null) || available=""
    [ -n "$available" ] || return 1
    [ ! -r "${HUGEPAGES_1G_NR%/*}/free_hugepages" ] || read -r free_1g <"${HUGEPAGES_1G_NR%/*}/free_hugepages" || true
    [ ! -r "${HUGEPAGES_1G_NR%/*}/resv_hugepages" ] || read -r reserved_1g <"${HUGEPAGES_1G_NR%/*}/resv_hugepages" || true
    page_size=$(awk '/^Hugepagesize:/ {print $2; exit}' "$MEMINFO" 2>/dev/null) || page_size=""
    if [ "$page_size" != 1048576 ] && [[ "$free_1g" =~ ^[0-9]+$ && "$reserved_1g" =~ ^[0-9]+$ ]] && [ "$free_1g" -gt "$reserved_1g" ]; then
        available=$((available + (free_1g - reserved_1g) * 1048576))
    fi
    printf '%s\n' "$available"
}

_check_randomx_memory() {
    local settings available
    RX_MODE=""
    if [ ! -f "$CONFIG_JSON" ]; then
        _ck_info "RandomX mode unavailable — no config.json" randomx-mode
        return 0
    fi
    if ! settings=$(_read_randomx_config 2>/dev/null); then
        _ck_warn "Invalid xmrig.randomx settings — check mode, init and init-avx2" randomx-mode
        return 1
    fi
    RX_MODE=$(jq -r '.mode' <<<"$settings")
    if [ "$RX_MODE" = auto ]; then
        _randomx_auto_pick "$@"
        return $?
    fi
    _ck_info "RandomX mode: $RX_MODE" randomx-mode
    [ "$RX_MODE" = fast ] && [ "${1:-n}" != y ] || return 0
    available=$(_randomx_available_kib) || available=""
    if [ -z "$available" ]; then
        _ck_info "Available memory unknown — cannot check the RandomX fast dataset" randomx-memory
        return 0
    fi
    if [ "$available" -lt "$RANDOMX_FAST_MIN_KIB" ]; then
        _ck_warn "RandomX fast needs at least 2080 MiB for its dataset; only $((available / 1024)) MiB available including free HugePages — set xmrig.randomx.mode to light or auto before starting" randomx-memory
        return 1
    fi
}

RANDOMX_FAST_MIN_KIB=2129920

_randomx_auto_decide() {
    local available
    RX_AUTO_NOTE=""
    [ "$RX_MODE" = auto ] || return 0
    if [ "${1:-n}" = y ]; then
        if [ "$(jq -r '.randomx.mode // empty' "${WORKER_ROOT:-$(_worker_root_from_config 2>/dev/null)}/xmrig/build/config.json" 2>/dev/null)" = light ]; then
            RX_MODE=light
            RX_AUTO_NOTE="RandomX auto: service running in light mode — keeping light"
        else
            RX_AUTO_NOTE="RandomX auto: service running, memory in use by the miner is not counted — keeping auto"
        fi
        return 0
    fi
    available=$(_randomx_available_kib) || available=""
    if [ -z "$available" ]; then
        RX_AUTO_NOTE="RandomX auto: available memory unknown — cannot decide the fallback, keeping auto"
    elif [ "$available" -lt "$RANDOMX_FAST_MIN_KIB" ]; then
        RX_AUTO_NOTE="RandomX auto: $((available / 1024)) MiB available (need ~2080 MiB for fast); picking light mode (shared 256 MiB cache, 1 GB pages off) — degraded performance on this hardware"
        RX_MODE=light
    else
        RX_AUTO_NOTE="RandomX auto: $((available / 1024)) MiB available — fast mode is viable"
    fi
}

_randomx_auto_pick() {
    _randomx_auto_decide "$@"
    [ -z "$RX_AUTO_NOTE" ] || _ck_info "$RX_AUTO_NOTE" randomx-memory
    _ck_info "RandomX mode: $RX_MODE" randomx-mode
}

_randomx_auto_pick_log() {
    local svc_up=n
    [ "$RX_MODE" = auto ] || return 0
    [ "${OS_TYPE:-}" != Linux ] || ! systemctl is-active --quiet "${SERVICE_NAME:-xmrig}" 2>/dev/null || svc_up=y
    _randomx_auto_decide "$svc_up"
    [ -z "$RX_AUTO_NOTE" ] || log "$RX_AUTO_NOTE"
}
