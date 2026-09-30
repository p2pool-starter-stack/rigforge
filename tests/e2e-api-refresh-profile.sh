#!/usr/bin/env bash
# Read-only comparison for #540; invoked by the reserved control phase, never standalone.
set -euo pipefail
# shellcheck disable=SC1090
source "$1"
TMPDIR=${TMPDIR:-/run}
RIGFORGE_API_DATA=$(mktemp -d "$TMPDIR/rigforge-refresh-profile.XXXXXX")
export RIGFORGE_API_DATA
trap 'rm -rf "$RIGFORGE_API_DATA"' EXIT
eval "$(declare -f _cpu_eff_khz | sed '1s/_cpu_eff_khz/_cpu_eff_khz_builtin/')"
_cpu_eff_khz_legacy() {
    local f v sum=0 n=0
    for f in "$CPU_SYSFS"/cpu[0-9]*/cpufreq/scaling_cur_freq; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null)
        case "$v" in '' | *[!0-9]*) continue ;; esac
        sum=$((sum + v))
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && echo $((sum / n)) || echo ""
}
# Fixed helper names only; emit durations, never arguments or probe values.
for probe in parse_config _read_api_summary _api_tune_json _api_power_json _health_json _mem_summary _msr_log_status _dmi _watchdog_json _api_config_json _api_config_meta_json _api_control_json _api_control_history_json; do
    eval "$(declare -f "$probe" | sed "1s/$probe/${probe}_profile_original/")"
    eval "$probe() { local started=\$SECONDS rc; ${probe}_profile_original \"\$@\"; rc=\$?; printf 'refresh-profile: %s $probe %ss\\n' \"\$mode\" \"\$((SECONDS - started))\" >&2; return \"\$rc\"; }"
done
for mode in legacy builtin builtin legacy; do
    systemctl is-active --quiet "$SERVICE_NAME"
    systemctl show rigforge-api-refresh.timer rigforge-api-refresh.service -p ActiveState -p SubState -p LastTriggerUSec
    _cpu_eff_khz() {
        local started=$SECONDS rc
        "_cpu_eff_khz_$mode"
        rc=$?
        printf 'refresh-profile: %s clock probe %ss\n' "$mode" "$((SECONDS - started))" >&2
        return "$rc"
    }
    started=$SECONDS
    api_refresh
    jq -e '.generated_at and .rigforge.watchdog and .rigforge.health.service_active' "$RIGFORGE_API_DATA/summary.json" >/dev/null
    printf 'refresh-profile: %s complete refresh %ss\n' "$mode" "$((SECONDS - started))"
    systemctl is-active --quiet "$SERVICE_NAME"
    systemctl show rigforge-api-refresh.timer rigforge-api-refresh.service -p ActiveState -p SubState -p LastTriggerUSec
done
