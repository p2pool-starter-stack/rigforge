#!/usr/bin/env bash
# shellcheck shell=bash
_selftest_units() {
    local unit
    for unit in xmrig rigforge-autotune.timer rigforge-watchdog.timer; do
        printf '%s=%s ' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
    done
}

phase_selftest() {
    phase "selftest — real XMRig benchmark verdict and bounded stress restoration (#533)"
    local out record before after failed=0
    record="$(dirname "$(dirname "$(dirname "$GEN_CFG")")")/rigforge-bench.json"
    rm -f "$record"
    if out=$("$RIGFORGE" bench 2>&1) && grep -q 'Benchmark correctness: verified' <<<"$out" &&
        [ "$(jq -r '.verdict' "$record" 2>/dev/null)" = verified ]; then
        ok "real XMRig bench verified its RandomX hash and recorded the verdict (#533)"
    else
        printf '%s\n' "$out" | tail -n 15 >&2
        bad "real XMRig bench did not verify its RandomX hash (#533)" || failed=1
    fi
    before=$(_selftest_units)
    if out=$("$RIGFORGE" stress --minutes "${E2E_STRESS_MINUTES:-1}" 2>&1) && grep -q 'Stress PASS' <<<"$out"; then
        ok "real XMRig stress hashed for the bounded window (#533)"
    else
        printf '%s\n' "$out" | tail -n 15 >&2
        bad "real XMRig stress did not pass (#533)" || failed=1
    fi
    after=$(_selftest_units)
    if [ "$before" = "$after" ] && [[ "$before" != *"= "* ]]; then
        ok "stress restored the miner and timer states: $after(#533)"
    else
        bad "stress left units changed: before '$before', after '$after' (#533)" || failed=1
    fi
    return "$failed"
}
