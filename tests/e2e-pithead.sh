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
#   E2E_API_LATENCY_S            responsiveness budget for /health under full load (default 15)
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

# #183: the shared-rig lock — see tests/e2e-real.sh for the full story. The function is duplicated
# verbatim there on purpose: the same helper against the same path IS the cross-project contract
# with Pithead's harness (tests/run.sh guards the two copies against drift). FD 9 is inherited by
# children — that is what keeps the lock held for the whole run; do not close it. NOTE: rig_lock's
# own EXIT trap is later REPLACED by snapshot_config's `trap '_cleanup' EXIT` (traps replace, not
# stack), so _cleanup also removes the holder sidecar.
rig_lock() { # rig_lock <project> <suite> [shared]
    local mode=-x
    [ "${3:-}" = shared ] && mode=-s
    local lf="${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}"
    # Holder breadcrumb defaults BESIDE the lock, not under root-owned /run (a non-root box can't
    # write /run/rig-e2e.holder — the lock still holds, but the write errors with stderr noise). (#244)
    local hf="${RIG_LOCK_HOLDER:-$lf.holder}"
    # /run/lock is world-writable + sticky; refuse a symlinked lock/holder path so a planted symlink
    # can't redirect our root-side create/chmod/holder-write onto another file (defence for a
    # multi-tenant box; single-tenant rigs aren't exposed, but the guard is free).
    { [ -L "$lf" ] || [ -L "$hf" ]; } && {
        echo "rig_lock: lock/holder path is a symlink — refusing" >&2
        exit 1
    }
    # Open the lock READ-only (9<). A lock file first created by a NON-root flock (a manual reserve
    # after a reboot clears the /run/lock tmpfs) is owned by that user, and fs.protected_regular then
    # blocks even root's O_CREAT-*write* of it (a 9> open) with EACCES. A read-open is never guarded,
    # and flock -x/-s works fine on a read fd, so this sidesteps it without rm-ing a possibly-held
    # lock. Create it first if absent; keep it 0666 so a shared reader can still join. (#242)
    [ -e "$lf" ] || : >"$lf" 2>/dev/null || true
    chmod 666 "$lf" 2>/dev/null || true # best-effort world-writable; a read-open (9<) only needs o+r
    exec 9<"$lf"
    if ! flock -n $mode 9; then
        if [ "${RIG_LOCK_WAIT:-0}" = 1 ]; then
            echo "rig busy ($(cat "$hf" 2>/dev/null || echo unknown)) — waiting..." >&2
            flock $mode 9
        else
            echo "miner-0 busy: $(cat "$hf" 2>/dev/null || echo unknown). Retry with RIG_LOCK_WAIT=1 to queue." >&2
            exit 75 # EX_TEMPFAIL — callers can tell "busy, retry later" from a real failure
        fi
    fi
    # DISPLAY-ONLY and strictly best-effort. The flock is already HELD on FD 9 above; a holder
    # marker we can't write (a root-owned RIG_LOCK_HOLDER + a non-root runner) must NEVER abort
    # under set -e and drop the lock — that would leave the box UNRESERVED, the exact bug (#249).
    # Plain write, then passwordless sudo, then swallow. Portable UTC stamp — the GNU-only
    # `date -Iseconds` errors on BSD/macOS. (#244)
    local _line
    _line="$(printf '%s %s pid=%s started=%s' "$1" "$2" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    { printf '%s\n' "$_line" >"$hf" || printf '%s\n' "$_line" | sudo -n tee "$hf" >/dev/null; } 2>/dev/null || true
    # The trap fires at EXIT when the $hf local is out of scope, so re-derive the path from the
    # durable env/default; best-effort removal, may need sudo for a root-written marker. (#244/#249)
    trap 'rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || sudo -n rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || true' EXIT
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
    rm -f "${RIG_LOCK_HOLDER:-/run/rig-e2e.holder}" # #183: the rig lock's display-only sidecar
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

api8081() { # [curl args...] -> body (empty on failure); token-aware like api8080 — the phases must
    # work standalone against an operator config that keeps its own ACCESS_TOKEN
    local tok auth=()
    tok=$(jq -r '.ACCESS_TOKEN // empty' "$CFG" 2>/dev/null || true)
    [ -n "$tok" ] && auth=(-H "Authorization: Bearer $tok")
    curl -fsS --max-time 20 "${auth[@]}" "$@" 2>/dev/null || true
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
    # Normalize first: the operator's config may carry its own ACCESS_TOKEN (miner-0 does), and this
    # phase tests the CONTRACT in both modes — the EXIT trap restores the operator's token afterwards.
    set_cfg '.ACCESS_TOKEN = ""'
    sleep 3 # give the restarted miner a beat to bind
    local body code
    body=$(curl -fsS --max-time 5 http://127.0.0.1:8080/2/summary 2>/dev/null || true)
    if [ -n "$body" ] && printf '%s' "$body" | jq -e '.hashrate' >/dev/null 2>&1; then
        ok "open posture: /2/summary readable with no token"
    else
        bad "open posture: /2/summary not readable without a token"
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
        body=$(api8081 http://127.0.0.1:8081/health)
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
    # Worst-case polling, measured HONESTLY: a real dashboard polls from the STACK HOST, so the
    # load generator must not itself churn processes on the rig — per-iteration jq/curl spawns
    # pollute the same L3 the assertion measures (the v1.3 gate spent three iterations discovering
    # that). One token read, then ONE long-lived curl per client issuing sequential requests via a
    # URL range: zero client-side spawns between requests, full pressure on the server path.
    local htok hauth=()
    htok=$(jq -r '.ACCESS_TOKEN // empty' "$CFG" 2>/dev/null || true)
    [ -n "$htok" ] && hauth=(-H "Authorization: Bearer $htok")
    for _ in 1 2 3 4; do
        (
            while :; do
                curl -fsS --max-time 300 "${hauth[@]}" "http://127.0.0.1:8081/2/summary?[1-10000]" >/dev/null 2>&1 || true
            done
        ) &
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
    # Responsiveness is the OTHER half of the perf contract: the guard that stops the API shaving
    # hashrate must not starve it either (a v1.2.0 handler took ~51s on a loaded 96-core EPYC).
    # Bound it WHILE the miner is fully loaded.
    local t0 t1 elapsed budget="${E2E_API_LATENCY_S:-15}"
    t0=$(date +%s)
    api8081 http://127.0.0.1:8081/health >/dev/null
    t1=$(date +%s)
    elapsed=$((t1 - t0))
    if [ "$elapsed" -lt "$budget" ]; then
        ok "sister API answers /health in ${elapsed}s under full mining load (budget ${budget}s)"
    else
        bad "sister API too slow under load: /health took >=${budget}s — handler starved (check Nice / MaxConnections)"
    fi
    set_cfg '.api = "disabled"'
}

phase_network() {
    phase "network — nothing listens or leaks beyond what the config defines"
    local port="${PITHEAD_URL##*:}" remotes bad_remote=0 r xl k1 k2 sweep waited=0
    # Outbound: the miner's ONLY established TCP peers are the configured pool. Anything else would
    # mean traffic the operator never asked for. The previous phase's cleanup `apply` restarts the
    # miner, so give the stratum connection up to 45s to re-establish before judging.
    remotes=$(ss -Htnp 2>/dev/null | awk '$1 == "ESTAB" && /xmrig/ {print $5}' | sort -u)
    while [ -z "$remotes" ] && [ "$waited" -lt 45 ]; do
        sleep 5
        waited=$((waited + 5))
        remotes=$(ss -Htnp 2>/dev/null | awk '$1 == "ESTAB" && /xmrig/ {print $5}' | sort -u)
    done
    if [ -n "$remotes" ]; then
        for r in $remotes; do
            case "$r" in
            *:"$port") ;;
            *)
                bad_remote=1
                bad "unexpected xmrig peer: $r"
                ;;
            esac
        done
        [ "$bad_remote" = 0 ] && ok "outbound: xmrig's only TCP peers are the pool (:$port)"
    else
        bad "no established xmrig connections found to inspect"
    fi
    # Listeners: the miner owns :8080 and nothing else; :8081 exists exactly while enabled.
    set_cfg '.api = "enabled"'
    sleep 3
    if ss -Htln 2>/dev/null | grep -q ':8081 '; then
        ok ":8081 listening while api enabled"
    else
        bad ":8081 not listening while api enabled"
    fi
    xl=$(ss -Htlnp 2>/dev/null | awk '/xmrig/ {print $4}' | grep -v ':8080$' | sort -u || true)
    if [ -z "$xl" ]; then
        ok "miner listens on :8080 only"
    else
        bad "miner has unexpected listeners: $xl"
    fi
    # Spirit-of-XMRig on the wire: the sister /2/summary minus `rigforge` must carry EXACTLY the key
    # set XMRig's own API serves — verbatim superset, nothing renamed, dropped, or invented.
    k1=$(api8080 http://127.0.0.1:8080/2/summary | jq -cS 'keys' 2>/dev/null || true)
    k2=$(api8081 http://127.0.0.1:8081/2/summary | jq -cS 'del(.rigforge) | keys' 2>/dev/null || true)
    if [ -n "$k1" ] && [ "$k1" = "$k2" ]; then
        ok "wire superset: sister /2/summary = xmrig's keys + rigforge, nothing else"
    else
        bad "superset mismatch: xmrig keys $k1 vs sister-without-rigforge $k2"
    fi
    # Leak sweep: with a token AND a stratum pass configured, no byte of any response on either port
    # — authed, unauthed, or error, headers included — may contain either secret.
    set_cfg '.ACCESS_TOKEN = "tok-net1" | .pools[0].pass = "pass-net1"'
    sleep 3
    sweep=$(
        for p in 8080 8081; do
            for path in /1/summary /2/summary /health /tune /nope; do
                curl -is --max-time 8 -H "Authorization: Bearer tok-net1" "http://127.0.0.1:$p$path" 2>/dev/null || true
                curl -is --max-time 8 "http://127.0.0.1:$p$path" 2>/dev/null || true
            done
        done
    )
    case "$sweep" in
    *tok-net1*) bad "leak: ACCESS_TOKEN appears in a response" ;;
    *) ok "leak sweep: ACCESS_TOKEN never appears in any response (both ports, all routes + errors)" ;;
    esac
    case "$sweep" in
    *pass-net1*) bad "leak: the stratum pass appears in a response" ;;
    *) ok "leak sweep: pools[].pass never appears in any response" ;;
    esac
    set_cfg '.api = "disabled" | .ACCESS_TOKEN = "" | .pools[0].pass = "x"'
    sleep 3
    if ss -Htln 2>/dev/null | grep -q ':8081 '; then
        bad ":8081 still listening after api disabled"
    else
        ok ":8081 closed when api disabled"
    fi
}

phase_stratum_auth() {
    phase "stratum-auth — right pass mines, wrong pass is rejected (#113, stack phase 1)"
    if [ -z "$WLOG" ]; then
        bad "no worker xmrig.log found — run the connect phase (or setup) first"
        return 0
    fi
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
    phase "dev-fee — the effective donation follows config and the compiled floor"
    # XMRig clamps donate-level to the kMinimumDonateLevel compiled into donate.h and AUTOSAVES the
    # clamped value back into the generated config — so a DONATION lowered after the build only takes
    # effect on a rebuild. The effective contract is max(config, compiled floor). Caught live on
    # miner-0 (config 0, floor 1) the first time this gate ran, 2026-07-10.
    local want got minlvl src eff
    want=$(jq -r '.DONATION // 1' "$CFG")
    src=$(find "$HERE" -path '*worker*/xmrig/src/donate.h' 2>/dev/null | head -1)
    minlvl=""
    [ -n "$src" ] && minlvl=$(sed -nE 's/.*kMinimumDonateLevel *= *([0-9]+).*/\1/p' "$src" | head -1)
    minlvl="${minlvl:-1}"
    eff="$want"
    if [ "$want" -lt "$minlvl" ] 2>/dev/null; then eff="$minlvl"; fi
    got=$(jq -r '."donate-level"' "$GEN_CFG" 2>/dev/null || true)
    if [ "$got" = "$eff" ]; then
        ok "effective donate-level $got (config $want, compiled floor $minlvl)"
        if [ "$eff" != "$want" ]; then
            printf '  \033[1;33m∙\033[0m NOTE: config wants %s but this build was compiled with floor %s — rebuild to lower it (docs/configuration.md)\n' "$want" "$minlvl"
        fi
    else
        bad "donate-level is '$got'; expected $eff (config $want, compiled floor $minlvl)"
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
case "${1:-all}" in
connect | worker-api | api-impact | network | stratum-auth | dashboard | dev-fee | all) ;;
*) die "unknown phase '$1' (connect|worker-api|api-impact|network|stratum-auth|dashboard|dev-fee|all)" ;;
esac
# #183: serialize the shared rig — taken after arg parsing, before snapshot_config (its _cleanup
# runs `apply`, a service restart) and before the first API touch.
rig_lock rigforge e2e-pithead

snapshot_config
case "${1:-all}" in
connect) phase_connect ;;
worker-api) phase_worker_api ;;
api-impact) phase_api_impact ;;
network) phase_network ;;
stratum-auth) phase_stratum_auth ;;
dashboard) phase_dashboard ;;
dev-fee) phase_dev_fee ;;
all)
    phase_connect
    phase_worker_api
    phase_api_impact
    phase_network
    phase_stratum_auth
    phase_dashboard
    phase_dev_fee
    ;;
*) die "unknown phase '$1' (connect|worker-api|api-impact|network|stratum-auth|dashboard|dev-fee|all)" ;;
esac
summary
