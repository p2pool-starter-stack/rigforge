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
