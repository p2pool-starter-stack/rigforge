#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d)
TABLE_CREATED=0
SERVER_PID=
test_rc=0

cleanup() {
    local cleanup_rc=0
    if [ "$TABLE_CREATED" = 1 ]; then
        nft delete table inet rigforge >/dev/null 2>&1 || cleanup_rc=1
    fi
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || cleanup_rc=1
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TASK_TMP" || cleanup_rc=1
    return "$cleanup_rc"
}
trap 'test_rc=$?; trap - EXIT; cleanup || [ "$test_rc" -ne 0 ] || test_rc=1; exit "$test_rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(uname -s)" = Linux ]
[ "$(id -u)" -eq 0 ]
[ -e /.dockerenv ] || [ "${E2E_ALLOWLIST_LINUX_TEST:-}" = 1 ]
for tool in ip nft curl jq python3; do command -v "$tool" >/dev/null; done
if nft list table inet rigforge >/dev/null 2>&1; then
    printf 'api allowlist linux test: inet rigforge already exists\n' >&2
    exit 1
fi

python3 - "$TASK_TMP/port" <<'PY' &
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_args):
        pass


server = http.server.ThreadingHTTPServer(("", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$TASK_TMP/port" ] && break
    sleep 0.1
done
[ -s "$TASK_TMP/port" ]
API_PORT=$(cat "$TASK_TMP/port")
ALLOWED_SOURCE=$(ip -j -4 address show dev lo | jq -r '[.[].addr_info[] | select(.scope == "host")][0].local // empty')
[ -n "$ALLOWED_SOURCE" ]

# shellcheck source=tests/e2e-pithead-allowlist.sh
source "$ROOT/tests/e2e-pithead-allowlist.sh"
live_hashrate() { printf 1; }

install_rules() {
    local mode=$1 host_if="rfah-$$"
    if [ "$TABLE_CREATED" = 1 ]; then
        nft delete table inet rigforge
        TABLE_CREATED=0
    fi
    nft add table inet rigforge
    TABLE_CREATED=1
    nft 'add chain inet rigforge api { type filter hook input priority filter; policy accept; }'
    nft add rule inet rigforge api tcp dport "$API_PORT" iifname lo accept
    nft add rule inet rigforge api tcp dport "$API_PORT" ip saddr "$ALLOWED_SOURCE" accept
    case "$mode" in
    blocked) nft add rule inet rigforge api tcp dport "$API_PORT" counter drop ;;
    admitted)
        nft add rule inet rigforge api tcp dport "$API_PORT" iifname "$host_if" accept
        nft add rule inet rigforge api tcp dport "$API_PORT" counter drop
        ;;
    stalled)
        nft add rule inet rigforge api tcp dport "$API_PORT" drop
        nft add rule inet rigforge api tcp dport "$API_PORT" counter drop
        ;;
    esac
}

assert_clean() {
    if ip netns list | awk '{print $1}' | grep -Fxq "rfapi-$$"; then return 1; fi
    if ip link show "rfah-$$" >/dev/null 2>&1; then return 1; fi
}

install_rules blocked
api_allowlist_probe "$ALLOWED_SOURCE" "$ALLOWED_SOURCE" "$API_PORT" "probe-$RANDOM"
assert_clean

install_rules admitted
if api_allowlist_probe "$ALLOWED_SOURCE" "$ALLOWED_SOURCE" "$API_PORT" "probe-$RANDOM"; then
    printf 'api allowlist linux test: admitted namespace passed\n' >&2
    exit 1
fi
assert_clean

install_rules stalled
if api_allowlist_probe "$ALLOWED_SOURCE" "$ALLOWED_SOURCE" "$API_PORT" "probe-$RANDOM"; then
    printf 'api allowlist linux test: unmoved counter passed\n' >&2
    exit 1
fi
assert_clean
printf 'api allowlist linux tests passed\n'
