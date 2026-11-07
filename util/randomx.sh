#!/usr/bin/env bash

_read_randomx_config() {
    jq -ce 'if has("xmrig") then .xmrig | select(type == "object") | select((keys - ["randomx"]) == []) | if has("randomx") then .randomx else {} end else {} end | select(type == "object") | select((keys - ["mode", "init", "init-avx2"]) == []) | {mode: "fast", init: -1, "init-avx2": -1} + . | select(.mode == "auto" or .mode == "fast" or .mode == "light") | select(.init | type == "number" and floor == . and (. == -1 or (. >= 1 and . <= 2147483647))) | select(."init-avx2" == -1 or ."init-avx2" == 0 or ."init-avx2" == 1)' "$CONFIG_JSON"
}

_apply_randomx_config() {
    local settings="${RANDOMX_JSON:-}" rendered
    [ -n "$settings" ] || settings='{}'
    rendered=$(jq --argjson settings "$settings" '.randomx *= $settings | if .randomx.mode == "light" then .randomx."1gb-pages" = false else . end' "$1") || return 1
    printf '%s\n' "$rendered" >"$1"
}

_check_randomx_memory() {
    local settings available page_size free_1g=0 reserved_1g=0
    RX_MODE=""
    if [ ! -f "$CONFIG_JSON" ]; then
        _ck_info "RandomX mode unavailable — no config.json"
        return 0
    fi
    if ! settings=$(_read_randomx_config 2>/dev/null); then
        _ck_warn "Invalid xmrig.randomx settings — check mode, init and init-avx2"
        return 1
    fi
    RX_MODE=$(jq -r '.mode' <<<"$settings")
    _ck_info "RandomX mode: $RX_MODE"
    [ "$RX_MODE" = fast ] && [ "${1:-n}" != y ] || return 0
    available=$(awk '/^MemAvailable:/ { available=$2; seen=1 } /^MemFree:/ { free=$2; seen_free=1 } /^HugePages_Free:/ { pages=$2 } /^HugePages_Rsvd:/ { reserved=$2 } /^Hugepagesize:/ { size=$2 } END { if (!seen && !seen_free) exit; if (pages < reserved) pages=reserved; printf "%.0f", (seen ? available : free) + (pages-reserved)*(size ? size : 2048) }' "$MEMINFO" 2>/dev/null) || available=""
    if [ -z "$available" ]; then
        _ck_info "Available memory unknown — cannot check the RandomX fast dataset"
        return 0
    fi
    [ ! -r "${HUGEPAGES_1G_NR%/*}/free_hugepages" ] || read -r free_1g <"${HUGEPAGES_1G_NR%/*}/free_hugepages" || true
    [ ! -r "${HUGEPAGES_1G_NR%/*}/resv_hugepages" ] || read -r reserved_1g <"${HUGEPAGES_1G_NR%/*}/resv_hugepages" || true
    page_size=$(awk '/^Hugepagesize:/ {print $2; exit}' "$MEMINFO" 2>/dev/null) || page_size=""
    if [ "$page_size" != 1048576 ] && [[ "$free_1g" =~ ^[0-9]+$ && "$reserved_1g" =~ ^[0-9]+$ ]] && [ "$free_1g" -gt "$reserved_1g" ]; then
        available=$((available + (free_1g - reserved_1g) * 1048576))
    fi
    if [ "$available" -lt 2129920 ]; then
        _ck_warn "RandomX fast needs at least 2080 MiB for its dataset; only $((available / 1024)) MiB available including free HugePages — set xmrig.randomx.mode to light or auto before starting"
        return 1
    fi
}
