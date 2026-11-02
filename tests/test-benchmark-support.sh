#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${1:-$ROOT/rigforge.sh}
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export SCRIPT RF_TEST_ROOT="$D"
mkdir -p "$D/worker" "$D/extracted"
printf '{}\n' >"$D/config.json"
printf '%s\n' '{"seed":"00000000","hash":"898B6E0431C28A6B","verdict":"verified","id":"AbC123","extra":"excluded"}' >"$D/worker/rigforge-bench.json"
bundle() {
    bash -c '
        source "$SCRIPT"
        SCRIPT_DIR="$RF_TEST_ROOT" CONFIG_JSON="$RF_TEST_ROOT/config.json"
        SYSTEMD_DIR="$RF_TEST_ROOT/absent" OS_TYPE=Linux
        _worker_root_from_config() { printf "%s/worker" "$RF_TEST_ROOT"; }
        cmd_version() { echo test; }
        hostname() { :; }
        uname() { echo Linux; }
        lscpu() { :; }
        free() { :; }
        support_bundle
    ' /usr/bin/false >"$D/output" 2>&1
    tar -xzf "$D"/rigforge-support-*.tar.gz -C "$D/extracted"
}
bundle
test -f "$D/extracted/rigforge-bench.json" || {
    echo 'FAIL: bundle omitted last bench'
    exit 1
}
jq -e '.seed == "00000000" and .hash == "898B6E0431C28A6B" and .verdict == "verified" and .id == "AbC123" and (has("extra") | not)' "$D/extracted/rigforge-bench.json" >/dev/null
printf '%s\n' '{"seed":"bad seed","hash":"898B6E0431C28A6B","verdict":"verified"}' >"$D/worker/rigforge-bench.json"
rm -f "$D/extracted/rigforge-bench.json" "$D"/rigforge-support-*.tar.gz
bundle
test ! -e "$D/extracted/rigforge-bench.json"
jq -e '.not_collected | index("rigforge-bench.json(absent-or-invalid)") != null' "$D/extracted/manifest.json" >/dev/null
printf 'benchmark support bundle: PASS\n'
