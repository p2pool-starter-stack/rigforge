#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail

SRC=/src
PKI=/pki
GIT_ROOT=/srv/git
export HOME=/root
git config --global user.email isolation@example.invalid
git config --global user.name isolation
git config --global init.defaultBranch main
git config --global --add safe.directory '*'

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$PKI/ca.key" -out "$PKI/ca.crt" -subj "/CN=rigforge-isolation-ca" -days 2 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$PKI/srv.key" -out "$PKI/srv.csr" -subj "/CN=github.com" 2>/dev/null
printf 'subjectAltName=DNS:github.com,DNS:api.github.com\n' >"$PKI/san.cnf"
openssl x509 -req -in "$PKI/srv.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -out "$PKI/srv.crt" -days 2 -extfile "$PKI/san.cnf" 2>/dev/null

mkdir -p "$GIT_ROOT/xmrig" "$GIT_ROOT/p2pool-starter-stack"
pin_file="$PKI/pins.env"
: >"$pin_file"
xm=$(mktemp -d)
git -C "$xm" init -q
mkdir -p "$xm/src"
n=0
for tag in viso1 viso2 viso3; do
    n=$((n + 1))
    printf 'constexpr const int kDefaultDonateLevel = 1;\nconstexpr const int kMinimumDonateLevel = 1;\nconstexpr const int kBuild = %s;\n' "$n" >"$xm/src/donate.h"
    git -C "$xm" add -A
    git -C "$xm" commit -q -m "xmrig $tag"
    git -C "$xm" tag "$tag"
    printf 'PIN_%s=%s\n' "$tag" "$(git -C "$xm" rev-parse HEAD)" >>"$pin_file"
done
git clone -q --bare "$xm" "$GIT_ROOT/xmrig/xmrig.git"

# shellcheck disable=SC1090,SC2154
source "$pin_file"
patch_pin() {
    sed -i "s|^XMRIG_VERSION=.*|XMRIG_VERSION=\"\${XMRIG_VERSION:-$2}\"|; s|^XMRIG_COMMIT=.*|XMRIG_COMMIT=\"\${XMRIG_COMMIT:-$3}\"|" "$1/rigforge.sh"
}
rf=$(mktemp -d)
(cd "$SRC" && tar --exclude=.git -cf - .) | tar -xf - -C "$rf"
patch_pin "$rf" viso1 "$PIN_viso1"
git -C "$rf" init -q
git -C "$rf" add -A
git -C "$rf" commit -q -m "release base"
git clone -q --bare "$rf" "$GIT_ROOT/p2pool-starter-stack/rigforge.git"

release() {
    local w bare="$GIT_ROOT/p2pool-starter-stack/rigforge.git"
    w=$(mktemp -d)
    git clone -q "$bare" "$w"
    printf '99.0.0\n' >"$w/VERSION"
    patch_pin "$w" viso3 "$PIN_viso3"
    git -C "$w" commit -q -am "release 99.0.0"
    git -C "$w" tag v99.0.0
    git -C "$bare" fetch -q "$w" 'refs/heads/main:refs/heads/main' 'refs/tags/*:refs/tags/*'
}

python3 "$SRC/tests/e2e/isolation-https.py" --listen 0.0.0.0:443 --root "$GIT_ROOT" --cert "$PKI/srv.crt" --key "$PKI/srv.key" >"$PKI/https.log" 2>&1 &
python3 "$SRC/tests/e2e/isolation-socks5.py" --listen 0.0.0.0:1080 --map github.com:443=127.0.0.1:443 --map api.github.com:443=127.0.0.1:443 --log "$PKI/socks.log" >"$PKI/socks.err" 2>&1 &
sleep 1
touch "$PKI/ready"

while :; do
    if [ -f "$PKI/want-release" ] && [ ! -f "$PKI/release-done" ]; then
        release
        touch "$PKI/release-done"
    fi
    sleep 1
done
