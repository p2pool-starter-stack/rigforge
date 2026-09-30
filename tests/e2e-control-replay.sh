# shellcheck shell=bash
# #540: only the runner's private pithead-control fixture authorizes these replay cases.
REPLAY_RUNNER_LOCK=0
replay_lock() {
    case "${E2E_PITHEAD_CONTROL_FIXTURE:-}:$1" in
    :control-replay-*) die "replay requires the queued pithead-control fixture" ;;
    :*) rig_lock rigforge e2e-pithead ;;
    pithead-control:control-replay-thermal | pithead-control:control-replay-pools)
        [[ "${E2E_RIG_LOCK_UNIT:-}" =~ ^bench-ci-riglock-[a-zA-Z0-9_-]+-[0-9]+$ ]] &&
            systemctl is-active --quiet "$E2E_RIG_LOCK_UNIT" || die "runner reservation is unavailable"
        printf '%s' "${E2E_PITHEAD_CONTROL_CONTEXT:-}" | jq -e '.version == 1 and .fixture == "pithead-control" and .thermal.feed_deadline_s == 90 and .thermal.starting_scalars == {max_temp_c:100,DONATION:0,watchdog_interval_min:5} and (.unknown | type == "array" and length > 0)' >/dev/null || die "invalid replay context"
        printf '%s' "${IT_RIG_POOLS_PROBE:-}" | jq -e 'type == "array" and length > 0 and all(.[]; type == "object" and all(.url,.user,.pass; type == "string" and length > 0))' >/dev/null || die "missing private pools probe"
        REPLAY_RUNNER_LOCK=1
        ;;
    *) die "fixture requires one declaring replay phase" ;;
    esac
}
phase_control_replay_thermal() { phase_control_replay thermal; }
phase_control_replay_pools() { phase_control_replay pools; }

_replay_apply() { # JSON on stdin; credentials never become process arguments or log output.
    local request response code id curl_rc=0
    request=$(mktemp) || return 1
    response=$(mktemp) || {
        rm -f "$request"
        return 1
    }
    cat >"$request" || {
        rm -f "$request" "$response"
        return 1
    }
    code=$(_control_curl "$tok" -s -o "$response" -w '%{http_code}' --max-time 10 --max-filesize 16384 \
        -H 'Content-Type: application/json' --data-binary "@$request" "http://127.0.0.1:$port/apply" 2>/dev/null) || curl_rc=$?
    id=$(jq -ser 'select(length == 1) | .[0].change_id | select(type == "string" and test("^[0-9a-f]{16}$"))' "$response" 2>/dev/null || true)
    rm -f "$request" "$response"
    [ "$curl_rc" = 0 ] && [ "$code" = 202 ] && [ -n "$id" ] || return 1
    printf '%s\n' "$id"
}
_replay_status() {
    _control_curl "$tok" -fsS --max-time 3 --max-filesize 16384 "http://127.0.0.1:$port/status?change_id=$cid" 2>/dev/null |
        jq -sr 'select(length == 1) | .[0].status | select(. == "applied" or . == "pending" or . == "accepted" or . == "rolled_back" or . == "failed" or . == "rejected")' || true
}
_replay_settle() { # Preserve the recorded 90-second apply bound, without logging payloads.
    local started=$SECONDS st
    while [ "$((SECONDS - started))" -lt 90 ]; do
        st=$(_replay_status)
        refresh_profile_state allow-inactive || return 1
        [ "$((SECONDS - started))" -lt 90 ] || break
        case "$st" in
        applied) return 0 ;;
        rolled_back | failed | rejected) return 1 ;;
        esac
        sleep 5
    done
    return 1
}
_replay_window() { # <thermal|pools> -- publication of this exact ID, not a later change.
    local kind="$1" started=$SECONDS observed=0 body stamp temp terminal st elapsed
    while [ "$((SECONDS - started))" -lt 300 ]; do
        refresh_profile_state allow-inactive || return 1
        st=$(_replay_status)
        body=$(_control_curl "$tok" -fsS --max-time 3 --max-filesize 65536 "http://127.0.0.1:$api_port/1/summary" 2>/dev/null || true)
        # Only bounded scalar fields are exported; arbitrary responses/config remain private.
        stamp=$(printf '%s' "$body" | jq -sr 'select(length == 1) | .[0].generated_at | select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' 2>/dev/null || true)
        temp=$(printf '%s' "$body" | jq -sr 'select(length == 1) | .[0].rigforge.watchdog.max_temp_c | select(type == "number" and . >= 40 and . <= 110)' 2>/dev/null || true)
        terminal=$(printf '%s' "$body" | jq -sr --arg id "$cid" 'select(length == 1) | .[0] | ([.rigforge.control] + (.rigforge.control_history // [])) | any(.[]; .change_id == $id and .status == "applied")' 2>/dev/null || true)
        elapsed=$((SECONDS - started))
        printf 'replay-window: case=%s elapsed_s=%s change_id=%s status=%s generated_at=%s max_temp_c=%s published=%s\n' "$kind" "$elapsed" "$cid" "${st:-unknown}" "${stamp:-missing}" "${temp:-missing}" "${terminal:-false}"
        if [ "$elapsed" -lt 90 ] && [ "$st" = applied ] && [[ "$stamp" > "$before" ]] && [ "$observed" = 0 ]; then
            if [ "$terminal" = true ] && { [ "$kind" = pools ] || [ "$temp" = 102 ]; }; then observed=1; fi
        fi
        sleep 5
    done
    [ "$observed" = 1 ]
}
_replay_setup() {
    local stage
    stage=$(mktemp) || return 1
    # Token and endpoint enter jq through stdin. Promote the runner-added pool without
    # altering source pools, worker identities or credentials; refuse a missing bench pool.
    if printf '%s\n%s\n' "$tok" "$PITHEAD_URL" | jq -Rn --slurpfile cfg "$CFG" '
        [inputs] as $i | $cfg[0] |
        if any(.pools[]; .url == $i[1]) then
            .pools |= (map(select(.url == $i[1])) + map(select(.url != $i[1]))) |
            .api="enabled" | .control="enabled" | .ACCESS_TOKEN=$i[0] |
            .api_allow_from="127.0.0.1/32" | .watchdog="enabled" |
            .max_temp_c=100 | .DONATION=0 | .watchdog_interval_min=5
        else error("runner bench pool missing") end' >"$stage" && mv "$stage" "$CFG"; then
        "$RIGFORGE" apply >/dev/null 2>&1
    else
        rm -f "$stage"
        return 1
    fi
}
phase_control_replay() {
    local kind="$1" tok port api_port cid before payload
    [ "$REPLAY_RUNNER_LOCK" = 1 ] || bad "replay requires verified runner reservation"
    phase "control replay — $kind publication (#540)"
    tok=$(head -c 32 /dev/urandom | xxd -p -c 256)
    # Replay only the recorded scalars; preserve worker threads, tuning and payout identity.
    _replay_setup || bad "replay setup failed"
    phase_connect preserve-pools || bad "replay mining precondition failed"
    port=$(jq -r '.control_port // 8082' "$CFG")
    api_port=$(jq -r '.api_port // 8081' "$CFG")
    refresh_profile_start || bad "could not instrument replay"
    for payload in '{"max_temp_c":101}' '{"max_temp_c":100}' '{"DONATION":1}' '{"DONATION":0}' '{"watchdog_interval_min":6}' '{"watchdog_interval_min":5}'; do
        cid=$(printf '%s' "$payload" | _replay_apply) || bad "replay scalar apply refused"
        _replay_settle || bad "replay scalar apply did not settle within 90s"
    done
    before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cid=$(printf '%s' "$IT_RIG_POOLS_PROBE" | jq -c '{pools:.}' | _replay_apply) || bad "replay pools apply refused"
    if [ "$kind" = thermal ]; then
        _replay_settle || bad "replay pools apply did not settle within 90s"
        [ "$(jq -r .max_temp_c "$CFG")" = 100 ] || bad "thermal baseline is not 100"
        before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        cid=$(printf '{"max_temp_c":102}' | _replay_apply) || bad "replay thermal apply refused"
    fi
    local rc=0
    _replay_window "$kind" || rc=1
    refresh_profile_finish || bad "replay profiling or restoration failed"
    [ "$rc" = 0 ] && ok "replay $kind published within 90s (#540)" || bad "replay $kind feed stale after 90s (#540)"
}
