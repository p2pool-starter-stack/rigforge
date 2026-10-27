# shellcheck shell=bash
source "$(dirname "${BASH_SOURCE[0]}")/e2e-refresh-window.sh"
source "$(dirname "${BASH_SOURCE[0]}")/e2e-pithead-tokens.sh"

_control_curl() {
    local token="$1"
    shift
    printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "$token" | jq -Rs .)" | curl -q --noproxy '*' --config - "$@"
}

_control_startup_diagnostics() {
    local unit active log_file marker
    for unit in rigforge-api rigforge-control; do
        active=$(systemctl show "$unit.service" -p ActiveState --value 2>/dev/null) || active=unknown
        case "$active" in active | inactive | activating | deactivating | failed | reloading) ;; *) active=unknown ;; esac
        printf 'receiver-startup: unit=%s active=%s\n' "$unit" "$active" >&2
    done
    log_file=$(mktemp) || return 0
    if journalctl -u rigforge-control.service -n 80 --no-pager >"$log_file" 2>/dev/null; then
        for marker in 'Permission denied' 'Failed to load credential' 'Address already in use' 'ModuleNotFoundError' 'No such file or directory' 'SyntaxError' 'Failed at step CREDENTIALS' 'Traceback'; do
            if grep -Fq "$marker" "$log_file"; then printf 'receiver-startup: %s\n' "$marker" >&2; fi
        done
    fi
    rm -f "$log_file"
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
    port=$(jq -r '.control_port // 8082' "$CFG")
    api_port=$(jq -r '.api_port // 8081' "$CFG")
    _access_tokens_ready control "$port" setup || {
        _control_startup_diagnostics
        return 1
    }
    resp="$(mktemp)"
    code=$(_control_curl "$tok" -s -o "$resp" -w '%{http_code}' --max-time 10 \
        -H "Content-Type: application/json" -d "{\"DONATION\": $new}" "http://127.0.0.1:$port/apply" 2>/dev/null || true)
    cid=$(jq -r '.change_id // empty' "$resp" 2>/dev/null || true)
    rm -f "$resp"
    if [ "$code" = 202 ] && [ -n "$cid" ]; then
        ok "POST /apply accepted (change_id=$cid)"
    else
        _control_startup_diagnostics
        bad "POST /apply returned HTTP '$code' (expected 202)"
    fi
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
    appliance_pool_refusal "$tok" "$port"
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

appliance_pool_refusal() (
    local tok="$1" port="$2" dropin response request code cid body st waited=0 before
    dropin="${E2E_APPLIANCE_POLICY_DROPIN:-/run/systemd/system/rigforge-control-apply.service.d/583-pool-policy.conf}"
    [ ! -e "$dropin" ] || bad "appliance policy test override already exists"
    mkdir -p "$(dirname "$dropin")" || bad "cannot create appliance policy override directory"
    request=$(mktemp) || bad "cannot allocate appliance policy request"
    response=$(mktemp) || bad "cannot allocate appliance policy response"
    trap 'rm -f "$dropin" "$request" "$response"; systemctl daemon-reload' EXIT
    printf '[Service]\nEnvironment=RIGFORGE_APPLIANCE=1\n' >"$dropin" || bad "cannot write appliance policy override"
    systemctl daemon-reload || bad "cannot load appliance policy override"
    before=$(sha256sum "$CFG")
    jq -c '{pools:.pools,watchdog_interval_min:6}' "$CFG" >"$request" || bad "cannot prepare appliance policy request"
    code=$(_control_curl "$tok" -s -o "$response" -w '%{http_code}' --max-time 10 \
        -H 'Content-Type: application/json' --data-binary "@$request" "http://127.0.0.1:$port/apply" 2>/dev/null || true)
    cid=$(jq -r '.change_id // empty' "$response" 2>/dev/null || true)
    rm -f "$response"
    [ "$code" = 202 ] && [[ "$cid" =~ ^[0-9a-f]{16}$ ]] || bad "appliance pool request was not staged"
    while [ "$waited" -lt 30 ]; do
        body=$(_control_curl "$tok" -fsS --max-time 3 "http://127.0.0.1:$port/status?change_id=$cid" 2>/dev/null || true)
        st=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)
        case "$st" in applied | rejected | rolled_back | failed) break ;; esac
        sleep 1
        waited=$((waited + 1))
    done
    [ "$st" = rejected ] && printf '%s' "$body" | jq -e '.reason | contains("appliance-pools-read-only") and contains("rig.json")' >/dev/null &&
        [ "$before" = "$(sha256sum "$CFG")" ] &&
        ok "appliance pool edit rejected with ownership reason and config unchanged (#583)" ||
        bad "appliance pool edit did not reject atomically with ownership reason"
)
