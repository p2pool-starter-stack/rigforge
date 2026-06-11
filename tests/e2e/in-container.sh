#!/usr/bin/env bash
#
# Runs INSIDE a disposable Linux container (invoked by tests/e2e/run.sh). Provisions a writable copy
# of the repo, runs the real rigforge.sh twice against the container's real /etc, and asserts the
# Linux deploy path + idempotency. Exits non-zero on any failed assertion.
#
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
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac }
assert_absent() { case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac }

# 1. Real prerequisites: jq + envsubst (gettext). Installed with the REAL apt before stubs go on
#    PATH, so the script's own dependency step is the only thing we stub out.
#    Reproducibility comes from the digest-pinned base image (see run.sh). The apt package versions
#    are intentionally NOT hard-pinned: Ubuntu's archive rotates superseded versions out of the
#    release pocket, so a pinned `jq=<ver>` would 404 and break the run once a new build lands.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq jq gettext-base >/dev/null

# 2. Writable copy of the repo (/src is mounted read-only).
WORK=/work
cp -a /src "$WORK"
cd "$WORK" || {
    echo "cannot enter $WORK"
    exit 1
}

# 3. Seed the system files the deploy expects to edit (base images ship none of these).
mkdir -p /etc/modules-load.d /etc/default /etc/systemd/system
: >/etc/fstab
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >/etc/default/grub
[ -f /etc/security/limits.conf ] || {
    mkdir -p /etc/security
    : >/etc/security/limits.conf
}

# 4. Stubs for the heavy/privileged/hardware bits. Passthrough sudo so real writes land in /etc.
#    Hardware detection is stubbed for a deterministic EPYC profile.
STUBS="$WORK/.stubs"
mkdir -p "$STUBS"
cat >"$STUBS/sudo" <<'X'
#!/usr/bin/env bash
exec "$@"
X
cat >"$STUBS/git" <<'X'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*) echo "${XMRIG_COMMIT:-}" ;;   # #18 verifies the cloned commit
  *clone*)     mkdir -p xmrig/src; printf 'static int DonateLevel = 1;\n' > xmrig/src/donate.h ;;
esac
exit 0
X
cat >"$STUBS/lscpu" <<'X'
#!/usr/bin/env bash
echo "Model name:            AMD EPYC 7763 64-Core Processor"
echo "L3 cache:              256 MiB"
echo "Socket(s):             2"
X
printf '#!/usr/bin/env bash\necho 8\n' >"$STUBS/nproc"
printf '#!/usr/bin/env bash\necho poolbox\n' >"$STUBS/hostname"
# No-op the rest (sysctl -w / mount / systemctl etc. cannot run unprivileged in a container).
for c in cmake make systemctl modprobe mount cpupower update-grub sysctl dpkg; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$c"
done
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
# Pin the XMRig version/commit to known test values so the build's commit verification (#18) passes
# without a real clone; the git stub echoes XMRIG_COMMIT for `rev-parse`.
export XMRIG_VERSION="vTEST" XMRIG_COMMIT="testcommit0000000000000000000000000000"

# 5. Seed config.json (writable HOME_DIR; DONATION 7). Use an explicit (dotted) host so this doesn't
#    depend on the .local/mDNS appending that PR #15 removes.
cat >"$WORK/config.json" <<EOF
{ "HOME_DIR": "$WORK/data-home", "DONATION": 7, "pools": [{"url": "poolbox.lan:3333"}] }
EOF

BUILD="$WORK/data-home/worker/xmrig/build"
ARCH="$(uname -m)"

echo "== first run =="
out1="$(./rigforge.sh </dev/null 2>&1)"
rc1=$?
assert_rc "first run exits 0" "$rc1" "0"
[ "$rc1" = 0 ] || printf '%s\n' "$out1" | tail -20
assert_contains "donate.h patched by real sed" "$(cat "$WORK/data-home/worker/xmrig/src/donate.h" 2>/dev/null)" "DonateLevel = 7;"
assert_eq "build: output captured to logfile" "$([ -f "$WORK/data-home/worker/build.log" ] && echo yes || echo no)" "yes"
assert_contains "build: verified pinned commit" "$out1" "Verified XMRig"
assert_eq "deploy: pool url from hostname" "$(jq -r '.pools[0].url' "$BUILD/config.json" 2>/dev/null)" "poolbox.lan:3333"
assert_eq "deploy: EPYC numa applied" "$(jq -r '.randomx.numa' "$BUILD/config.json" 2>/dev/null)" "true"
assert_eq "deploy: donate-level = 7" "$(jq -r '.["donate-level"]' "$BUILD/config.json" 2>/dev/null)" "7"
# #55: the config is built entirely in-script — there is no bundled template. Prove, with the REAL jq
# in the container, that the result is valid JSON and carries the static defaults that used to live in
# the template file (so a missing/empty template can never silently drop them again).
assert_eq "deploy: config.json is valid JSON" "$(jq -e . "$BUILD/config.json" >/dev/null 2>&1 && echo y || echo n)" "y"
assert_eq "in-script default: autosave on" "$(jq -r '.autosave' "$BUILD/config.json" 2>/dev/null)" "true"
assert_eq "in-script: no dead cpu.hwloc key" "$(jq -r '.cpu.hwloc' "$BUILD/config.json" 2>/dev/null)" "null"
assert_eq "in-script: huge-pages-jit off (XMRig default)" "$(jq -r '.cpu."huge-pages-jit"' "$BUILD/config.json" 2>/dev/null)" "false"
assert_eq "in-script default: randomx.mode fast" "$(jq -r '.randomx.mode' "$BUILD/config.json" 2>/dev/null)" "fast"
assert_eq "in-script default: http.port 8080" "$(jq -r '.http.port' "$BUILD/config.json" 2>/dev/null)" "8080"
assert_eq "in-script default: opencl off" "$(jq -r '.opencl' "$BUILD/config.json" 2>/dev/null)" "false"
assert_eq "in-script default: cuda off" "$(jq -r '.cuda' "$BUILD/config.json" 2>/dev/null)" "false"
assert_eq "no bundled template shipped" "$([ -e "$WORK/worker-config" ] && echo present || echo gone)" "gone"
svc="$(cat /etc/systemd/system/xmrig.service 2>/dev/null)"
assert_contains "service rendered by real envsubst" "$svc" "$BUILD"
# #13: hardening directives + ReadWritePaths got WORKER_ROOT expanded by the REAL envsubst.
assert_contains "service: NoNewPrivileges hardening" "$svc" "NoNewPrivileges=true"
assert_contains "service: ProtectSystem=full" "$svc" "ProtectSystem=full"
assert_contains "service: ReadWritePaths -> worker root" "$svc" "ReadWritePaths=$WORK/data-home/worker"
assert_absent "service: no unexpanded WORKER_ROOT" "$svc" 'ReadWritePaths=$WORKER_ROOT'
assert_contains "limits: fstab hugepages written" "$(cat /etc/fstab)" "hugetlbfs /dev/hugepages"
assert_contains "limits: memlock written" "$(cat /etc/security/limits.conf)" "soft memlock unlimited"
assert_absent "limits: not wildcard memlock" "$(cat /etc/security/limits.conf)" "* soft memlock unlimited"
assert_contains "grub: hugepages configured" "$(cat /etc/default/grub)" "hugepages"
assert_contains "grub: preserves existing params" "$(cat /etc/default/grub)" "quiet splash"
if [ "$ARCH" = x86_64 ]; then
    assert_contains "kernel: msr module enabled (x86)" "$(cat /etc/modules-load.d/msr.conf 2>/dev/null)" "msr"
else
    echo "  • $ARCH container: MSR module path is x86-only, skipped (run linux/amd64 for full coverage)"
fi
cp "$BUILD/config.json" "$WORK/config-run1.json"

echo "== second run (idempotency) =="
out2="$(./rigforge.sh </dev/null 2>&1)"
rc2=$?
assert_rc "second run exits 0" "$rc2" "0"
[ "$rc2" = 0 ] || printf '%s\n' "$out2" | tail -20
assert_eq "fstab: hugepages line not doubled" "$(grep -c 'hugetlbfs /dev/hugepages ' /etc/fstab)" "1"
assert_eq "fstab: 1G line not doubled" "$(grep -c 'hugetlbfs_1g ' /etc/fstab)" "1"
assert_eq "limits: soft line not doubled" "$(grep -c 'soft memlock unlimited' /etc/security/limits.conf)" "1"
assert_eq "grub: single cmdline entry" "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)" "1"
assert_contains "grub: detected already-configured" "$out2" "already configured"
assert_eq "workspace: prior install archived" "$(find "$WORK/data-home/worker" -maxdepth 1 -name 'xmrig-*' | wc -l | tr -d ' ')" "1"
# Shell string compare (portable; no dependency on cmp/diff being present).
if [ "$(cat "$WORK/config-run1.json" 2>/dev/null)" = "$(cat "$BUILD/config.json" 2>/dev/null)" ] && [ -s "$BUILD/config.json" ]; then
    ok "deploy: config.json stable across runs"
else
    bad "deploy: config.json stable across runs" "differs or missing"
fi

echo "== third run (recompile is skipped when already built) =="
# #audit: the skip-the-recompile engine behind a no-op re-run + `upgrade`. The stub `make` never produces
# a binary, so runs 1+2 above ALWAYS rebuild — the skip path was never exercised in a dispatched run. Drop
# in a fake built binary at the pinned commit, then a third run must skip the clone/compile entirely.
printf '#!/bin/sh\necho fake-xmrig\n' >"$BUILD/xmrig"
chmod +x "$BUILD/xmrig"
: >"$WORK/calls3.log"
out3="$(CALL_LOG="$WORK/calls3.log" ./rigforge.sh </dev/null 2>&1)"
assert_rc "third run (already built) exits 0" "$?" "0"
assert_contains "recompile SKIPPED when already built at the pinned commit" "$out3" "recompile will be skipped"
assert_absent "no git clone on a build-skip re-run" "$(cat "$WORK/calls3.log" 2>/dev/null)" "clone"
assert_eq "no new build archive on a skip re-run" "$(find "$WORK/data-home/worker" -maxdepth 1 -name 'xmrig-*' | wc -l | tr -d ' ')" "1"

# #54: the iterative auto-tuner, end-to-end on REAL Linux (real bash/jq/awk/sort). The compile is
# stubbed, so drop in a fake xmrig that reports a hashrate as a function of the knobs (peak at
# prefetch=2 / yield=false / threads=8 — the L3=256 MiB center clamped to the 8 stub cores). This
# exercises the genuine hill-climb, median, memoization, the reboot-bound 1gb-pages guard, and the
# overrides→generate merge — none of which the macOS unit suite runs on a real kernel.
echo "== tune: iterative hill-climb (#54) =="
cat >"$BUILD/xmrig" <<'X'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
y=$(jq -r '.cpu.yield' "$cfg" 2>/dev/null)
t=$(jq -r '.cpu.rx' "$cfg" 2>/dev/null)
base=5000
case "$m" in 2) base=6000 ;; 1) base=5500 ;; 0) base=5000 ;; *) base=5200 ;; esac
[ "$y" = false ] && base=$((base + 50))
tt="$t"
[ "$tt" = "-1" ] && tt=6
pen=$(((tt > 8 ? tt - 8 : 8 - tt) * 100))
base=$((base - pen))
echo "speed 10s/60s/15m $base.0 H/s max $base.0 H/s"
X
chmod +x "$BUILD/xmrig"
OVR="$WORK/data-home/worker/tune-overrides.json"
TLOG="$WORK/data-home/worker/rigforge-tune.json"
tout="$(TUNE_ITERS=1 ./rigforge.sh tune </dev/null 2>&1)"
trc=$?
assert_rc "tune exits 0" "$trc" "0"
[ "$trc" = 0 ] || printf '%s\n' "$tout" | tail -20
assert_contains "tune finds the global optimum" "$tout" "Best: prefetch_mode=2 yield=false threads=8"
assert_eq "tune wrote overrides" "$([ -f "$OVR" ] && echo y || echo n)" "y"
assert_eq "overrides: winning prefetch" "$(jq -r '.randomx.scratchpad_prefetch_mode' "$OVR" 2>/dev/null)" "2"
assert_eq "overrides: winning thread count" "$(jq -r '.cpu.rx' "$OVR" 2>/dev/null)" "8"
assert_eq "tune log is valid JSON" "$(jq -e . "$TLOG" >/dev/null 2>&1 && echo y || echo n)" "y"
assert_eq "tune log best threads" "$(jq -r '.best.threads' "$TLOG" 2>/dev/null)" "8"
assert_eq "tune left config.json untouched" "$([ -f ./config.json ] && echo y || echo n)" "y"
# apply merges the tuned overrides into the generated config.
./rigforge.sh apply </dev/null >/dev/null 2>&1
assert_eq "apply merged tuned prefetch" "$(jq -r '.randomx.scratchpad_prefetch_mode' "$BUILD/config.json" 2>/dev/null)" "2"
assert_eq "apply merged tuned thread count" "$(jq -r '.cpu.rx' "$BUILD/config.json" 2>/dev/null)" "8"
# tune --clear resets the tuning state.
./rigforge.sh tune --clear </dev/null >/dev/null 2>&1
assert_eq "tune --clear removed overrides" "$([ -f "$OVR" ] && echo y || echo n)" "n"

# #12: uninstall reverts everything (real Linux, real GNU sed for the GRUB strip).
echo "== uninstall (clean revert) =="
out3="$(./rigforge.sh uninstall --yes </dev/null 2>&1)"
rc3=$?
assert_rc "uninstall exits 0" "$rc3" "0"
[ "$rc3" = 0 ] || printf '%s\n' "$out3" | tail -20
assert_eq "uninstall: service unit removed" "$([ -f /etc/systemd/system/xmrig.service ] && echo y || echo n)" "n"
assert_eq "uninstall: fstab hugepages reverted" "$(grep -c 'hugetlbfs' /etc/fstab)" "0"
assert_eq "uninstall: memlock reverted" "$(grep -c 'memlock unlimited' /etc/security/limits.conf)" "0"
assert_eq "uninstall: msr.conf removed" "$([ -f /etc/modules-load.d/msr.conf ] && echo y || echo n)" "n"
assert_absent "uninstall: GRUB hugepages stripped" "$(cat /etc/default/grub)" "default_hugepagesz"
assert_absent "uninstall: GRUB msr param stripped" "$(cat /etc/default/grub)" "msr.allow_writes"
assert_contains "uninstall: GRUB keeps base params" "$(cat /etc/default/grub)" "quiet splash"
assert_eq "uninstall: config.json left in place" "$([ -f ./config.json ] && echo y || echo n)" "y"
./rigforge.sh uninstall --yes </dev/null >/dev/null 2>&1
assert_rc "uninstall is idempotent" "$?" "0"

echo ""
printf 'in-container: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
