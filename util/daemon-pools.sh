#!/usr/bin/env bash

_validate_pool_url() {
    local pool="$1" example="$2" url="${3:-}" daemon key
    [ -n "$url" ] || url=$(jq -r '.url' <<<"$pool")
    case "$pool" in
    *'"daemon"'* | *'"daemon-'* | *'daemon+http://'* | *'daemon+https://'*) ;;
    *)
        _validate_host_port "$url" "Pool url" "$example"
        return
        ;;
    esac
    if ! jq -e 'if has("daemon") then (.daemon | type == "boolean") else true end' <<<"$pool" >/dev/null; then
        error "Pool daemon must be a boolean."
    fi
    daemon=$(jq -r '.daemon == true' <<<"$pool")
    case "$url" in
    daemon+http://* | daemon+https://*)
        [ "$(jq -r 'has("daemon") and .daemon == false' <<<"$pool")" != true ] || error "Pool daemon cannot be false with a daemon+ URL."
        daemon=true
        url=${url#*://}
        ;;
    esac
    if [ "$daemon" = true ]; then
        case "$url" in
        *[@/\?\#\\]* | *[[:cntrl:]]*) error "Pool url for daemon mining must contain only a host and port, without credentials, a path or a query." ;;
        esac
        for key in socks5 tls-fingerprint; do
            if jq -e --arg k "$key" '.[$k] != null' <<<"$pool" >/dev/null; then
                error "Pool $key is unsupported for daemon mining by the pinned XMRig build."
            fi
        done
    fi
    _validate_host_port "$url" "Pool url" "$example"
    for key in daemon-poll-interval daemon-job-timeout daemon-zmq-port; do
        jq -e --arg k "$key" 'has($k)' <<<"$pool" >/dev/null || continue
        [ "$daemon" = true ] || error "Pool $key requires a daemon pool."
        if ! jq -e --arg k "$key" '.[$k] | type == "number" and . >= 1 and . <= 9007199254740991 and . == floor' <<<"$pool" >/dev/null; then
            error "Pool $key must be an integer between 1 and 9007199254740991."
        fi
        if [ "$key" = daemon-zmq-port ] && ! jq -e '."daemon-zmq-port" <= 65535' <<<"$pool" >/dev/null; then
            error "Pool daemon-zmq-port must be between 1 and 65535."
        fi
    done
}

_active_daemon_pool() {
    local summary="${1:-}"
    [ -n "$summary" ] || summary='{}'
    jq -ce --argjson s "$summary" '
        def authority: sub("^daemon\\+https?://"; "");
        [.pools[]? | select(.enabled != false)] as $p |
        ($s.connection.pool // "") as $url |
        ([$p[] | select((.url | authority) == ($url | authority))][0] //
            (if $url == "" then $p[0] else null end)) |
        select(. != null and ($s.connection.mode // "daemon") == "daemon") |
        select(.daemon == true or (.url | startswith("daemon+http://") or startswith("daemon+https://")))
    ' "$CONFIG_JSON" 2>/dev/null
}

_daemon_node_status() {
    local pool="$1" url target body status tls
    if ! (_validate_pool_url "$pool" "") >/dev/null 2>&1; then
        printf 'daemon-down\n'
        return 0
    fi
    url=$(jq -r '.url' <<<"$pool")
    target="$url"
    tls=$(jq -r '.tls == true' <<<"$pool")
    case "$url" in
    daemon+http://*) url=${url#*://} ;;
    daemon+https://*) url=${url#*://} tls=true ;;
    esac
    if [ "$tls" = true ]; then url="https://$url"; else url="http://$url"; fi
    body=$(curl -q -fsS --noproxy '*' --proto '=http,https' --connect-timeout 2 --max-time 5 --max-filesize 65536 --header 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":"rigforge","method":"get_info"}' --url "$url/json_rpc" 2>/dev/null) || body=""
    if ! status=$(jq -ser --arg url "$target" 'if length == 1 and (.[0] | .error == null and (.result | .status == "OK" and (.height | type == "number" and . >= 0 and floor == .) and (.synchronized | type == "boolean"))) then .[0] | ["daemon", $url, .result.height, (if .result.synchronized then "synced" else "syncing" end)] | @tsv else error("invalid node response") end' <<<"$body" 2>/dev/null); then
        printf 'daemon-down\n'
        return 0
    fi
    printf '%s\n' "$status"
}

_doctor_daemon_status() {
    local state url height sync
    IFS=$'\t' read -r state url height sync <<<"$1"
    if [ "$state" = daemon ]; then
        if [ "$sync" = synced ]; then
            _ck_ok "node connection live: height $height ($sync)"
        else
            _ck_warn "node is syncing: height $height ($sync)"
            return 1
        fi
    else
        _ck_warn "node get_info is unavailable, invalid or timed out — check the configured daemon and its RPC access"
        return 1
    fi
}
