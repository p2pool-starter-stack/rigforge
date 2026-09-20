# shellcheck shell=bash
# ACCESS_TOKENS phase for e2e-pithead.sh (#516), split out to stay under e2e-pithead.sh's file
# budget (docs/dev/file-budget.tsv) — same convention as e2e-pithead-control.sh. Sourced by
# e2e-pithead.sh AFTER phase()/ok()/bad()/set_cfg()/$CFG are defined; must not be run standalone.
phase_access_tokens() {
    phase "access-tokens — a non-master ACCESS_TOKENS entry authenticates :8081 and :8082 (#516)"
    local master bench cur new port resp code cid st waited=0 body bread
    master=$(head -c 32 /dev/urandom | xxd -p -c 256)
    bench=$(head -c 32 /dev/urandom | xxd -p -c 256)
    cur=$(jq -r '.DONATION // 1' "$CFG")
    new=$(((cur + 1) % 101))
    set_cfg ".api=\"enabled\" | .control=\"enabled\" | .ACCESS_TOKEN=\"$master\" | .ACCESS_TOKENS={\"bench\":\"$bench\"} | .api_allow_from=\"127.0.0.1/32\"" ||
        bad "could not enable api+control with a named ACCESS_TOKENS entry"
    sleep 3 # let the sister API + control services (restarted by apply) settle
    port=$(jq -r '.control_port // 8082' "$CFG")

    # :8080 stays master-only — a named entry must not reach xmrig's own API. The refusal code is a
    # present-but-wrong Bearer, not a missing one, and varies by xmrig version (same reasoning as
    # e2e-pithead.sh's phase_worker_api restricted-PUT check); != 200 is the contract.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $bench" http://127.0.0.1:8080/2/summary 2>/dev/null || true)
    [ -n "$code" ] && [ "$code" != 200 ] && ok "the bench entry is refused on :8080 (master-only, $code, #516)" || bad ":8080 answered $code to a non-master entry (expected refusal)"

    # :8081 — the sister API accepts the bench entry raw, and its own derived read bearer.
    body=$(curl -fsS --max-time 10 -H "Authorization: Bearer $bench" "http://127.0.0.1:$(jq -r '.api_port // 8081' "$CFG")/health" 2>/dev/null || true)
    printf '%s' "$body" | jq -e . >/dev/null 2>&1 && ok "a non-master ACCESS_TOKENS entry authenticates :8081 raw (#516)" || bad ":8081 refused the bench entry raw"
    bread=$(printf 'rigforge:api-read:v1' | openssl dgst -sha256 -hmac "$bench" | awk '{print $NF}')
    body=$(curl -fsS --max-time 10 -H "Authorization: Bearer $bread" "http://127.0.0.1:$(jq -r '.api_port // 8081' "$CFG")/health" 2>/dev/null || true)
    printf '%s' "$body" | jq -e . >/dev/null 2>&1 && ok "the bench entry's derived read bearer authenticates :8081 too (#516)" || bad ":8081 refused the bench entry's derived read bearer"

    # :8082 — a full apply round trip authenticated with the bench entry, never the master.
    resp="$(mktemp)"
    code=$(curl -s -o "$resp" -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $bench" \
        -H "Content-Type: application/json" -d "{\"DONATION\": $new}" "http://127.0.0.1:$port/apply" 2>/dev/null || true)
    cid=$(jq -r '.change_id // empty' "$resp" 2>/dev/null || true)
    rm -f "$resp"
    [ "$code" = 202 ] && [ -n "$cid" ] && ok "a non-master ACCESS_TOKENS entry authenticates :8082's POST /apply (#516, change_id=$cid)" ||
        bad ":8082 POST /apply with the bench entry returned HTTP '$code' (expected 202)"
    while [ "$waited" -lt 300 ]; do
        body=$(curl -fsS --max-time 5 -H "Authorization: Bearer $bench" "http://127.0.0.1:$port/status?change_id=$cid" 2>/dev/null || true)
        st=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)
        case "$st" in applied | rejected | rolled_back | failed) break ;; esac
        sleep 5
        waited=$((waited + 5))
    done
    [ "$st" = applied ] && ok "DONATION $cur -> $new reached 'applied' via the bench entry within ${waited}s (#516)" ||
        bad "bench-entry DONATION change $cid did not reach 'applied' within 300s (last status: ${st:-unreachable})"

    # Revocation: drop the entry and confirm it stops on both ports (red before / green after #516).
    set_cfg '.ACCESS_TOKENS={}' || bad "could not revoke the bench ACCESS_TOKENS entry"
    sleep 3
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $bench" "http://127.0.0.1:$(jq -r '.api_port // 8081' "$CFG")/health" 2>/dev/null || true)
    [ "$code" = 401 ] && ok "a revoked ACCESS_TOKENS entry stops authenticating :8081 (#516)" || bad "revoked entry still answered $code on :8081"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H "Authorization: Bearer $bench" -H 'Content-Type: application/json' -d '{"DONATION":1}' "http://127.0.0.1:$port/apply" 2>/dev/null || true)
    [ "$code" = 401 ] && ok "a revoked ACCESS_TOKENS entry stops authenticating :8082 (#516)" || bad "revoked entry still answered $code on :8082"
    # No further restoration here: _cleanup's EXIT trap restores DONATION, the tokens and the
    # control state from the snapshot, same convention as phase_control.
}
