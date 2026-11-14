#!/usr/bin/env bash
# shellcheck disable=SC2034

XMRIG_OVERLAY='{}'

_parse_xmrig_overlay() {
    XMRIG_OVERLAY=$(jq -c 'if has("xmrig") then .xmrig else {} end' "$CONFIG_JSON")
    jq -e 'type == "object"' <<<"$XMRIG_OVERLAY" >/dev/null || error "xmrig must be a JSON object."
    local key
    while IFS= read -r key; do
        error "xmrig overlay cannot set protected key: $key"
    done < <(jq -r 'keys[] | select(. == "pools" or . == "http" or . == "donate-level" or . == "donate-over-proxy" or . == "opencl" or . == "cuda")' <<<"$XMRIG_OVERLAY")
    while IFS= read -r key; do
        warn "xmrig overlay: undocumented key $key; XMRig may ignore it."
    done < <(jq -rf "$(_script_dir)/util/xmrig-overlay-keys.jq" <<<"$XMRIG_OVERLAY")
}

_xmrig_overlay_pins() {
    local overlay="${1:-$XMRIG_OVERLAY}"
    jq -r '[paths as $p | select(getpath($p) | type != "object") | select(all($p[]; type == "string")) | $p | join(".")] | unique | join(", ")' <<<"$overlay"
}

_xmrig_knob_path() {
    case "$1" in
    prefetch) echo '["randomx","scratchpad_prefetch_mode"]' ;;
    yield) echo '["cpu","yield"]' ;;
    threads) echo '["cpu","rx"]' ;;
    onegb) echo '["randomx","1gb-pages"]' ;;
    priority) echo '["cpu","priority"]' ;;
    hpjit) echo '["cpu","huge-pages-jit"]' ;;
    cacheqos) echo '["randomx","cache_qos"]' ;;
    wrmsr) echo '["randomx","wrmsr"]' ;;
    esac
}

_xmrig_knob_pinned() {
    [ "$XMRIG_OVERLAY" != '{}' ] || return 1
    jq -e --argjson p "$(_xmrig_knob_path "$1")" 'has($p[0]) and (.[$p[0]] | if type == "object" then has($p[1]) else true end)' <<<"$XMRIG_OVERLAY" >/dev/null
}

_xmrig_knob_value() {
    jq -c --argjson p "$(_xmrig_knob_path "$1")" 'try getpath($p) catch null' <<<"$XMRIG_OVERLAY"
}

_xmrig_knob_lines() {
    if _xmrig_knob_pinned "$1"; then
        _xmrig_knob_value "$1"
    else
        _knob_values "$1" | tr '[:space:]' '\n' | sed '/^$/d'
    fi
}

_xmrig_pin_seed() {
    local knob
    for knob in prefetch yield threads onegb priority hpjit cacheqos wrmsr; do
        if _xmrig_knob_pinned "$knob"; then _knob_set "$knob" "$(_xmrig_knob_value "$knob")"; fi
    done
}

_xmrig_unpinned() {
    if [ "$XMRIG_OVERLAY" = '{}' ]; then
        cat
        return
    fi
    jq --argjson overlay "$XMRIG_OVERLAY" 'delpaths([$overlay | paths as $p | select(getpath($p) | type != "object") | $p])'
}

_xmrig_logging_in_effect() {
    jq '{colors: (if has("colors") then .colors else true end), "print-time": (."print-time" // 60), "health-print-time": (."health-print-time" // 60), verbose: (.verbose // 0), syslog: (.syslog // false)}'
}

_merge_xmrig_overlay() {
    local merged
    if [ "$XMRIG_OVERLAY" != '{}' ]; then
        merged=$(jq --argjson overlay "$XMRIG_OVERLAY" '. * $overlay' "$1") || return 1
        printf '%s\n' "$merged" >"$1"
    fi
}

_cap_xmrig_threads() {
    local capped
    if [ -n "${THREADS_CAP:-}" ]; then
        capped=$(jq --argjson cap "$THREADS_CAP" '.cpu = (if (.cpu | type) == "object" then .cpu else {} end) | .cpu.rx = (if (.cpu.rx | type) == "number" and .cpu.rx >= 1 and .cpu.rx <= $cap then .cpu.rx else $cap end)' "$1") || return 1
        printf '%s\n' "$capped" >"$1"
    fi
}

_validate_xmrig_config() {
    local bin="$1" config="$2" validation="$3" output
    jq -e 'any(.pools[]; .enabled == true)' "$config" >/dev/null || {
        warn "XMRig requires an enabled pool; the live config was left unchanged."
        return 1
    }
    [ -x "$bin" ] || {
        warn "No built XMRig executable; run setup before apply validation."
        return 1
    }
    jq '."dry-run" = true | .background = false | ."log-file" = null | .syslog = false | .title = false | .colors = false | if (.cpu | type) == "object" then .cpu."memory-pool" = false else . end' "$config" >"$validation" || return 1
    if output=$("$bin" --config "$validation" --dry-run 2>&1); then
        log "XMRig configuration validation passed."
    else
        printf '%s\n' "$output" >&2
        warn "XMRig configuration validation failed; the live config was left unchanged."
        return 1
    fi
}

_stage_xmrig_config() (
    local build="$WORKER_ROOT/xmrig/build" stage
    [ -x "$build/xmrig" ] || {
        warn "No built XMRig executable; run setup before apply validation."
        return 1
    }
    if [ "${1:-}" != preview ]; then
        _config_apply_begin
    fi
    umask 077
    stage=$(mktemp -d) || return 1
    trap 'rm -rf "$stage"' EXIT
    cd "$stage" || return 1
    generate_xmrig_config stage || return 1
    _validate_xmrig_config "$build/xmrig" "$stage/config.json" "$stage/validation.json" || return 1
    if [ "${1:-}" != preview ]; then
        local pending
        pending=$(mktemp "$build/.config.XXXXXX") || return 1
        if [ "$OS_TYPE" = Linux ] && [ -n "${MINER_USER:-}" ]; then
            if ! _ensure_miner_user || ! sudo chown "$MINER_USER:$MINER_USER" "$pending"; then
                rm -f "$pending"
                return 1
            fi
        fi
        if cat config.json >"$pending" && mv "$pending" "$build/config.json"; then
            _config_apply_stamp "${CONFIG_INPUT_HASH:-}"
            _xmrig_log_policy
        else
            rm -f "$pending"
            return 1
        fi
    fi
)

_refresh_xmrig_unit() {
    NFT_PATH=$(command -v nft || echo "/usr/sbin/nft")
    export NFT_PATH
    export BUILD_DIR="$WORKER_ROOT/xmrig/build"
    CPUPOWER_PATH=$(command -v cpupower || echo "/usr/bin/cpupower")
    export CPUPOWER_PATH
    _render_xmrig_unit || return 1
    _shared_host_reload
}
