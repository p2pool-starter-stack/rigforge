#!/usr/bin/env bash
# Worker ↔ stack contract gate (#114): drive a REAL provisioned RigForge worker against a LIVE
# Pithead stack and assert the integration contract documented in docs/pithead-integration.md.
# Release-gated and manual, like e2e-real.sh — GitHub runners can't reach a LAN stack.
#
#   PITHEAD_URL=gouda.lan:3333 sudo bash tests/e2e-pithead.sh all
#
# Env knobs:
#   PITHEAD_URL                  (required) the stack's stratum host:port
#   E2E_STRATUM_PASS             opt-in: run the stratum-auth phases with this stack secret
#   E2E_DASH_URL                 opt-in: dashboard workers payload URL (worker must appear in it)
#   E2E_SHARE_TIMEOUT            seconds to wait for an accepted share (default 180)
#   E2E_DROPOFF_TIMEOUT          seconds for the dashboard to drop a stopped worker (default 300)
#   E2E_API_IMPACT_TOLERANCE_PCT max hashrate loss under sister-API load (default 3)
#
# Preconditions: a provisioned worker on this rig (`setup` has run; the miner may be running).
# The operator's config.json is snapshotted and restored (+ `apply`) on exit, whatever happens.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIGFORGE="$HERE/rigforge.sh"
CFG="$HERE/config.json"

PASS=0
FAIL=0
ok() {
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
    PASS=$((PASS + 1))
}
bad() {
    printf '  \033[1;31m✗\033[0m %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}
skip() { printf '  \033[1;33m∙\033[0m SKIP: %s\n' "$1"; }
phase() { printf '\n\033[1m== e2e-pithead: %s ==\033[0m\n' "$1"; }
die() {
    printf '\033[31me2e-pithead: %s\033[0m\n' "$1" >&2
    exit 2
}

require_preflight() {
    [ "$(uname -s)" = "Linux" ] || die "Linux-only (this host is $(uname -s)) — run on a real rig."
    [ "$(id -u)" -eq 0 ] || die "must run as root (service control / apply): sudo bash tests/e2e-pithead.sh $*"
    [ -x "$RIGFORGE" ] || die "$RIGFORGE not found or not executable."
    [ -n "${PITHEAD_URL:-}" ] || die "PITHEAD_URL is required (the stack's stratum host:port, e.g. gouda.lan:3333)."
    [ -f "$CFG" ] || die "no $CFG — run setup first (this gate needs a provisioned worker)."
    WLOG="$(find "$HERE" -path '*worker*' -name xmrig.log 2>/dev/null | head -1)"
    GEN_CFG="$(find "$HERE" -path '*worker*/xmrig/build/config.json' 2>/dev/null | head -1)"
    [ -n "$GEN_CFG" ] || die "no generated worker config found — run setup first."
}

# --- operator-config snapshot: whatever happens, the rig leaves this gate as it entered it ---
SAVED_CFG=""
HAMMER_PIDS=""
_cleanup() {
    # Stop any API load generators first, then put the operator's config back and re-apply it.
    local p
    for p in $HAMMER_PIDS; do kill "$p" 2>/dev/null || true; done
    if [ -n "$SAVED_CFG" ] && [ -f "$SAVED_CFG" ]; then
        cp "$SAVED_CFG" "$CFG"
        "$RIGFORGE" apply >/dev/null 2>&1 || true
    fi
}
snapshot_config() {
    SAVED_CFG="$(mktemp)"
    cp "$CFG" "$SAVED_CFG"
    trap '_cleanup' EXIT
}

# Edit the operator config with a jq program and roll it out (apply = regenerate + restart).
set_cfg() { # <jq program>
    local tmp
    tmp="$(mktemp)"
    jq "$1" "$CFG" >"$tmp" && mv "$tmp" "$CFG"
    "$RIGFORGE" apply >/dev/null 2>&1 || true
}

api8080() { # [curl args...] -> body (empty on failure); token-aware like rigforge's own reader
    local tok auth=()
    tok=$(jq -r '.ACCESS_TOKEN // empty' "$CFG" 2>/dev/null || true)
    [ -n "$tok" ] && auth=(-H "Authorization: Bearer $tok")
    curl -fsS --max-time 5 "${auth[@]}" "$@" 2>/dev/null || true
}

live_hashrate() { # 10s-window hashrate from the worker API, empty if none
    api8080 http://127.0.0.1:8080/2/summary | jq -r '.hashrate.total[0] // empty' 2>/dev/null || true
}

wait_for_job() { # <timeout_s> -> 0 when the log shows a stratum job
    local waited=0
    while [ "$waited" -lt "$1" ]; do
        grep -q 'new job from' "$WLOG" 2>/dev/null && return 0
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# --- phases ---

phase_connect() {
    phase "connect — worker mines against the live stack ($PITHEAD_URL)"
    set_cfg ".pools[0].url = \"$PITHEAD_URL\""
    systemctl is-active --quiet xmrig || "$RIGFORGE" start >/dev/null 2>&1 || true
    [ -n "$WLOG" ] || WLOG="$(find "$HERE" -path '*worker*' -name xmrig.log 2>/dev/null | head -1)"
    if [ -z "$WLOG" ]; then
        bad "could not find the worker's xmrig.log"
        return 0
    fi
    : >"$WLOG" || true # truncate so every assertion below is about THIS stack, not an old pool
    "$RIGFORGE" restart >/dev/null 2>&1 || true
    if wait_for_job 60; then
        ok "connected — stratum job from $(grep -oE 'new job from [^ ]+' "$WLOG" | tail -1 | awk '{print $NF}')"
    else
        bad "no stratum job from $PITHEAD_URL within 60s — is the stack up and reachable?"
    fi
    local share_to="${E2E_SHARE_TIMEOUT:-180}" waited=0
    while [ "$waited" -lt "$share_to" ] && ! grep -q 'accepted (' "$WLOG" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
    done
    if grep -q 'accepted (' "$WLOG" 2>/dev/null; then
        ok "share accepted by the stack ($(grep -c 'accepted (' "$WLOG") so far)"
    else
        bad "no accepted share within ${share_to}s"
    fi
    # Discovery contract: the dashboard identifies workers by the stratum `user` label.
    local user
    user=$(jq -r '.pools[0].user' "$GEN_CFG" 2>/dev/null || true)
    if [ "$user" = "$(hostname)" ] || [ -n "$user" ]; then
        ok "stratum user label set ('$user') — what the dashboard discovers by"
    else
        bad "generated config has no pools[0].user"
    fi
}

phase_worker_api() {
    phase "worker-api — the :8080 contract (open read-only by default; Bearer when ACCESS_TOKEN set)"
    local body code
    body=$(curl -fsS --max-time 5 http://127.0.0.1:8080/2/summary 2>/dev/null || true)
    if [ -n "$body" ] && printf '%s' "$body" | jq -e '.hashrate' >/dev/null 2>&1; then
        ok "default posture: /2/summary readable with no token"
    else
        bad "default posture: /2/summary not readable without a token"
    fi
    if [ "$(jq -r '.http.host' "$GEN_CFG" 2>/dev/null)" = "0.0.0.0" ]; then
        ok "API bound to 0.0.0.0 (reachable from the stack host)"
    else
        bad "API not bound to 0.0.0.0 — the dashboard can't reach it"
    fi
    # restricted:true — control endpoints refuse. The refusal code varies by xmrig version; != 200 is the contract.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X PUT http://127.0.0.1:8080/1/config 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != 200 ]; then
        ok "restricted: PUT /1/config refused ($code)"
    else
        bad "restricted NOT enforced: PUT /1/config answered $code"
    fi
    # Custom-token pairing (worker half of pithead#171): unauthed read fails, matching Bearer works.
    set_cfg '.ACCESS_TOKEN = "tok-114"'
    sleep 3 # give the restarted miner a beat to bind
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/2/summary 2>/dev/null || true)
    if [ "$code" = 401 ]; then
        ok "custom token: unauthed read -> 401"
    else
        bad "custom token: unauthed read answered $code (want 401)"
    fi
    body=$(curl -fsS --max-time 5 -H "Authorization: Bearer tok-114" http://127.0.0.1:8080/2/summary 2>/dev/null || true)
    if printf '%s' "$body" | jq -e '.hashrate' >/dev/null 2>&1; then
        ok "custom token: matching Bearer -> 200"
    else
        bad "custom token: matching Bearer failed"
    fi
    set_cfg '.ACCESS_TOKEN = ""' # back to the open default before the next phase
}

phase_api_impact() {
    phase "api-impact — the sister API must not shave hashrate (#99 perf guard)"
    set_cfg '.api = "enabled"'
    local body=""
    for _ in 1 2 3 4 5; do
        body=$(curl -fsS --max-time 8 http://127.0.0.1:8081/health 2>/dev/null || true)
        [ -n "$body" ] && break
        sleep 3
    done
    if ! printf '%s' "$body" | jq -e '.service_active' >/dev/null 2>&1; then
        bad "sister API did not come up on :8081 — cannot measure impact"
        return 0
    fi
    ok "sister API serving on :8081"
    # Let the 10s hashrate window warm up, then sample a baseline.
    local waited=0 hr
    while [ "$waited" -lt 90 ]; do
        hr=$(live_hashrate)
        if [ -n "$hr" ] && awk -v h="$hr" 'BEGIN{exit !(h > 0)}'; then break; fi
        sleep 3
        waited=$((waited + 3))
    done
    if [ -z "$hr" ] || ! awk -v h="$hr" 'BEGIN{exit !(h > 0)}'; then
        bad "no live hashrate to baseline against"
        return 0
    fi
    sample_mean() { # <n> <interval_s> -> mean of n live-hashrate samples
        local n=$1 iv=$2 v vals=""
        for _ in $(seq 1 "$n"); do
            v=$(live_hashrate)
            [ -n "$v" ] && vals="$vals $v"
            sleep "$iv"
        done
        # shellcheck disable=SC2086 # word-splitting the sample list is the point
        printf '%s\n' $vals | awk '{s += $1; n++} END {if (n > 0) printf "%.1f", s / n}'
    }
    local base loaded p tol="${E2E_API_IMPACT_TOLERANCE_PCT:-3}"
    base=$(sample_mean 6 5)
    # Worst-case polling: several clients hammering the heaviest endpoint back-to-back (each request
    # spawns a handler that runs the probes + a 1s RAPL window). MaxConnectionsPerSource caps the rest.
    for _ in 1 2 3 4; do
        (while :; do curl -fsS --max-time 8 http://127.0.0.1:8081/2/summary >/dev/null 2>&1 || true; done) &
        HAMMER_PIDS="$HAMMER_PIDS $!"
    done
    sleep 5 # let the load establish before sampling
    loaded=$(sample_mean 6 5)
    for p in $HAMMER_PIDS; do kill "$p" 2>/dev/null || true; done
    HAMMER_PIDS=""
    if [ -z "$base" ] || [ -z "$loaded" ]; then
        bad "could not sample hashrate around the load window (base='$base' loaded='$loaded')"
        return 0
    fi
    if awk -v b="$base" -v l="$loaded" -v t="$tol" 'BEGIN{exit !(l >= b * (1 - t / 100))}'; then
        ok "hashrate under API hammering within ${tol}% of baseline (${base} -> ${loaded} H/s)"
    else
        bad "sister API load shaved hashrate beyond ${tol}%: ${base} -> ${loaded} H/s"
    fi
    set_cfg '.api = "disabled"'
}

phase_stratum_auth() {
    phase "stratum-auth — right pass mines, wrong pass is rejected (#113, stack phase 1)"
    if [ -z "${E2E_STRATUM_PASS:-}" ]; then
        skip "E2E_STRATUM_PASS not set (stack auth off, or secret not provided) — phases skipped"
        return 0
    fi
    set_cfg ".pools[0].pass = \"$E2E_STRATUM_PASS\""
    : >"$WLOG" || true
    "$RIGFORGE" restart >/dev/null 2>&1 || true
    if wait_for_job 60; then
        ok "right pass: worker mines"
    else
        bad "right pass: no stratum job within 60s"
    fi
    set_cfg '.pools[0].pass = "wrong-114"'
    : >"$WLOG" || true
    "$RIGFORGE" restart >/dev/null 2>&1 || true
    local waited=0
    while [ "$waited" -lt 60 ] && ! grep -qi 'permission denied\|login error' "$WLOG" 2>/dev/null; do
        sleep 3
        waited=$((waited + 3))
    done
    if grep -qi 'permission denied\|login error' "$WLOG" 2>/dev/null; then
        ok "wrong pass: rejected by the proxy"
    else
        bad "wrong pass: no rejection within 60s"
    fi
    if grep -q 'new job from' "$WLOG" 2>/dev/null; then
        bad "wrong pass: worker still received jobs (auth not enforced?)"
    else
        ok "wrong pass: no jobs delivered"
    fi
    set_cfg ".pools[0].pass = \"$E2E_STRATUM_PASS\"" # the #113 rotation runbook, proven mechanically
    : >"$WLOG" || true
    "$RIGFORGE" restart >/dev/null 2>&1 || true
    if wait_for_job 60; then
        ok "rotation runbook: re-pasting the right pass recovers the worker"
    else
        bad "rotation runbook: worker did not recover after restoring the pass"
    fi
}

phase_dashboard() {
    phase "dashboard — workers-alive shows this rig; a stopped rig drops off"
    if [ -z "${E2E_DASH_URL:-}" ]; then
        skip "E2E_DASH_URL not set — dashboard phases skipped (agree fixtures with pithead#209)"
        return 0
    fi
    local me payload
    me=$(hostname)
    payload=$(curl -fsS --max-time 10 "$E2E_DASH_URL" 2>/dev/null || true)
    if printf '%s' "$payload" | grep -q "$me"; then
        ok "worker '$me' visible in the dashboard payload"
    else
        bad "worker '$me' not in the dashboard payload"
    fi
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    local to="${E2E_DROPOFF_TIMEOUT:-300}" waited=0
    while [ "$waited" -lt "$to" ]; do
        payload=$(curl -fsS --max-time 10 "$E2E_DASH_URL" 2>/dev/null || true)
        printf '%s' "$payload" | grep -q "$me" || break
        sleep 15
        waited=$((waited + 15))
    done
    if printf '%s' "$payload" | grep -q "$me"; then
        bad "stopped worker still listed after ${to}s"
    else
        ok "stopped worker dropped off within ${waited}s"
    fi
    "$RIGFORGE" start >/dev/null 2>&1 || true
}

phase_dev_fee() {
    phase "dev-fee — the worker's donation follows config, independent of the stack"
    local want got
    want=$(jq -r '.DONATION // 1' "$CFG")
    got=$(jq -r '."donate-level"' "$GEN_CFG" 2>/dev/null || true)
    if [ "$got" = "$want" ]; then
        ok "donate-level $got matches config"
    else
        bad "donate-level is '$got', config says '$want'"
    fi
}

summary() {
    printf '\ne2e-pithead: \033[1;32m%d ok\033[0m, ' "$PASS"
    if [ "$FAIL" -gt 0 ]; then
        printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
        exit 1
    fi
    printf '0 failed\n'
}

require_preflight "$@"
snapshot_config
case "${1:-all}" in
connect) phase_connect ;;
worker-api) phase_worker_api ;;
api-impact) phase_api_impact ;;
stratum-auth) phase_stratum_auth ;;
dashboard) phase_dashboard ;;
dev-fee) phase_dev_fee ;;
all)
    phase_connect
    phase_worker_api
    phase_api_impact
    phase_stratum_auth
    phase_dashboard
    phase_dev_fee
    ;;
*) die "unknown phase '$1' (connect|worker-api|api-impact|stratum-auth|dashboard|dev-fee|all)" ;;
esac
summary
