# shellcheck shell=bash
# control phase for e2e-pithead.sh (#509), split out to stay under e2e-pithead.sh's file budget
# (docs/dev/file-budget.tsv) — same convention as tests/run.sh sourcing its own test-e2e-*.sh
# fragments. Sourced by e2e-pithead.sh AFTER phase()/ok()/bad()/set_cfg()/$CFG are defined; this
# file declares no preflight of its own and must not be run standalone.
phase_control() {
    phase "control — writable control path DONATION apply round trip (#344/#509)"
    local tok cur new port resp code cid st waited=0 body
    tok=$(head -c 32 /dev/urandom | xxd -p -c 256)
    cur=$(jq -r '.DONATION // 1' "$CFG")
    new=$(((cur + 1) % 101))
    set_cfg ".api=\"enabled\" | .control=\"enabled\" | .ACCESS_TOKEN=\"$tok\" | .api_allow_from=\"127.0.0.1/32\"" || bad "could not enable the control path"
    sleep 3 # let rigforge-control.service (restarted by install_control) settle
    port=$(jq -r '.control_port // 8082' "$CFG")
    resp="$(mktemp)"
    code=$(curl -s -o "$resp" -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" -d "{\"DONATION\": $new}" "http://127.0.0.1:$port/apply" 2>/dev/null || true)
    cid=$(jq -r '.change_id // empty' "$resp" 2>/dev/null || true)
    rm -f "$resp"
    [ "$code" = 202 ] && [ -n "$cid" ] && ok "POST /apply accepted (change_id=$cid)" || bad "POST /apply returned HTTP '$code' (expected 202)"
    while [ "$waited" -lt 300 ]; do
        body=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" "http://127.0.0.1:$port/status?change_id=$cid" 2>/dev/null || true)
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
    # No token blanking here: _cleanup's EXIT trap restores DONATION, the token and the control
    # state from the snapshot, and blanking ACCESS_TOKEN while control is enabled is #514's own
    # fail-closed abort (rigforge.sh refuses that apply) — the bug this phase must not re-enact.
}
