#!/usr/bin/env bash
#
# Native macOS end-to-end (#69 layer 2). Runs the REAL rigforge.sh on real macOS with only the
# heavy/privileged bits stubbed (Homebrew, git/cmake/make), and asserts the macOS deploy path with
# GENUINE tools the Linux CI can only stub: BSD `sed` (the donate.h patch), the macOS config profile,
# `mac_*` process control (real `nohup` + PID file), the launchd login agent (real `launchctl`), and
# `backup`/`restore` (BSD `tar`/`date`/`mktemp`). Run on a macos-* runner (or any Mac). CI-only.
#
# It never compiles XMRig or brew-installs for real (slow/flaky) — those are stubbed, like the Linux
# e2e. A tiny sleeping fake `xmrig` stands in for the binary so start/stop/status are real.
#
set -uo pipefail

[ "$(uname -s)" = "Darwin" ] || {
    echo "macos e2e: skipped (not macOS — this is $(uname -s))"
    exit 0
}

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
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac }
assert_absent() { case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rigforge-macos-e2e.XXXXXX")"
# Sandbox HOME so the LaunchAgent plist and backups never touch the real ~/Library or ~/.
export HOME="$WORK/home"
PLIST="$HOME/Library/LaunchAgents/com.rigforge.xmrig.plist"
PIDFILE="$WORK/data-home/worker/xmrig.pid"
cleanup() {
    launchctl unload "$PLIST" 2>/dev/null || true
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
    [ -n "${WORK:-}" ] && rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$HOME"

# Writable copy of just the deploy bits (not .git / the suite / build artifacts).
(cd "$SRC" && cp -a rigforge.sh util systemd config.minimal.json config.reference.json VERSION "$WORK"/) 2>/dev/null
cd "$WORK" || {
    echo "cannot enter $WORK"
    exit 1
}

# Stubs for the heavy bits only — brew (deps), git (clone+donate.h, rev-parse), cmake/make (compile).
# Everything else is the REAL macOS tool (sed/tar/date/mktemp/nohup/launchctl/jq/sysctl/uname).
STUBS="$WORK/.stubs"
mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/brew"
cat >"$STUBS/git" <<'X'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*) echo "${XMRIG_COMMIT:-}" ;;
  *clone*)     mkdir -p xmrig/src; printf 'constexpr const int kDefaultDonateLevel = 1;\nstatic int DonateLevel = 1;\n' > xmrig/src/donate.h ;;
esac
exit 0
X
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/cmake"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/make"
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
export XMRIG_VERSION="vTEST" XMRIG_COMMIT="testcommit0000000000000000000000000000"

cat >"$WORK/config.json" <<EOF
{ "HOME_DIR": "$WORK/data-home", "DONATION": 7, "pools": [{"url": "poolbox.lan:3333"}] }
EOF

BUILD="$WORK/data-home/worker/xmrig/build"

echo "== setup (real macOS deploy path) =="
out="$(./rigforge.sh setup </dev/null 2>&1)"
rc=$?
assert_rc "setup exits 0" "$rc" "0"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -25
assert_contains "donate.h patched by real BSD sed" "$(cat "$WORK/data-home/worker/xmrig/src/donate.h" 2>/dev/null)" "DonateLevel = 7;"
assert_eq "config.json generated + valid JSON" "$(jq -e . "$BUILD/config.json" >/dev/null 2>&1 && echo y || echo n)" "y"
assert_eq "macOS profile: API host = :: (all interfaces)" "$(jq -r '.http.host' "$BUILD/config.json" 2>/dev/null)" "::"
assert_eq "macOS profile: donate-level = 7" "$(jq -r '.["donate-level"]' "$BUILD/config.json" 2>/dev/null)" "7"
# macOS does NO kernel tuning and installs NO service — finish_deployment points at `start`.
assert_contains "no kernel tuning on macOS" "$out" "Skipping kernel tuning"
assert_contains "no service install on macOS" "$out" "Service installation is not supported"
assert_contains "finish points at './rigforge.sh start'" "$out" "./rigforge.sh start"
assert_absent "no mandatory-reboot dance on macOS" "$out" "sudo reboot"

echo "== process control: real nohup + PID file (start/status/stop) =="
# A sleeping fake xmrig stands in for the compiled binary (compile is stubbed).
mkdir -p "$BUILD"
printf '#!/usr/bin/env bash\nexec sleep 600\n' >"$BUILD/xmrig"
chmod +x "$BUILD/xmrig"
out="$(./rigforge.sh start </dev/null 2>&1)"
assert_rc "start exits 0" "$?" "0"
assert_eq "start wrote a PID file" "$([ -f "$PIDFILE" ] && echo y || echo n)" "y"
spid="$(cat "$PIDFILE" 2>/dev/null)"
assert_eq "start: the miner process is alive" "$(kill -0 "$spid" 2>/dev/null && echo y || echo n)" "y"
assert_contains "status reports running" "$(./rigforge.sh status </dev/null 2>&1)" "running"
out="$(./rigforge.sh stop </dev/null 2>&1)"
assert_rc "stop exits 0" "$?" "0"
assert_eq "stop killed the process" "$(kill -0 "$spid" 2>/dev/null && echo y || echo n)" "n"
assert_eq "stop removed the PID file" "$([ -f "$PIDFILE" ] && echo y || echo n)" "n"

echo "== launchd login agent: real launchctl (enable/disable) =="
out="$(./rigforge.sh enable </dev/null 2>&1)"
erc=$?
# mac_enable writes the plist BEFORE attempting the load, so it exists whether or not a headless
# runner can actually load a GUI LaunchAgent (#69 caveat) — assert the plist content either way.
assert_eq "enable generated the LaunchAgent plist" "$([ -f "$PLIST" ] && echo y || echo n)" "y"
assert_contains "plist: correct Label" "$(cat "$PLIST" 2>/dev/null)" "com.rigforge.xmrig"
assert_contains "plist: runs the built binary" "$(cat "$PLIST" 2>/dev/null)" "$BUILD/xmrig"
assert_contains "plist: RunAtLoad" "$(cat "$PLIST" 2>/dev/null)" "<key>RunAtLoad</key>"
if [ "$erc" = 0 ]; then
    assert_contains "enable: launchctl loaded the agent" "$out" "Enabled"
    assert_contains "status: delegates to the login agent" "$(./rigforge.sh status </dev/null 2>&1)" "login agent"
else
    ok "enable: plist generated; headless launchctl load unavailable — scoped per #69"
fi
out="$(./rigforge.sh disable </dev/null 2>&1)"
assert_rc "disable exits 0" "$?" "0"
assert_eq "disable removed the LaunchAgent plist" "$([ -f "$PLIST" ] && echo y || echo n)" "n"

echo "== backup / restore round-trip (real BSD tar/date/mktemp) =="
printf '{ "randomx": { "scratchpad_prefetch_mode": 2 } }\n' >"$WORK/data-home/worker/tune-overrides.json"
out="$(./rigforge.sh backup </dev/null 2>&1)"
assert_rc "backup exits 0" "$?" "0"
arch="$(find "$WORK/backups" -name '*.tar.gz' 2>/dev/null | head -1)"
assert_eq "backup wrote a .tar.gz archive" "$([ -n "$arch" ] && echo y || echo n)" "y"
# Mutate config, then restore from the archive and confirm the round-trip.
cp "$WORK/config.json" "$WORK/config.before.json"
printf '{ "pools": [{"url": "changed.example:3333"}] }\n' >"$WORK/config.json"
out="$(./rigforge.sh restore -y "$arch" </dev/null 2>&1)"
assert_rc "restore exits 0" "$?" "0"
assert_eq "restore brought config.json back" "$(jq -r '.pools[0].url' "$WORK/config.json" 2>/dev/null)" "poolbox.lan:3333"
assert_eq "restore brought tune-overrides back" "$(jq -r '.randomx.scratchpad_prefetch_mode' "$WORK/data-home/worker/tune-overrides.json" 2>/dev/null)" "2"

echo ""
printf 'macos e2e: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
