#!/usr/bin/env bash
echo "== split dirs: read-only lib, writable state (#780, #781) =="
SPLIT_LIB=/work-lib
SPLIT_STATE=/work-state
mkdir -p "$SPLIT_LIB" "$SPLIT_STATE"
cp -a "$WORK/rigforge.sh" "$WORK/VERSION" "$WORK/systemd" "$WORK/util" "$SPLIT_LIB/"
cat >"$SPLIT_STATE/config.json" <<EOF
{ "HOME_DIR": "DYNAMIC_HOME", "DONATION": 7, "tor_socks5": null, "api": "enabled", "api_allow_from": "10.20.30.40", "miner_user": "rf-miner", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
chmod -R a-w "$SPLIT_LIB"
split_hash() { (cd "$SPLIT_LIB" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
split_rf() { RIGFORGE_LIB="$SPLIT_LIB" RIGFORGE_STATE="$SPLIT_STATE" "$SPLIT_LIB/rigforge.sh" "${@:-setup}" --no-root-guard </dev/null; }
split_before="$(split_hash)"
sout="$(split_rf 2>&1)"
src=$?
assert_rc "split: setup exits 0" "$src" "0"
[ "$src" = 0 ] || printf '%s\n' "$sout" | tail -20
assert_eq "split: worker root lands under the state dir" "$([ -d "$SPLIT_STATE/data/worker/xmrig" ] && echo y || echo n)" "y"
assert_contains "split: miner unit carries the state dir" "$(cat /etc/systemd/system/xmrig.service 2>/dev/null)" "Environment=RIGFORGE_STATE=$SPLIT_STATE"
assert_contains "split: API unit loads config from the state dir" "$(cat /etc/systemd/system/rigforge-api.service 2>/dev/null)" "LoadCredential=config:$SPLIT_STATE/config.json"
assert_contains "split: API unit loads its server from the lib dir" "$(cat /etc/systemd/system/rigforge-api.service 2>/dev/null)" "LoadCredential=server:$SPLIT_LIB/util/api-server.py"
printf '#!/bin/sh\necho fake-xmrig\n' >"$SPLIT_STATE/data/worker/xmrig/build/xmrig"
chmod +x "$SPLIT_STATE/data/worker/xmrig/build/xmrig"
uout="$(split_rf upgrade 2>&1)"
urc=$?
assert_rc "split: upgrade exits 0" "$urc" "0"
[ "$urc" = 0 ] || printf '%s\n' "$uout" | tail -20
split_rf doctor --json >"$WORK/split-doctor.json" 2>/dev/null
assert_eq "split: doctor emits JSON" "$(jq -e . "$WORK/split-doctor.json" >/dev/null 2>&1 && echo y || echo n)" "y"
split_rf backup >/dev/null 2>&1
assert_rc "split: backup exits 0" "$?" "0"
assert_eq "split: backup archive lands under the state dir" "$(find "$SPLIT_STATE/backups" -name 'rigforge-backup-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')" "1"
split_rf support-bundle >/dev/null 2>&1
assert_rc "split: support-bundle exits 0" "$?" "0"
assert_eq "split: support tarball lands under the state dir" "$(find "$SPLIT_STATE" -maxdepth 1 -name 'rigforge-support-*.tar.gz' | wc -l | tr -d ' ')" "1"
assert_eq "split: lib tree is unchanged after setup, upgrade, doctor, backup and support-bundle" "$(split_hash)" "$split_before"
assert_eq "split: nothing but the bundle files under the lib dir" "$(find "$SPLIT_LIB" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "4"
summarize
