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
    mkdir -p "$d/out" "$TMP/runtime/worker"
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

plain="$(generate_case plain '{}' '' '')"

echo '== xmrig overlay: logging keys (#530) =='
eq 'Linux defaults colors off' "$(jq -c '.colors' "$plain")" false
eq 'print-time keeps the 60 s default' "$(jq -c '.["print-time"]' "$plain")" 60
eq 'health-print-time keeps the 60 s default' "$(jq -c '.["health-print-time"]' "$plain")" 60
absent 'verbose is not emitted by default' "$(jq -c 'keys' "$plain")" verbose
absent 'syslog is not emitted by default' "$(jq -c 'keys' "$plain")" syslog
logging="$(generate_case logging '{"xmrig":{"colors":true,"print-time":900,"health-print-time":0,"verbose":2,"syslog":true}}' '' '')"
eq 'every logging key round-trips through the overlay' "$(jq -c '[.colors, .["print-time"], .["health-print-time"], .verbose, .syslog]' "$logging")" '[true,900,0,2,true]'
parse_out="$(parse_case '{"colors":true,"print-time":900,"health-print-time":0,"verbose":2,"syslog":true}')"
eq 'logging overlay parses' "$(
    parse_case '{"verbose":1}' >/dev/null
    echo $?
)" 0
absent 'logging keys are documented overlay keys' "$parse_out" undocumented
echo '{}' | (
    source "$SCRIPT"
    _xmrig_logging_in_effect
) >"$TMP/logging-empty.json"
eq 'bundle fills XMRig defaults for absent keys' "$(jq -c '[.colors, .["print-time"], .["health-print-time"], .verbose, .syslog]' "$TMP/logging-empty.json")" '[true,60,60,0,false]'
(
    source "$SCRIPT"
    _xmrig_logging_in_effect
) <"$logging" >"$TMP/logging-set.json"
eq 'bundle records overlay values, including false and 0' "$(jq -c '[.colors, .["print-time"], .["health-print-time"], .verbose, .syslog]' "$TMP/logging-set.json")" '[true,900,0,2,true]'
(
    source "$SCRIPT"
    _xmrig_logging_in_effect
) <"$plain" >"$TMP/logging-plain.json"
eq 'bundle records colors false from the generated config' "$(jq -c '.colors' "$TMP/logging-plain.json")" false

printf 'xmrig logging: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
