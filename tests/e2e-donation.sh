#!/usr/bin/env bash
# shellcheck shell=bash
phase_dev_fee() {
    phase "dev-fee — donation reductions take effect without rebuilding (#602)"
    local level got waited binary before
    binary="$(dirname "$GEN_CFG")/xmrig"
    [ -x "$binary" ] || {
        bad "no XMRig binary for donation proof"
        return 1
    }
    before=$(cksum "$binary") || return 1
    for level in 1 0 5 2; do
        set_cfg '.DONATION=$level' soft --argjson level "$level" || {
            bad "DONATION apply failed"
            return 1
        }
        waited=0 got=""
        while [ "$waited" -lt 60 ]; do
            got=$(api8080 http://127.0.0.1:8080/2/summary | jq -r '.donate_level // empty' 2>/dev/null || true)
            [ "$got" = "$level" ] && break
            sleep 2
            waited=$((waited + 2))
        done
        if [ "$got" = "$level" ] && [ "$(jq -r '."donate-level"' "$GEN_CFG")" = "$level" ] && [ "$(cksum "$binary")" = "$before" ]; then
            ok "DONATION $level matches XMRig donate_level without rebuild (#602)"
        else
            bad "DONATION $level did not reach XMRig with the original binary (#602)"
        fi
    done
}
