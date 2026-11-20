#!/usr/bin/env bash

_DR_JSON_FILE=""

_dr_record() {
    [ -n "$_DR_JSON_FILE" ] || return 0
    jq -cn --arg status "$1" --arg message "$2" --arg id "$3" \
        '{id: $id, status: $status, message: $message}' >>"$_DR_JSON_FILE" || exit 1
}

_ck_ok() { _dr_record ok "$1" "${2:-}" && echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
_ck_warn() { _dr_record warn "$1" "${2:-}" && echo -e "  ${C_YELLOW}!${C_RESET} $1"; }
_ck_info() { _dr_record info "$1" "${2:-}" && echo -e "  ${C_BLUE}∙${C_RESET} $1"; }

_doctor_placement() {
    local body cores
    if [ "$1" != y ]; then
        _ck_info "thread placement unavailable: the miner is not running" thread-placement
        return 0
    fi
    body=$(ACCESS_TOKEN="$(jq -r '.ACCESS_TOKEN // empty' "$CONFIG_JSON" 2>/dev/null || true)" _read_api_summary backends)
    if [ -z "$body" ]; then
        _ck_info "thread placement unavailable: /2/backends is not reachable" thread-placement
        return 0
    fi
    cores=$(jq -r '[.[]? | select(.type == "cpu") | .threads[]? | .affinity | select(. != null)] | if length == 0 then empty else "\(length) thread(s), affinity " + (map(tostring) | join(",")) end' <<<"$body" 2>/dev/null || true)
    if [ -n "$cores" ]; then
        _ck_info "thread placement: $cores (-1 = not pinned)" thread-placement
    else
        _ck_info "thread placement unavailable: /2/backends reported no CPU thread affinity" thread-placement
    fi
}

_bundle_topology() {
    local bin="$1/xmrig/build/xmrig" out="$1/xmrig/build/topology.xml"
    [ -x "$bin" ] || { echo "miner-not-built" && return 1; }
    "$bin" --help 2>&1 </dev/null | grep -q -- '--export-topology' || { echo "export-topology-unsupported" && return 1; }
    command -v timeout >/dev/null 2>&1 || { echo "no-timeout-binary" && return 1; }
    rm -f "$out" 2>/dev/null
    [ ! -e "$out" ] || { echo "stale-export-not-removable" && return 1; }
    timeout 20 "$bin" --export-topology >/dev/null 2>&1 </dev/null || true
    [ -s "$out" ] || { echo "export-failed" && return 1; }
    cp "$out" "$2" || { rm -f "$out" && echo "copy-failed" && return 1; }
    rm -f "$out"
}

doctor_json() (
    local _DR_JSON_FILE rc=0 version
    command -v jq >/dev/null 2>&1 || error "doctor --json requires jq."
    _DR_JSON_FILE=$(mktemp) || return 1
    trap 'rm -f "$_DR_JSON_FILE"' EXIT
    (doctor) >&2 || rc=$?
    version=$(cmd_version)
    jq -s --arg version "${version#RigForge }" --argjson exit "$rc" '
        {version: $version, exit: $exit,
         summary: {ok: (map(select(.status == "ok")) | length),
                   warn: (map(select(.status == "warn")) | length),
                   fail: (map(select(.status == "fail")) | length),
                   info: (map(select(.status == "info")) | length)},
         checks: .}' "$_DR_JSON_FILE" || return 1
    return "$rc"
)

doctor_command() {
    if [ "$#" -eq 0 ]; then
        doctor
    elif [ "$#" -eq 1 ] && [ "$1" = --json ]; then
        doctor_json
    else
        error "Unexpected argument for doctor: '${2:-$1}'. Run '$0 help'."
    fi
}
