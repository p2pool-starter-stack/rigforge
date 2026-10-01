#!/usr/bin/env bash
# #546: executed by the reserved harness's refresh-service override, never standalone on a rig.
# Reuses #540's fixed-helper wrappers, now inside real timer dispatches rather than a scratch A/B.
set -euo pipefail
# shellcheck disable=SC1090
source "$1"
PROFILE_CLOCK_TICKS=$(getconf CLK_TCK)
[[ "$PROFILE_CLOCK_TICKS" =~ ^[1-9][0-9]*$ ]]
refresh_profile_cpu() {
    local stat runtime wait slices field profile_pid="${BASHPID:-$$}"
    local -a fields
    IFS= read -r stat <"${REFRESH_PROFILE_STAT_FILE:-/proc/$profile_pid/stat}" || return 1
    # comm may contain spaces or parentheses; every field after its final ')' is numeric/state.
    read -r -a fields <<<"${stat##*) }"
    read -r runtime wait slices <"${REFRESH_PROFILE_SCHEDSTAT_FILE:-/proc/$profile_pid/schedstat}" || return 1
    for field in "${fields[11]:-}" "${fields[12]:-}" "${fields[13]:-}" "${fields[14]:-}" "$runtime" "$wait" "$slices"; do
        [[ "$field" =~ ^[0-9]+$ ]] || return 1
    done
    [[ "${fields[16]:-}" =~ ^-?[0-9]+$ ]] && [ "${fields[16]}" -ge -20 ] && [ "${fields[16]}" -le 19 ] || return 1
    # CPU ticks include this shell and waited-for children; scheduler delay is this shell only.
    printf 'refresh-profile-cpu: pid=%s event=%s cpu_ticks=%s clock_ticks_per_s=%s nice=%s scheduler_wait_ns=%s\n' \
        "$profile_pid" "$1" "$((10#${fields[11]} + 10#${fields[12]} + 10#${fields[13]} + 10#${fields[14]}))" "$PROFILE_CLOCK_TICKS" "${fields[16]}" "$wait" >&2
}
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
        [ $probe != api_refresh ] || refresh_profile_cpu begin
        ${probe}_profile_original \"\$@\"
        profile_rc=\$?
        [ $probe != api_refresh ] || refresh_profile_cpu end
        profile_end=\$(date +%s%N)
        refresh_profile_event $probe end \"\$profile_end\" \"\$((profile_end - profile_start))\" \"\$profile_rc\"
        return \"\$profile_rc\"
    }"
done
api_refresh
