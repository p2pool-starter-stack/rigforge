#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
hp() {
    (
        source "$SCRIPT"
        _validate_host_port "$1" "Pool socks5" 9050
    ) 2>&1
    echo "rc=$?"
}
pc() {
    printf '%s' "$1" >"$D/config.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$D/config.json"
        SCRIPT_DIR="$ROOT"
        parse_config
    ) 2>&1
    echo "rc=$?"
}
refused_unprinted() {
    case "$2" in
    *NOTREALPW*) check "$1: the value is not printed" clean leaked ;;
    *) check "$1: the value is not printed" clean clean ;;
    esac
    check "$1: refused" "rc=1" "${2##*$'\n'}"
    check "$1: names the rule" y "$(case "$2" in *"without a user name or password"*) echo y ;; *) echo n ;; esac)"
}

echo "== unit: a host:port with a user name or password is refused without printing it =="
refused_unprinted "with a port" "$(hp 'user:NOTREALPW@127.0.0.1:9050')"
refused_unprinted "without a port" "$(hp 'user:NOTREALPW@127.0.0.1')"
refused_unprinted "with a long port" "$(hp 'user:NOTREALPW@h:1234567')"
refused_unprinted "with a port out of range" "$(hp 'user:NOTREALPW@h:0')"
refused_unprinted "in a bracketed literal" "$(hp '[user:NOTREALPW@x]:9050')"
refused_unprinted "as a bare token before the host" "$(hp 'NOTREALPW@h:9050')"
refused_unprinted "with nothing after the at sign" "$(hp 'user:NOTREALPW@')"
refused_unprinted "as a pool url" "$(pc '{"pools":[{"url":"user:NOTREALPW@pool.lan:3333"}]}')"
refused_unprinted "as a pool socks5" "$(pc '{"pools":[{"url":"pool.lan:3333","socks5":"user:NOTREALPW@127.0.0.1:9050"}]}')"
check "a plain host:port is accepted" "rc=0" "$(hp '127.0.0.1:9050')"
check "a bad host is still named" y "$(case "$(hp 'evil;rm:9050')" in *"host 'evil;rm'"*) echo y ;; *) echo n ;; esac)"
check "a missing port is still explained" y "$(case "$(hp '127.0.0.1')" in *"'127.0.0.1' must include a port"*) echo y ;; *) echo n ;; esac)"
exit "$fail"
