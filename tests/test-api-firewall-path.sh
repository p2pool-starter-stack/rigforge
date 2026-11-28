#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
fail=0
mkdir -p "$D/bin"
cat >"$D/bin/envsubst" <<'EOF'
#!/usr/bin/env bash
text=$(cat)
for v in ${1//\$/}; do text=${text//\$$v/${!v-}}; done
printf '%s\n' "$text"
EOF
chmod +x "$D/bin/envsubst"
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
run_fw() {
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CASE="$1" WORKER_ROOT="$1/wr" SYSTEMD_DIR="$1/sd"
        API_ALLOW_FROM="$2"
        sudo() { "$@"; }
        nft() {
            echo "[nft] $*" >>"$CASE/calls.log"
            [ ! -e "$CASE/reject" ]
        }
        _shared_host_remove() { :; }
        PATH="$D/bin:$PATH"
        set +e
        if [ "${3:-}" = control ]; then
            systemctl() { :; }
            python3() { :; }
            CONTROL_MODE=enabled CONTROL_BIND=0.0.0.0 CONTROL_PORT=8082 REAL_USER=rfop install_control 2>&1
            exit 0
        fi
        install_api_firewall ${3:+"$3"} 2>&1
        [ -z "${3:-}" ] || exit 0
        NFT_PATH=/usr/sbin/nft BUILD_DIR="$WORKER_ROOT/xmrig/build" CPUPOWER_PATH=/usr/bin/cpupower _render_xmrig_unit
    )
}
new_case() {
    mkdir -p "$D/$1/wr" "$D/$1/sd"
    : >"$D/$1/calls.log"
    echo "$D/$1"
}

echo "== unit: API firewall rules are read only from the root-owned unit folder =="
c=$(new_case upgrade)
printf 'old rules\n' >"$c/wr/api-firewall.nft"
out=$(run_fw "$c" 10.0.0.5)
check "rules file written in the unit folder" y "$([ -f "$c/sd/rigforge-api-firewall.nft" ] && echo y || echo n)"
check "rules file carries the configured source" y "$(grep -q 'ip saddr 10.0.0.5 accept' "$c/sd/rigforge-api-firewall.nft" && echo y || echo n)"
check "rules loaded from the unit folder" y "$(grep -qF "[nft] -f $c/sd/rigforge-api-firewall.nft" "$c/calls.log" && echo y || echo n)"
check "previous rules file under the worker root is removed" n "$([ -e "$c/wr/api-firewall.nft" ] && echo y || echo n)"
check "no rules file is left under the worker root" 0 "$(find "$c/wr" -name '*api-firewall*' | wc -l | tr -d ' ')"
check "miner unit loads the rules from the unit folder" y "$(grep -qF "test -f $c/sd/rigforge-api-firewall.nft && /usr/sbin/nft -f $c/sd/rigforge-api-firewall.nft" "$c/sd/xmrig.service" && echo y || echo n)"
check "miner unit names no rules file under the worker root" n "$(grep -qF "$c/wr/api-firewall.nft" "$c/sd/xmrig.service" && echo y || echo n)"

c=$(new_case control)
run_fw "$c" 10.0.0.5 control >/dev/null
check "control unit loads the rules from the unit folder" 1 "$(grep -c -- "^ExecStartPre=+.* -f $c/sd/rigforge-api-firewall.nft\$" "$c/sd/rigforge-control.service" 2>/dev/null)"

c=$(new_case link)
printf 'kept\n' >"$c/target"
ln -s "$c/target" "$c/wr/api-firewall.nft"
run_fw "$c" 10.0.0.5 >/dev/null
check "a link at the previous rules name is removed" n "$([ -L "$c/wr/api-firewall.nft" ] && echo y || echo n)"
check "the link target is left as it was" kept "$(cat "$c/target")"

c=$(new_case cleared)
printf 'old rules\n' >"$c/wr/api-firewall.nft"
out=$(run_fw "$c" "")
check "cleared allow list removes the previous rules file" n "$([ -e "$c/wr/api-firewall.nft" ] && echo y || echo n)"
check "cleared allow list destroys the table" y "$(grep -qF '[nft] destroy table inet rigforge' "$c/calls.log" && echo y || echo n)"
check "cleared allow list logs the removal" y "$(case "$out" in *"API firewall removed."*) echo y ;; *) echo n ;; esac)"

c=$(new_case cleared-new)
printf 'rules\n' >"$c/sd/rigforge-api-firewall.nft"
run_fw "$c" "" >/dev/null
check "cleared allow list removes the rules file from the unit folder" n "$([ -e "$c/sd/rigforge-api-firewall.nft" ] && echo y || echo n)"
check "cleared allow list destroys the table for the unit-folder file" y "$(grep -qF '[nft] destroy table inet rigforge' "$c/calls.log" && echo y || echo n)"

c=$(new_case early)
printf 'old rules\n' >"$c/wr/api-firewall.nft"
run_fw "$c" 10.0.0.5 early >/dev/null
check "early pass writes the rules file in the unit folder" y "$([ -f "$c/sd/rigforge-api-firewall.nft" ] && echo y || echo n)"
check "early pass loads the rules from the unit folder" y "$(grep -qF "[nft] -f $c/sd/rigforge-api-firewall.nft" "$c/calls.log" && echo y || echo n)"
check "early pass keeps the previous rules file" "old rules" "$(cat "$c/wr/api-firewall.nft" 2>/dev/null)"
run_fw "$c" 10.0.0.5 >/dev/null
check "late pass removes the previous rules file" n "$([ -e "$c/wr/api-firewall.nft" ] && echo y || echo n)"

c=$(new_case rejected)
printf 'old rules\n' >"$c/wr/api-firewall.nft"
: >"$c/reject"
out=$(run_fw "$c" 10.0.0.5)
check "a rejected load reports the failure" y "$(case "$out" in *"FAILED to load"*) echo y ;; *) echo n ;; esac)"
check "a rejected load keeps the previous rules file" "old rules" "$(cat "$c/wr/api-firewall.nft" 2>/dev/null)"

c=$(new_case early-cleared)
printf 'old rules\n' >"$c/wr/api-firewall.nft"
printf 'rules\n' >"$c/sd/rigforge-api-firewall.nft"
out=$(run_fw "$c" "" early)
check "early pass with a cleared allow list keeps the previous rules file" "old rules" "$(cat "$c/wr/api-firewall.nft" 2>/dev/null)"
check "early pass with a cleared allow list keeps the unit-folder rules file" rules "$(cat "$c/sd/rigforge-api-firewall.nft" 2>/dev/null)"
check "early pass with a cleared allow list leaves the table alone" "" "$(cat "$c/calls.log")"
check "early pass with a cleared allow list logs nothing" "" "$out"

before() {
    awk -v fn="$1() {" -v want="$2" '
        $0 == fn { on = 1; next }
        on && /^}/ { exit }
        on && !fw && $1 == "install_api_firewall" && $2 == "early" { fw = NR }
        on && !u && $1 == want { u = NR }
        END { print (fw && u && fw < u) ? "y" : "n" }' "$SCRIPT"
}
check "setup names its step before the early load" y "$(grep -B1 -m1 'install_api_firewall early' "$SCRIPT" | grep -q 'CURRENT_STEP="configuring the API firewall"' && echo y || echo n)"
check "setup loads the rules before it renders the miner unit" y "$(before main install_service)"
check "upgrade loads the rules before it renders the miner unit" y "$(before upgrade install_service)"
check "apply loads the rules before it renders the miner unit" y "$(before apply _apply_runtime)"
exit "$fail"
