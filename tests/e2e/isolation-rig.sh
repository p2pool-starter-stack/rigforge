#!/usr/bin/env bash
# shellcheck disable=SC2154
set -uo pipefail

PASS=0
FAIL=0
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"
}
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac }
tail_out() { printf '%s\n' "$1" | tail -15; }

PKI=/pki
S5="${RF_PROXY:?RF_PROXY=host:port is required}"
S5_HOST="${S5%:*}"
S5_PORT="${S5##*:}"
WORK=/work
STUBS=/opt/rf-stubs
SOCKS_LOG="$PKI/socks.log"
export DEBIAN_FRONTEND=noninteractive HOME=/root

cp "$PKI/ca.crt" /usr/local/share/ca-certificates/rigforge-isolation.crt
update-ca-certificates >/dev/null 2>&1
# shellcheck disable=SC1091,SC2154
source "$PKI/pins.env"

upstream_hits() { grep -c ' ALLOW$' "$SOCKS_LOG" 2>/dev/null || true; }
set_proxy_key() { jq --arg v "$1" '.tor_socks5 = $v' "$WORK/config.json" >"$WORK/config.json.new" && mv "$WORK/config.json.new" "$WORK/config.json"; }
grew() { [ "$(upstream_hits)" -gt "$1" ] && echo y || echo n; }

echo "== the rig has no way out except the proxy =="
direct="$(curl --noproxy '*' -sS --max-time 8 https://api.github.com/repos/p2pool-starter-stack/rigforge/releases/latest 2>&1)"
case "$direct" in *tag_name*) reach=reached ;; *) reach=blocked ;; esac
assert_eq "direct https to api.github.com is blocked" "$reach" "blocked"
timeout 6 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null
assert_eq "a direct TCP connection to a public address is blocked" "$?" "1"
timeout 20 git ls-remote https://github.com/xmrig/xmrig.git >/dev/null 2>&1
assert_eq "a direct git ls-remote of the XMRig source is blocked" "$([ "$?" -ne 0 ] && echo blocked || echo reached)" "blocked"
timeout 6 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$S5_HOST" "$S5_PORT" 2>/dev/null
assert_rc "the SOCKS5 proxy is reachable" "$?" "0"

echo "== the rig's checkout comes through the proxy =="
git -c "http.proxy=socks5h://$S5" clone -q https://github.com/p2pool-starter-stack/rigforge.git "$WORK" 2>&1
assert_eq "proxied clone of the rig's own checkout" "$([ -f "$WORK/rigforge.sh" ] && echo y || echo n)" "y"
assert_eq "origin is an https URL" "$(git -C "$WORK" remote get-url origin)" "https://github.com/p2pool-starter-stack/rigforge.git"
git config --global --add safe.directory '*'

mkdir -p /etc/modules-load.d /etc/default /etc/systemd/system /etc/security "$STUBS"
: >/etc/fstab
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >/etc/default/grub
[ -f /etc/security/limits.conf ] || : >/etc/security/limits.conf
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$STUBS/sudo"
cat >"$STUBS/lscpu" <<'X'
#!/usr/bin/env bash
echo "Architecture:          x86_64"
echo "Model name:            AMD EPYC 7763 64-Core Processor"
echo "L3 cache:              256 MiB"
echo "Socket(s):             2"
X
printf '#!/usr/bin/env bash\necho 8\n' >"$STUBS/nproc"
printf '#!/usr/bin/env bash\necho poolbox\n' >"$STUBS/hostname"
for c in cmake make systemctl modprobe mount cpupower update-grub sysctl dpkg nft cc; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$c"
done
cat >"$STUBS/curl" <<'X'
#!/usr/bin/env bash
case "$*" in *'%{http_code}'*'/health'*) printf 200; exit 0 ;; esac
exec /usr/bin/curl "$@"
X
chmod +x "$STUBS"/*
python3 - <<'X' &
import http.server

BODY = b'{"hashrate":{"total":[1234.5,0,0]},"connection":{"pool":"poolbox.lan:3333","uptime":93700,"failures":0,"accepted":42,"rejected":1},"uptime":93780}'


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()
X
FAKE_API=$!
trap 'kill "$FAKE_API" 2>/dev/null' EXIT
cat >"$WORK/config.json" <<JSON
{ "HOME_DIR": "$WORK/data-home", "DONATION": 0, "tor_socks5": "$S5", "pools": [{"url": "poolbox.lan:3333"}] }
JSON
rf() { (cd "$WORK" && PATH="$STUBS:$PATH" ./rigforge.sh "$@" </dev/null 2>&1); }

echo "== upgrade --check =="
before="$(upstream_hits)"
out="$(rf upgrade --check)"
assert_rc "upgrade --check exits 0" "$?" "0"
assert_contains "upgrade --check reaches the release API through the proxy" "$out" "A newer RigForge is available: 99.0.0"
assert_eq "upgrade --check went through the proxy" "$(grew "$before")" "y"

echo "== setup clones the pinned XMRig through the proxy =="
before="$(upstream_hits)"
out="$(rf setup)"
rc=$?
assert_rc "setup exits 0" "$rc" "0"
[ "$rc" = 0 ] || tail_out "$out"
assert_contains "setup verified the pinned XMRig commit" "$out" "Verified XMRig viso1"
assert_eq "setup's clone went through the proxy" "$(grew "$before")" "y"
assert_contains "the built source is the pinned one" "$(cat "$WORK/data-home/worker/xmrig/src/donate.h" 2>/dev/null)" "kBuild = 1"

echo "== local upgrade with an XMRig pin change =="
before="$(upstream_hits)"
out="$(export XMRIG_VERSION=viso2 XMRIG_COMMIT="$PIN_viso2" && rf upgrade)"
rc=$?
assert_rc "upgrade with a changed pin exits 0" "$rc" "0"
[ "$rc" = 0 ] || tail_out "$out"
assert_contains "upgrade verified the new pinned commit" "$out" "Verified XMRig viso2"
assert_contains "upgrade reports the new XMRig" "$out" "Upgraded to XMRig viso2"
assert_eq "upgrade's clone went through the proxy" "$(grew "$before")" "y"
assert_contains "the live source is the new pin" "$(cat "$WORK/data-home/worker/xmrig/src/donate.h" 2>/dev/null)" "kBuild = 2"

echo "== remote upgrade under the oneshot's own environment =="
touch "$PKI/want-release"
for _ in $(seq 1 30); do
    [ -f "$PKI/release-done" ] && break
    sleep 1
done
assert_eq "the stand-in origin published the release" "$([ -f "$PKI/release-done" ] && echo y || echo n)" "y"
install -d -m 700 /run/rigforge-control /var/lib/rigforge-control /var/lib/rigforge-control/spool /var/lib/rigforge-control-upgrade
printf '{"version":"v99.0.0"}\n' >/var/lib/rigforge-control/spool/upgrade-0123456789abcdef.json
before="$(upstream_hits)"
env -i PATH="$STUBS:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" RIGFORGE_OPERATOR=root RIGFORGE_APPLIANCE=0 CONTROL_LIVE_TRIES=3 \
    "$WORK/rigforge.sh" control-upgrade </dev/null >"$WORK/control-upgrade.log" 2>&1
assert_rc "control-upgrade exits 0" "$?" "0"
status="$(cat /var/lib/rigforge-control/status.json 2>/dev/null)"
assert_eq "the remote upgrade was applied" "$(printf '%s' "$status" | jq -r .status 2>/dev/null)" "applied"
[ "$(printf '%s' "$status" | jq -r .status 2>/dev/null)" = applied ] || {
    printf '%s\n' "$status"
    tail -20 "$WORK/control-upgrade.log"
}
assert_eq "the checkout moved to the release tag" "$(git -C "$WORK" describe --tags --exact-match 2>/dev/null)" "v99.0.0"
assert_eq "the release's VERSION is installed" "$(tr -d '[:space:]' <"$WORK/VERSION")" "99.0.0"
assert_contains "the release's own pin was cloned through the proxy" "$(cat "$WORK/data-home/worker/xmrig/src/donate.h" 2>/dev/null)" "kBuild = 3"
assert_eq "the remote upgrade went through the proxy" "$([ "$(upstream_hits)" -ge $((before + 2)) ] && echo y || echo n)" "y"

echo "== fail closed =="
set_proxy_key "$S5_HOST:1"
before="$(upstream_hits)"
out="$(rf upgrade --check)"
assert_rc "upgrade --check with the proxy down exits 0" "$?" "0"
assert_contains "upgrade --check with the proxy down says so" "$out" "through tor_socks5 (no direct fallback)"
out="$(export XMRIG_VERSION=viso1 XMRIG_COMMIT="$PIN_viso1" && rf upgrade)"
rc=$?
assert_eq "upgrade with the proxy down fails instead of going direct" "$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" "failed"
assert_contains "the live source is untouched by the failed upgrade" "$(cat "$WORK/data-home/worker/xmrig/src/donate.h" 2>/dev/null)" "kBuild = 3"
assert_eq "nothing reached the upstream with the proxy down" "$(upstream_hits)" "$before"
set_proxy_key "$S5"

echo "== negative control: without the key the same fetch has nowhere to go =="
jq 'del(.tor_socks5)' "$WORK/config.json" >"$WORK/config.json.new" && mv "$WORK/config.json.new" "$WORK/config.json"
out="$(rf upgrade --check)"
assert_contains "upgrade --check without the key cannot reach GitHub" "$out" "Couldn't reach GitHub to check"
set_proxy_key "$S5"

echo "== what the proxy saw =="
assert_eq "every proxied request named a hostname (remote DNS), none an address" "$(grep -vc '^domain ' "$SOCKS_LOG")" "0"
assert_eq "the proxy denied nothing" "$(grep -c ' DENY$' "$SOCKS_LOG")" "0"
assert_eq "the proxy saw only GitHub's two hostnames" "$(awk '{print $2}' "$SOCKS_LOG" | sort -u | tr '\n' ' ')" "api.github.com:443 github.com:443 "

echo ""
printf 'isolation: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
