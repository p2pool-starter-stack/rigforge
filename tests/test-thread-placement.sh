#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s — %s\n' "$1" "$2" >&2
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in [$2]" ;; esac }
absent() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in [$2]" ;; *) ok "$1" ;; esac }

base_config() {
    local out="$1" extra="${2:-}"
    [ -n "$extra" ] || extra='{}'
    jq --arg home "$TMP/runtime" --argjson extra "$extra" \
        '.pools[0].url |= gsub("[^A-Za-z0-9.:-]"; "") | .HOME_DIR = $home | . * $extra' \
        "$ROOT/config.minimal.json" >"$out"
}
TEST_HOST="$(jq -r '.pools[0].url | gsub("[^A-Za-z0-9.:-]"; "") | sub(":[0-9]+$"; "")' "$ROOT/config.minimal.json")"

parse_case() {
    local overlay="$1" cfg="$TMP/parse.json"
    base_config "$cfg" "$(jq -cn --argjson x "$overlay" '{xmrig:$x}')"
    (
        source "$SCRIPT"
        CONFIG_JSON="$cfg"
        SCRIPT_DIR="$ROOT"
        set +e
        parse_config
    ) 2>&1
}
generate_case() {
    local name="$1" overlay="$2" tune="$3" cap="$4" script="${5:-$SCRIPT}" d cfg
    d="$TMP/$name"
    cfg="$d/config.json"
    mkdir -p "$d/out" "$TMP/runtime/worker/xmrig/build"
    base_config "$cfg" "$overlay"
    rm -f "$TMP/runtime/worker/tune-overrides.json"
    [ -z "$tune" ] || printf '%s\n' "$tune" >"$TMP/runtime/worker/tune-overrides.json"
    (
        source "$script"
        CONFIG_JSON="$cfg"
        SCRIPT_DIR="$ROOT"
        OS_TYPE=Linux
        RIGFORGE_APPLIANCE=1
        lscpu() { printf 'Model name: Fixture CPU\n'; }
        hostname() { printf '%s\n' "$TEST_HOST"; }
        _cpu_missing_isa() { :; }
        sudo() { "$@"; }
        parse_config >/dev/null
        THREADS_CAP="$cap"
        cd "$d/out" || exit 1
        generate_xmrig_config >/dev/null
    )
    printf '%s' "$d/out/config.json"
}

STUBS="$TMP/stubs"
mkdir -p "$STUBS"
printf '#!/bin/sh\necho 8\n' >"$STUBS/getconf"
chmod +x "$STUBS/getconf"
export PATH="$STUBS:$PATH"

echo '== thread placement: overlay pin validation =='
validate() {
    (
        source "$SCRIPT"
        XMRIG_OVERLAY="{\"cpu\":{\"rx\":$1}}"
        _validate_overlay_cpu_rx
    ) 2>&1
}
for ok_rx in '[0,2,4,6]' '[-1,-1]' '[[1,0],[1,7]]' '{"threads":4,"affinity":15}' '{"threads":4,"affinity":-1}' 'false' '4'; do
    out="$(validate "$ok_rx")"
    eq "valid cpu.rx $ok_rx is accepted" "$?" 0
    absent "valid cpu.rx $ok_rx draws no error" "$out" 'xmrig.cpu.rx'
done
for bad_rx in '"0,1"' 'true' 'null' '0' '1.5' '[]' '[8]' '[0,-2]' '["0"]' '[[1,8]]' '[[0,1]]' '[[1,2,3]]' '{"threads":-1}' '{"threads":"4"}' '{"affinity":256}' '{"affinity":"x"}'; do
    out="$(validate "$bad_rx")"
    eq "invalid cpu.rx $bad_rx is rejected" "$?" 1
    has "invalid cpu.rx $bad_rx names the key" "$out" 'xmrig.cpu.rx'
done
out="$(parse_case '{"cpu":{"rx":[9]}}')"
eq 'parse_config rejects a core beyond the host' "$?" 1
has 'parse_config names the key' "$out" 'xmrig.cpu.rx'
out="$(parse_case '{"cpu":{"rx":[0,2]}}')"
eq 'parse_config accepts a valid pin' "$?" 0

echo '== thread placement: generated config and the cap =='
arr='{"xmrig":{"cpu":{"rx":[0,2,4,6]}}}'
rx_of() { jq -c '.cpu.rx' "$1"; }
eq 'array pin reaches the config unchanged without a cap' "$(rx_of "$(generate_case a0 "$arr" '' '')")" '[0,2,4,6]'
eq 'array under the cap is untouched' "$(rx_of "$(generate_case a5 "$arr" '' 5)")" '[0,2,4,6]'
eq 'array at the cap is untouched' "$(rx_of "$(generate_case a4 "$arr" '' 4)")" '[0,2,4,6]'
eq 'array over the cap is cut to its leading entries' "$(rx_of "$(generate_case a3 "$arr" '' 3)")" '[0,2,4]'
eq 'array cut to a cap of one stays an array' "$(rx_of "$(generate_case a1 "$arr" '' 1)")" '[0]'
pairs='{"xmrig":{"cpu":{"rx":[[1,0],[1,2],[1,4]]}}}'
eq 'pair entries are cut as whole entries' "$(rx_of "$(generate_case p2 "$pairs" '' 2)")" '[[1,0],[1,2]]'
eq 'overlay array beats a tuned count' "$(rx_of "$(generate_case t1 "$arr" '{"cpu":{"rx":{"mode":0,"threads":3,"max_threads_cnt":3,"intensity":1,"affinity":-1}}}' '')")" '[0,2,4,6]'
eq 'overlay object affinity survives the cap' "$(jq -c '.cpu.rx | [.threads, .affinity]' "$(generate_case o1 '{"xmrig":{"cpu":{"rx":{"threads":6,"affinity":255}}}}' '' 3)")" '[3,255]'

echo '== thread placement: tune candidates =='
for case_row in '4|[0,2,4,6]' '3|[0,2,4]' '2|[0,2]'; do
    cap="${case_row%%|*}"
    printf '{"cpu":{"rx":[0,2,4,6]}}\n' >"$TMP/cand.json"
    (
        source "$SCRIPT"
        WORKER_ROOT="$TMP/runtime/worker" THREADS_CAP="$cap"
        _rx_clamp_candidate "$TMP/cand.json" "$TMP/cand.json" '[0,2,4,6]'
    )
    eq "tune candidate array under cap $cap" "$(rx_of "$TMP/cand.json")" "${case_row#*|}"
done
printf '{"cpu":{"rx":[0,2,4,6]}}\n' >"$TMP/cand.json"
(
    source "$SCRIPT"
    WORKER_ROOT="$TMP/runtime/worker" THREADS_CAP=''
    _rx_clamp_candidate "$TMP/cand.json" "$TMP/cand.json" '[0,2,4,6]'
)
eq 'tune candidate array without a cap is untouched' "$(rx_of "$TMP/cand.json")" '[0,2,4,6]'
pins="$(
    source "$SCRIPT"
    _xmrig_overlay_pins '{"cpu":{"rx":[0,2]}}'
)"
has 'an array pin is listed as excluded from tuning' "$pins" cpu.rx
knob="$(
    source "$SCRIPT"
    XMRIG_OVERLAY='{"cpu":{"rx":[0,2]}}' TUNE_THREADS='-1 4 8'
    _knob_values threads
)"
eq 'an array pin leaves tune a single thread candidate' "$knob" '[0,2]'

eq 'tune-overrides cannot override an array pin' "$(printf '{"cpu":{"rx":[0,2],"yield":true}}' | (
    source "$SCRIPT"
    XMRIG_OVERLAY='{"cpu":{"rx":[0,2]}}'
    _xmrig_unpinned | jq -c '.cpu'
) )" '{"yield":true}'

echo '== thread placement: doctor and bundle evidence =='
doc_out() {
    (
        source "$SCRIPT"
        CONFIG_JSON="$TMP/doc-config.json"
        API_BACKENDS_CMD="$2"
        _doctor_placement "$1"
    ) 2>&1
}
printf '{}\n' >"$TMP/doc-config.json"
has 'doctor shows per-thread placement' "$(doc_out y "echo '[{\"type\":\"cpu\",\"threads\":[{\"affinity\":0},{\"affinity\":2}]}]'")" '2 thread(s), affinity 0,2'
has 'doctor says why when the miner is stopped' "$(doc_out n 'true')" 'the miner is not running'
has 'doctor says why when the API is silent' "$(doc_out y 'true')" 'not reachable'
has 'doctor says why when no affinity is reported' "$(doc_out y "echo '[{\"type\":\"cpu\",\"threads\":[]}]'")" 'no CPU thread affinity'
doc_out y "echo 'not json'" >/dev/null
eq 'doctor placement never fails on a garbled body' "$?" 0

wr="$TMP/bundle-wr"
mkdir -p "$wr/xmrig/build"
topo() { (
    source "$SCRIPT"
    _bundle_topology "$wr" "$TMP/topology.xml"
); }
rm -f "$TMP/topology.xml"
out="$(topo)"
eq 'a missing miner is not collected' "$?" 1
eq 'a missing miner is named' "$out" miner-not-built
printf '#!/bin/sh\necho usage\n' >"$wr/xmrig/build/xmrig"
chmod +x "$wr/xmrig/build/xmrig"
out="$(topo)"
eq 'a miner without the flag is not collected' "$?" 1
eq 'a miner without the flag is named' "$out" export-topology-unsupported
printf '#!/bin/sh\n[ "$1" = --help ] && echo "  --export-topology" && exit 0\nexit 0\n' >"$wr/xmrig/build/xmrig"
out="$(topo)"
eq 'a miner that exports nothing is not collected' "$?" 1
eq 'a miner that exports nothing is named' "$out" no-hwloc-topology
printf '#!/bin/sh\n[ "$1" = --help ] && echo "  --export-topology" && exit 0\necho "<topology/>" >topology.xml\n' >"$wr/xmrig/build/xmrig"
topo >/dev/null
eq 'a topology file is collected' "$?" 0
eq 'the collected topology is the miner export' "$(cat "$TMP/topology.xml")" '<topology/>'
printf '#!/bin/sh\n[ "$1" = --help ] && echo "  --export-topology" && exit 0\necho "<topology version=\\"2\\"/>"\n' >"$wr/xmrig/build/xmrig"
topo >/dev/null
eq 'a topology on stdout is collected' "$?" 0

printf 'thread placement regressions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
