#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
source "$SCRIPT"
git() {
    case "$*" in
    *clone*)
        printf 'clone\n' >>"$D/build-calls"
        mkdir -p xmrig/src
        if [ "${fixture_drift:-0}" = 1 ]; then
            printf 'constexpr const int kDefaultDonateLevel = 1;\nconstexpr const int kMinimumDonateLevel=1;\n' >xmrig/src/donate.h
        else
            printf 'constexpr const int kDefaultDonateLevel = 1;\nconstexpr const int kMinimumDonateLevel = 1;\n' >xmrig/src/donate.h
        fi
        ;;
    *rev-parse*) printf '%s\n' "$XMRIG_COMMIT" ;;
    *) return 1 ;;
    esac
}
sudo() { "$@"; }
cmake() { :; }
make() {
    printf '#!/bin/sh\nexit 0\n' >xmrig
    chmod +x xmrig
}
brew() { printf '%s\n' "$D"; }
sysctl() { printf '1\n'; }
nproc() { printf '1\n'; }
compute_build_jobs() { printf '1\n'; }
_cpu_missing_isa() { :; }
OS_TYPE=$(uname -s)
if [ "$OS_TYPE" = Darwin ]; then sed() { /usr/bin/sed "$@"; }; fi
POOLS_JSON='[{"url":"pool.example:3333"}]'
ACCESS_TOKEN=""
RIGFORGE_APPLIANCE=1
build_count=0
for initial in 1 5; do
    build_count=$((build_count + 1))
    WORKER_ROOT="$D/build-$initial"
    mkdir -p "$WORKER_ROOT"
    cd "$WORKER_ROOT"
    DONATION=$initial XMRIG_REBUILD=true compile_xmrig >/dev/null
    grep -qx "constexpr const int kDefaultDonateLevel = $initial;" ../src/donate.h
    xmrig_already_built
    before=$(_sha256 xmrig)
    for DONATION in "$initial" "$((initial - 1 - initial / 2))"; do
        generate_xmrig_config >/dev/null
        level=$(jq -r '."donate-level"' config.json)
        floor=$(sed -n 's/.*kMinimumDonateLevel = \([0-9]*\);/\1/p' ../src/donate.h)
        [ "$level" = "$DONATION" ] && [ "$level" -le 99 ]
        if [ "$level" -lt "$floor" ]; then
            printf 'DONATION %s -> %s rejected by compiled minimum %s\n' "$initial" "$level" "$floor" >&2
            exit 1
        fi
        xmrig_already_built
        XMRIG_REBUILD=false compile_xmrig >/dev/null
        [ "$(_sha256 xmrig)" = "$before" ]
    done
    [ "$(cat "$WORKER_ROOT/xmrig/.rigforge-donate-min")" = 0 ]
    [ "$(wc -l <"$D/build-calls" | tr -d ' ')" = "$build_count" ]
    rm "$WORKER_ROOT/xmrig/.rigforge-donate-min"
    if xmrig_already_built; then exit 1; fi
    printf '1\n' >"$WORKER_ROOT/xmrig/.rigforge-donate-min"
    if xmrig_already_built; then exit 1; fi
    printf '0\n' >"$WORKER_ROOT/xmrig/.rigforge-donate-min"
    xmrig_already_built
    printf 'donation %s -> %s without rebuild: PASS\n' "$initial" "$DONATION"
done
WORKER_ROOT="$D/drifted-header"
mkdir -p "$WORKER_ROOT"
cd "$WORKER_ROOT"
if (fixture_drift=1 DONATION=2 XMRIG_REBUILD=true compile_xmrig) >"$D/drift.log" 2>&1; then exit 1; fi
grep -q 'donation patch verification failed' "$D/drift.log"
[ ! -e "$WORKER_ROOT/xmrig/.rigforge-donate-min" ]
[ ! -e "$WORKER_ROOT/xmrig/build/xmrig" ]
printf 'unmatched donation patch refuses build and marker: PASS\n'
CONFIG_JSON="$D/config.json"
printf '{}' >"$CONFIG_JSON"
unset DONATION
[ "$(_api_config_json | jq -r .DONATION)" = 0 ]
_read_api_summary() { printf '%s' "$summary"; }
for pair in '0 0' '1 0' '5 2' '2 2'; do
    read -r reported configured <<PAIR
$pair
PAIR
    printf '{"DONATION":%s}' "$configured" >"$CONFIG_JSON"
    summary="{\"donate_level\":$reported}"
    rc=0
    out=$(_check_donation) || rc=$?
    if [ "$reported" = "$configured" ]; then
        [ "$rc" = 0 ] && [[ "$out" == *'matches DONATION'* ]]
    else
        [ "$rc" = 1 ] && [[ "$out" == *'differs from DONATION'* ]]
    fi
done
printf '{}' >"$CONFIG_JSON"
summary='{"donate_level":0}'
out=$(_check_donation)
[[ "$out" == *'matches DONATION (0%)'* ]]
for summary in '' '{}' 'invalid' '{"donate_level":"untrusted"}'; do
    out=$(_check_donation)
    [[ "$out" == *'donation level unavailable'* ]]
done
printf 'donation doctor and defaults: PASS\n'
bash "$(dirname "$SCRIPT")/tests/test-e2e-donation.sh"
