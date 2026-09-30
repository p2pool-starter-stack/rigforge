#!/usr/bin/env bash
# #546: executed by the reserved harness's refresh-service override, never standalone on a rig.
# Reuses #540's fixed-helper wrappers, now inside real timer dispatches rather than a scratch A/B.
set -euo pipefail
# shellcheck disable=SC1090
source "$1"
refresh_profile_event() {
    printf 'refresh-profile: pid=%s helper=%s event=%s at_ns=%s duration_ns=%s rc=%s\n' \
        "$$" "$1" "$2" "$3" "$4" "$5" >&2
}
# No arguments, config values or payloads in diagnostics. Begin events identify an unfinished probe.
for probe in api_refresh parse_config _read_api_summary _api_rigforge_block _api_tune_json _api_power_json _health_json _cpu_eff_khz _mem_summary _msr_log_status _dmi _watchdog_json _api_config_json _api_config_meta_json _api_control_json _api_control_history_json; do
    declare -f "$probe" >/dev/null
    eval "$(declare -f "$probe" | sed "1s/$probe/${probe}_profile_original/")"
    eval "$probe() {
        local profile_start profile_end profile_rc
        profile_start=\$(date +%s%N)
        refresh_profile_event $probe begin \"\$profile_start\" 0 0
        ${probe}_profile_original \"\$@\"
        profile_rc=\$?
        profile_end=\$(date +%s%N)
        refresh_profile_event $probe end \"\$profile_end\" \"\$((profile_end - profile_start))\" \"\$profile_rc\"
        return \"\$profile_rc\"
    }"
done
api_refresh
