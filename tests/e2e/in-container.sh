#!/usr/bin/env bash
#
# Runs INSIDE a disposable Linux container (invoked by tests/e2e/run.sh). Provisions a writable copy
# of the repo, runs the real rigforge.sh twice against the container's real /etc, and asserts the
# Linux deploy path + idempotency. Exits non-zero on any failed assertion.
#
set -uo pipefail

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"; }
assert_rc()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac; }

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
cd "$WORK" || { echo "cannot enter $WORK"; exit 1; }

# 3. Seed the system files the deploy expects to edit (base images ship none of these).
mkdir -p /etc/modules-load.d /etc/default /etc/systemd/system
: > /etc/fstab
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' > /etc/default/grub
[ -f /etc/security/limits.conf ] || { mkdir -p /etc/security; : > /etc/security/limits.conf; }

# 4. Stubs for the heavy/privileged/hardware bits. Passthrough sudo so real writes land in /etc.
#    Hardware detection is stubbed for a deterministic EPYC profile.
STUBS="$WORK/.stubs"; mkdir -p "$STUBS"
cat > "$STUBS/sudo" <<'X'
#!/usr/bin/env bash
exec "$@"
X
cat > "$STUBS/git" <<'X'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*) echo "${XMRIG_COMMIT:-}" ;;   # #18 verifies the cloned commit
  *clone*)     mkdir -p xmrig/src; printf 'static int DonateLevel = 1;\n' > xmrig/src/donate.h ;;
esac
exit 0
X
cat > "$STUBS/lscpu" <<'X'
#!/usr/bin/env bash
echo "Model name:            AMD EPYC 7763 64-Core Processor"
echo "L3 cache:              256 MiB"
echo "Socket(s):             2"
X
printf '#!/usr/bin/env bash\necho 8\n'       > "$STUBS/nproc"
printf '#!/usr/bin/env bash\necho poolbox\n' > "$STUBS/hostname"
# No-op the rest (sysctl -w / mount / systemctl etc. cannot run unprivileged in a container).
for c in cmake make systemctl modprobe mount cpupower update-grub sysctl dpkg; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/$c"
done
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
# Pin the XMRig version/commit to known test values so the build's commit verification (#18) passes
# without a real clone; the git stub echoes XMRIG_COMMIT for `rev-parse`.
export XMRIG_VERSION="vTEST" XMRIG_COMMIT="testcommit0000000000000000000000000000"

# 5. Seed config.json (writable HOME_DIR; DONATION 7). Use an explicit (dotted) host so this doesn't
#    depend on the .local/mDNS appending that PR #15 removes.
cat > "$WORK/config.json" <<EOF
{ "HOME_DIR": "$WORK/data-home", "DONATION": 7, "WORKER_CONFIG_FILE": "./worker-config/example-config.json.template", "P2POOL_NODE_HOSTNAME": "poolbox.lan" }
EOF

BUILD="$WORK/data-home/worker/xmrig/build"
ARCH="$(uname -m)"

echo "== first run =="
out1="$(./rigforge.sh </dev/null 2>&1)"; rc1=$?
assert_rc       "first run exits 0"                "$rc1" "0"
[ "$rc1" = 0 ] || printf '%s\n' "$out1" | tail -20
assert_contains "donate.h patched by real sed"     "$(cat "$WORK/data-home/worker/xmrig/src/donate.h" 2>/dev/null)" "DonateLevel = 7;"
assert_eq       "build: output captured to logfile" "$([ -f "$WORK/data-home/worker/build.log" ] && echo yes || echo no)" "yes"
assert_contains "build: verified pinned commit"    "$out1" "Verified XMRig"
assert_eq       "deploy: pool url from hostname"   "$(jq -r '.pools[0].url' "$BUILD/config.json" 2>/dev/null)"   "poolbox.lan:3333"
assert_eq       "deploy: EPYC numa applied"        "$(jq -r '.randomx.numa' "$BUILD/config.json" 2>/dev/null)"   "true"
assert_eq       "deploy: donate-level = 7"         "$(jq -r '.["donate-level"]' "$BUILD/config.json" 2>/dev/null)" "7"
assert_contains "service rendered by real envsubst" "$(cat /etc/systemd/system/xmrig.service 2>/dev/null)" "$BUILD"
assert_contains "limits: fstab hugepages written"  "$(cat /etc/fstab)" "hugetlbfs /dev/hugepages"
assert_contains "limits: memlock written"          "$(cat /etc/security/limits.conf)" "soft memlock unlimited"
assert_contains "grub: hugepages configured"       "$(cat /etc/default/grub)" "hugepages"
if [ "$ARCH" = x86_64 ]; then
    assert_contains "kernel: msr module enabled (x86)" "$(cat /etc/modules-load.d/msr.conf 2>/dev/null)" "msr"
else
    echo "  • $ARCH container: MSR module path is x86-only, skipped (run linux/amd64 for full coverage)"
fi
cp "$BUILD/config.json" "$WORK/config-run1.json"

echo "== second run (idempotency) =="
out2="$(./rigforge.sh </dev/null 2>&1)"; rc2=$?
assert_rc       "second run exits 0"               "$rc2" "0"
[ "$rc2" = 0 ] || printf '%s\n' "$out2" | tail -20
assert_eq       "fstab: hugepages line not doubled" "$(grep -c 'hugetlbfs /dev/hugepages ' /etc/fstab)" "1"
assert_eq       "fstab: 1G line not doubled"        "$(grep -c 'hugetlbfs_1g ' /etc/fstab)" "1"
assert_eq       "limits: soft line not doubled"     "$(grep -c 'soft memlock unlimited' /etc/security/limits.conf)" "1"
assert_eq       "grub: single cmdline entry"        "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)" "1"
assert_contains "grub: detected already-configured" "$out2" "already configured"
assert_eq       "workspace: prior install archived" "$(find "$WORK/data-home/worker" -maxdepth 1 -name 'xmrig-*' | wc -l | tr -d ' ')" "1"
# Shell string compare (portable; no dependency on cmp/diff being present).
if [ "$(cat "$WORK/config-run1.json" 2>/dev/null)" = "$(cat "$BUILD/config.json" 2>/dev/null)" ] && [ -s "$BUILD/config.json" ]; then
    ok "deploy: config.json stable across runs"
else
    bad "deploy: config.json stable across runs" "differs or missing"
fi

echo ""
printf 'in-container: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then printf '\033[1;31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'
