#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
FAIL=0
eq() {
    if [ "$2" = "$3" ]; then printf '  ok: %s\n' "$1"; else
        printf '  FAIL: %s — expected [%s], got [%s]\n' "$1" "$3" "$2" >&2
        FAIL=$((FAIL + 1))
    fi
}
absent() {
    if grep -qF -- "$3" "$2"; then
        printf '  FAIL: %s — found in the jq argument log\n' "$1" >&2
        FAIL=$((FAIL + 1))
    else printf '  ok: %s\n' "$1"; fi
}
REAL_JQ=$(command -v jq)
mkdir -p "$D/bin" "$D/logrotate"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$D/argv.log" "$REAL_JQ" >"$D/bin/jq"
chmod +x "$D/bin/jq"
PW='PlantedPoolPw"q\b$x'"'"'y9'
SPACED_PW='SpacedPoolPw "a\ü$'"'"'z'
FP=$(printf '%064d' 7)
TOK='Tok3nValueQ7'
PROMPT_PW='Pr0mptPassZ4'
run_all() {
    (
        RIGFORGE_HOME=$(dirname "$SCRIPT") LOGROTATE_DIR="$D/logrotate" source "$SCRIPT"
        CONFIG_JSON="$1" SCRIPT_DIR=$(dirname "$SCRIPT") OS_TYPE=Linux LOGROTATE_DIR="$D/logrotate"
        PATH="$D/bin:$PATH"
        parse_config >/dev/null 2>&1 || exit 3
        mkdir -p "$2/xmrig/build"
        printf '%s' "$POOLS_JSON" >"$2/pools.json"
        _writable_config_canonical >"$2/canonical.json"
        WORKER_ROOT="$2" CPUINFO="$D/no-cpuinfo"
        lscpu() { printf 'Model name: fixture cpu\n'; }
        hostname() { printf 'fixture-host\n'; }
        sudo() { "$@"; }
        cd "$WORKER_ROOT/xmrig/build" || exit 4
        generate_xmrig_config >/dev/null 2>&1 || exit 5
    )
}
first_run() {
    (
        source "$SCRIPT"
        CONFIG_JSON="$1"
        _reown_worker() { :; }
        printf '%b' "$2" | PATH="$D/bin:$PATH" ensure_config_exists >/dev/null 2>&1
    )
}

echo "== pool settings and the API token reach jq off its argument list =="
jq -n --arg pw "$PW" --arg tok "$TOK" --arg fp "$FP" '{pools: [{url: "pool.example:3333", user: "w.rig", pass: $pw, tls: true, "tls-fingerprint": $fp, socks5: "127.0.0.1:9050", "rig-id": "r1", keepalive: false}, {url: "daemon+http://127.0.0.1:18081", pass: "z"}], ACCESS_TOKEN: $tok, DONATION: 0}' >"$D/config.json"
run_all "$D/config.json" "$D/w1"
eq "parse, canonical view and render complete" "$?" 0
eq "the parsed pools keep the password" "$(jq -r '.[0].pass' "$D/w1/pools.json")" "$PW"
eq "the parsed pools keep the optional fields" "$(jq -c '.[0] | [."tls-fingerprint", .socks5, ."rig-id", .keepalive]' "$D/w1/pools.json")" "[\"$FP\",\"127.0.0.1:9050\",\"r1\",false]"
eq "the second pool is a daemon pool" "$(jq -c '.[1].daemon' "$D/w1/pools.json")" true
eq "the canonical view keeps the password" "$(jq -r '.pools[0].pass' "$D/w1/canonical.json")" "$PW"
eq "the miner config carries the password" "$(jq -r '.pools[0].pass' "$D/w1/xmrig/build/config.json")" "$PW"
eq "the miner config carries the API token" "$(jq -r '.http."access-token"' "$D/w1/xmrig/build/config.json")" "$TOK"
printf '{"pools":[{"url":"h.example:3333"}]}\n' >"$D/plain.json"
run_all "$D/plain.json" "$D/w2"
eq "a config with no API token renders it as null" "$(jq -c '.http."access-token"' "$D/w2/xmrig/build/config.json" 2>/dev/null)" null
jq -n --arg pw "$SPACED_PW" '{pools: [{url: "h.example:3333", pass: $pw}]}' >"$D/spaced.json"
eq "the canonical view keeps a password with spaces and quotes" "$(
    source "$SCRIPT"
    CONFIG_JSON="$D/spaced.json" PATH="$D/bin:$PATH"
    _writable_config_canonical | jq -r '.pools[0].pass'
)" "$SPACED_PW"
first_run "$D/first.json" "y\npool.example:3333\n$PROMPT_PW\n"
eq "the first-run prompt writes the entered password" "$(jq -c '.pools' "$D/first.json" 2>/dev/null)" "[{\"url\":\"pool.example:3333\",\"pass\":\"$PROMPT_PW\"}]"
first_run "$D/first-nopass.json" 'y\npool.example:3333\n'
eq "the first-run prompt with no password writes only the url" "$(jq -c '.pools' "$D/first-nopass.json" 2>/dev/null)" '[{"url":"pool.example:3333"}]'
eq "jq calls were recorded" "$([ -s "$D/argv.log" ] && echo y || echo n)" y
absent "no pool password in any jq argument list" "$D/argv.log" PlantedPoolPw
absent "no spaced pool password in any jq argument list" "$D/argv.log" SpacedPoolPw
absent "no API token in any jq argument list" "$D/argv.log" "$TOK"
absent "no first-run password in any jq argument list" "$D/argv.log" "$PROMPT_PW"
[ "$FAIL" -eq 0 ]
