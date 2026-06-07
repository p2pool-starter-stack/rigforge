#!/usr/bin/env bash
#
# Dependency-free test suite for rigforge (no bats required).
# Mixes unit tests (sourcing rigforge.sh and calling its functions in isolation) with black-box
# tests that run the full script end-to-end with every side effect stubbed on PATH. The whole suite
# runs on macOS or Linux with nothing installed but bash + jq + coreutils. Run: tests/run.sh
#
# How platforms are simulated FROM ANY MACHINE: hardware detection (uname/lscpu/sysctl/nproc/hostname)
# and the privileged/external commands (git/make/cmake/sudo/systemctl/modprobe/mount/apt-get/...) are
# all faked in a stub directory placed first on PATH. The fakes read STUB_* env vars, so one test run
# can exercise the EPYC, Ryzen X3D, generic-Linux and macOS code paths back to back.
#
# We source the script-under-test from a dynamic path, and set many globals that the sourced rigforge
# functions consume (shellcheck can't see across the source boundary). Disable the two warnings that
# are inherent to that black-box pattern, file-wide (this directive must precede the first command).
# shellcheck disable=SC1090,SC2034
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/rigforge.sh"
TEMPLATE="$ROOT/worker-config/example-config.json.template"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac; }
assert_rc()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }

# A throwaway sandbox, cleaned on exit.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# jq helpers: J = raw scalar, JC = compact (for arrays).
J()  { jq -r "$2" "$1"; }
JC() { jq -c "$2" "$1"; }

# ---------------------------------------------------------------------------
# Stub factory: fake every external/privileged command rigforge calls. Behaviour is driven by STUB_*
# env vars so each test can describe a different machine. `sudo` is a *passthrough* (exec "$@") so a
# `sudo tee $FSTAB` actually writes to the test's redirected sandbox path — no real root, no real /etc.
make_stubs() {
    local bin="$1"
    mkdir -p "$bin"

    cat > "$bin/sudo"   <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    cat > "$bin/lscpu"  <<'EOF'
#!/usr/bin/env bash
echo "Model name:            ${STUB_CPU_MODEL:-Generic CPU}"
echo "L3 cache:              ${STUB_L3:-8 MiB}"
echo "Socket(s):             ${STUB_SOCKETS:-1}"
EOF
    cat > "$bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-n hw.ncpu")                   echo "${STUB_NCPU:-4}" ;;
  "-n machdep.cpu.brand_string")  echo "${STUB_CPU_MODEL:-Apple Test}" ;;
  *)                              exit 0 ;;   # e.g. `sudo sysctl -w vm.nr_hugepages=...`
esac
EOF
    cat > "$bin/nproc"    <<'EOF'
#!/usr/bin/env bash
echo "${STUB_NPROC:-4}"
EOF
    cat > "$bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_HOSTNAME:-rigbox}"
EOF
    cat > "$bin/uname"    <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "${STUB_UNAME_S:-Linux}" ;;
  -m) echo "${STUB_UNAME_M:-x86_64}" ;;
  -r) echo "${STUB_UNAME_R:-6.0.0-test}" ;;
  *)  echo "${STUB_UNAME_S:-Linux}" ;;
esac
EOF
    # git stub: `clone` fabricates a minimal xmrig tree (so the donate.h sed patch has a target);
    # `rev-parse` reports the pinned commit so #18's commit verification passes. A test can force a
    # mismatch by exporting STUB_GIT_HEAD.
    cat > "$bin/git" <<'EOF'
#!/usr/bin/env bash
echo "[git] $*" >> "${CALL_LOG:-/dev/null}"
case "$*" in
  *rev-parse*) echo "${STUB_GIT_HEAD:-${XMRIG_COMMIT:-}}" ;;
  *clone*)     mkdir -p xmrig/src; printf 'static int DonateLevel = 1;\n' > xmrig/src/donate.h ;;
esac
exit 0
EOF
    # envsubst stub: substitute exactly the two vars the systemd template uses (gettext may be absent on macOS).
    cat > "$bin/envsubst" <<'EOF'
#!/usr/bin/env bash
sed -e "s|\$BUILD_DIR|${BUILD_DIR:-}|g" -e "s|\$CPUPOWER_PATH|${CPUPOWER_PATH:-}|g"
EOF
    # No-op recorders / package managers. dpkg/rpm/pacman exit 0 so "is this dep installed?" is always yes.
    local cmd
    for cmd in make cmake systemctl modprobe mount update-grub apt-get apt-cache dpkg dnf rpm pacman brew cpupower; do
        cat > "$bin/$cmd" <<EOF
#!/usr/bin/env bash
echo "[$cmd] \$*" >> "\${CALL_LOG:-/dev/null}"
exit 0
EOF
    done

    chmod +x "$bin"/*
}

STUBS="$SANDBOX/stubs"
make_stubs "$STUBS"

# Source rigforge with the given config + script dir, run parse_config, print one resulting variable.
parse_and_print() { # <config_file> <script_dir> <var>
    ( source "$SCRIPT"
      CONFIG_JSON="$1"; SCRIPT_DIR="$2"; local var="$3"
      set +eu
      PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
      eval "printf '%s' \"\${$var}\"" )
}
# Same, but we only care about parse_config's exit code.
parse_rc() { # <config_file> <script_dir>
    ( source "$SCRIPT"
      CONFIG_JSON="$1"; SCRIPT_DIR="$2"
      set +e
      PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1 )
}

# Write a config.json into the sandbox and echo its path.
mkconf() { # <name> <json>
    local f="$SANDBOX/$1.json"; printf '%s\n' "$2" > "$f"; echo "$f"
}

CFG_TPL='"WORKER_CONFIG_FILE": "./worker-config/example-config.json.template"'

# ---------------------------------------------------------------------------
# PR #15 (#14) removed the .local/mDNS appending: P2POOL_NODE_ADDRESS is now the host verbatim,
# whether it's a short name, an FQDN, or an IP. The dotless case is the regression guard that proves
# the removal — it must NOT come back as "box.local".
echo "== unit: parse_config — pool address used verbatim (#15) =="
c="$(mkconf dotless "{ \"P2POOL_NODE_HOSTNAME\": \"box\", $CFG_TPL }")"
assert_eq "short host used as-is (no .local)" "$(parse_and_print "$c" "$ROOT" P2POOL_NODE_ADDRESS)" "box"
c="$(mkconf fqdn "{ \"P2POOL_NODE_HOSTNAME\": \"box.lan\", $CFG_TPL }")"
assert_eq "FQDN passed through"               "$(parse_and_print "$c" "$ROOT" P2POOL_NODE_ADDRESS)" "box.lan"
c="$(mkconf ip "{ \"P2POOL_NODE_HOSTNAME\": \"10.0.0.5\", $CFG_TPL }")"
assert_eq "IPv4 host passed through"          "$(parse_and_print "$c" "$ROOT" P2POOL_NODE_ADDRESS)" "10.0.0.5"

echo "== unit: hostname validation (#8) =="
for h in box box.lan 10.0.0.5 fe80::1 rig-01; do
    c="$(mkconf hnok "{ \"P2POOL_NODE_HOSTNAME\": \"$h\", $CFG_TPL }")"
    parse_rc "$c" "$ROOT"; assert_rc "host '$h' accepted" "$?" "0"
done
c="$(mkconf hnempty "{ \"P2POOL_NODE_HOSTNAME\": \"\", $CFG_TPL }")"
parse_rc "$c" "$ROOT"; assert_rc "empty host rejected"   "$?" "1"
c="$(mkconf hnmiss "{ $CFG_TPL }")"
parse_rc "$c" "$ROOT"; assert_rc "missing host rejected" "$?" "1"
for h in 'bad host' 'evil;rm' 'a/b' '<P2POOL_NODE_HOSTNAME>'; do
    c="$(mkconf hnbad "{ \"P2POOL_NODE_HOSTNAME\": \"$h\", $CFG_TPL }")"
    parse_rc "$c" "$ROOT"; assert_rc "host '$h' rejected" "$?" "1"
done

echo "== unit: parse_config — workspace + token + template resolution =="
c="$(mkconf dyn "{ \"HOME_DIR\": \"DYNAMIC_HOME\", \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
assert_eq "DYNAMIC_HOME -> script data dir" "$(parse_and_print "$c" "$ROOT" WORKER_ROOT)" "$ROOT/data/worker"
c="$(mkconf home "{ \"HOME_DIR\": \"/opt/rig\", \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
assert_eq "custom HOME_DIR -> HOME/worker"  "$(parse_and_print "$c" "$ROOT" WORKER_ROOT)" "/opt/rig/worker"
c="$(mkconf tok "{ \"ACCESS_TOKEN\": \"tok123\", \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
assert_eq "ACCESS_TOKEN honoured"        "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "tok123"
c="$(mkconf notok "{ \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
assert_eq "ACCESS_TOKEN falls back to hostname" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "rigbox"
c="$(mkconf rel "{ \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
assert_eq "relative template resolved vs SCRIPT_DIR" "$(parse_and_print "$c" "$ROOT" TEMPLATE_CONFIG)" "$ROOT/./worker-config/example-config.json.template"
c="$(mkconf abs "{ \"P2POOL_NODE_HOSTNAME\": \"h\", \"WORKER_CONFIG_FILE\": \"$TEMPLATE\" }")"
assert_eq "absolute template kept as-is"   "$(parse_and_print "$c" "$ROOT" TEMPLATE_CONFIG)" "$TEMPLATE"

echo "== unit: parse_config — error paths =="
printf '{ not json ' > "$SANDBOX/bad.json"
parse_rc "$SANDBOX/bad.json" "$ROOT"; assert_rc "invalid JSON rejected" "$?" "1"
c="$(mkconf noworker "{ \"P2POOL_NODE_HOSTNAME\": \"h\" }")"
parse_rc "$c" "$ROOT"; assert_rc "missing WORKER_CONFIG_FILE rejected" "$?" "1"
c="$(mkconf notmpl "{ \"P2POOL_NODE_HOSTNAME\": \"h\", \"WORKER_CONFIG_FILE\": \"./nope/missing.json\" }")"
parse_rc "$c" "$ROOT"; assert_rc "missing template file rejected" "$?" "1"

echo "== unit: DONATION validation (new) =="
for d in 0 1 100; do
    c="$(mkconf "don$d" "{ \"DONATION\": $d, \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
    parse_rc "$c" "$ROOT"; assert_rc "DONATION $d accepted" "$?" "0"
done
c="$(mkconf d0 "{ \"DONATION\": 0, \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
assert_eq "DONATION 0 parsed as 0" "$(parse_and_print "$c" "$ROOT" DONATION)" "0"
c="$(mkconf dmiss "{ \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
assert_eq "DONATION defaults to 1 when absent" "$(parse_and_print "$c" "$ROOT" DONATION)" "1"
for d in 101 -1 1.5 abc; do
    c="$(mkconf "donbad" "{ \"DONATION\": \"$d\", \"P2POOL_NODE_HOSTNAME\": \"h\", $CFG_TPL }")"
    parse_rc "$c" "$ROOT"; assert_rc "DONATION '$d' rejected" "$?" "1"
done

echo "== unit: append_once idempotency =="
F="$SANDBOX/append.txt"; : > "$F"
( source "$SCRIPT"; set +e
  PATH="$STUBS:$PATH"
  append_once "$F" "alpha"; append_once "$F" "alpha"; append_once "$F" "beta" )
assert_eq "duplicate line appended once" "$(grep -c '^alpha$' "$F")" "1"
assert_eq "distinct line also present"   "$(grep -c '^beta$'  "$F")" "1"
assert_eq "exactly two lines total"      "$(wc -l < "$F" | tr -d ' ')" "2"

# ---------------------------------------------------------------------------
# Config-generation matrix. Each profile sets STUB_* (the simulated hardware) + globals, runs
# generate_xmrig_config in a fresh dir, and we assert the emitted config.json with jq. This is where
# the per-CPU "optimizations" are proven to fire.
gen_config() { # echoes path to the dir containing config.json
    local d; d="$(mktemp -d "$SANDBOX/gen.XXXXXX")"
    ( cd "$d" || exit 1
      source "$SCRIPT"
      OS_TYPE="$SIM_OS"; WORKER_ROOT="$d"; TEMPLATE_CONFIG="$TEMPLATE"
      P2POOL_NODE_ADDRESS="${SIM_ADDR:-myrig.local}"
      ACCESS_TOKEN="${SIM_TOK:-tok123}"
      DONATION="${SIM_DON:-1}"
      LOGROTATE_DIR="$d"
      set +e
      PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1 )
    echo "$d"
}

echo "== config-gen: generic Linux (default profile) =="
export STUB_CPU_MODEL="Intel(R) Xeon(R) Silver 4310" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=5 SIM_TOK=tok123 SIM_ADDR=myrig.local
d="$(gen_config)"; cfg="$d/config.json"
assert_eq "generic: rx auto (-1)"        "$(J  "$cfg" '.cpu.rx')"            "-1"
assert_eq "generic: asm auto"            "$(J  "$cfg" '.cpu.asm')"           "auto"
assert_eq "generic: numa off"            "$(J  "$cfg" '.randomx.numa')"      "false"
assert_eq "generic: huge-pages on"       "$(J  "$cfg" '.cpu."huge-pages"')"  "true"
assert_eq "generic: msr on"              "$(J  "$cfg" '.cpu.msr')"           "true"
assert_eq "generic: priority default"    "$(J  "$cfg" '.cpu.priority')"      "null"
# HTTP API locked down on Linux (#7 / #17): made READ-ONLY (restricted) so it can't control the
# miner remotely. It stays bound to 0.0.0.0 (NOT localhost) on purpose: Pithead reads per-rig stats
# from the stack host at http://<rig>:8080 (read-only, token = rig name) — localhost would break that
# integration (issue #24). The access-token assertion below is the auth half of the lockdown.
assert_eq "generic: http restricted"     "$(J  "$cfg" '.http.restricted')"   "true"
assert_eq "generic: http reachable (LAN)" "$(J  "$cfg" '.http.host')"        "0.0.0.0"
# Shared invariants (assert once, here):
assert_eq "pools collapsed to one"       "$(J  "$cfg" '.pools | length')"    "1"
assert_eq "pool url = addr:3333"         "$(J  "$cfg" '.pools[0].url')"      "myrig.local:3333"
assert_eq "pool enabled"                 "$(J  "$cfg" '.pools[0].enabled')"  "true"
assert_eq "pool user = hostname"         "$(J  "$cfg" '.pools[0].user')"     "rigbox"
assert_eq "access-token applied"         "$(J  "$cfg" '.http."access-token"')" "tok123"
assert_eq "donate-level = DONATION"      "$(J  "$cfg" '.["donate-level"]')"  "5"
assert_eq "donate-over-proxy = DONATION" "$(J  "$cfg" '.["donate-over-proxy"]')" "5"

echo "== config-gen: AMD EPYC (server) =="
# Run directly (not via gen_config) so we can also capture the profile log line from stdout.
export STUB_CPU_MODEL="AMD EPYC 7763 64-Core Processor" STUB_NPROC=8 STUB_HOSTNAME=rigbox
d="$(mktemp -d "$SANDBOX/epyc.XXXXXX")"
log_out="$( cd "$d" || exit 1; source "$SCRIPT"; OS_TYPE=Linux; WORKER_ROOT="$d"; TEMPLATE_CONFIG="$TEMPLATE"
            P2POOL_NODE_ADDRESS=myrig.local; ACCESS_TOKEN=tok123; DONATION=1; LOGROTATE_DIR="$d"
            set +e; PATH="$STUBS:$PATH" generate_xmrig_config 2>&1 )"
cfg="$d/config.json"
assert_eq "epyc: numa on"                "$(J "$cfg" '.randomx.numa')"  "true"
assert_eq "epyc: rx auto (-1)"           "$(J "$cfg" '.cpu.rx')"        "-1"
assert_eq "epyc: asm auto"               "$(J "$cfg" '.cpu.asm')"       "auto"
assert_eq "epyc: msr on"                 "$(J "$cfg" '.cpu.msr')"       "true"
assert_eq "epyc: http stays restricted"  "$(J "$cfg" '.http.restricted')" "true"
assert_eq "epyc: http reachable (LAN)"   "$(J "$cfg" '.http.host')"     "0.0.0.0"
assert_contains "epyc: profile logged"   "$log_out"                     "AMD EPYC"

echo "== config-gen: AMD Ryzen X3D (desktop) =="
export STUB_CPU_MODEL="AMD Ryzen 9 7950X3D 16-Core Processor" STUB_NPROC=4 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1
d="$(gen_config)"; cfg="$d/config.json"
assert_eq "x3d: rx pins cores [0..3]"    "$(JC "$cfg" '.cpu.rx')"            "[0,1,2,3]"
assert_eq "x3d: asm ryzen"               "$(J  "$cfg" '.cpu.asm')"           "ryzen"
assert_eq "x3d: priority 4"              "$(J  "$cfg" '.cpu.priority')"      "4"
assert_eq "x3d: yield off"               "$(J  "$cfg" '.cpu.yield')"         "false"
assert_eq "x3d: init-avx2 on"            "$(J  "$cfg" '.randomx."init-avx2"')" "1"
assert_eq "x3d: msr on"                  "$(J  "$cfg" '.cpu.msr')"           "true"

echo "== config-gen: macOS overrides =="
export STUB_CPU_MODEL="Apple M2" STUB_NCPU=4 STUB_HOSTNAME=rigbox
SIM_OS=Darwin SIM_DON=1
d="$(gen_config)"; cfg="$d/config.json"
assert_eq "macos: huge-pages off"        "$(J  "$cfg" '.cpu."huge-pages"')"  "false"
assert_eq "macos: memory-pool off"       "$(J  "$cfg" '.cpu."memory-pool"')" "false"
assert_eq "macos: asm boolean true"      "$(J  "$cfg" '.cpu.asm')"           "true"
assert_eq "macos: priority 5"            "$(J  "$cfg" '.cpu.priority')"      "5"
assert_eq "macos: rx [-1] per core"      "$(JC "$cfg" '.cpu.rx')"            "[-1,-1,-1,-1]"
assert_eq "macos: 1gb-pages off"         "$(J  "$cfg" '.randomx."1gb-pages"')" "false"
assert_eq "macos: http host all v6"      "$(J  "$cfg" '.http.host')"         "::"
assert_eq "macos: http restricted"       "$(J  "$cfg" '.http.restricted')"   "true"
assert_eq "macos: yield off"             "$(J  "$cfg" '.cpu.yield')"         "false"
unset STUB_CPU_MODEL STUB_NPROC STUB_NCPU STUB_HOSTNAME STUB_L3 STUB_SOCKETS

echo "== config-gen: idempotent (same inputs -> identical output) =="
export STUB_CPU_MODEL="Intel(R) Xeon(R)" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1
d="$(mktemp -d "$SANDBOX/idem.XXXXXX")"
( cd "$d" || exit 1; source "$SCRIPT"; OS_TYPE=Linux; WORKER_ROOT="$d"; TEMPLATE_CONFIG="$TEMPLATE"
  P2POOL_NODE_ADDRESS=myrig.local; ACCESS_TOKEN=tok123; DONATION=1; LOGROTATE_DIR="$d"
  set +e; PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1 )
cp "$d/config.json" "$d/first.json"
( cd "$d" || exit 1; source "$SCRIPT"; OS_TYPE=Linux; WORKER_ROOT="$d"; TEMPLATE_CONFIG="$TEMPLATE"
  P2POOL_NODE_ADDRESS=myrig.local; ACCESS_TOKEN=tok123; DONATION=1; LOGROTATE_DIR="$d"
  set +e; PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1 )
if cmp -s "$d/first.json" "$d/config.json"; then ok "config.json byte-identical on re-run"; else bad "config.json byte-identical on re-run" "differs"; fi
unset STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME

# ---------------------------------------------------------------------------
echo "== unit: util/proposed-grub.sh hardware math =="
PG="$ROOT/util/proposed-grub.sh"
printf 'flags : fpu pdpe1gb\n' > "$SANDBOX/cpuinfo_1g"
: > "$SANDBOX/cpuinfo_no1g"
# 32 MiB L3 / 2 sockets, with 1G support: threads=16; 1G pages=3*2=6; 2M=128+16+10=154.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=2 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: 1G dataset pages"  "$out" "hugepagesz=1G hugepages=6"
assert_contains "grub: 2M jit pages"      "$out" "hugepagesz=2M hugepages=154"
# K->M normalization: 32768K == 32M -> threads 16.
out="$(PATH="$STUBS:$PATH" STUB_L3="32768K" STUB_SOCKETS=1 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: K normalized to M"  "$out" "hugepagesz=1G hugepages=3"
# No pdpe1gb -> pure-2M fallback: 1168*1 + 16 + 50 = 1234, and no 1G stanza.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 CPUINFO="$SANDBOX/cpuinfo_no1g" bash "$PG" -q)"
assert_contains "grub: 2M fallback total"  "$out" "hugepages=1234"
assert_absent   "grub: no 1G stanza"       "$out" "hugepagesz=1G"
# --runtime: fallback when no 1G pages allocated, smaller set once they are.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 HUGEPAGES_1G_NR="$SANDBOX/nr_none" bash "$PG" --runtime)"
assert_eq "grub --runtime: 2M fallback"    "$out" "1234"
printf '4\n' > "$SANDBOX/nr_4"
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 HUGEPAGES_1G_NR="$SANDBOX/nr_4" bash "$PG" --runtime)"
assert_eq "grub --runtime: 1G allocated"   "$out" "154"

# ---------------------------------------------------------------------------
# tune_kernel must MERGE its HugePage/MSR params into the existing GRUB cmdline, not overwrite it
# wholesale (#19 — overwriting drops other kernel params; a boot-safety risk).
echo "== unit: grub_merge_cmdline preserves other kernel params (#19) =="
m="$( source "$SCRIPT"; grub_merge_cmdline "default_hugepagesz=2M hugepages=1234 msr.allow_writes=on" "quiet splash nomodeset" )"
assert_contains "merge keeps quiet"            "$m" "quiet"
assert_contains "merge keeps custom nomodeset" "$m" "nomodeset"
assert_contains "merge adds hugepages"         "$m" "hugepages=1234"
assert_contains "merge adds msr.allow_writes"  "$m" "msr.allow_writes=on"
m2="$( source "$SCRIPT"; grub_merge_cmdline "default_hugepagesz=2M hugepages=1234 msr.allow_writes=on" "$m" )"
assert_eq       "merge is idempotent"          "$m2" "$m"
m3="$( source "$SCRIPT"; grub_merge_cmdline "hugepages=2000" "quiet hugepages=999 default_hugepagesz=2M" )"
assert_contains "stale managed param replaced" "$m3" "hugepages=2000"
assert_absent   "old managed param dropped"    "$m3" "hugepages=999"
assert_contains "non-managed param kept"       "$m3" "quiet"

# ---------------------------------------------------------------------------
# Pinned-build verification (#18): compile_xmrig clones the pinned XMRIG_VERSION and aborts if the
# cloned HEAD doesn't match XMRIG_COMMIT. STUB_GIT_HEAD makes the git stub report a tampered commit
# so we can prove the supply-chain check rejects it (and passes when they match).
echo "== unit: compile_xmrig pinned-commit verification (#18) =="
pin_compile() { # <stub_git_head>; runs compile_xmrig in a sandbox, prints its output, returns rc
    local d; d="$(mktemp -d "$SANDBOX/pin.XXXXXX")"
    ( cd "$d" || exit 1
      source "$SCRIPT"
      OS_TYPE="$(uname -s)"; DONATION=1
      export XMRIG_COMMIT="pinnedsha000000000000000000000000000000"
      [ -n "$1" ] && export STUB_GIT_HEAD="$1"
      set +e
      PATH="$STUBS:$PATH" compile_xmrig 2>&1 )
}
out="$(pin_compile "")"; rc=$?
assert_rc       "matching commit builds"        "$rc" "0"
assert_contains "matching commit is verified"   "$out" "Verified XMRig"
out="$(pin_compile "tamperedsha1111111111111111111111111111")"; rc=$?
assert_rc       "tampered commit fails build"   "$rc" "1"
assert_contains "tampered commit is reported"   "$out" "commit mismatch"

# ---------------------------------------------------------------------------
# The manual-run hint must point at the config where it's actually generated — the build dir
# ($WORKER_ROOT/xmrig/build/config.json), the same path the systemd unit uses — not $WORKER_ROOT (#20).
echo "== unit: finish_deployment manual-run hint (#20) =="
hint="$( source "$SCRIPT"; WORKER_ROOT=/opt/rig/worker; REBOOT_REQUIRED=false; SERVICE_INSTALLED=false
         set +e; finish_deployment 2>&1 )"
assert_contains "hint runs the built binary"        "$hint" "/opt/rig/worker/xmrig/build/xmrig"
assert_contains "hint config points at build dir"   "$hint" "--config=/opt/rig/worker/xmrig/build/config.json"
assert_absent   "hint not the stale top-level path" "$hint" "--config=/opt/rig/worker/config.json"

# ---------------------------------------------------------------------------
# Full end-to-end run of the REAL script with everything stubbed, executed TWICE to prove idempotency.
# Every /etc target is redirected into the work dir, and passthrough sudo lets the writes land there.
#
# The run uses the HOST's OS path: the Linux deploy path uses GNU `sed -i` (no suffix), which BSD/macOS
# sed rejects, so simulating Linux natively on a Mac is impossible. On Linux we exercise the full
# kernel/limits/service path here; on macOS we exercise the macOS deploy path natively, and the Linux
# /etc idempotency is validated from any host by the Docker E2E (tests/e2e/run.sh) and by Linux CI.
HOST_OS="$(uname -s)"

e2e_setup() { # echoes the work dir
    local W; W="$(mktemp -d "$SANDBOX/e2e.XXXXXX")"
    cp "$SCRIPT" "$W/rigforge.sh"
    cp -R "$ROOT/worker-config" "$ROOT/systemd" "$ROOT/util" "$W/"
    mkdir -p "$W/etc/logrotate.d" "$W/etc/modules-load.d" "$W/etc/systemd" \
             "$W/etc/security" "$W/etc/default" "$W/home" "$W/proc" "$W/sys"
    : > "$W/etc/fstab"
    : > "$W/etc/security/limits.conf"
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' > "$W/etc/default/grub"
    printf 'flags : fpu pdpe1gb\n' > "$W/proc/cpuinfo"
    # Use an explicit (dotted) host so this E2E doesn't depend on the .local/mDNS appending that
    # PR #15 removes — "poolbox.lan" -> "poolbox.lan:3333" holds before and after that change.
    cat > "$W/config.json" <<EOF
{ "HOME_DIR": "$W/home", "DONATION": 7, "WORKER_CONFIG_FILE": "./worker-config/example-config.json.template", "P2POOL_NODE_HOSTNAME": "poolbox.lan" }
EOF
    echo "$W"
}

E2E_OUT=""
e2e_run() { # <work-dir> <os>; sets E2E_OUT, returns the script's exit code
    local W="$1" os="$2" cpu uname_m
    if [ "$os" = Darwin ]; then cpu="Apple M2"; uname_m=arm64
    else cpu="AMD EPYC 7763 64-Core Processor"; uname_m=x86_64; fi
    E2E_OUT="$( cd "$W" && \
        PATH="$STUBS:$PATH" \
        STUB_UNAME_S="$os" STUB_UNAME_M="$uname_m" STUB_UNAME_R=6.0.0-test \
        STUB_CPU_MODEL="$cpu" STUB_NPROC=4 STUB_NCPU=4 STUB_HOSTNAME=poolbox \
        STUB_L3="32 MiB" STUB_SOCKETS=2 \
        LOGROTATE_DIR="$W/etc/logrotate.d" GRUB_DEFAULT="$W/etc/default/grub" \
        FSTAB="$W/etc/fstab" LIMITS_CONF="$W/etc/security/limits.conf" \
        MODULES_LOAD_DIR="$W/etc/modules-load.d" MODULES_FILE="$W/etc/modules" \
        SYSTEMD_DIR="$W/etc/systemd" HUGEPAGES_1G_DIR="$W/dev/hugepages1G" \
        CPUINFO="$W/proc/cpuinfo" HUGEPAGES_1G_NR="$W/sys/none" \
        CALL_LOG="$W/calls.log" \
        XMRIG_VERSION="vTEST" XMRIG_COMMIT="testcommit0000000000000000000000000000" \
        bash "$W/rigforge.sh" </dev/null 2>&1 )"
}

echo "== black-box: full deployment run (stubbed, native $HOST_OS path) =="
W="$(e2e_setup)"
e2e_run "$W" "$HOST_OS"; rc=$?
BUILD="$W/home/worker/xmrig/build"
assert_rc       "first run exits 0"                 "$rc" "0"
assert_contains "build: cloned xmrig"               "$(cat "$W/calls.log")" "[git] clone"
assert_contains "build: ran cmake"                  "$(cat "$W/calls.log")" "[cmake]"
assert_contains "build: ran make"                   "$(cat "$W/calls.log")" "[make]"
assert_contains "build: donate.h patched to 7"      "$(cat "$W/home/worker/xmrig/src/donate.h")" "DonateLevel = 7;"
assert_contains "build: verified pinned commit"     "$E2E_OUT" "Verified XMRig"
assert_eq       "deploy: pool url from hostname"    "$(J "$BUILD/config.json" '.pools[0].url')"   "poolbox.lan:3333"
assert_eq       "deploy: donate-level = 7"          "$(J "$BUILD/config.json" '.["donate-level"]')" "7"
if [ "$HOST_OS" = Linux ]; then
    assert_eq       "deploy: EPYC numa applied"         "$(J "$BUILD/config.json" '.randomx.numa')" "true"
    assert_contains "service: rendered with build dir"  "$(cat "$W/etc/systemd/xmrig.service")" "$BUILD"
    assert_contains "kernel: msr module enabled"        "$(cat "$W/etc/modules-load.d/msr.conf")" "msr"
    assert_contains "limits: fstab 2M mount written"    "$(cat "$W/etc/fstab")" "hugetlbfs /dev/hugepages"
    assert_contains "limits: memlock unlimited written" "$(cat "$W/etc/security/limits.conf")" "soft memlock unlimited"
    assert_contains "grub: hugepages params written"    "$(cat "$W/etc/default/grub")" "default_hugepagesz=2M"
    assert_contains "grub: preserves existing params (#19)" "$(cat "$W/etc/default/grub")" "quiet splash"
else
    assert_eq       "deploy: macOS huge-pages off"      "$(J "$BUILD/config.json" '.cpu."huge-pages"')" "false"
    assert_eq       "deploy: macOS http host all v6"    "$(J "$BUILD/config.json" '.http.host')" "::"
    assert_contains "service: unsupported on macOS"     "$E2E_OUT" "not supported"
fi
cp "$BUILD/config.json" "$W/config-after-run1.json"

echo "== black-box: re-run is idempotent (#5) =="
e2e_run "$W" "$HOST_OS"; rc=$?
assert_rc       "second run exits 0"                "$rc" "0"
assert_eq       "workspace: prior install archived"  "$(find "$W/home/worker" -maxdepth 1 -name 'xmrig-*' | wc -l | tr -d ' ')" "1"
if cmp -s "$W/config-after-run1.json" "$BUILD/config.json"; then ok "deploy: config.json stable across runs"; else bad "deploy: config.json stable across runs" "differs"; fi
if [ "$HOST_OS" = Linux ]; then
    assert_eq       "fstab: hugepages line not doubled" "$(grep -c 'hugetlbfs /dev/hugepages ' "$W/etc/fstab")" "1"
    assert_eq       "fstab: 1G line not doubled"        "$(grep -c 'hugetlbfs_1g ' "$W/etc/fstab")" "1"
    assert_eq       "limits: soft line not doubled"     "$(grep -c 'soft memlock unlimited' "$W/etc/security/limits.conf")" "1"
    assert_eq       "grub: single cmdline entry"        "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' "$W/etc/default/grub")" "1"
    assert_contains "grub: detected already-configured" "$E2E_OUT" "already configured"
else
    echo "  • macOS host: Linux /etc idempotency (fstab/limits/grub) is covered by the Docker E2E"
    echo "    (make test-e2e) and by the Linux CI job — the Linux deploy path needs GNU sed."
fi

# ---------------------------------------------------------------------------
echo ""
printf 'rigforge tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then printf '\033[1;31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'
