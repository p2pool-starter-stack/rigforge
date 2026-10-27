#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
source "$ROOT/tests/e2e-donation.sh"
phase() { :; }
ok() { printf '%s\n' "$1"; }
bad() {
    printf '%s\n' "$1" >&2
    return 1
}
sleep() { :; }
set_cfg() {
    [ "$mode" != apply-failed ] || return 1
    level=$5
    printf '{"donate-level":%s}' "$level" >"$GEN_CFG"
    [ "$mode" != changed-binary ] || printf 'changed' >>"$D/xmrig"
}
api8080() {
    case "$mode" in
    stale) printf '{"donate_level":1}' ;;
    missing) printf '{}' ;;
    *) printf '{"donate_level":%s}' "$level" ;;
    esac
}
GEN_CFG="$D/config.json"
for mode in good stale missing changed-binary apply-failed; do
    printf '#!/bin/sh\nexit 0\n' >"$D/xmrig"
    chmod +x "$D/xmrig"
    if (
        set -e
        phase_dev_fee
    ) >"$D/$mode.log" 2>&1; then
        [ "$mode" = good ]
        [ "$(grep -c 'matches XMRig donate_level without rebuild' "$D/$mode.log")" = 4 ]
    else
        [ "$mode" != good ]
    fi
done
printf 'donation hardware assertions reject stale, missing, rebuilt and failed applies: PASS\n'
