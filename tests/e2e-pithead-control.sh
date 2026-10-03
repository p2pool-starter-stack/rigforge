# shellcheck shell=bash
# control phase for e2e-pithead.sh (#509), split out to stay under e2e-pithead.sh's file budget
# (docs/dev/file-budget.tsv) — same convention as tests/run.sh sourcing its own test-e2e-*.sh
# fragments. Sourced by e2e-pithead.sh AFTER phase()/ok()/bad()/set_cfg()/$CFG are defined; this
# file declares no preflight of its own and must not be run standalone.
source "$(dirname "${BASH_SOURCE[0]}")/e2e-refresh-window.sh"

_control_curl() { # Keep the temporary write token out of process arguments.
    local token="$1"
    shift
    printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "$token" | jq -Rs .)" | curl -q --noproxy '*' --config - "$@"
}

phase_control() {
    phase "control — writable control path DONATION apply round trip (#344/#509)"
    local tok cur new port api_port resp code cid st waited=0 body max_temp target_temp
    tok=$(head -c 32 /dev/urandom | xxd -p -c 256)
    cur=$(jq -r '.DONATION // 1' "$CFG")
    new=$(((cur + 1) % 101))
    max_temp=$(jq -r 'if .max_temp_c == null or .max_temp_c == "" then 100 else .max_temp_c end' "$CFG")
    [ "$max_temp" -le 100 ] || max_temp=100
    [ "$max_temp" -gt 40 ] || bad "cannot lower the existing thermal cutoff safely"
    target_temp=$((max_temp - 1))
    printf '%s' "$tok" | set_cfg '.api="enabled" | .control="enabled" | .ACCESS_TOKEN=$token | .api_allow_from="127.0.0.1/32" | .watchdog="enabled" | .max_temp_c=$max_temp' soft \
        --rawfile token /dev/stdin --argjson max_temp "$max_temp" || bad "could not enable the control path"
    sleep 3 # let rigforge-control.service (restarted by install_control) settle
    port=$(jq -r '.control_port // 8082' "$CFG")
    api_port=$(jq -r '.api_port // 8081' "$CFG")
    resp="$(mktemp)"
    code=$(_control_curl "$tok" -s -o "$resp" -w '%{http_code}' --max-time 10 \
        -H "Content-Type: application/json" -d "{\"DONATION\": $new}" "http://127.0.0.1:$port/apply" 2>/dev/null || true)
    cid=$(jq -r '.change_id // empty' "$resp" 2>/dev/null || true)
    rm -f "$resp"
    [ "$code" = 202 ] && [ -n "$cid" ] && ok "POST /apply accepted (change_id=$cid)" || bad "POST /apply returned HTTP '$code' (expected 202)"
    while [ "$waited" -lt 300 ]; do
        body=$(_control_curl "$tok" -fsS --max-time 5 "http://127.0.0.1:$port/status?change_id=$cid" 2>/dev/null || true)
        st=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)
        case "$st" in applied | rejected | rolled_back | failed) break ;; esac
        sleep 5
        waited=$((waited + 5))
    done
    [ "$st" = applied ] &&
        ok "DONATION $cur -> $new reached 'applied' within ${waited}s (#344/#509)" ||
        bad "DONATION change $cid did not reach 'applied' within 300s (last status: ${st:-unreachable})"
    [ "$(jq -r '.DONATION' "$CFG")" = "$new" ] &&
        ok "config.json carries DONATION=$new (control-apply persisted it)" ||
        bad "config.json DONATION is '$(jq -r '.DONATION' "$CFG")', expected $new"
    refresh_profile_start || bad "could not instrument timer-driven refreshes"
    sleep 20 # allow a natural timer dispatch before thermal apply
    local before feed_temp feed_stamp started observed=0
    before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    resp="$(mktemp)" || bad "could not allocate the thermal response file"
    code=$(_control_curl "$tok" -s -o "$resp" -w '%{http_code}' --max-time 10 \
        -H "Content-Type: application/json" -d "{\"max_temp_c\":$target_temp}" "http://127.0.0.1:$port/apply" 2>/dev/null || true)
    cid=$(jq -r '.change_id // empty' "$resp" 2>/dev/null || true)
    rm -f "$resp"
    [ "$code" = 202 ] && [ -n "$cid" ] || bad "max_temp_c apply was not accepted (HTTP $code)"
    started=$SECONDS
    while [ "$((SECONDS - started))" -lt 300 ]; do
        refresh_profile_state || bad "miner or refresh-state observation failed"
        body=$(_control_curl "$tok" -fsS --max-time 5 "http://127.0.0.1:$port/status?change_id=$cid" 2>/dev/null || true)
        st=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)
        body=$(_control_curl "$tok" -fsS --max-time 5 "http://127.0.0.1:$api_port/1/summary" 2>/dev/null || true)
        feed_temp=$(printf '%s' "$body" | jq -r '.rigforge.watchdog.max_temp_c // empty' 2>/dev/null || true)
        feed_stamp=$(printf '%s' "$body" | jq -r '.generated_at // empty' 2>/dev/null || true)
        printf 'refresh-window: elapsed_s=%s status=%s max_temp_c=%s generated_at=%s\n' "$((SECONDS - started))" "${st:-unknown}" "${feed_temp:-missing}" "${feed_stamp:-missing}"
        if [ "$((SECONDS - started))" -lt 90 ] && [ "$st" = applied ] && [ "$feed_temp" = "$target_temp" ] && [[ "$feed_stamp" > "$before" ]] && [ "$observed" = 0 ]; then
            observed=$((SECONDS - started + 1))
        fi
        sleep 5
    done
    refresh_profile_finish || bad "timer profiling or restoration failed"
    waited=$((observed - 1))
    [ "$observed" -gt 0 ] &&
        ok "applied max_temp_c reaches a new direct sister-API summary within ${waited}s (#540)" ||
        bad "max_temp_c feed stale after 90s (status=${st:-unknown}, temp=${feed_temp:-missing}, generated_at=${feed_stamp:-missing})"
    # No token blanking here: _cleanup's EXIT trap restores DONATION, the token and the control
    # state from the snapshot, and blanking ACCESS_TOKEN while control is enabled is #514's own
    # fail-closed abort (rigforge.sh refuses that apply) — the bug this phase must not re-enact.
}
