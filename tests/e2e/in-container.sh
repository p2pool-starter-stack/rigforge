#!/usr/bin/env bash
#
# Runs INSIDE a disposable Linux container (invoked by tests/e2e/linux.sh). Provisions a writable copy
# of the repo, runs the real rigforge.sh twice against the container's real /etc, and asserts the
# Linux deploy path + idempotency. With RIGFORGE_APPLIANCE=1 in the environment (linux.sh's second
# pass, #348) it instead asserts the appliance contracts against the same real /etc: units in
# /run/systemd/system, no package installs, no fstab/limits.conf/logrotate writes, --runtime enables.
# Exits non-zero on any failed assertion.
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
summarize() { # print the tally and exit (non-zero if any assertion failed)
    echo ""
    printf 'in-container: \033[1;32m%d passed\033[0m, ' "$PASS"
    if [ "$FAIL" -gt 0 ]; then
        printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
        exit 1
    fi
    printf '0 failed\n'
    exit 0
}

# 1. Real prerequisites: jq + envsubst (gettext). Installed with the REAL apt before stubs go on
#    PATH, so the script's own dependency step is the only thing we stub out.
#    Reproducibility comes from the digest-pinned base image (see run.sh). The apt package versions
#    are intentionally NOT hard-pinned: Ubuntu's archive rotates superseded versions out of the
#    release pocket, so a pinned `jq=<ver>` would 404 and break the run once a new build lands.
_apt_failure_reason() { # <apt output> -> a cause, named ONLY where apt itself named one (#442)
    # A mirror mid-sync serves an index its own Release file does not describe. Measured once here
    # as a Hash Sum mismatch at an IDENTICAL filesize; the sibling case in the image builds reports
    # "File has unexpected size (N != M)" instead — same class, different string, so match both and
    # still retry on the COMMAND failing rather than on either symptom. One apt run prints every
    # repo's errors together, so this names the cause it can see, not the only cause there was.
    case "$1" in
    *"Hash Sum mismatch"* | *"File has unexpected size"*) echo "the archive served an index that does not match its Release file (a mirror mid-sync; it clears on a re-run)" ;;
    *) echo "see the apt output above for the cause" ;;
    esac
}
# One attempt against a public archive is a coin flip on a bad day, and the failure has nothing to
# do with the tree under test. Bounded, so a genuinely dead archive still aborts rather than hanging
# the job; the backoff grows so a mirror has time to finish its sync. (#442)
_apt_prereqs() { # -> 0 once apt succeeds, 1 once the bound is spent (having named a cause)
    _apt_tries="${E2E_APT_TRIES:-3}"
    _apt_err=""
    _apt_rc=1
    for ((_apt_n = 1; _apt_n <= _apt_tries; _apt_n++)); do
        _apt_err="$({ apt-get update -qq >/dev/null && apt-get install -y -qq jq gettext-base python3 >/dev/null; } 2>&1)"
        _apt_rc=$?
        # Replayed on EVERY attempt, not just the failing ones: apt's stderr went straight to the
        # job log before this loop existed, and a noisy-but-successful run is worth keeping there.
        [ -z "$_apt_err" ] || printf '%s\n' "$_apt_err" >&2
        [ "$_apt_rc" -eq 0 ] && return 0
        [ "$_apt_n" -ge "$_apt_tries" ] || {
            echo "apt prerequisites failed (attempt $_apt_n/$_apt_tries) — retrying in $((_apt_n * 5))s." >&2
            sleep $((_apt_n * 5))
        }
    done
    echo "FATAL: apt prerequisites (jq gettext-base python3) failed after $_apt_tries attempts — $(_apt_failure_reason "$_apt_err"). Aborting the e2e run." >&2
    return 1
}
# Sourced with E2E_LIB_ONLY=1 the file stops here, so the helpers above are testable outside Docker.
# Above the guard: line 10's `set -uo pipefail`, PASS/FAIL=0 and the helper definitions — so source
# this from a subshell if you keep a tally. The DEBIAN_FRONTEND export below deliberately sits under.
[ -z "${E2E_LIB_ONLY:-}" ] || return 0

export DEBIAN_FRONTEND=noninteractive
# No set -e in this harness (it counts assertions), so a failure must abort here explicitly —
# every later assertion depends on jq + envsubst existing. (#135)
_apt_prereqs || exit 1

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
echo "[git] $*" >>"${CALL_LOG:-/dev/null}"
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
# No-op the rest (sysctl -w / mount / systemctl etc. cannot run unprivileged in a container). Each
# stub logs "[cmd] args" to $CALL_LOG (run.sh's idiom) so call-shape assertions read real evidence
# instead of an always-empty file. cc exists only for the appliance pass's baked-toolchain probe.
for c in cmake make systemctl modprobe mount cpupower update-grub sysctl dpkg nft cc; do
    printf '#!/usr/bin/env bash\necho "[%s] $*" >>"${CALL_LOG:-/dev/null}"\nexit 0\n' "$c" >"$STUBS/$c"
done
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
# Pin the XMRig version/commit to known test values so the build's commit verification (#18) passes
# without a real clone; the git stub echoes XMRIG_COMMIT for `rev-parse`.
export XMRIG_VERSION="vTEST" XMRIG_COMMIT="testcommit0000000000000000000000000000"

# 5. Seed config.json (writable HOME_DIR; DONATION 7). Use an explicit (dotted) host so this doesn't
#    depend on the .local/mDNS appending that PR #15 removes.
cat >"$WORK/config.json" <<EOF
{ "HOME_DIR": "$WORK/data-home", "DONATION": 7, "add_to_path": true, "api": "enabled", "api_allow_from": "10.20.30.40", "miner_user": "rf-miner", "pools": [{"url": "poolbox.lan:3333"}] }
EOF

BUILD="$WORK/data-home/worker/xmrig/build"
ARCH="$(uname -m)"

# Appliance pass (#348): RIGFORGE_APPLIANCE=1 in the environment (linux.sh's second pass) asserts
# the appliance contracts against the same real container /etc, then exits — tests/run.sh already
# covers the mode's per-function branches with PATH stubs; this proves the /etc side for real.
# What is REAL here: the filesystem (/etc and /run), the unit renders (envsubst | tee), sed, jq,
# useradd, and the mountpoint probe. What stays STUBBED — so those contracts are proven at the
# argument level only: systemctl (no pid-1 systemd in a container; --runtime is asserted on the
# logged args), mount (needs privileges), the compile toolchain, and apt-get (stubbed to LOG so a
# wrongful install attempt becomes assertion evidence instead of a real package install).
if [ "${RIGFORGE_APPLIANCE:-0}" = 1 ]; then
    cat >"$STUBS/apt-get" <<'X'
#!/usr/bin/env bash
echo "[apt-get] $*" >>"${CALL_LOG:-/dev/null}"
exit 0
X
    chmod +x "$STUBS/apt-get"
    # systemd owns /run/systemd/system on the real appliance; the container has no pid-1 systemd.
    mkdir -p /run/systemd/system
    # Byte-identical before/after is the contract: appliance mode writes NOTHING to these files.
    # (Grepping for e.g. "memlock" would false-fail — the stock limits.conf documents it in comments.)
    grub_before="$(cat /etc/default/grub)"
    fstab_before="$(cat /etc/fstab)"
    limits_before="$(cat /etc/security/limits.conf)"

    echo "== appliance run (the real /etc must stay untouched) =="
    aout="$(CALL_LOG="$WORK/appliance-calls.log" ./rigforge.sh </dev/null 2>&1)"
    arc=$?
    assert_rc "appliance run exits 0" "$arc" "0"
    [ "$arc" = 0 ] || printf '%s\n' "$aout" | tail -20
    acalls="$(cat "$WORK/appliance-calls.log" 2>/dev/null)"
    # Units land in /run/systemd/system, never on the volatile /etc overlay.
    assert_eq "appliance: xmrig unit rendered into /run/systemd/system" "$([ -f /run/systemd/system/xmrig.service ] && echo y || echo n)" "y"
    assert_eq "appliance: no xmrig unit in /etc/systemd/system" "$([ -e /etc/systemd/system/xmrig.service ] && echo present || echo absent)" "absent"
    assert_eq "appliance: sister API server unit in /run (#99)" "$([ -f /run/systemd/system/rigforge-api.service ] && echo y || echo n)" "y"
    assert_eq "appliance: API refresh timer in /run (#99)" "$([ -f /run/systemd/system/rigforge-api-refresh.timer ] && echo y || echo n)" "y"
    assert_eq "appliance: no rigforge/xmrig unit anywhere under /etc/systemd/system" "$(find /etc/systemd/system \( -name '*.service' -o -name '*.timer' -o -name '*.path' \) 2>/dev/null | grep -c 'xmrig\|rigforge')" "0"
    assert_contains "appliance: unit rendered by real envsubst" "$(cat /run/systemd/system/xmrig.service 2>/dev/null)" "ReadWritePaths=$WORK/data-home/worker"
    assert_absent "appliance: server unit fully rendered (no unexpanded vars)" "$(cat /run/systemd/system/rigforge-api.service 2>/dev/null)" '$SCRIPT_DIR'
    # Never installs packages: the toolchain reads baked (stub cc + git/cmake/make on PATH).
    assert_contains "appliance: deps declared baked, no install" "$aout" "dependencies are baked into the image"
    assert_absent "appliance: apt-get never invoked" "$acalls" "[apt-get]"
    # /etc stays byte-identical: no fstab/limits/GRUB/modules-load/logrotate writes.
    assert_eq "appliance: fstab byte-identical" "$(cat /etc/fstab)" "$fstab_before"
    assert_eq "appliance: limits.conf byte-identical" "$(cat /etc/security/limits.conf)" "$limits_before"
    assert_eq "appliance: GRUB byte-identical" "$(cat /etc/default/grub)" "$grub_before"
    assert_eq "appliance: no GRUB backup written" "$([ -e /etc/default/grub.bak ] && echo present || echo absent)" "absent"
    assert_contains "appliance: GRUB skip is deliberate (image-owned cmdline)" "$aout" "the kernel cmdline is image-owned"
    assert_eq "appliance: no modules-load drop-in" "$([ -e /etc/modules-load.d/msr.conf ] && echo present || echo absent)" "absent"
    assert_eq "appliance: no logrotate drop-in" "$([ -e /etc/logrotate.d/xmrig ] && echo present || echo absent)" "absent"
    # Enablement is transient. The xmrig assert pins one real site (non-vacuous), the count guards
    # every other enable site (timers, api, control) against a forgotten ${ENABLE_RUNTIME:+...}.
    assert_contains "appliance: xmrig enable carries --runtime" "$acalls" "[systemctl] enable --runtime xmrig.service"
    assert_eq "appliance: every systemctl enable is --runtime" "$(grep -F "[systemctl] enable" "$WORK/appliance-calls.log" | grep -cv -- --runtime)" "0"
    # hugetlbfs is mounted at runtime instead of via fstab (mount is stubbed: argument-level proof;
    # the real mountpoint probe reports not-mounted in a fresh container, so both mounts must fire).
    assert_contains "appliance: runtime 2MB hugetlbfs mount" "$acalls" "[mount] -t hugetlbfs hugetlbfs /dev/hugepages"
    assert_contains "appliance: runtime 1G hugetlbfs mount" "$acalls" "[mount] -t hugetlbfs -o pagesize=1G hugetlbfs_1g /dev/hugepages1G"
    assert_eq "appliance: 1G mountpoint dir created for real" "$([ -d /dev/hugepages1G ] && echo y || echo n)" "y"

    echo "== appliance second run (the every-boot path accretes no /etc state) =="
    aout2="$(CALL_LOG="$WORK/appliance-calls2.log" ./rigforge.sh </dev/null 2>&1)"
    arc2=$?
    assert_rc "appliance re-run exits 0" "$arc2" "0"
    [ "$arc2" = 0 ] || printf '%s\n' "$aout2" | tail -20
    assert_eq "appliance re-run: fstab still byte-identical" "$(cat /etc/fstab)" "$fstab_before"
    assert_eq "appliance re-run: limits.conf still byte-identical" "$(cat /etc/security/limits.conf)" "$limits_before"
    assert_eq "appliance re-run: GRUB still byte-identical" "$(cat /etc/default/grub)" "$grub_before"
    assert_contains "appliance re-run: xmrig re-enabled --runtime" "$(cat "$WORK/appliance-calls2.log" 2>/dev/null)" "[systemctl] enable --runtime xmrig.service"
    assert_eq "appliance re-run: every systemctl enable is --runtime" "$(grep -F "[systemctl] enable" "$WORK/appliance-calls2.log" | grep -cv -- --runtime)" "0"

    summarize
fi

# #146: the dry-run plan, against the REAL container: real dpkg probe, real /proc for the
# HugePages count, real proposed-grub.sh for the exact GRUB before -> after diff. Run BEFORE the
# real setup so the plan shows the fresh-box actions — and prove it changed nothing.
echo "== setup --dry-run (before anything) =="
dr_out="$(./rigforge.sh setup --dry-run </dev/null 2>&1)"
assert_rc "dry-run exits 0" "$?" "0"
# dpkg is stubbed in this harness (every package reads installed), so assert the probe line, not
# a specific missing list — the "install packages: <list>" branch is plain-shell over _missing_deps.
assert_contains "dry-run: dependency probe line" "$dr_out" "installing dependencies: all dependencies already installed"
assert_contains "dry-run: real GRUB before -> after diff" "$dr_out" "GRUB cmdline: 'quiet splash' ->"
assert_contains "dry-run: reboot callout" "$dr_out" "a reboot WILL be required"
assert_contains "dry-run: build line" "$dr_out" "build XMRig"
assert_contains "dry-run: footer" "$dr_out" "Dry run — nothing was changed"
assert_eq "dry-run: no unit installed" "$([ -f /etc/systemd/system/xmrig.service ] && echo y || echo n)" "n"
assert_absent "dry-run: fstab untouched" "$(cat /etc/fstab)" "hugetlbfs"

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
# Sister API (#99/#164) against the real /etc: the persistent server + refresh timer land rendered.
assert_eq "deploy: sister API server unit installed" "$([ -f /etc/systemd/system/rigforge-api.service ] && echo y || echo n)" "y"
assert_contains "deploy: server unit carries the default bind:port" "$(cat /etc/systemd/system/rigforge-api.service 2>/dev/null)" "api-server.py 0.0.0.0 8081"
assert_eq "deploy: refresh timer installed" "$([ -f /etc/systemd/system/rigforge-api-refresh.timer ] && echo y || echo n)" "y"
# API firewall (#142): the nft file is rendered against the real /etc for the configured source.
FW_NFT="$(find "$WORK" -name api-firewall.nft 2>/dev/null | head -1)"
assert_eq "deploy: api-firewall.nft rendered" "$([ -n "$FW_NFT" ] && echo y || echo n)" "y"
assert_contains "deploy: firewall scopes to the configured source" "$(cat "$FW_NFT" 2>/dev/null)" "ip saddr 10.20.30.40 accept"
assert_contains "deploy: firewall covers both API ports (api enabled)" "$(cat "$FW_NFT" 2>/dev/null)" "8080, 8081"
assert_contains "deploy: xmrig unit re-applies the firewall on boot" "$(cat /etc/systemd/system/xmrig.service 2>/dev/null)" "api-firewall.nft"
assert_absent "deploy: server unit fully rendered (no unexpanded vars)" "$(cat /etc/systemd/system/rigforge-api.service 2>/dev/null)" '$SCRIPT_DIR'
assert_eq "in-script default: opencl off" "$(jq -r '.opencl' "$BUILD/config.json" 2>/dev/null)" "false"
assert_eq "in-script default: cuda off" "$(jq -r '.cuda' "$BUILD/config.json" 2>/dev/null)" "false"
assert_eq "no bundled template shipped" "$([ -e "$WORK/worker-config" ] && echo present || echo gone)" "gone"
svc="$(cat /etc/systemd/system/xmrig.service 2>/dev/null)"
assert_contains "service rendered by real envsubst" "$svc" "$BUILD"
# #13: hardening directives + ReadWritePaths got WORKER_ROOT expanded by the REAL envsubst.
assert_contains "service: NoNewPrivileges hardening" "$svc" "NoNewPrivileges=true"
assert_contains "service: ProtectSystem=full" "$svc" "ProtectSystem=full"
assert_contains "service: ReadWritePaths -> worker root" "$svc" "ReadWritePaths=$WORK/data-home/worker"
# Privilege separation (#140): the REAL useradd created the system user, the unit drops privileges to
# it, MSRs are applied root-side via the pre-step, and xmrig's own MSR writes are disabled.
assert_eq "miner_user: system user created by real useradd" "$(id -u rf-miner >/dev/null 2>&1 && echo y || echo n)" "y"
assert_contains "miner_user: unit runs unprivileged" "$svc" "User=rf-miner"
assert_contains "miner_user: root-side msr-apply pre-step" "$svc" "ExecStartPre=+$WORK/rigforge.sh msr-apply"
assert_eq "miner_user: xmrig wrmsr disabled" "$(jq -r '.randomx.wrmsr' "$BUILD/config.json" 2>/dev/null)" "false"
assert_eq "miner_user: config.json owned by the miner user" "$(stat -c %U "$BUILD/config.json" 2>/dev/null)" "rf-miner"
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
# #cli: add_to_path is enabled in config.json above, so setup put a `rigforge` command on PATH. Assert
# the REAL symlink, and — the important part — that invoking it THROUGH the symlink still resolves the
# repo: `rigforge version` reads /work/VERSION via the resolved SCRIPT_DIR, not /usr/local/bin. (PATH has
# the stubs first, but none stub `rigforge`.)
assert_eq "cli: /usr/local/bin/rigforge is a symlink" "$([ -L /usr/local/bin/rigforge ] && echo y || echo n)" "y"
assert_eq "cli: symlink targets the repo script" "$(readlink /usr/local/bin/rigforge)" "$WORK/rigforge.sh"
assert_contains "cli: 'rigforge' runs from PATH and resolves the repo" "$(rigforge version 2>&1)" "$(cat "$WORK/VERSION")"
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
assert_eq "uninstall: miner user preserved (hint only, never deleted) (#140)" "$(id -u rf-miner >/dev/null 2>&1 && echo y || echo n)" "y"
assert_eq "uninstall: sister API server removed (#99)" "$([ -f /etc/systemd/system/rigforge-api.service ] && echo y || echo n)" "n"
assert_eq "uninstall: refresh timer removed (#99)" "$([ -f /etc/systemd/system/rigforge-api-refresh.timer ] && echo y || echo n)" "n"
assert_eq "uninstall: fstab hugepages reverted" "$(grep -c 'hugetlbfs' /etc/fstab)" "0"
assert_eq "uninstall: memlock reverted" "$(grep -c 'memlock unlimited' /etc/security/limits.conf)" "0"
assert_eq "uninstall: msr.conf removed" "$([ -f /etc/modules-load.d/msr.conf ] && echo y || echo n)" "n"
assert_absent "uninstall: GRUB hugepages stripped" "$(cat /etc/default/grub)" "default_hugepagesz"
assert_absent "uninstall: GRUB msr param stripped" "$(cat /etc/default/grub)" "msr.allow_writes"
assert_contains "uninstall: GRUB keeps base params" "$(cat /etc/default/grub)" "quiet splash"
assert_eq "uninstall: config.json left in place" "$([ -f ./config.json ] && echo y || echo n)" "y"
assert_eq "uninstall: removed the 'rigforge' command from PATH" "$([ -L /usr/local/bin/rigforge ] && echo present || echo gone)" "gone"
./rigforge.sh uninstall --yes </dev/null >/dev/null 2>&1
assert_rc "uninstall is idempotent" "$?" "0"

summarize
