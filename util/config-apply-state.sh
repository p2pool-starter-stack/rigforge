#!/usr/bin/env bash

_config_tune_hash() {
    local overlay="$WORKER_ROOT/tune-overrides.json"
    if [ ! -e "$overlay" ] && [ ! -L "$overlay" ]; then
        printf 'absent\n'
    else
        [ -f "$overlay" ] || return 1
        _sha256 "$overlay"
    fi
}

_config_apply_begin() {
    [ "${1:-}" != stage ] || return 0
    CONFIG_TUNE_HASH=$(_config_tune_hash 2>/dev/null) || CONFIG_TUNE_HASH=""
    if [ -n "$CONFIG_TUNE_HASH" ] && [ "$CONFIG_TUNE_HASH" != absent ]; then
        jq -se 'length == 1 and (.[0] | type == "object")' "$WORKER_ROOT/tune-overrides.json" >/dev/null 2>&1 || CONFIG_TUNE_HASH=""
    fi
    rm -f "$WORKER_ROOT/xmrig/build/.rigforge-apply.json"
}

_config_apply_stamp() {
    local config_hash tune_hash stamp tmp
    [ "${2:-}" != stage ] || return 0
    [ -f "$CONFIG_JSON" ] || return 0
    config_hash=$(_sha256 "$CONFIG_JSON" 2>/dev/null) || return 0
    tune_hash=$(_config_tune_hash 2>/dev/null) || return 0
    [ "$config_hash" = "$1" ] && [ "$tune_hash" = "${CONFIG_TUNE_HASH:-}" ] || return 0
    stamp="$WORKER_ROOT/xmrig/build/.rigforge-apply.json"
    tmp=$(mktemp "$stamp.XXXXXX") || return 0
    if ! jq -n --arg c "$config_hash" --arg t "$tune_hash" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{config_hash: $c, tune_hash: $t, generated_at: $at}' >"$tmp" || ! mv -f "$tmp" "$stamp"; then
        rm -f "$tmp"
    fi
}

_config_apply_check() (
    local root stamp config_hash tune_hash previous previous_config previous_tune changed
    [ -f "$CONFIG_JSON" ] && root=$(jq -er '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON" 2>/dev/null) &&
        WORKER_ROOT=$(_worker_root_for_home "$root" 2>/dev/null) || {
        _ck_info "Generated configuration: source config unavailable — cannot verify the last apply" config-apply
        return 0
    }
    stamp="$WORKER_ROOT/xmrig/build/.rigforge-apply.json"
    if [ ! -e "$stamp" ]; then
        _ck_info "Generated configuration: no apply stamp (pre-existing install or unrecorded generation); run: sudo ./rigforge.sh apply" config-apply
        return 0
    fi
    if [ ! -f "$stamp" ] || ! previous=$(jq -esr 'select(length == 1) | .[0] | select(type == "object" and (.config_hash | type == "string" and test("^[0-9a-f]{64}$")) and (.tune_hash | type == "string" and (. == "absent" or test("^[0-9a-f]{64}$"))) and (.generated_at | type == "string" and length > 0)) | [.config_hash, .tune_hash] | @tsv' "$stamp" 2>/dev/null); then
        _ck_info "Generated configuration: apply stamp unreadable or invalid — cannot verify the last apply" config-apply
        return 0
    fi
    config_hash=$(_sha256 "$CONFIG_JSON" 2>/dev/null) && tune_hash=$(_config_tune_hash 2>/dev/null) || {
        _ck_info "Generated configuration: source files unreadable or invalid — cannot verify the last apply" config-apply
        return 0
    }
    IFS=$'\t' read -r previous_config previous_tune <<<"$previous"
    changed=""
    [ "$config_hash" = "$previous_config" ] || changed="config.json"
    if [ "$tune_hash" != "$previous_tune" ]; then changed="${changed:+$changed and }tune-overrides.json"; fi
    if [ -n "$changed" ]; then
        _ck_warn "$changed changed since the last apply — run: sudo ./rigforge.sh apply to regenerate the configuration" config-apply
    else
        _ck_ok "Generated configuration matches config.json and tune-overrides.json at the last generation" config-apply
    fi
)
