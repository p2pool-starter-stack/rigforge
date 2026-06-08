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
# can exercise the generic-Linux (incl. EPYC / Ryzen X3D inputs) and macOS code paths back to back.
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

ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"
}

assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac }
assert_absent() { case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac }
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }

# A throwaway sandbox, cleaned on exit.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# jq helpers: J = raw scalar, JC = compact (for arrays).
J() { jq -r "$2" "$1"; }
JC() { jq -c "$2" "$1"; }

# ---------------------------------------------------------------------------
# Stub factory: fake every external/privileged command rigforge calls. Behaviour is driven by STUB_*
# env vars so each test can describe a different machine. `sudo` is a *passthrough* (exec "$@") so a
# `sudo tee $FSTAB` actually writes to the test's redirected sandbox path — no real root, no real /etc.
make_stubs() {
    local bin="$1"
    mkdir -p "$bin"

    cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
    cat >"$bin/lscpu" <<'EOF'
#!/usr/bin/env bash
echo "Model name:            ${STUB_CPU_MODEL:-Generic CPU}"
echo "L3 cache:              ${STUB_L3:-8 MiB}"
echo "Socket(s):             ${STUB_SOCKETS:-1}"
EOF
    cat >"$bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-n hw.ncpu")                   echo "${STUB_NCPU:-4}" ;;
  "-n machdep.cpu.brand_string")  echo "${STUB_CPU_MODEL:-Apple Test}" ;;
  *)                              exit 0 ;;   # e.g. `sudo sysctl -w vm.nr_hugepages=...`
esac
EOF
    cat >"$bin/nproc" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_NPROC:-4}"
EOF
    cat >"$bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_HOSTNAME:-rigbox}"
EOF
    cat >"$bin/uname" <<'EOF'
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
    cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
echo "[git] $*" >> "${CALL_LOG:-/dev/null}"
case "$*" in
  *rev-parse*) echo "${STUB_GIT_HEAD:-${XMRIG_COMMIT:-}}" ;;
  *clone*)     mkdir -p xmrig/src; printf 'static int DonateLevel = 1;\n' > xmrig/src/donate.h ;;
esac
exit 0
EOF
    # envsubst stub: substitute exactly the two vars the systemd template uses (gettext may be absent on macOS).
    cat >"$bin/envsubst" <<'EOF'
#!/usr/bin/env bash
sed -e "s|\$BUILD_DIR|${BUILD_DIR:-}|g" -e "s|\$CPUPOWER_PATH|${CPUPOWER_PATH:-}|g" -e "s|\$WORKER_ROOT|${WORKER_ROOT:-}|g"
EOF
    # No-op recorders / package managers. dpkg/rpm/pacman exit 0 so "is this dep installed?" is always yes.
    local cmd
    for cmd in make cmake systemctl modprobe mount umount mountpoint update-grub apt-get apt-cache dpkg dnf rpm pacman brew cpupower journalctl; do
        cat >"$bin/$cmd" <<EOF
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
    (
        source "$SCRIPT"
        CONFIG_JSON="$1"
        SCRIPT_DIR="$2"
        local var="$3"
        set +eu
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        eval "printf '%s' \"\${$var}\""
    )
}
# Convenience: the host of the first resolved pool (POOLS_JSON[0].url with the :port stripped), so the
# host-resolution regression tests can assert a bare host.
pool_host0() { # <config_file> <script_dir>
    parse_and_print "$1" "$2" POOLS_JSON | jq -r '.[0].url | sub(":[0-9]+$"; "")'
}
# Same, but we only care about parse_config's exit code.
parse_rc() { # <config_file> <script_dir>
    (
        source "$SCRIPT"
        CONFIG_JSON="$1"
        SCRIPT_DIR="$2"
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
    )
}

# Write a config.json into the sandbox and echo its path.
mkconf() { # <name> <json>
    local f="$SANDBOX/$1.json"
    printf '%s\n' "$2" >"$f"
    echo "$f"
}

# A minimal valid pool, for tests that just need *a* pool present.
POOL='"pools": [{"url": "h:3333"}]'

# ---------------------------------------------------------------------------
# PR #15 (#14) removed the .local/mDNS appending: the pool url's host is used verbatim, whether it's a
# short name, an FQDN, or an IP. The dotless case is the regression guard — it must NOT become
# "box.local". (pool_host0 strips the :port so we can assert a bare host.)
echo "== unit: parse_config — pool url used verbatim (#15) =="
c="$(mkconf dotless "{ \"pools\": [{\"url\":\"box:3333\"}] }")"
assert_eq "short host used as-is (no .local)" "$(pool_host0 "$c" "$ROOT")" "box"
c="$(mkconf fqdn "{ \"pools\": [{\"url\":\"box.lan:3333\"}] }")"
assert_eq "FQDN passed through" "$(pool_host0 "$c" "$ROOT")" "box.lan"
c="$(mkconf ip "{ \"pools\": [{\"url\":\"10.0.0.5:3333\"}] }")"
assert_eq "IPv4 host passed through" "$(pool_host0 "$c" "$ROOT")" "10.0.0.5"

# A url is host:port — valid forms accepted; bad chars, the unfilled placeholder, and a MISSING PORT
# are all rejected (we don't guess a port).
echo "== unit: pool url validation (#8) =="
for u in box:3333 box.lan:3333 10.0.0.5:3333 rig-01:5555; do
    c="$(mkconf hnok "{ \"pools\": [{\"url\":\"$u\"}] }")"
    parse_rc "$c" "$ROOT"
    assert_rc "url '$u' accepted" "$?" "0"
done
for u in 'bad host:3333' 'evil;rm:3333' 'a/b:3333' '<YOUR_POOL_HOST>:3333' 'noport'; do
    c="$(mkconf hnbad "{ \"pools\": [{\"url\":\"$u\"}] }")"
    parse_rc "$c" "$ROOT"
    assert_rc "url '$u' rejected" "$?" "1"
done

# #21/#42: the pool target is XMRig's native `pools` array. Each entry needs a host:port `url`; other
# fields fall back to Pithead defaults. Multiple entries = failover.
echo "== unit: native pools array + defaults (#21, #42) =="
PJ() { parse_and_print "$1" "$ROOT" POOLS_JSON; } # echoes the resolved POOLS_JSON
# Single pool, only url set -> other fields filled with defaults.
c="$(mkconf p_simple "{ \"pools\": [{\"url\":\"h:3333\"}] }")"
assert_eq "one pool" "$(PJ "$c" | jq -c 'length')" "1"
assert_eq "url passed through" "$(PJ "$c" | jq -r '.[0].url')" "h:3333"
assert_eq "default pass = x" "$(PJ "$c" | jq -r '.[0].pass')" "x"
assert_eq "default tls = false" "$(PJ "$c" | jq -c '.[0].tls')" "false"
assert_eq "default keepalive = true" "$(PJ "$c" | jq -c '.[0].keepalive')" "true"
# Explicit pool — full XMRig structure passed through (#21: any host/port + tls).
c="$(mkconf p_full "{ \"pools\": [{\"url\":\"pool.example:443\",\"tls\":true,\"pass\":\"w\"}] }")"
assert_eq "explicit url kept" "$(PJ "$c" | jq -r '.[0].url')" "pool.example:443"
assert_eq "explicit tls kept" "$(PJ "$c" | jq -c '.[0].tls')" "true"
assert_eq "explicit pass kept" "$(PJ "$c" | jq -r '.[0].pass')" "w"
# A non-default port is honoured verbatim.
c="$(mkconf p_port "{ \"pools\": [{\"url\":\"stack.lan:14444\"}] }")"
assert_eq "non-default port kept" "$(PJ "$c" | jq -r '.[0].url')" "stack.lan:14444"
# Missing fields in an entry fall back (here only url+tls set -> pass defaults to x).
c="$(mkconf p_partial "{ \"pools\": [{\"url\":\"x:3333\",\"tls\":true}] }")"
assert_eq "missing pass -> x" "$(PJ "$c" | jq -r '.[0].pass')" "x"
# Backup pools (#42) = multiple entries, order preserved.
c="$(mkconf p_backup "{ \"pools\": [{\"url\":\"a:3333\"},{\"url\":\"b:14444\",\"tls\":true}] }")"
assert_eq "two pools" "$(PJ "$c" | jq -c 'length')" "2"
assert_eq "order preserved" "$(PJ "$c" | jq -c '[.[].url]')" '["a:3333","b:14444"]'
assert_eq "backup tls kept" "$(PJ "$c" | jq -c '.[1].tls')" "true"
# Validation: bad url, blank url, missing port, non-boolean tls, no pools key, and an empty pools array
# all fail fast.
c="$(mkconf p_badurl "{ \"pools\": [{\"url\":\"evil;rm:3333\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "bad pool url rejected" "$?" "1"
c="$(mkconf p_blankurl "{ \"pools\": [{\"url\":\"\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "blank pool url rejected" "$?" "1"
c="$(mkconf p_noport "{ \"pools\": [{\"url\":\"stack.lan\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "url without a port rejected" "$?" "1"
c="$(mkconf p_badtls "{ \"pools\": [{\"url\":\"h:3333\",\"tls\":\"yes\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "non-boolean tls rejected" "$?" "1"
c="$(mkconf p_nopools "{ }")"
parse_rc "$c" "$ROOT"
assert_rc "no pools rejected" "$?" "1"
c="$(mkconf p_emptypools "{ \"pools\": [] }")"
parse_rc "$c" "$ROOT"
assert_rc "empty pools array rejected" "$?" "1"

echo "== unit: parse_config — workspace + token + template resolution =="
c="$(mkconf dyn "{ \"HOME_DIR\": \"DYNAMIC_HOME\", $POOL }")"
assert_eq "DYNAMIC_HOME -> script data dir" "$(parse_and_print "$c" "$ROOT" WORKER_ROOT)" "$ROOT/data/worker"
c="$(mkconf home "{ \"HOME_DIR\": \"/opt/rig\", $POOL }")"
assert_eq "custom HOME_DIR -> HOME/worker" "$(parse_and_print "$c" "$ROOT" WORKER_ROOT)" "/opt/rig/worker"
c="$(mkconf tok "{ \"ACCESS_TOKEN\": \"tok123\", $POOL }")"
assert_eq "ACCESS_TOKEN honoured" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "tok123"
# The XMRig template is internal/bundled now — always the same path, not user-configurable.
c="$(mkconf tmpl "{ $POOL }")"
assert_eq "template is the bundled path" "$(parse_and_print "$c" "$ROOT" TEMPLATE_CONFIG)" "$ROOT/worker-config/example-config.json.template"

# #22: the rig's label is the pool `user` (folded in from the old WORKER_NAME); blank -> hostname (at
# config-gen). The HTTP API token follows the rig name (the first pool's user), so the Pithead
# "Bearer <rig name>" contract holds out of the box; an explicit ACCESS_TOKEN overrides it.
echo "== unit: rig label = pool user, token follows it (#22) =="
c="$(mkconf userset "{ \"pools\": [{\"url\":\"h:3333\",\"user\":\"rig-07\"}] }")"
assert_eq "pool user honoured" "$(parse_and_print "$c" "$ROOT" POOLS_JSON | jq -r '.[0].user')" "rig-07"
assert_eq "token defaults to the pool user" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "rig-07"
c="$(mkconf userblank "{ $POOL }")"
assert_eq "token falls back to hostname when user blank" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "rigbox"
c="$(mkconf usertok "{ \"pools\": [{\"url\":\"h:3333\",\"user\":\"rig-07\"}], \"ACCESS_TOKEN\": \"custom\" }")"
assert_eq "explicit token overrides the rig name" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "custom"

echo "== unit: parse_config — error paths =="
printf '{ not json ' >"$SANDBOX/bad.json"
parse_rc "$SANDBOX/bad.json" "$ROOT"
assert_rc "invalid JSON rejected" "$?" "1"

# Interactive first-run: ensure_config_exists prompts (y, then the host:port pool URL) and writes a
# minimal { "pools": [{ "url": ... }] }. A blank or port-less URL aborts and writes nothing.
echo "== unit: ensure_config_exists interactive first-run =="
ecd="$(mktemp -d "$SANDBOX/ec.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$ecd/config.json"
    set +eu
    printf 'y\nstack.lan:3333\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "first-run writes minimal pools config" "$(jq -c '.pools' "$ecd/config.json" 2>/dev/null)" '[{"url":"stack.lan:3333"}]'
for bad in '' 'stack.lan'; do
    ecd2="$(mktemp -d "$SANDBOX/ec2.XXXXXX")"
    (
        source "$SCRIPT"
        CONFIG_JSON="$ecd2/config.json"
        set +eu
        printf 'y\n%s\n' "$bad" | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
    )
    assert_eq "invalid URL '$bad' writes no config" "$([ -f "$ecd2/config.json" ] && echo yes || echo no)" "no"
done

echo "== unit: DONATION validation (new) =="
for d in 0 1 100; do
    c="$(mkconf "don$d" "{ \"DONATION\": $d, $POOL }")"
    parse_rc "$c" "$ROOT"
    assert_rc "DONATION $d accepted" "$?" "0"
done
c="$(mkconf d0 "{ \"DONATION\": 0, $POOL }")"
assert_eq "DONATION 0 parsed as 0" "$(parse_and_print "$c" "$ROOT" DONATION)" "0"
c="$(mkconf dmiss "{ $POOL }")"
assert_eq "DONATION defaults to 1 when absent" "$(parse_and_print "$c" "$ROOT" DONATION)" "1"
for d in 101 -1 1.5 abc; do
    c="$(mkconf "donbad" "{ \"DONATION\": \"$d\", $POOL }")"
    parse_rc "$c" "$ROOT"
    assert_rc "DONATION '$d' rejected" "$?" "1"
done

echo "== unit: append_once idempotency =="
F="$SANDBOX/append.txt"
: >"$F"
(
    source "$SCRIPT"
    set +e
    PATH="$STUBS:$PATH"
    append_once "$F" "alpha"
    append_once "$F" "alpha"
    append_once "$F" "beta"
)
assert_eq "duplicate line appended once" "$(grep -c '^alpha$' "$F")" "1"
assert_eq "distinct line also present" "$(grep -c '^beta$' "$F")" "1"
assert_eq "exactly two lines total" "$(wc -l <"$F" | tr -d ' ')" "2"

# #12: remove_line is the inverse — drops exact-match lines, idempotent, leaves others.
echo "== unit: remove_line (#12) =="
R="$SANDBOX/remove.txt"
printf 'keep me\nalpha\nkeep me too\n' >"$R"
(
    source "$SCRIPT"
    set +e
    PATH="$STUBS:$PATH"
    remove_line "$R" "alpha"
    remove_line "$R" "alpha"     # idempotent — already gone
    remove_line "$R" "not-there" # no-op
)
assert_eq "target line removed" "$(grep -c '^alpha$' "$R")" "0"
assert_eq "other lines preserved" "$(grep -c 'keep me' "$R")" "2"

# ---------------------------------------------------------------------------
# Config-generation matrix. Each profile sets STUB_* (the simulated hardware) + globals, runs
# generate_xmrig_config in a fresh dir, and we assert the emitted config.json with jq. This is where
# the per-CPU "optimizations" are proven to fire.
gen_config() { # echoes path to the dir containing config.json
    local d
    d="$(mktemp -d "$SANDBOX/gen.XXXXXX")"
    (
        cd "$d" || exit 1
        source "$SCRIPT"
        OS_TYPE="$SIM_OS"
        WORKER_ROOT="$d"
        TEMPLATE_CONFIG="$TEMPLATE"
        POOL_ADDRESS="${SIM_ADDR:-myrig.local}"
        if [ -n "${SIM_POOLS:-}" ]; then
            POOLS_JSON="$SIM_POOLS"
        else
            POOLS_JSON="[{\"url\":\"$POOL_ADDRESS:3333\",\"user\":\"\",\"pass\":\"x\",\"keepalive\":true,\"tls\":false,\"enabled\":true}]"
        fi
        ACCESS_TOKEN="${SIM_TOK:-tok123}"
        DONATION="${SIM_DON:-1}"
        LOGROTATE_DIR="$d"
        set +e
        PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
    )
    echo "$d"
}

echo "== config-gen: generic Linux (default profile) =="
export STUB_CPU_MODEL="Intel(R) Xeon(R) Silver 4310" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=5 SIM_TOK=tok123 SIM_ADDR=myrig.local
d="$(gen_config)"
cfg="$d/config.json"
assert_eq "generic: rx auto (-1)" "$(J "$cfg" '.cpu.rx')" "-1"
assert_eq "generic: asm auto" "$(J "$cfg" '.cpu.asm')" "auto"
assert_eq "generic: numa on (XMRig default)" "$(J "$cfg" '.randomx.numa')" "true"
assert_eq "generic: huge-pages on" "$(J "$cfg" '.cpu."huge-pages"')" "true"
# Dedicated-miner defaults (#43): busy-wait for max hashrate, priority 2.
assert_eq "generic: yield off (dedicated)" "$(J "$cfg" '.cpu.yield')" "false"
assert_eq "generic: priority 2" "$(J "$cfg" '.cpu.priority')" "2"
# MSR mod is driven by randomx.wrmsr (XMRig auto-detects the CPU family). The old cpu.msr key and
# top-level msr object are NOT valid XMRig keys and must not appear in the generated config (#43).
assert_eq "generic: randomx.wrmsr on (real MSR control)" "$(J "$cfg" '.randomx.wrmsr')" "true"
assert_eq "generic: no dead cpu.msr key" "$(J "$cfg" '.cpu.msr')" "null"
assert_eq "generic: no dead msr object" "$(J "$cfg" '.msr')" "null"
# HTTP API locked down on Linux (#7 / #17): made READ-ONLY (restricted) so it can't control the
# miner remotely. It stays bound to 0.0.0.0 (NOT localhost) on purpose: Pithead reads per-rig stats
# from the stack host at http://<rig>:8080 (read-only, token = rig name) — localhost would break that
# integration (issue #24). The access-token assertion below is the auth half of the lockdown.
assert_eq "generic: http restricted" "$(J "$cfg" '.http.restricted')" "true"
assert_eq "generic: http reachable (LAN)" "$(J "$cfg" '.http.host')" "0.0.0.0"
assert_eq "contract: http port 8080 (#24)" "$(J "$cfg" '.http.port')" "8080"
# Shared invariants (assert once, here):
assert_eq "pools collapsed to one" "$(J "$cfg" '.pools | length')" "1"
assert_eq "pool url = addr:3333" "$(J "$cfg" '.pools[0].url')" "myrig.local:3333"
assert_eq "pool enabled" "$(J "$cfg" '.pools[0].enabled')" "true"
assert_eq "pool user = hostname" "$(J "$cfg" '.pools[0].user')" "rigbox"
assert_eq "access-token applied" "$(J "$cfg" '.http."access-token"')" "tok123"
assert_eq "donate-level = DONATION" "$(J "$cfg" '.["donate-level"]')" "5"
assert_eq "donate-over-proxy = DONATION" "$(J "$cfg" '.["donate-over-proxy"]')" "5"

echo "== config-gen: AMD EPYC (server) =="
# Run directly (not via gen_config) so we can also capture the profile log line from stdout.
export STUB_CPU_MODEL="AMD EPYC 7763 64-Core Processor" STUB_NPROC=8 STUB_HOSTNAME=rigbox
d="$(mktemp -d "$SANDBOX/epyc.XXXXXX")"
log_out="$(
    cd "$d" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$d"
    TEMPLATE_CONFIG="$TEMPLATE"
    POOL_ADDRESS=myrig.local
    POOLS_JSON='[{"url":"myrig.local:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
    ACCESS_TOKEN=tok123
    DONATION=1
    LOGROTATE_DIR="$d"
    set +e
    PATH="$STUBS:$PATH" generate_xmrig_config 2>&1
)"
cfg="$d/config.json"
assert_eq "epyc: numa on" "$(J "$cfg" '.randomx.numa')" "true"
assert_eq "epyc: rx auto (-1)" "$(J "$cfg" '.cpu.rx')" "-1"
assert_eq "epyc: asm auto" "$(J "$cfg" '.cpu.asm')" "auto"
assert_eq "epyc: randomx.wrmsr on" "$(J "$cfg" '.randomx.wrmsr')" "true"
assert_eq "epyc: http stays restricted" "$(J "$cfg" '.http.restricted')" "true"
assert_eq "epyc: http reachable (LAN)" "$(J "$cfg" '.http.host')" "0.0.0.0"
assert_contains "epyc: detected CPU logged" "$log_out" "AMD EPYC"

# #44: a dual-CCD X3D (7950X3D) must NOT get a hand-pinned all-cores list — only one CCD has the
# V-cache, so listing every core forces threads onto the slow CCD. It now uses XMRig's cache-aware
# auto-config like every other CPU.
echo "== config-gen: AMD Ryzen X3D — auto, not hand-pinned (#44) =="
export STUB_CPU_MODEL="AMD Ryzen 9 7950X3D 16-Core Processor" STUB_NPROC=4 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1
d="$(gen_config)"
cfg="$d/config.json"
assert_eq "x3d: rx auto (-1), not all-cores" "$(J "$cfg" '.cpu.rx')" "-1"
assert_eq "x3d: asm auto" "$(J "$cfg" '.cpu.asm')" "auto"
assert_eq "x3d: priority 2" "$(J "$cfg" '.cpu.priority')" "2"
assert_eq "x3d: yield off" "$(J "$cfg" '.cpu.yield')" "false"
assert_eq "x3d: no dead cpu.msr key" "$(J "$cfg" '.cpu.msr')" "null"

echo "== config-gen: macOS overrides =="
export STUB_CPU_MODEL="Apple M2" STUB_NCPU=4 STUB_HOSTNAME=rigbox
SIM_OS=Darwin SIM_DON=1
d="$(gen_config)"
cfg="$d/config.json"
assert_eq "macos: huge-pages off" "$(J "$cfg" '.cpu."huge-pages"')" "false"
assert_eq "macos: memory-pool off" "$(J "$cfg" '.cpu."memory-pool"')" "false"
assert_eq "macos: asm boolean true" "$(J "$cfg" '.cpu.asm')" "true"
assert_eq "macos: priority 5" "$(J "$cfg" '.cpu.priority')" "5"
assert_eq "macos: rx [-1] per core" "$(JC "$cfg" '.cpu.rx')" "[-1,-1,-1,-1]"
assert_eq "macos: 1gb-pages off" "$(J "$cfg" '.randomx."1gb-pages"')" "false"
assert_eq "macos: http host all v6" "$(J "$cfg" '.http.host')" "::"
assert_eq "macos: http restricted" "$(J "$cfg" '.http.restricted')" "true"
assert_eq "macos: yield off" "$(J "$cfg" '.cpu.yield')" "false"
unset STUB_CPU_MODEL STUB_NPROC STUB_NCPU STUB_HOSTNAME STUB_L3 STUB_SOCKETS

# #21 / #42: the emitted pools array carries each entry through in order, all enabled, blank user filled
# with the rig name.
echo "== config-gen: multi-pool passthrough (#21, #42) =="
export STUB_CPU_MODEL="Intel(R) Xeon" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1
SIM_POOLS='[{"url":"primary:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true},{"url":"backup:14444","user":"","pass":"x","keepalive":true,"tls":true,"enabled":true}]'
d="$(gen_config)"
cfg="$d/config.json"
unset SIM_POOLS
assert_eq "two pool entries emitted" "$(J "$cfg" '.pools | length')" "2"
assert_eq "pool[0] url passed through" "$(J "$cfg" '.pools[0].url')" "primary:3333"
assert_eq "pool[1] url passed through" "$(J "$cfg" '.pools[1].url')" "backup:14444"
assert_eq "pool[1] tls applied" "$(J "$cfg" '.pools[1].tls')" "true"
assert_eq "all pools enabled" "$(J "$cfg" '[.pools[].enabled] | all')" "true"
assert_eq "blank user filled with rig name" "$(JC "$cfg" '[.pools[].user] | unique')" '["rigbox"]'
unset STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME

# #22: a pool entry that sets its own `user` keeps it (the rig label); a blank user gets the hostname
# (covered by "pool user = hostname" above).
echo "== config-gen: explicit pool user / rig label (#22) =="
export STUB_CPU_MODEL="Intel(R) Xeon" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1 SIM_POOLS='[{"url":"myrig.local:3333","user":"fancy-rig","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
d="$(gen_config)"
cfg="$d/config.json"
unset SIM_POOLS STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME
assert_eq "explicit pool user kept" "$(J "$cfg" '.pools[0].user')" "fancy-rig"

echo "== config-gen: idempotent (same inputs -> identical output) =="
export STUB_CPU_MODEL="Intel(R) Xeon(R)" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1
d="$(mktemp -d "$SANDBOX/idem.XXXXXX")"
(
    cd "$d" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$d"
    TEMPLATE_CONFIG="$TEMPLATE"
    POOL_ADDRESS=myrig.local
    POOLS_JSON='[{"url":"myrig.local:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
    ACCESS_TOKEN=tok123
    DONATION=1
    LOGROTATE_DIR="$d"
    set +e
    PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
)
cp "$d/config.json" "$d/first.json"
(
    cd "$d" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$d"
    TEMPLATE_CONFIG="$TEMPLATE"
    POOL_ADDRESS=myrig.local
    POOLS_JSON='[{"url":"myrig.local:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
    ACCESS_TOKEN=tok123
    DONATION=1
    LOGROTATE_DIR="$d"
    set +e
    PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
)
if cmp -s "$d/first.json" "$d/config.json"; then ok "config.json byte-identical on re-run"; else bad "config.json byte-identical on re-run" "differs"; fi
unset STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME

# ---------------------------------------------------------------------------
echo "== unit: util/proposed-grub.sh hardware math =="
PG="$ROOT/util/proposed-grub.sh"
printf 'flags : fpu pdpe1gb\n' >"$SANDBOX/cpuinfo_1g"
: >"$SANDBOX/cpuinfo_no1g"
# 32 MiB L3 / 2 sockets, with 1G support: threads=16; 1G pages=3*2=6; 2M=128+16+10=154.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=2 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: 1G dataset pages" "$out" "hugepagesz=1G hugepages=6"
assert_contains "grub: 2M jit pages" "$out" "hugepagesz=2M hugepages=154"
# K->M normalization: 32768K == 32M -> threads 16.
out="$(PATH="$STUBS:$PATH" STUB_L3="32768K" STUB_SOCKETS=1 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: K normalized to M" "$out" "hugepagesz=1G hugepages=3"
# No pdpe1gb -> pure-2M fallback: 1168*1 + 16 + 50 = 1234, and no 1G stanza.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 CPUINFO="$SANDBOX/cpuinfo_no1g" bash "$PG" -q)"
assert_contains "grub: 2M fallback total" "$out" "hugepages=1234"
assert_absent "grub: no 1G stanza" "$out" "hugepagesz=1G"
# --runtime: fallback when no 1G pages allocated, smaller set once they are.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 HUGEPAGES_1G_NR="$SANDBOX/nr_none" bash "$PG" --runtime)"
assert_eq "grub --runtime: 2M fallback" "$out" "1234"
printf '4\n' >"$SANDBOX/nr_4"
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 HUGEPAGES_1G_NR="$SANDBOX/nr_4" bash "$PG" --runtime)"
assert_eq "grub --runtime: 1G allocated" "$out" "154"

# ---------------------------------------------------------------------------
# tune_kernel must MERGE its HugePage/MSR params into the existing GRUB cmdline, not overwrite it
# wholesale (#19 — overwriting drops other kernel params; a boot-safety risk).
echo "== unit: grub_merge_cmdline preserves other kernel params (#19) =="
m="$(
    source "$SCRIPT"
    grub_merge_cmdline "default_hugepagesz=2M hugepages=1234 msr.allow_writes=on" "quiet splash nomodeset"
)"
assert_contains "merge keeps quiet" "$m" "quiet"
assert_contains "merge keeps custom nomodeset" "$m" "nomodeset"
assert_contains "merge adds hugepages" "$m" "hugepages=1234"
assert_contains "merge adds msr.allow_writes" "$m" "msr.allow_writes=on"
m2="$(
    source "$SCRIPT"
    grub_merge_cmdline "default_hugepagesz=2M hugepages=1234 msr.allow_writes=on" "$m"
)"
assert_eq "merge is idempotent" "$m2" "$m"
m3="$(
    source "$SCRIPT"
    grub_merge_cmdline "hugepages=2000" "quiet hugepages=999 default_hugepagesz=2M"
)"
assert_contains "stale managed param replaced" "$m3" "hugepages=2000"
assert_absent "old managed param dropped" "$m3" "hugepages=999"
assert_contains "non-managed param kept" "$m3" "quiet"

# #12: grub_strip_managed is the inverse — drops ONLY the params RigForge added, keeps the rest.
echo "== unit: grub_strip_managed (#12) =="
s="$(
    source "$SCRIPT"
    grub_strip_managed "quiet splash nomodeset hugepagesz=1G hugepages=3 hugepagesz=2M hugepages=200 default_hugepagesz=2M msr.allow_writes=on"
)"
assert_eq "strip keeps only non-managed params" "$s" "quiet splash nomodeset"
s="$(
    source "$SCRIPT"
    grub_strip_managed "quiet splash"
)"
assert_eq "strip leaves a clean cmdline untouched" "$s" "quiet splash"

# ---------------------------------------------------------------------------
# Pinned-build verification (#18): compile_xmrig clones the pinned XMRIG_VERSION and aborts if the
# cloned HEAD doesn't match XMRIG_COMMIT. STUB_GIT_HEAD makes the git stub report a tampered commit
# so we can prove the supply-chain check rejects it (and passes when they match).
echo "== unit: compile_xmrig pinned-commit verification (#18) =="
pin_compile() { # <stub_git_head>; runs compile_xmrig in a sandbox, prints its output, returns rc
    local d
    d="$(mktemp -d "$SANDBOX/pin.XXXXXX")"
    (
        cd "$d" || exit 1
        source "$SCRIPT"
        OS_TYPE="$(uname -s)"
        DONATION=1
        WORKER_ROOT="$d" # compile_xmrig writes build.log + the commit marker under WORKER_ROOT
        export XMRIG_COMMIT="pinnedsha000000000000000000000000000000"
        [ -n "$1" ] && export STUB_GIT_HEAD="$1"
        set +e
        PATH="$STUBS:$PATH" compile_xmrig 2>&1
    )
}
out="$(pin_compile "")"
rc=$?
assert_rc "matching commit builds" "$rc" "0"
assert_contains "matching commit is verified" "$out" "Verified XMRig"
out="$(pin_compile "tamperedsha1111111111111111111111111111")"
rc=$?
assert_rc "tampered commit fails build" "$rc" "1"
assert_contains "tampered commit is reported" "$out" "commit mismatch"

# ---------------------------------------------------------------------------
# Build robustness (#9): cap -j by RAM (~1 job / 2 GB) and report the failing step on error.
echo "== unit: compute_build_jobs caps -j by RAM (#9) =="
mk_meminfo() {
    printf 'MemTotal:       %s kB\n' "$1" >"$SANDBOX/$2"
    echo "$SANDBOX/$2"
}
assert_eq "2GB host caps to 1 job" "$(
    source "$SCRIPT"
    MEMINFO="$(mk_meminfo 2097152 mi2)" compute_build_jobs 8
)" "1"
assert_eq "8GB host caps to 4 jobs" "$(
    source "$SCRIPT"
    MEMINFO="$(mk_meminfo 8388608 mi8)" compute_build_jobs 16
)" "4"
assert_eq "ample RAM uses all cores" "$(
    source "$SCRIPT"
    MEMINFO="$(mk_meminfo 33554432 mi32)" compute_build_jobs 8
)" "8"
assert_eq "unknown RAM -> all cores" "$(
    source "$SCRIPT"
    MEMINFO=/nonexistent compute_build_jobs 6
)" "6"

echo "== unit: on_err reports the failing step (#9) =="
out="$(
    source "$SCRIPT"
    set +e
    CURRENT_STEP="compiling XMRig"
    false
    on_err 2>&1
)"
assert_contains "err trap names the step" "$out" "compiling XMRig"
assert_contains "err trap suggests bash -x" "$out" "bash -x"

# prepare_workspace archives the existing build and must prune old archives so re-runs don't grow the
# disk without bound (#4). KEEP_ARCHIVES caps how many are retained.
echo "== unit: prepare_workspace prunes old build archives (#4) =="
ws="$(mktemp -d "$SANDBOX/ws.XXXXXX")"
mkdir -p "$ws/xmrig" "$ws/xmrig-20240101_000001" "$ws/xmrig-20240101_000002" \
    "$ws/xmrig-20240101_000003" "$ws/xmrig-20240101_000004"
(
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$ws"
    set +e
    PATH="$STUBS:$PATH" KEEP_ARCHIVES=2 prepare_workspace >/dev/null 2>&1
)
assert_eq "archives pruned to KEEP_ARCHIVES" "$(find "$ws" -maxdepth 1 -type d -name 'xmrig-*' | wc -l | tr -d ' ')" "2"
assert_eq "current install was archived (gone)" "$([ -d "$ws/xmrig" ] && echo present || echo gone)" "gone"
# Regression: with NO archives present the prune must not trip set -e/pipefail (the script runs under
# `set -Eeuo pipefail`, so this runs WITHOUT the `set +e` the other unit helpers use).
empty="$(mktemp -d "$SANDBOX/ws-empty.XXXXXX")"
(
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$empty"
    PATH="$STUBS:$PATH" prepare_workspace >/dev/null 2>&1
)
rc=$?
assert_rc "prune is set -e safe with no archives" "$rc" "0"

# ---------------------------------------------------------------------------
# Idempotent re-runs / upgrade (#4): a build already at the pinned commit is detected and the slow
# recompile + restart are skipped, so re-running is a fast no-op and `upgrade` only acts on a bump.
echo "== unit: xmrig_already_built detection (#4) =="
b="$(mktemp -d "$SANDBOX/built.XXXXXX")"
mkdir -p "$b/xmrig/build"
: >"$b/xmrig/build/xmrig"
chmod +x "$b/xmrig/build/xmrig"
printf 'ABC\n' >"$b/xmrig/.rigforge-commit"
(
    source "$SCRIPT"
    WORKER_ROOT="$b"
    XMRIG_COMMIT=ABC
    set +e
    xmrig_already_built
)
assert_rc "matching commit -> built" "$?" "0"
(
    source "$SCRIPT"
    WORKER_ROOT="$b"
    XMRIG_COMMIT=XYZ
    set +e
    xmrig_already_built
)
assert_rc "different commit -> rebuild" "$?" "1"
rm -f "$b/xmrig/build/xmrig"
(
    source "$SCRIPT"
    WORKER_ROOT="$b"
    XMRIG_COMMIT=ABC
    set +e
    xmrig_already_built
)
assert_rc "missing binary -> rebuild" "$?" "1"

echo "== unit: compile_xmrig honours XMRIG_REBUILD (#4) =="
s="$(mktemp -d "$SANDBOX/skip.XXXXXX")"
(
    cd "$s" || exit 1
    source "$SCRIPT"
    OS_TYPE="$(uname -s)"
    WORKER_ROOT="$s"
    DONATION=1
    XMRIG_REBUILD=false
    set +e
    PATH="$STUBS:$PATH" CALL_LOG="$s/calls.log" compile_xmrig >/dev/null 2>&1
)
assert_absent "skips clone when already built" "$(cat "$s/calls.log" 2>/dev/null)" "clone"
r="$(mktemp -d "$SANDBOX/rebuild.XXXXXX")"
(
    cd "$r" || exit 1
    source "$SCRIPT"
    OS_TYPE="$(uname -s)"
    WORKER_ROOT="$r"
    DONATION=1
    XMRIG_REBUILD=true
    export XMRIG_COMMIT=ABC
    set +e
    PATH="$STUBS:$PATH" CALL_LOG="$r/calls.log" compile_xmrig >/dev/null 2>&1
)
assert_contains "clones when rebuilding" "$(cat "$r/calls.log" 2>/dev/null)" "clone"
assert_eq "records the built commit" "$(cat "$r/xmrig/.rigforge-commit" 2>/dev/null)" "ABC"

echo "== black-box: upgrade / help / unknown command (#4) =="
U="$(mktemp -d "$SANDBOX/upg.XXXXXX")"
cp "$SCRIPT" "$U/rigforge.sh"
cp "$ROOT/VERSION" "$U/"
cp -R "$ROOT/worker-config" "$U/"
mkdir -p "$U/home/worker/xmrig/build"
: >"$U/home/worker/xmrig/build/xmrig"
chmod +x "$U/home/worker/xmrig/build/xmrig"
printf 'ABC\n' >"$U/home/worker/xmrig/.rigforge-commit"
cat >"$U/config.json" <<EOF
{ "HOME_DIR": "$U/home", "DONATION": 1, "pools": [{"url": "poolbox.lan:3333"}] }
EOF
out="$(cd "$U" && PATH="$STUBS:$PATH" XMRIG_COMMIT=ABC bash ./rigforge.sh upgrade </dev/null 2>&1)"
rc=$?
assert_rc "upgrade exits 0 when up-to-date" "$rc" "0"
assert_contains "upgrade no-op when version unchanged" "$out" "nothing to upgrade"
out="$(cd "$U" && PATH="$STUBS:$PATH" bash ./rigforge.sh help 2>&1)"
rc=$?
assert_rc "help exits 0" "$rc" "0"
assert_contains "help shows usage" "$out" "Usage:"
assert_contains "help lists upgrade" "$out" "upgrade"
out="$(cd "$U" && PATH="$STUBS:$PATH" bash ./rigforge.sh frobnicate 2>&1)"
rc=$?
assert_rc "unknown command fails" "$rc" "1"
assert_contains "unknown command message" "$out" "Unknown command"

# #11: command surface — version, the service verbs, and help listing them.
echo "== black-box: command surface (#11) =="
out="$(cd "$U" && PATH="$STUBS:$PATH" bash ./rigforge.sh version 2>&1)"
rc=$?
assert_rc "version exits 0" "$rc" "0"
assert_contains "version prints RigForge + semver" "$out" "RigForge $(tr -d '[:space:]' <"$ROOT/VERSION")"
for verb in status start stop restart enable disable; do
    out="$(cd "$U" && PATH="$STUBS:$PATH" bash ./rigforge.sh "$verb" </dev/null 2>&1)"
    rc=$?
    assert_rc "$verb exits 0 (Linux + stubbed systemd)" "$rc" "0"
done
out="$(cd "$U" && PATH="$STUBS:$PATH" bash ./rigforge.sh help 2>&1)"
assert_contains "help lists doctor" "$out" "doctor"
assert_contains "help lists status" "$out" "status"
assert_contains "help lists apply" "$out" "apply"
assert_contains "help lists enable" "$out" "enable"
assert_contains "help lists bench" "$out" "bench"
# Service verbs are Linux-only: on a non-Linux uname they fail with a clear message.
out="$(cd "$U" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin bash ./rigforge.sh status 2>&1)"
rc=$?
assert_rc "status rejected on non-Linux" "$rc" "1"
assert_contains "non-Linux service message" "$out" "only supported on Linux"

# #11: `apply` regenerates the live config + restarts without rebuilding. The $U sandbox already has a
# built worker (build dir + binary) and a config.json pointing at HOME_DIR=$U/home.
echo "== black-box: apply / bench (#11) =="
mkdir -p "$U/logrotate"
out="$(cd "$U" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$U/logrotate" bash ./rigforge.sh apply </dev/null 2>&1)"
rc=$?
assert_rc "apply exits 0" "$rc" "0"
assert_eq "apply regenerated config" "$(J "$U/home/worker/xmrig/build/config.json" '.pools[0].url')" "poolbox.lan:3333"
# `bench` runs xmrig --bench; install a fake bench binary that prints a hashrate.
cat >"$U/home/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "miner speed 10s/60s/15m 1234.5 n/a n/a H/s max 1234.5 H/s"
EOF
chmod +x "$U/home/worker/xmrig/build/xmrig"
out="$(cd "$U" && PATH="$STUBS:$PATH" bash ./rigforge.sh bench </dev/null 2>&1)"
rc=$?
assert_rc "bench exits 0" "$rc" "0"
assert_contains "bench reports hashrate" "$out" "1234.5 H/s"

# #11/#46: the shared hashrate parser picks the peak H/s figure.
echo "== unit: _parse_hashrate (#11) =="
hr="$(printf 'starting\nminer 1100.0 H/s max 1180.5 H/s\n' | (
    source "$SCRIPT"
    _parse_hashrate
))"
assert_eq "parses peak H/s" "$hr" "1180.5"

# ---------------------------------------------------------------------------
# The manual-run hint must point at the config where it's actually generated — the build dir
# ($WORKER_ROOT/xmrig/build/config.json), the same path the systemd unit uses — not $WORKER_ROOT (#20).
echo "== unit: finish_deployment manual-run hint (#20) =="
hint="$(
    source "$SCRIPT"
    WORKER_ROOT=/opt/rig/worker
    REBOOT_REQUIRED=false
    SERVICE_INSTALLED=false
    set +e
    finish_deployment 2>&1
)"
assert_contains "hint runs the built binary" "$hint" "/opt/rig/worker/xmrig/build/xmrig"
assert_contains "hint config points at build dir" "$hint" "--config=/opt/rig/worker/xmrig/build/config.json"
assert_absent "hint not the stale top-level path" "$hint" "--config=/opt/rig/worker/config.json"

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
    local W
    W="$(mktemp -d "$SANDBOX/e2e.XXXXXX")"
    cp "$SCRIPT" "$W/rigforge.sh"
    cp -R "$ROOT/worker-config" "$ROOT/systemd" "$ROOT/util" "$W/"
    mkdir -p "$W/etc/logrotate.d" "$W/etc/modules-load.d" "$W/etc/systemd" \
        "$W/etc/security" "$W/etc/default" "$W/home" "$W/proc" "$W/sys"
    : >"$W/etc/fstab"
    : >"$W/etc/security/limits.conf"
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$W/etc/default/grub"
    printf 'flags : fpu pdpe1gb\n' >"$W/proc/cpuinfo"
    # Use an explicit (dotted) host so this E2E doesn't depend on the .local/mDNS appending that
    # Host is used verbatim (#15 removed the .local appending); the url is host:port.
    cat >"$W/config.json" <<EOF
{ "HOME_DIR": "$W/home", "DONATION": 7, "pools": [{"url": "poolbox.lan:3333"}] }
EOF
    echo "$W"
}

E2E_OUT=""
e2e_run() { # <work-dir> <os>; sets E2E_OUT, returns the script's exit code
    local W="$1" os="$2" cpu uname_m
    if [ "$os" = Darwin ]; then
        cpu="Apple M2"
        uname_m=arm64
    else
        cpu="AMD EPYC 7763 64-Core Processor"
        uname_m=x86_64
    fi
    E2E_OUT="$(cd "$W" &&
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
            bash "$W/rigforge.sh" </dev/null 2>&1)"
}

echo "== black-box: full deployment run (stubbed, native $HOST_OS path) =="
W="$(e2e_setup)"
e2e_run "$W" "$HOST_OS"
rc=$?
BUILD="$W/home/worker/xmrig/build"
assert_rc "first run exits 0" "$rc" "0"
assert_contains "build: cloned xmrig" "$(cat "$W/calls.log")" "[git] clone"
assert_contains "build: ran cmake" "$(cat "$W/calls.log")" "[cmake]"
assert_contains "build: ran make" "$(cat "$W/calls.log")" "[make]"
assert_contains "build: donate.h patched to 7" "$(cat "$W/home/worker/xmrig/src/donate.h")" "DonateLevel = 7;"
assert_eq "build: output captured to logfile" "$([ -f "$W/home/worker/build.log" ] && echo yes || echo no)" "yes"
assert_contains "build: verified pinned commit" "$E2E_OUT" "Verified XMRig"
assert_eq "deploy: pool url from hostname" "$(J "$BUILD/config.json" '.pools[0].url')" "poolbox.lan:3333"
assert_eq "deploy: donate-level = 7" "$(J "$BUILD/config.json" '.["donate-level"]')" "7"
if [ "$HOST_OS" = Linux ]; then
    assert_eq "deploy: EPYC numa applied" "$(J "$BUILD/config.json" '.randomx.numa')" "true"
    svc="$(cat "$W/etc/systemd/xmrig.service")"
    assert_contains "service: rendered with build dir" "$svc" "$BUILD"
    # #13: hardening directives present, and ReadWritePaths got WORKER_ROOT substituted (not literal).
    assert_contains "service: NoNewPrivileges" "$svc" "NoNewPrivileges=true"
    assert_contains "service: ProtectSystem=full" "$svc" "ProtectSystem=full"
    assert_contains "service: LimitMEMLOCK=infinity" "$svc" "LimitMEMLOCK=infinity"
    assert_contains "service: ReadWritePaths -> worker root" "$svc" "ReadWritePaths=$W/home/worker"
    assert_absent "service: no unexpanded WORKER_ROOT" "$svc" 'ReadWritePaths=$WORKER_ROOT'
    assert_contains "kernel: msr module enabled" "$(cat "$W/etc/modules-load.d/msr.conf")" "msr"
    assert_contains "limits: fstab 2M mount written" "$(cat "$W/etc/fstab")" "hugetlbfs /dev/hugepages"
    # #13: memlock scoped to the mining user, NOT granted to every account ("*").
    assert_contains "limits: memlock unlimited written" "$(cat "$W/etc/security/limits.conf")" "soft memlock unlimited"
    assert_absent "limits: not wildcard memlock" "$(cat "$W/etc/security/limits.conf")" "* soft memlock unlimited"
    assert_contains "grub: hugepages params written" "$(cat "$W/etc/default/grub")" "default_hugepagesz=2M"
    assert_contains "grub: preserves existing params (#19)" "$(cat "$W/etc/default/grub")" "quiet splash"
else
    assert_eq "deploy: macOS huge-pages off" "$(J "$BUILD/config.json" '.cpu."huge-pages"')" "false"
    assert_eq "deploy: macOS http host all v6" "$(J "$BUILD/config.json" '.http.host')" "::"
    assert_contains "service: unsupported on macOS" "$E2E_OUT" "not supported"
fi
cp "$BUILD/config.json" "$W/config-after-run1.json"

echo "== black-box: re-run is idempotent (#5) =="
e2e_run "$W" "$HOST_OS"
rc=$?
assert_rc "second run exits 0" "$rc" "0"
assert_eq "workspace: prior install archived" "$(find "$W/home/worker" -maxdepth 1 -name 'xmrig-*' | wc -l | tr -d ' ')" "1"
if cmp -s "$W/config-after-run1.json" "$BUILD/config.json"; then ok "deploy: config.json stable across runs"; else bad "deploy: config.json stable across runs" "differs"; fi
if [ "$HOST_OS" = Linux ]; then
    assert_eq "fstab: hugepages line not doubled" "$(grep -c 'hugetlbfs /dev/hugepages ' "$W/etc/fstab")" "1"
    assert_eq "fstab: 1G line not doubled" "$(grep -c 'hugetlbfs_1g ' "$W/etc/fstab")" "1"
    assert_eq "limits: soft line not doubled" "$(grep -c 'soft memlock unlimited' "$W/etc/security/limits.conf")" "1"
    assert_eq "grub: single cmdline entry" "$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' "$W/etc/default/grub")" "1"
    assert_contains "grub: detected already-configured" "$E2E_OUT" "already configured"
else
    echo "  • macOS host: Linux /etc idempotency (fstab/limits/grub) is covered by the Docker E2E"
    echo "    (make test-e2e) and by the Linux CI job — the Linux deploy path needs GNU sed."
fi

# ---------------------------------------------------------------------------
# Release metadata (#3): VERSION must be valid SemVer so it stays in lock-step with tags/CHANGELOG.
# #45: doctor inspects read-only system state (overridable paths) and reports PASS/WARN.
echo "== unit: doctor health checks (#45) =="
DOC="$(mktemp -d "$SANDBOX/doc.XXXXXX")"
printf 'HugePages_Total:    2048\n' >"$DOC/meminfo_ok"
printf 'HugePages_Total:    0\n' >"$DOC/meminfo_zero"
mkdir -p "$DOC/msrmod"
printf 'performance\n' >"$DOC/gov_perf"
printf 'powersave\n' >"$DOC/gov_ps"
printf '3\n' >"$DOC/nr1g"
printf '0\n' >"$DOC/nr1g_zero"
mkdir -p "$DOC/home/worker"
printf 'net      use pool ...\n* HUGE PAGES 100%%\n' >"$DOC/home/worker/xmrig.log"
cat >"$DOC/config.json" <<EOF
{ "HOME_DIR": "$DOC/home", "pools": [{"url": "h:3333"}] }
EOF
run_doctor() { # <meminfo> <msr_dir> <governor_file> <nr1g_file>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$DOC/config.json"
        MEMINFO="$1"
        MSR_MODULE_DIR="$2"
        GOVERNOR_FILE="$3"
        HUGEPAGES_1G_NR="$4"
        set +e
        PATH="$STUBS:$PATH" doctor 2>&1
    )
}
out="$(run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: prints version" "$out" "RigForge "
assert_contains "doctor: HugePages OK" "$out" "HugePages reserved"
assert_contains "doctor: 1GB pages OK" "$out" "1GB HugePages reserved"
assert_contains "doctor: msr module OK" "$out" "msr kernel module loaded"
assert_contains "doctor: governor OK" "$out" "governor = performance"
assert_contains "doctor: log HUGE PAGES 100%" "$out" "HUGE PAGES 100%"
assert_contains "doctor: all passed" "$out" "all critical checks passed"
out="$(run_doctor "$DOC/meminfo_zero" "$DOC/nope-missing" "$DOC/gov_ps" "$DOC/nr1g_zero")"
assert_contains "doctor: HugePages WARN" "$out" "HugePages not reserved"
assert_contains "doctor: msr module WARN" "$out" "msr module not loaded"
assert_contains "doctor: governor WARN" "$out" "governor is 'powersave'"
assert_contains "doctor: reports issues" "$out" "issue(s) found"
out="$( (
    source "$SCRIPT"
    OS_TYPE=Darwin
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" doctor 2>&1
))"
assert_contains "doctor: macOS skips checks" "$out" "Linux-only"

# #12: uninstall reverts every system change setup made, idempotently, leaving config.json. The GRUB
# revert uses GNU `sed -i` so it's exercised in the Docker e2e (real Linux); here we point GRUB_DEFAULT
# at a nonexistent path so that block is skipped and the test runs on macOS too.
echo "== black-box: uninstall reverts system changes (#12) =="
UN="$(mktemp -d "$SANDBOX/uninst.XXXXXX")"
cp "$SCRIPT" "$UN/rigforge.sh"
cp "$ROOT/VERSION" "$UN/"
cp -R "$ROOT/worker-config" "$UN/"
ME="${SUDO_USER:-${USER:-$(id -un)}}"
mkdir -p "$UN/etc/systemd/system" "$UN/etc/logrotate.d" "$UN/etc/security" "$UN/etc/modules-load.d" "$UN/dev/hp1g" "$UN/home/worker/xmrig/build"
: >"$UN/etc/systemd/system/xmrig.service"
: >"$UN/etc/logrotate.d/xmrig"
: >"$UN/etc/modules-load.d/msr.conf"
: >"$UN/home/worker/xmrig/build/xmrig"
printf 'proc /proc proc defaults 0 0\nhugetlbfs /dev/hugepages hugetlbfs defaults 0 0\nhugetlbfs_1g %s/dev/hp1g hugetlbfs pagesize=1G 0 0\n' "$UN" >"$UN/etc/fstab"
printf 'root hard nofile 1024\n%s soft memlock unlimited\n%s hard memlock unlimited\n* soft memlock unlimited\n' "$ME" "$ME" >"$UN/etc/security/limits.conf"
printf 'loop\nmsr\n' >"$UN/etc/modules"
cat >"$UN/config.json" <<EOF
{ "HOME_DIR": "$UN/home", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
un_run() {
    (cd "$UN" && PATH="$STUBS:$PATH" \
        SYSTEMD_DIR="$UN/etc/systemd/system" LOGROTATE_DIR="$UN/etc/logrotate.d" \
        FSTAB="$UN/etc/fstab" LIMITS_CONF="$UN/etc/security/limits.conf" \
        MODULES_LOAD_DIR="$UN/etc/modules-load.d" MODULES_FILE="$UN/etc/modules" \
        HUGEPAGES_1G_DIR="$UN/dev/hp1g" GRUB_DEFAULT="$UN/nonexistent-grub" \
        bash ./rigforge.sh uninstall --yes </dev/null 2>&1)
}
out="$(un_run)"
rc=$?
assert_rc "uninstall exits 0" "$rc" "0"
assert_eq "service unit removed" "$([ -f "$UN/etc/systemd/system/xmrig.service" ] && echo y || echo n)" "n"
assert_eq "logrotate policy removed" "$([ -f "$UN/etc/logrotate.d/xmrig" ] && echo y || echo n)" "n"
assert_eq "msr.conf removed" "$([ -f "$UN/etc/modules-load.d/msr.conf" ] && echo y || echo n)" "n"
assert_eq "worker build/logs removed" "$([ -d "$UN/home/worker" ] && echo y || echo n)" "n"
assert_eq "fstab hugepage lines gone" "$(grep -c 'hugetlbfs' "$UN/etc/fstab")" "0"
assert_contains "fstab unrelated line kept" "$(cat "$UN/etc/fstab")" "proc /proc proc"
assert_eq "limits memlock lines gone" "$(grep -c 'memlock unlimited' "$UN/etc/security/limits.conf")" "0"
assert_contains "limits unrelated line kept" "$(cat "$UN/etc/security/limits.conf")" "root hard nofile 1024"
assert_eq "modules msr line gone" "$(grep -cx 'msr' "$UN/etc/modules")" "0"
assert_contains "modules unrelated line kept" "$(cat "$UN/etc/modules")" "loop"
# Idempotent: a second uninstall is a clean no-op.
out="$(un_run)"
assert_rc "second uninstall exits 0" "$?" "0"

echo "== unit: VERSION is SemVer (#3) =="
ver="$(tr -d '[:space:]' <"$ROOT/VERSION" 2>/dev/null)"
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.].*)?$ ]]; then ok "VERSION is SemVer ($ver)"; else bad "VERSION is SemVer" "got [$ver]"; fi

# #23: the advanced example must be valid JSON and must document every config.json key parse_config
# reads — so the reference can't silently drift from the code.
echo "== unit: config.advanced.example.json (#23) =="
ADV="$ROOT/config.advanced.example.json"
if jq -e . "$ADV" >/dev/null 2>&1; then ok "advanced example is valid JSON"; else bad "advanced example is valid JSON" "jq parse failed"; fi
# The advanced example documents exactly the user-facing keys. The rig label lives in pools[].user and
# the template is internal, so WORKER_NAME / WORKER_CONFIG_FILE / POOL_HOST must NOT appear.
for k in pools ACCESS_TOKEN DONATION HOME_DIR; do
    if jq -e --arg k "$k" 'has($k)' "$ADV" >/dev/null 2>&1; then ok "advanced example documents $k"; else bad "advanced example documents $k" "key missing"; fi
done
for k in POOL_HOST WORKER_NAME WORKER_CONFIG_FILE; do
    assert_absent "advanced example has no $k key" "$(cat "$ADV")" "\"$k\""
done

# ---------------------------------------------------------------------------
echo ""
printf 'rigforge tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
