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
git() { printf 'candidate-commit\n'; }
systemctl() { [ "$(cat "$C/active")" = 1 ]; }
RIGFORGE=donation_rigforge

donation_rigforge() {
    case "$1" in
    stop)
        { [ "$mode" != restore-stop-failed ] || [ ! -f "$C/built" ]; } || return 1
        printf '0' >"$C/active"
        ;;
    start) printf '1' >"$C/active" ;;
    apply) [ "$(jq -r .autotune "$CFG")" = performance ] ;;
    upgrade)
        [ "${KEEP_ARCHIVES:-}" = 2147483647 ] || return 1
        [ ! -e "$tree/.rigforge-donate-min" ] && [ "$(jq -r .autotune "$CFG")" = disabled ] || return 1
        printf 'upgrade\n' >>"$C/upgrades"
        [ "$mode" != upgrade-failed ] || return 1
        [ "$mode" != skipped-build ] || return 0
        mv "$tree" "$worker/xmrig-proof-archive"
        if [ "$mode" = archive-mutated ]; then
            printf 'changed' >>"$worker/xmrig-proof-archive/build/xmrig"
            chmod 600 "$worker/xmrig-proof-archive/build/xmrig"
        fi
        mkdir -p "$tree/build" "$tree/src"
        if [ "$mode" = archive-extra-file ]; then
            mkdir -p "$worker/xmrig-proof-archive/.git/hooks"
            printf '#!/bin/sh\nexit 0\n' >"$worker/xmrig-proof-archive/.git/hooks/unexpected"
            chmod +x "$worker/xmrig-proof-archive/.git/hooks/unexpected"
            chmod 700 "$worker/xmrig-proof-archive"
        fi
        if [ "$mode" = reused-binary ]; then
            ln "$worker/xmrig-proof-archive/build/xmrig" "$tree/build/xmrig"
        else
            printf '#!/bin/sh\nexit 0\n' >"$tree/build/xmrig"
            chmod +x "$tree/build/xmrig"
        fi
        if [ "$mode" = copied-binary ]; then
            cp -p "$worker/xmrig-proof-archive/build/xmrig" "$tree/build/xmrig"
        else
            printf '[ 32%%] Building CXX object CMakeFiles/xmrig.dir/src/base/net/stratum/Pools.cpp.o\n[100%%] Linking CXX executable xmrig\n' >"$worker/build.log"
        fi
        printf '0\n' >"$tree/.rigforge-donate-min"
        printf 'candidate-commit\n' >"$tree/.rigforge-commit"
        printf 'constexpr const int kMinimumDonateLevel = 0;\nconstexpr const int kDefaultDonateLevel = 0;\n' >"$tree/src/donate.h"
        case "$mode" in
        wrong-minimum)
            sed 's/kMinimumDonateLevel = 0/kMinimumDonateLevel = 1/' "$tree/src/donate.h" >"$C/header"
            cp "$C/header" "$tree/src/donate.h"
            ;;
        wrong-default)
            sed 's/kDefaultDonateLevel = 0/kDefaultDonateLevel = 1/' "$tree/src/donate.h" >"$C/header"
            cp "$C/header" "$tree/src/donate.h"
            ;;
        missing-marker) rm "$tree/.rigforge-donate-min" ;;
        wrong-commit) printf 'wrong-commit\n' >"$tree/.rigforge-commit" ;;
        esac
        printf '{"donate-level":0}' >"$GEN_CFG"
        printf 'built' >"$C/built"
        ;;
    *) return 1 ;;
    esac
}

set_cfg() {
    [ "$mode" != apply-failed ] || return 1
    jq "${@:3}" "$1" "$CFG" >"$C/config.next"
    mv "$C/config.next" "$CFG"
    printf '%s' "$5" >"$C/level"
    printf '{"donate-level":%s}' "$5" >"$GEN_CFG"
    if [ -f "$C/built" ]; then
        case "$mode" in
        changed-binary) printf 'changed' >>"$tree/build/xmrig" ;;
        replaced-binary)
            cp "$tree/build/xmrig" "$C/replacement"
            mv "$C/replacement" "$tree/build/xmrig"
            ;;
        wrong-generated) printf '{"donate-level":99}' >"$GEN_CFG" ;;
        esac
    fi
}
api8080() {
    case "$mode" in
    stale) printf '{"donate_level":1}' ;;
    missing) printf '{}' ;;
    clamped)
        if [ -f "$C/built" ] && [ "$(cat "$C/level")" = 1 ]; then touch "$C/raised"; fi
        if [ -f "$C/raised" ] && [ "$(cat "$C/level")" = 0 ]; then printf '{"donate_level":1}'; else printf '{"donate_level":%s}' "$(cat "$C/level")"; fi
        ;;
    *) printf '{"donate_level":%s}' "$(cat "$C/level")" ;;
    esac
}
for mode in good missing-legacy-marker originally-stopped archive-mutated archive-extra-file upgrade-failed skipped-build reused-binary copied-binary wrong-minimum wrong-default missing-marker wrong-commit stale missing clamped changed-binary replaced-binary wrong-generated apply-failed restore-stop-failed; do
    C="$D/$mode"
    mkdir -p "$C/worker/xmrig/build" "$C/tmp" "$C/worker/xmrig-kept"
    CFG="$C/config.json"
    GEN_CFG="$C/worker/xmrig/build/config.json"
    export TMPDIR="$C/tmp"
    printf '{"DONATION":3,"autotune":"performance"}' >"$CFG"
    printf '{"donate-level":3}' >"$GEN_CFG"
    printf '#!/bin/sh\nexit 0\n' >"$C/worker/xmrig/build/xmrig"
    chmod +x "$C/worker/xmrig/build/xmrig"
    printf 'original build log\n[ 32%%] Building CXX object CMakeFiles/xmrig.dir/src/base/net/stratum/Pools.cpp.o\n[100%%] Linking CXX executable xmrig\n' >"$C/worker/build.log"
    cp -p "$C/worker/build.log" "$C/build.before"
    printf 'legacy-commit\n' >"$C/worker/xmrig/.rigforge-commit"
    [ "$mode" = missing-legacy-marker ] || printf '1\n' >"$C/worker/xmrig/.rigforge-donate-min"
    printf 'keep' >"$C/worker/xmrig-kept/sentinel"
    if [ "$mode" = originally-stopped ]; then printf '0' >"$C/active"; else printf '1' >"$C/active"; fi
    cp -p "$C/active" "$C/active.before"
    cp -a "$C/worker/xmrig" "$C/original"
    cp -p "$CFG" "$C/config.before"
    if phase_dev_fee >"$C/result.log" 2>&1; then
        case "$mode" in good | missing-legacy-marker | originally-stopped | archive-mutated | archive-extra-file) ;; *)
            cat "$C/result.log" >&2
            exit 1
            ;;
        esac
        grep -q 'missing minimum marker rebuilt' "$C/result.log" || {
            printf 'phase accepted a pre-existing miner without migration proof\n' >&2
            exit 1
        }
        [ "$(grep -c '^donation-runtime:' "$C/result.log")" = 4 ]
        grep -q 'restores original artifacts' "$C/result.log"
    else
        case "$mode" in good | missing-legacy-marker | originally-stopped | archive-mutated | archive-extra-file)
            cat "$C/result.log" >&2
            exit 1
            ;;
        esac
        grep -q 'donation migration, runtime reduction or original-artifact restoration failed' "$C/result.log"
    fi
    if [ "$mode" = restore-stop-failed ]; then
        [ -d "$C/worker/xmrig-proof-archive" ]
        [ "$(find "$C/tmp" -name xmrig-config.json | wc -l | tr -d ' ')" = 1 ]
    else
        diff -r "$C/original" "$C/worker/xmrig"
        cmp "$C/config.before" "$CFG"
        cmp "$C/active.before" "$C/active"
        cmp "$C/build.before" "$C/worker/build.log"
        expected_mode=$(stat -c '%u:%g:%a' "$C/original" 2>/dev/null || stat -f '%u:%g:%Lp' "$C/original")
        actual_mode=$(stat -c '%u:%g:%a' "$C/worker/xmrig" 2>/dev/null || stat -f '%u:%g:%Lp' "$C/worker/xmrig")
        [ "$actual_mode" = "$expected_mode" ]
        [ ! -e "$C/worker/xmrig-proof-archive" ]
        [ -z "$(ls -A "$C/tmp")" ]
    fi
    [ "$(cat "$C/worker/xmrig-kept/sentinel")" = keep ]
done
printf 'donation migration, runtime reductions, failure guards and artifact restoration: PASS\n'
