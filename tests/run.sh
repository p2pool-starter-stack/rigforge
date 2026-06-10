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
    # launchctl stub (macOS): records calls; `list <label>` emits a plist dict with a PID when
    # STUB_LAUNCHD_PID is set (so `status` can be exercised), else a dict without one.
    cat >"$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "[launchctl] $*" >> "${CALL_LOG:-/dev/null}"
if [ "$1" = list ] && [ -n "$2" ]; then
    if [ -n "${STUB_LAUNCHD_PID:-}" ]; then
        printf '{\n\t"PID" = %s;\n\t"Label" = "%s";\n}\n' "$STUB_LAUNCHD_PID" "$2"
    else
        printf '{\n\t"Label" = "%s";\n}\n' "$2"
    fi
fi
exit 0
EOF

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

# Every config field is validated — bad input fails fast with a clear message rather than producing a
# config XMRig would choke on.
echo "== unit: config field sanitization =="
# Invalid hostnames in the url (the char-/host-shape checks).
for u in '-bad:3333' '.bad:3333' 'ba d:3333' 'a;b:3333' 'a/b:3333' 'http://h:3333' '<host>:3333'; do
    c="$(mkconf badhost "{ \"pools\": [{\"url\":\"$u\"}] }")"
    parse_rc "$c" "$ROOT"
    assert_rc "invalid host '$u' rejected" "$?" "1"
done
# Valid hostname / IPv4 / bracketed-IPv6 accepted.
for u in 'good-host.lan:3333' '10.0.0.5:3333' '[2001:db8::1]:3333'; do
    c="$(mkconf okhost "{ \"pools\": [{\"url\":\"$u\"}] }")"
    parse_rc "$c" "$ROOT"
    assert_rc "valid host '$u' accepted" "$?" "0"
done
# Port range.
c="$(mkconf p_port0 "{ \"pools\": [{\"url\":\"h:0\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "port 0 rejected" "$?" "1"
c="$(mkconf p_porthi "{ \"pools\": [{\"url\":\"h:99999\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "port > 65535 rejected" "$?" "1"
# Pool user / pass.
c="$(mkconf p_baduser "{ \"pools\": [{\"url\":\"h:3333\",\"user\":\"bad user\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "user with space rejected" "$?" "1"
c="$(mkconf p_okuser "{ \"pools\": [{\"url\":\"h:3333\",\"user\":\"rig.01_a-b\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "valid user accepted" "$?" "0"
c="$(mkconf p_badpass "{ \"pools\": [{\"url\":\"h:3333\",\"pass\":\"bad pass\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "pass with space rejected" "$?" "1"
# Non-boolean keepalive / enabled (tls covered above).
c="$(mkconf p_badka "{ \"pools\": [{\"url\":\"h:3333\",\"keepalive\":\"yes\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "non-boolean keepalive rejected" "$?" "1"
c="$(mkconf p_baden "{ \"pools\": [{\"url\":\"h:3333\",\"enabled\":1}] }")"
parse_rc "$c" "$ROOT"
assert_rc "non-boolean enabled rejected" "$?" "1"
# HOME_DIR must be DYNAMIC_HOME or a clean absolute path.
c="$(mkconf hd_rel "{ \"HOME_DIR\": \"relative/path\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "relative HOME_DIR rejected" "$?" "1"
c="$(mkconf hd_trav "{ \"HOME_DIR\": \"/opt/../etc\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "HOME_DIR with .. rejected" "$?" "1"
c="$(mkconf hd_meta "{ \"HOME_DIR\": \"/opt/rig;rm\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "HOME_DIR with metachar rejected" "$?" "1"
c="$(mkconf hd_ok "{ \"HOME_DIR\": \"/opt/rig\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "clean absolute HOME_DIR accepted" "$?" "0"
# ACCESS_TOKEN character set.
c="$(mkconf at_bad "{ \"ACCESS_TOKEN\": \"bad token\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "ACCESS_TOKEN with space rejected" "$?" "1"

echo "== unit: parse_config — workspace + token =="
c="$(mkconf dyn "{ \"HOME_DIR\": \"DYNAMIC_HOME\", $POOL }")"
assert_eq "DYNAMIC_HOME -> script data dir" "$(parse_and_print "$c" "$ROOT" WORKER_ROOT)" "$ROOT/data/worker"
c="$(mkconf home "{ \"HOME_DIR\": \"/opt/rig\", $POOL }")"
assert_eq "custom HOME_DIR -> HOME/worker" "$(parse_and_print "$c" "$ROOT" WORKER_ROOT)" "/opt/rig/worker"
c="$(mkconf tok "{ \"ACCESS_TOKEN\": \"tok123\", $POOL }")"
assert_eq "ACCESS_TOKEN honoured" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "tok123"
# #55: the XMRig config is built entirely in-script — there's no bundled template file anymore.
assert_eq "no bundled XMRig template file" "$([ -e "$ROOT/worker-config" ] && echo present || echo gone)" "gone"

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
# cpu.hwloc is NOT a valid XMRig cpu JSON key (hwloc is auto-on when built WITH_HWLOC=ON); it must not
# be emitted. huge-pages-jit defaults OFF, matching XMRig upstream (which warns it makes hashrate unstable).
assert_eq "generic: no dead cpu.hwloc key" "$(J "$cfg" '.cpu.hwloc')" "null"
assert_eq "generic: huge-pages-jit off (matches XMRig default)" "$(J "$cfg" '.cpu."huge-pages-jit"')" "false"
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
assert_eq "macos: priority 2 (matches Linux; XMRig warns >2 is unresponsive)" "$(J "$cfg" '.cpu.priority')" "2"
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
# #65: RX_THREADS overrides the L3-derived estimate so `setup` sizes the reservation for the tuned thread
# count and `tune` can price a candidate's page need. 1G present: 2M = 128 + RX_THREADS + 10.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RX_THREADS=24 HUGEPAGES_1G_NR="$SANDBOX/nr_4" bash "$PG" --runtime)"
assert_eq "grub --runtime: RX_THREADS override (#65)" "$out" "162"
# fallback (no 1G): 1168 + RX_THREADS + 50.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RX_THREADS=24 HUGEPAGES_1G_NR="$SANDBOX/nr_none" bash "$PG" --runtime)"
assert_eq "grub --runtime: RX_THREADS fallback (#65)" "$out" "1242"
# A non-positive / garbage RX_THREADS is ignored -> the L3 estimate stands (threads=16 -> 154).
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RX_THREADS=0 HUGEPAGES_1G_NR="$SANDBOX/nr_4" bash "$PG" --runtime)"
assert_eq "grub --runtime: RX_THREADS=0 falls back to L3 (#65)" "$out" "154"

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
cp "$ROOT/VERSION" "$U/"
mkdir -p "$U/home/worker/xmrig/build"
: >"$U/home/worker/xmrig/build/xmrig"
chmod +x "$U/home/worker/xmrig/build/xmrig"
printf 'ABC\n' >"$U/home/worker/xmrig/.rigforge-commit"
cat >"$U/config.json" <<EOF
{ "HOME_DIR": "$U/home", "DONATION": 1, "pools": [{"url": "poolbox.lan:3333"}] }
EOF
out="$(cd "$U" && PATH="$STUBS:$PATH" XMRIG_COMMIT=ABC RIGFORGE_HOME="$PWD" bash "$SCRIPT" upgrade </dev/null 2>&1)"
rc=$?
assert_rc "upgrade exits 0 when up-to-date" "$rc" "0"
assert_contains "upgrade no-op when version unchanged" "$out" "nothing to upgrade"
# #10: a rebuild (pinned commit changed) nudges to re-tune when saved tuning exists. compile_xmrig's
# `sed` differs by OS, so we run the host's real OS path (like the compile-verification + e2e tests). We
# derive the host OS from bash's built-in $OSTYPE — immune to the stubbed `uname` on PATH.
case "${OSTYPE:-}" in darwin*) UPG_OS=Darwin ;; *) UPG_OS=Linux ;; esac
UPG="$(mktemp -d "$SANDBOX/upg2.XXXXXX")"
cp "$ROOT/VERSION" "$UPG/"
cp -R "$ROOT/systemd" "$UPG/"
mkdir -p "$UPG/home/worker/xmrig/build" "$UPG/logrotate" "$UPG/etc-systemd"
printf 'OLDCOMMIT\n' >"$UPG/home/worker/xmrig/.rigforge-commit" # built at a different commit -> rebuild
printf '{ "randomx": { "scratchpad_prefetch_mode": 2 } }\n' >"$UPG/home/worker/tune-overrides.json"
cat >"$UPG/config.json" <<EOF
{ "HOME_DIR": "$UPG/home", "DONATION": 1, "pools": [{"url": "h:3333"}] }
EOF
out="$(cd "$UPG" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$UPG/logrotate" SYSTEMD_DIR="$UPG/etc-systemd" \
    STUB_UNAME_S="$UPG_OS" XMRIG_VERSION=vNEW XMRIG_COMMIT=NEWCOMMIT \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" upgrade </dev/null 2>&1)"
rc=$?
assert_rc "upgrade rebuild exits 0" "$rc" "0"
assert_contains "upgrade rebuilds on a changed pin" "$out" "Upgraded to XMRig vNEW"
assert_contains "upgrade nudges to re-tune when overrides exist (#10)" "$out" "consider re-running 'sudo"
# The nudge is only half the promise — assert the actual carry-over: tune-overrides.json SURVIVES the
# upgrade and its tuned knob is merged into the regenerated config (the substance of the warning) (#10).
assert_eq "upgrade keeps tune-overrides.json (tuning carried over) (#10)" \
    "$([ -f "$UPG/home/worker/tune-overrides.json" ] && echo kept || echo lost)" "kept"
assert_eq "upgrade re-merges the tuned prefetch into the live config (#10)" \
    "$(J "$UPG/home/worker/xmrig/build/config.json" '.randomx.scratchpad_prefetch_mode')" "2"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" help 2>&1)"
rc=$?
assert_rc "help exits 0" "$rc" "0"
assert_contains "help shows usage" "$out" "Usage:"
assert_contains "help lists upgrade" "$out" "upgrade"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" frobnicate 2>&1)"
rc=$?
assert_rc "unknown command fails" "$rc" "1"
assert_contains "unknown command message" "$out" "Unknown command"

# #11: command surface — version, the service verbs, and help listing them.
echo "== black-box: command surface (#11) =="
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" version 2>&1)"
rc=$?
assert_rc "version exits 0" "$rc" "0"
assert_contains "version prints RigForge + semver" "$out" "RigForge $(tr -d '[:space:]' <"$ROOT/VERSION")"
for verb in status start stop restart enable disable; do
    out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" "$verb" </dev/null 2>&1)"
    rc=$?
    assert_rc "$verb exits 0 (Linux + stubbed systemd)" "$rc" "0"
done
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" help 2>&1)"
assert_contains "help lists doctor" "$out" "doctor"
assert_contains "help lists status" "$out" "status"
assert_contains "help lists apply" "$out" "apply"
assert_contains "help lists enable" "$out" "enable"
assert_contains "help lists bench" "$out" "bench"
assert_contains "help lists backup" "$out" "backup"
assert_contains "help lists restore" "$out" "restore"
# All the run verbs (start/stop/restart/status/logs) AND enable/disable work on macOS too — covered by
# the dedicated macOS tests below (which sandbox $HOME so the launchd plist never touches the real home).
# Here just sanity-check that `status` runs on a non-Linux host (HOME sandboxed to $U).
out="$(cd "$U" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin HOME="$U" RIGFORGE_HOME="$PWD" bash "$SCRIPT" status </dev/null 2>&1)"
assert_rc "status works on macOS" "$?" "0"
assert_contains "macOS status reports miner state" "$out" "Miner is"

# #11: `apply` regenerates the live config + restarts without rebuilding. The $U sandbox already has a
# built worker (build dir + binary) and a config.json pointing at HOME_DIR=$U/home.
echo "== black-box: apply / bench (#11) =="
mkdir -p "$U/logrotate"
out="$(cd "$U" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$U/logrotate" RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply </dev/null 2>&1)"
rc=$?
assert_rc "apply exits 0" "$rc" "0"
assert_eq "apply regenerated config" "$(J "$U/home/worker/xmrig/build/config.json" '.pools[0].url')" "poolbox.lan:3333"
# The logrotate policy is actually written on a Linux apply, with the directives XMRig needs (it holds
# the log open, so copytruncate; minsize avoids rotating tiny logs). Asserting the content also guards
# the create-owner line (see the dedicated owner test below).
LRF="$U/logrotate/xmrig"
assert_eq "apply writes the logrotate policy" "$([ -f "$LRF" ] && echo y || echo n)" "y"
assert_contains "logrotate uses copytruncate" "$(cat "$LRF")" "copytruncate"
assert_contains "logrotate has a minsize guard" "$(cat "$LRF")" "minsize 50M"
# #16: the rotated log must be recreated owned by the real operator (SUDO_USER), not by `whoami` — which
# is root under `sudo ./rigforge.sh` and would lock the operator out of a manual run. Drive a simulated
# sudo (SUDO_USER set, effective user differs) and assert the operator owns the create line.
out="$(cd "$U" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$U/logrotate" SUDO_USER=rfoperator \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply </dev/null 2>&1)"
assert_contains "logrotate recreates the log owned by the operator, not whoami (#16)" "$(cat "$LRF")" "create 0644 rfoperator rfoperator"
# `bench` runs xmrig --bench; install a fake bench binary that prints a hashrate.
cat >"$U/home/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "miner speed 10s/60s/15m 1234.5 n/a n/a H/s max 1234.5 H/s"
EOF
chmod +x "$U/home/worker/xmrig/build/xmrig"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" bench </dev/null 2>&1)"
rc=$?
assert_rc "bench exits 0" "$rc" "0"
assert_contains "bench reports hashrate" "$out" "1234.5 H/s"

# #75: bench must strip `http`, `pools` and `log-file` from the config it hands to `xmrig --bench`. On
# real hardware `log-file` sends the result off stdout (we capture nothing), `pools` makes XMRig mine
# after the benchmark, and `http` keeps the API alive — so it never exits and the capture hangs. The
# generated build config has all three; this fake fails if it still sees any, so a passing bench proves
# the strip.
assert_eq "build config has pools + http (precondition)" "$(J "$U/home/worker/xmrig/build/config.json" '(.pools != null) and (.http != null)')" "true"
cat >"$U/home/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
if [ -n "$cfg" ] && grep -qE '"(http|pools|log-file)"' "$cfg" 2>/dev/null; then
    echo "FAIL: bench config still has http/pools/log-file (real xmrig would hang or write elsewhere)"
    exit 7
fi
echo "miner speed 10s/60s/15m 4242.0 n/a n/a H/s max 4242.0 H/s"
EOF
chmod +x "$U/home/worker/xmrig/build/xmrig"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" bench </dev/null 2>&1)"
rc=$?
assert_rc "bench strips http/pools/log-file (#75)" "$rc" "0"
assert_contains "bench (stripped) reports hashrate" "$out" "4242.0 H/s"

# #61: the smoke check relies on `bench` failing loudly on a dirty run (so a broken build/config is
# caught before tagging) and surfacing the XMRig output for diagnosis.
# (a) XMRig hit MEMORY ALLOC FAILED (dataset/HugePages/memlock) — even with a hashrate present, fail.
cat >"$U/home/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "MEMORY ALLOC FAILED: mmap failed"
echo "miner speed 10s/60s/15m 1234.5 n/a n/a H/s max 1234.5 H/s"
EOF
chmod +x "$U/home/worker/xmrig/build/xmrig"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" bench </dev/null 2>&1)"
rc=$?
assert_rc "bench fails on MEMORY ALLOC FAILED" "$rc" "1"
assert_contains "bench surfaces the fatal XMRig output" "$out" "MEMORY ALLOC FAILED"
# (b) No hashrate at all and no fatal marker (e.g. the binary aborted early) — still fail, not abort
# silently via set -e, and surface the output. Guards the `hr=$(...) || true` no-hashrate path.
cat >"$U/home/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "xmrig: aborted before producing a hashrate"
exit 1
EOF
chmod +x "$U/home/worker/xmrig/build/xmrig"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" bench </dev/null 2>&1)"
rc=$?
assert_rc "bench fails when no hashrate is produced" "$rc" "1"
assert_contains "bench surfaces the no-hashrate XMRig output" "$out" "aborted before producing a hashrate"
# Restore the healthy fake bench binary for any later tests that assume a working worker.
cat >"$U/home/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "miner speed 10s/60s/15m 1234.5 n/a n/a H/s max 1234.5 H/s"
EOF
chmod +x "$U/home/worker/xmrig/build/xmrig"

# Security: the privileged consumers (uninstall/backup/restore) resolve the worker root via
# _worker_root_from_config, which validates HOME_DIR (the same rule as parse_config) and FAILS CLOSED on
# anything that isn't a clean absolute path — a malformed/hostile HOME_DIR must never reach `sudo rm -rf`.
echo "== unit: _worker_root_from_config validates HOME_DIR =="
WV="$(mktemp -d "$SANDBOX/wv.XXXXXX")"
printf '{ "HOME_DIR": "/opt/rig", "pools":[{"url":"h:3333"}] }\n' >"$WV/good.json"
printf '{ "HOME_DIR": "/etc; rm -rf /tmp/x", "pools":[{"url":"h:3333"}] }\n' >"$WV/meta.json"
printf '{ "HOME_DIR": "/opt/../../etc", "pools":[{"url":"h:3333"}] }\n' >"$WV/trav.json"
wrc() { (
    source "$SCRIPT"
    SCRIPT_DIR="$WV"
    CONFIG_JSON="$1"
    set +e
    _worker_root_from_config 2>&1
); }
assert_eq "valid HOME_DIR resolves to the worker root" "$(wrc "$WV/good.json")" "/opt/rig/worker"
assert_contains "HOME_DIR with shell metacharacters is refused" "$(wrc "$WV/meta.json")" "Refusing to act"
assert_contains "HOME_DIR with .. traversal is refused" "$(wrc "$WV/trav.json")" "Refusing to act"

# The periodic-autotune systemd timer: enabling it (AUTOTUNE=true) writes the .service + .timer; disabling
# it (AUTOTUNE=false, files present) removes them — both via the SYSTEMD_DIR override the real units use.
echo "== black-box: install_autotune timer enable/disable =="
AT="$(mktemp -d "$SANDBOX/at.XXXXXX")"
mkdir -p "$AT/systemd"
run_autotune() { # <true|false> [oncalendar]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$AT"
        SYSTEMD_DIR="$AT/systemd"
        AUTOTUNE="$1"
        AUTOTUNE_ONCALENDAR="${2:-daily}"
        set +e
        PATH="$STUBS:$PATH" install_autotune 2>&1
    )
}
out="$(run_autotune true hourly)"
assert_eq "autotune enable writes the .timer" "$([ -f "$AT/systemd/rigforge-autotune.timer" ] && echo y || echo n)" "y"
assert_eq "autotune enable writes the .service" "$([ -f "$AT/systemd/rigforge-autotune.service" ] && echo y || echo n)" "y"
assert_contains "autotune timer honours the OnCalendar override" "$(cat "$AT/systemd/rigforge-autotune.timer")" "OnCalendar=hourly"
assert_contains "autotune service invokes the autotune verb" "$(cat "$AT/systemd/rigforge-autotune.service")" "rigforge.sh autotune"
out="$(run_autotune false)"
assert_eq "autotune disable removes the .timer" "$([ -f "$AT/systemd/rigforge-autotune.timer" ] && echo y || echo n)" "n"
assert_eq "autotune disable removes the .service" "$([ -f "$AT/systemd/rigforge-autotune.service" ] && echo y || echo n)" "n"

# #11/#46: the shared hashrate parser picks the peak H/s figure.
echo "== unit: _parse_hashrate (#11) =="
hr="$(printf 'starting\nminer 1100.0 H/s max 1180.5 H/s\n' | (
    source "$SCRIPT"
    _parse_hashrate
))"
assert_eq "parses peak H/s" "$hr" "1180.5"

# #74: `setup` runs headless (release e2e / over ssh), so install_dependencies must auto-install missing
# packages — an interactive `read` prompt hit EOF on a non-tty stdin and aborted under set -e — and must
# pass the apt lock-timeout so a fresh-boot unattended-upgrades lock doesn't fail the install.
echo "== unit: install_dependencies non-interactive auto-install (#74) =="
DEPT="$(mktemp -d "$SANDBOX/dep.XXXXXX")"
cat >"$DEPT/dpkg" <<'EOF'
#!/usr/bin/env bash
case "$*" in *build-essential*) exit 1 ;; *) exit 0 ;; esac   # build-essential "missing", rest present
EOF
cat >"$DEPT/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >>"$APT_LOG"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$DEPT/apt-cache"
printf '#!/usr/bin/env bash\nexec env "$@"\n' >"$DEPT/sudo" # `env` handles the `sudo VAR=x cmd` prefix
chmod +x "$DEPT"/*
APT_LOG="$DEPT/apt.log"
: >"$APT_LOG"
(
    source "$SCRIPT"
    OS_TYPE=Linux REAL_USER=test
    PATH="$DEPT:$PATH" APT_LOG="$APT_LOG" install_dependencies </dev/null
) >/dev/null 2>&1
rc=$?
assert_rc "install_dependencies exits 0 on a non-tty stdin (#74)" "$rc" "0"
assert_contains "auto-installs the missing dep (#74)" "$(cat "$APT_LOG")" "build-essential"
assert_contains "apt waits for the lock, not fail (#74)" "$(cat "$APT_LOG")" "DPkg::Lock::Timeout=300"

# ---------------------------------------------------------------------------
# When no service was installed (macOS), finish_deployment points the user at 'start' — not a raw
# screen/xmrig command (the build-dir config #20 guaranteed is now handled inside mac_start, asserted
# in the macOS process-control test below).
echo "== unit: finish_deployment points at 'start' =="
hint="$(
    source "$SCRIPT"
    WORKER_ROOT=/opt/rig/worker
    REBOOT_REQUIRED=false
    SERVICE_INSTALLED=false
    set +e
    finish_deployment 2>&1
)"
assert_contains "hint tells you to run 'start'" "$hint" "start"
assert_absent "hint no longer prints a raw screen command" "$hint" "screen -S xmrig"

# macOS process control: with no systemd, start/status/stop manage XMRig as a background process via a
# PID file. The fake miner records its args (proving start uses the BUILD-dir config) and sleeps so the
# PID stays alive; stop kills it.
echo "== black-box: macOS process control (start/status/stop) =="
MC="$(mktemp -d "$SANDBOX/mac.XXXXXX")"
cp "$ROOT/VERSION" "$MC/"
MCB="$MC/home/worker/xmrig/build"
mkdir -p "$MCB"
cat >"$MCB/xmrig" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$MC/home/worker/xmrig.args"
exec sleep 30
EOF
chmod +x "$MCB/xmrig"
printf '{}\n' >"$MCB/config.json"
cat >"$MC/config.json" <<EOF
{ "HOME_DIR": "$MC/home", "pools": [{"url": "h:3333"}] }
EOF
mac_run() { (cd "$MC" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin HOME="$MC" RIGFORGE_HOME="$PWD" bash "$SCRIPT" "$@" </dev/null 2>&1); }
PIDF="$MC/home/worker/xmrig.pid"
out="$(mac_run start)"
assert_rc "macOS start exits 0" "$?" "0"
assert_contains "macOS start reports a pid" "$out" "Started the miner"
assert_eq "macOS start wrote a PID file" "$([ -f "$PIDF" ] && echo y || echo n)" "y"
sleep 0.5 # let the backgrounded fake record its args
out="$(mac_run status)"
assert_contains "macOS status shows running" "$out" "is running"
assert_contains "macOS start used the build-dir config" "$(cat "$MC/home/worker/xmrig.args" 2>/dev/null)" "--config=$MCB/config.json"
out="$(mac_run start)"
assert_contains "macOS start is idempotent" "$out" "already running"
out="$(mac_run stop)"
assert_rc "macOS stop exits 0" "$?" "0"
assert_contains "macOS stop reports stopped" "$out" "Stopped the miner"
out="$(mac_run status)"
assert_contains "macOS status shows stopped after stop" "$out" "not running"
[ -f "$PIDF" ] && kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
rm -f "$PIDF"

# macOS login auto-start: enable installs a launchd LaunchAgent ($HOME sandboxed to $MC so the plist
# never touches the real ~/Library/LaunchAgents). With it installed, launchd owns the miner and
# start/stop/status delegate to launchctl (the stub records calls + reports a PID via STUB_LAUNCHD_PID).
echo "== black-box: macOS login agent (enable/disable via launchd) =="
PLIST="$MC/Library/LaunchAgents/com.rigforge.xmrig.plist"
LCL="$MC/launchctl.log"
mac_lr() { (cd "$MC" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin HOME="$MC" CALL_LOG="$LCL" RIGFORGE_HOME="$MC" "$@" </dev/null 2>&1); }
: >"$LCL"
out="$(mac_lr bash "$SCRIPT" enable)"
assert_rc "macOS enable exits 0" "$?" "0"
assert_eq "enable wrote the LaunchAgent plist" "$([ -f "$PLIST" ] && echo y || echo n)" "y"
assert_contains "plist has the agent label" "$(cat "$PLIST")" "com.rigforge.xmrig"
assert_contains "plist runs the binary with the build config" "$(cat "$PLIST")" "--config=$MCB/config.json"
assert_contains "plist runs at load" "$(cat "$PLIST")" "<key>RunAtLoad</key><true/>"
assert_contains "enable loaded the agent" "$(cat "$LCL")" "[launchctl] load"
: >"$LCL"
out="$(mac_lr bash "$SCRIPT" start)"
assert_contains "start delegates to launchctl when enabled" "$(cat "$LCL")" "[launchctl] start"
assert_contains "start reports login-agent control" "$out" "login agent"
out="$( (cd "$MC" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin HOME="$MC" CALL_LOG="$LCL" STUB_LAUNCHD_PID=4321 RIGFORGE_HOME="$PWD" bash "$SCRIPT" status </dev/null 2>&1))"
assert_contains "status reads the launchd PID" "$out" "pid 4321"
out="$(mac_lr bash "$SCRIPT" disable)"
assert_rc "macOS disable exits 0" "$?" "0"
assert_eq "disable removed the plist" "$([ -f "$PLIST" ] && echo y || echo n)" "n"
assert_contains "disable unloaded the agent" "$(cat "$LCL")" "[launchctl] unload"

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
    cp -R "$ROOT/systemd" "$ROOT/util" "$W/"
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
            RIGFORGE_HOME="$W" bash "$SCRIPT" </dev/null 2>&1)"
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
        # #67 advisory probes default to "unavailable"/skip here unless a caller sets them (see the #67 test).
        DMIDECODE="${DMIDECODE:-/nonexistent}"
        CPUFREQ_MAX="${CPUFREQ_MAX:-/nonexistent}"
        CPU_SYSFS="${CPU_SYSFS:-/nonexistent}"
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
# A worker log that mentions huge pages but is NOT 100% backed -> the "below 100%" WARN branch.
LOWHP="$DOC/lowhp"
mkdir -p "$LOWHP/worker"
printf 'net      use pool ...\n* HUGE PAGES 50%%\n' >"$LOWHP/worker/xmrig.log"
cat >"$DOC/config_lowhp.json" <<EOF
{ "HOME_DIR": "$LOWHP", "pools": [{"url": "h:3333"}] }
EOF
out="$( (
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$ROOT"
    CONFIG_JSON="$DOC/config_lowhp.json"
    MEMINFO="$DOC/meminfo_ok"
    MSR_MODULE_DIR="$DOC/msrmod"
    GOVERNOR_FILE="$DOC/gov_perf"
    HUGEPAGES_1G_NR="$DOC/nr1g"
    set +e
    PATH="$STUBS:$PATH" doctor 2>&1
))"
assert_contains "doctor: log HUGE PAGES below 100% WARN" "$out" "below 100%"

# #67: doctor flags hashrate-capping HARDWARE (advisory) — single-channel/slow RAM (via dmidecode) and a
# power/boost-capped clock (effective vs max, while mining). Fakes drive both the WARN and OK paths, and
# the absence of dmidecode is handled gracefully.
echo "== unit: doctor hashrate-capping hardware (#67) =="
cat >"$DOC/dmidecode_single" <<'EOF'
#!/usr/bin/env bash
printf 'Memory Device\n\tSize: 8 GB\n\tBank Locator: P0 CHANNEL A\n\tSpeed: 2133 MT/s\n\tConfigured Memory Speed: 2133 MT/s\nMemory Device\n\tSize: No Module Installed\n\tBank Locator: P0 CHANNEL B\n'
EOF
cat >"$DOC/dmidecode_dual" <<'EOF'
#!/usr/bin/env bash
printf 'Memory Device\n\tSize: 16 GB\n\tBank Locator: P0 CHANNEL A\n\tSpeed: 4800 MT/s\n\tConfigured Memory Speed: 6000 MT/s\nMemory Device\n\tSize: 16 GB\n\tBank Locator: P0 CHANNEL B\n\tSpeed: 4800 MT/s\n\tConfigured Memory Speed: 6000 MT/s\n'
EOF
chmod +x "$DOC/dmidecode_single" "$DOC/dmidecode_dual"
printf '5050000\n' >"$DOC/cpufreq_max"
mkdir -p "$DOC/cpu_throttle/cpu0/cpufreq" "$DOC/cpu_throttle/cpu1/cpufreq" "$DOC/cpu_ok/cpu0/cpufreq"
printf '3000000\n' >"$DOC/cpu_throttle/cpu0/cpufreq/scaling_cur_freq" # 3000/5050 = 59% -> WARN
printf '3000000\n' >"$DOC/cpu_throttle/cpu1/cpufreq/scaling_cur_freq"
printf '4600000\n' >"$DOC/cpu_ok/cpu0/cpufreq/scaling_cur_freq" # 4600/5050 = 91% -> OK
# single-channel + slow RAM + throttled clock -> warnings
out="$(DMIDECODE="$DOC/dmidecode_single" CPUFREQ_MAX="$DOC/cpufreq_max" CPU_SYSFS="$DOC/cpu_throttle" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: warns single-channel RAM (#67)" "$out" "single-channel"
assert_contains "doctor: warns slow RAM (#67)" "$out" "RAM speed 2133 MT/s is low"
assert_contains "doctor: warns throttled clock (#67)" "$out" "59% of"
# dual-channel + fast RAM + healthy clock -> OK
out="$(DMIDECODE="$DOC/dmidecode_dual" CPUFREQ_MAX="$DOC/cpufreq_max" CPU_SYSFS="$DOC/cpu_ok" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: dual-channel RAM OK (#67)" "$out" "2 channels"
assert_contains "doctor: RAM speed reported (#67)" "$out" "6000 MT/s"
assert_contains "doctor: healthy clock OK (#67)" "$out" "91% of max boost"
# dmidecode unavailable -> graceful advisory note (not a hard failure)
out="$(DMIDECODE="/nonexistent" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: degrades gracefully w/o dmidecode (#67)" "$out" "dmidecode not found"
# dmidecode present but empty output (e.g. run as non-root) -> "not readable" note, not a crash
printf '#!/usr/bin/env bash\n' >"$DOC/dmidecode_empty"
chmod +x "$DOC/dmidecode_empty"
out="$(DMIDECODE="$DOC/dmidecode_empty" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: RAM-unreadable note when dmidecode is empty (#67)" "$out" "RAM layout not readable"

# #66: doctor verifies the MSR mod ACTUALLY applied — XMRig's log line confirms the write, and (when
# rdmsr/msr-tools is present AND doctor runs as root) a register read-back catches a write a
# hypervisor/lockdown silently dropped. The read-back is gated on root, and "couldn't read" is kept
# distinct from "wrong value" so a non-root or module-less run advises instead of crying wolf.
echo "== unit: doctor MSR mod verification (#66) =="
MSRD="$DOC/msr"
mkdir -p "$MSRD/home/worker"
msr_log() { printf 'net      use pool ...\n* HUGE PAGES 100%%\nmsr      register values for "%s" preset have been set successfully (1 ms)\n' "$1" >"$MSRD/home/worker/xmrig.log"; }
msr_log ryzen_19h_zen4
cat >"$MSRD/config.json" <<EOF
{ "HOME_DIR": "$MSRD/home", "pools": [{"url": "h:3333"}] }
EOF
# fake rdmsr returning the real register values (Zen4 verified on the 7800X3D rig; intel 0x1a4=0xf); -p -0 <reg>
cat >"$DOC/rdmsr_ok" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in 0x*) reg="$a" ;; esac; done
case "$reg" in
0xc0011020) echo 0004400000000000 ;; 0xc0011021) echo 0004000000000040 ;;
0xc0011022) echo 8680000401570000 ;; 0xc001102b) echo 000000002040cc10 ;;
0x1a4) echo 000000000000000f ;;
esac
EOF
printf '#!/usr/bin/env bash\necho 0\n' >"$DOC/rdmsr_bad" # readable but WRONG (dropped write) -> mismatch
printf '#!/usr/bin/env bash\n' >"$DOC/rdmsr_empty"       # echoes nothing -> every register unreadable
cat >"$DOC/rdmsr_partial" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in 0x*) reg="$a" ;; esac; done
[ "$reg" = 0xc0011020 ] && echo 0004400000000000   # one register correct, the rest unreadable
EOF
chmod +x "$DOC/rdmsr_ok" "$DOC/rdmsr_bad" "$DOC/rdmsr_empty" "$DOC/rdmsr_partial"
# doctor gates the rdmsr read-back on root (id -u == 0); stub both, to exercise the gate.
mkdir -p "$DOC/asroot" "$DOC/asuser"
printf '#!/usr/bin/env bash\ncase "$*" in *-un*) echo root ;; *) echo 0 ;; esac\n' >"$DOC/asroot/id"
printf '#!/usr/bin/env bash\ncase "$*" in *-un*) echo tester ;; *) echo 1000 ;; esac\n' >"$DOC/asuser/id"
chmod +x "$DOC/asroot/id" "$DOC/asuser/id"
run_doctor_msr() { # <rdmsr_bin> [root|user]
    local idstub="$DOC/asroot"
    [ "${2:-root}" = user ] && idstub="$DOC/asuser"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$MSRD/config.json"
        MEMINFO="$DOC/meminfo_ok"
        MSR_MODULE_DIR="$DOC/msrmod"
        GOVERNOR_FILE="$DOC/gov_perf"
        HUGEPAGES_1G_NR="$DOC/nr1g"
        RDMSR_BIN="$1"
        set +e
        PATH="$idstub:$STUBS:$PATH" doctor 2>&1
    )
}
# Zen4 happy path (root): log confirms the preset + rdmsr verifies all 4 registers.
out="$(run_doctor_msr "$DOC/rdmsr_ok")"
assert_contains "doctor: MSR mod applied per XMRig log (#66)" "$out" "MSR mod applied"
assert_contains "doctor: names the applied preset (#66)" "$out" "ryzen_19h_zen4"
assert_contains "doctor: rdmsr verifies the registers (#66)" "$out" "verified via rdmsr (4/4"
# Readable but wrong values (a silently-dropped write) -> mismatch WARN.
out="$(run_doctor_msr "$DOC/rdmsr_bad")"
assert_contains "doctor: rdmsr mismatch WARN (#66)" "$out" "don't match the ryzen_19h_zen4 preset"
# Non-root: the read-back is SKIPPED with an advisory — NOT a false mismatch (regression guard for the gate).
out="$(run_doctor_msr "$DOC/rdmsr_ok" user)"
assert_contains "doctor: non-root asks for sudo to verify MSRs (#66)" "$out" "run 'doctor' as root"
assert_absent "doctor: non-root does NOT false-warn a mismatch (#66)" "$out" "don't match"
assert_contains "doctor: non-root still confirms the mod via the log (#66)" "$out" "MSR mod applied"
# rdmsr present but every register unreadable (e.g. msr module not loaded) -> advisory, not a mismatch.
out="$(run_doctor_msr "$DOC/rdmsr_empty")"
assert_contains "doctor: all-unreadable -> advisory (#66)" "$out" "couldn't read"
assert_absent "doctor: all-unreadable is NOT a mismatch (#66)" "$out" "don't match"
# Partial read (1 correct, 3 unreadable, none WRONG) -> advisory, not a mismatch.
out="$(run_doctor_msr "$DOC/rdmsr_partial")"
assert_contains "doctor: partial-read -> advisory not mismatch (#66)" "$out" "couldn't read"
# Intel happy path (root): the single 0x1a4 register verifies.
msr_log intel
out="$(run_doctor_msr "$DOC/rdmsr_ok")"
assert_contains "doctor: intel preset verified via rdmsr (#66)" "$out" "verified via rdmsr (1/1"
# rdmsr absent -> graceful advisory, not a failure (the log already confirms the write).
out="$(run_doctor_msr "/nonexistent-rdmsr")"
assert_contains "doctor: advises msr-tools when rdmsr absent (#66)" "$out" "install msr-tools"
# A FAILED-to-set log line -> WARN.
printf 'msr      register values for "intel" preset FAILED to set\n' >"$MSRD/home/worker/xmrig.log"
out="$(run_doctor_msr "$DOC/rdmsr_ok")"
assert_contains "doctor: MSR FAILED-to-set WARN (#66)" "$out" "FAILED to set"

# #66: the preset table is the SOURCE OF TRUTH for register verification — assert the exact
# (register value mask) triples against XMRig v6.26.0 (RxConfig.cpp), so a typo fails a test rather
# than silently weakening every rig's check. "-" = whole-register (no-mask) write.
echo "== unit: MSR preset table values (#66) =="
msr_regs() { (
    source "$SCRIPT"
    _msr_preset_regs "$1"
); }
assert_eq "preset: zen4 0xc0011020 value (#66)" "$(msr_regs ryzen_19h_zen4 | awk '$1=="0xc0011020"{print $2, $3}')" "0004400000000000 -"
assert_eq "preset: zen4 0xc0011021 masked (#66)" "$(msr_regs ryzen_19h_zen4 | awk '$1=="0xc0011021"{print $2, $3}')" "0004000000000040 ffffffffffffffdf"
assert_eq "preset: zen4 0xc001102b value (#66)" "$(msr_regs ryzen_19h_zen4 | awk '$1=="0xc001102b"{print $2, $3}')" "000000002040cc10 -"
assert_eq "preset: zen5 shares the zen4 table (#66)" "$(msr_regs ryzen_1Ah_zen5)" "$(msr_regs ryzen_19h_zen4)"
assert_eq "preset: zen3/19h 0xc0011022 value (#66)" "$(msr_regs ryzen_19h | awk '$1=="0xc0011022"{print $2}')" "c000000401570000"
assert_eq "preset: zen/17h 0xc001102b value (#66)" "$(msr_regs ryzen_17h | awk '$1=="0xc001102b"{print $2}')" "000000002000cc16"
assert_eq "preset: intel 0x1a4 whole-register (#66)" "$(msr_regs intel)" "0x1a4 000000000000000f -"
assert_eq "preset: unknown -> empty (#66)" "$(msr_regs bogus | grep -c .)" "0"
assert_contains "log status: missing file -> none (#66)" "$( (
    source "$SCRIPT"
    _msr_log_status /nonexistent
))" "none"
# Unreadable registers are counted in _MSR_UNREAD, kept OUT of _MSR_BAD (so they don't read as mismatches).
out="$( (
    source "$SCRIPT"
    RDMSR_BIN="$DOC/rdmsr_empty"
    _msr_rdmsr_verify intel
    printf '%s|%s|%s|[%s]' "$_MSR_OK" "$_MSR_TOTAL" "$_MSR_UNREAD" "$_MSR_BAD"
))"
assert_eq "rdmsr unreadable tracked separately from mismatch (#66)" "$out" "0|1|1|[]"

# #12: uninstall reverts every system change setup made, idempotently, leaving config.json. The GRUB
# revert uses GNU `sed -i` so it's exercised in the Docker e2e (real Linux); here we point GRUB_DEFAULT
# at a nonexistent path so that block is skipped and the test runs on macOS too.
echo "== black-box: uninstall reverts system changes (#12) =="
UN="$(mktemp -d "$SANDBOX/uninst.XXXXXX")"
cp "$ROOT/VERSION" "$UN/"
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
        RIGFORGE_HOME="$PWD" bash "$SCRIPT" uninstall --yes </dev/null 2>&1)
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

# #54: tune is an iterative, noise-aware, multi-knob hill-climb. It sweeps prefetch_mode, cpu.yield and
# the RandomX thread count (cpu.rx, around L3/2 MB), measures each candidate as the MEDIAN of N runs,
# memoizes so a combo is never benchmarked twice, climbs from two seeds (auto + educated guess), and
# writes the winner to a SEPARATE tune-overrides.json (merged into the config) — config.json untouched.
# A fake xmrig emits a hashrate that depends on all three knobs so a clear global optimum exists:
# prefetch=2, yield=false, threads=4 (the L3=8 MiB center; nproc=4). The fake also logs every call so we
# can prove memoization (no candidate benchmarked twice).
echo "== black-box: tune (iterative hill-climb, multi-knob) (#54) =="
TN="$(mktemp -d "$SANDBOX/tune.XXXXXX")"
cp "$ROOT/VERSION" "$TN/"
# Mirror the install layout: proposed-grub.sh sits alongside rigforge.sh, so tune's #65 reservation math
# (_hugepages_2m_need) can run it from SCRIPT_DIR just like production.
mkdir -p "$TN/util"
cp "$ROOT/util/proposed-grub.sh" "$TN/util/" && chmod +x "$TN/util/proposed-grub.sh"
BD="$TN/home/worker/xmrig/build"
mkdir -p "$BD"
# #62: give every tune run in this block a controlled, HEALTHY clock source. The fake xmrig isn't a real
# load, so real sysfs (e.g. an idle CI runner) would read a low clock and falsely flag every candidate as
# throttled. Export a fake ~96%-of-max sysfs; the #62 throttle test overrides these to simulate a throttle.
mkdir -p "$TN/cpuok/cpu0/cpufreq"
printf '5000000\n' >"$TN/cpu_max"
printf '4800000\n' >"$TN/cpuok/cpu0/cpufreq/scaling_cur_freq"
export CPUFREQ_MAX="$TN/cpu_max" CPU_SYSFS="$TN/cpuok"
# A built config for `tune` to sweep. Seeded with the knob values the in-script generator emits
# (#55 removed the worker-config template this used to be copied from), so the hill-climb's "guess"
# seed reads the same prefetch/yield/1gb-pages/priority starting points it would in production.
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
# Fake xmrig: hashrate = f(prefetch, yield, threads, 1gb-pages), peak at prefetch=2/yield=false/threads=4.
# BENCH_LOG records one line per invocation (used to assert no double-benchmarking).
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
[ -n "${BENCH_LOG:-}" ] && echo call >>"$BENCH_LOG"
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
y=$(jq -r '.cpu.yield' "$cfg" 2>/dev/null)
t=$(jq -r '.cpu.rx' "$cfg" 2>/dev/null)
g=$(jq -r '.randomx."1gb-pages"' "$cfg" 2>/dev/null)
base=1000; case "$m" in 2) base=1200 ;; 1) base=1100 ;; 0) base=1000 ;; *) base=1050 ;; esac
[ "$y" = false ] && base=$((base + 20))             # yield off is a touch faster
[ "$g" = true ] && base=$((base + 5))               # 1G pages help (only swept when reserved)
tt="$t"; [ "$tt" = "-1" ] && tt=3                    # XMRig auto lands slightly off the L3 center
pen=$(((tt > 4 ? tt - 4 : 4 - tt) * 30)); base=$((base - pen))   # RandomX peaks at threads=4
echo "miner speed 10s/60s/15m $base.0 n/a n/a H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
cat >"$TN/config.json" <<EOF
{ "HOME_DIR": "$TN/home", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
BENCHLOG="$TN/bench.log"
: >"$BENCHLOG"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 BENCH_LOG="$BENCHLOG" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
rc=$?
assert_rc "tune exits 0" "$rc" "0"
assert_contains "tune climbs (logs a candidate trial)" "$out" "try prefetch="
assert_contains "tune reports the winner" "$out" "Best: prefetch_mode=2 yield=false threads=4"
assert_contains "tune stops on a plateau" "$out" "plateau"
# #2: --bench mode stops the live service so the benchmark isn't contended, then restarts it after (the
# stub systemctl reports 'active', so this path fires).
assert_contains "bench tune stops the service (#2)" "$out" "Stopping the 'xmrig' service"
assert_contains "bench tune restarts the service after (#2)" "$out" "Restarting the 'xmrig' service"
# --bench measures Monero's rx/0; tune says so and points non-Monero pools at --live.
assert_contains "bench notes it measures rx/0" "$out" "measures Monero's RandomX"
# A pinned thread count carries a HugePages-sizing reminder (the reservation is set at setup time).
assert_contains "pinned threads -> hugepages re-size hint" "$out" "re-run 'sudo"
OVR="$TN/home/worker/tune-overrides.json"
TLOG="$TN/home/worker/rigforge-tune.json"
assert_eq "overrides file written" "$([ -f "$OVR" ] && echo y || echo n)" "y"
assert_eq "config.json NOT touched (no .bak)" "$([ -f "$BD/config.json.bak" ] && echo y || echo n)" "n"
assert_eq "winning prefetch in overrides" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"
assert_eq "winning yield in overrides" "$(J "$OVR" '.cpu.yield')" "false"
assert_eq "winning thread count in overrides" "$(J "$OVR" '.cpu.rx')" "4"
# 1gb-pages was NOT swept here (no 1G pages reserved on the test host), so it isn't pinned in overrides.
assert_eq "1gb-pages not pinned when unreserved" "$(J "$OVR" '.randomx["1gb-pages"] // "absent"')" "absent"
assert_contains "tune notes the reboot-bound 1gb-pages skip" "$out" "skipping the 1gb-pages knob"
# The off-by-default knobs must NOT leak into the overrides when they weren't swept (#7).
assert_eq "huge-pages-jit not pinned when inactive" "$(J "$OVR" '.cpu["huge-pages-jit"] // "absent"')" "absent"
assert_eq "cache_qos not pinned when inactive" "$(J "$OVR" '.randomx.cache_qos // "absent"')" "absent"
assert_eq "log is valid JSON" "$(jq -e . "$TLOG" >/dev/null 2>&1 && echo y || echo n)" "y"
assert_eq "log best prefetch" "$(J "$TLOG" '.best.scratchpad_prefetch_mode')" "2"
assert_eq "log best threads" "$(J "$TLOG" '.best.threads')" "4"
assert_eq "log records the mode" "$(J "$TLOG" '.mode')" "bench"
assert_eq "log records both seeds" "$(JC "$TLOG" '.seeds')" '["auto","guess"]'
# Memoization: with TUNE_ITERS=1, one bench call per DISTINCT candidate. The bench-call count must equal
# the number of logged (distinct) candidates — proving no combination was ever benchmarked twice.
NCAND="$(J "$TLOG" '.results | length')"
NCALLS="$(grep -c call "$BENCHLOG" 2>/dev/null || echo 0)"
assert_eq "no candidate benchmarked twice (memoized)" "$NCALLS" "$NCAND"
assert_eq "search explored more than one candidate" "$([ "$NCAND" -gt 1 ] && echo y || echo n)" "y"
# generate merges the overrides on top: apply regenerates from the template and the tuned knobs win.
mkdir -p "$TN/logrotate"
out="$(cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply </dev/null 2>&1)"
assert_rc "apply after tune exits 0" "$?" "0"
assert_eq "generated config has tuned prefetch" "$(J "$BD/config.json" '.randomx.scratchpad_prefetch_mode')" "2"
assert_eq "generated config has tuned yield" "$(J "$BD/config.json" '.cpu.yield')" "false"
assert_eq "generated config has tuned threads" "$(J "$BD/config.json" '.cpu.rx')" "4"
# tune --clear removes the tuning state.
out="$(cd "$TN" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --clear </dev/null 2>&1)"
assert_rc "tune --clear exits 0" "$?" "0"
assert_eq "overrides removed by --clear" "$([ -f "$OVR" ] && echo y || echo n)" "n"

# #54: median noise-handling. With a single (inactive) candidate and a fake whose three readings are
# base-10, base, base+10, the recorded hashrate must be the MEDIAN (base), not the max.
echo "== black-box: tune median-of-N noise handling (#54) =="
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
c="${JITTER_CTR:-/tmp/jit}"; n=0; [ -f "$c" ] && n=$(cat "$c"); echo $((n + 1)) >"$c"
case $((n % 3)) in 0) d=-10 ;; 1) d=0 ;; *) d=10 ;; esac
echo "speed $((1100 + d)).0 H/s max $((1100 + d)).0 H/s"
EOF
chmod +x "$BD/xmrig"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=3 JITTER_CTR="$TN/jit" \
    TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "median tune exits 0" "$?" "0"
assert_eq "single candidate measured" "$(J "$TLOG" '.results | length')" "1"
# Numeric compare (jq 1.7 preserves "1100.0"; older jq prints "1100") — median of 1090/1100/1110 is 1100.
assert_eq "records the median, not the max" "$(J "$TLOG" '.results[0].hashrate == 1100')" "true"
assert_eq "records all three samples" "$(J "$TLOG" '.results[0].samples | length')" "3"

# #54: the minimum-delta gate. With min-delta 0.5 (50%) and only the 'auto' seed, no candidate beats the
# seed by enough, so the search stays put — winner = seed (prefetch=1, yield=false, threads auto).
# Reset the base config to a pristine generated-style config so the 'auto' seed starts from prefetch=1
# (an earlier 'apply' rewrote $BD/config.json with the tuned prefetch=2).
echo "== black-box: tune min-delta gate (#54) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
base=1000; case "$m" in 2) base=1100 ;; 1) base=1080 ;; *) base=1050 ;; esac
echo "speed $base.0 H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_MIN_DELTA=0.5 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "min-delta tune exits 0" "$?" "0"
assert_eq "min-delta keeps the seed prefetch" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "1"
assert_eq "min-delta leaves threads at auto (rx unpinned)" "$(J "$OVR" '.cpu.rx // "absent"')" "absent"

# #63: variance-aware acceptance. A noisy fake returns 5 samples per candidate spread ±10 (median 100 for
# prefetch=1, 102 for prefetch=2) — a 2% median "win" that clears the 1% TUNE_MIN_DELTA floor but sits
# WITHIN the sample-noise band (combined sd ≈ 10). With the band ON it must be rejected (no phantom
# adoption); with TUNE_SIGMA=0 the same win is adopted — proving the band is what rejected it.
echo "== black-box: tune variance-aware acceptance gate (#63) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
ctr="$CTRDIR/$m"
i=$(cat "$ctr" 2>/dev/null || echo 0)
i=$((i + 1))
echo "$i" >"$ctr"
case "$m" in 2) c=102 ;; 1) c=100 ;; *) c=98 ;; esac
case "$i" in 1) v=$((c - 10)) ;; 2) v=$((c - 5)) ;; 3) v=$c ;; 4) v=$((c + 5)) ;; 5) v=$((c + 10)) ;; *) v=$c ;; esac
echo "speed $v.0 H/s max $v.0 H/s"
EOF
chmod +x "$BD/xmrig"
CTRDIR="$TN/ctr"
mkdir -p "$CTRDIR"
tune_variance() { # <sigma>; resets the per-candidate counters and runs a fixed prefetch sweep
    rm -f "$CTRDIR"/* 2>/dev/null
    (cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=5 TUNE_SEEDS=auto TUNE_PREFETCH_MODES="1 2" \
        TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MIN_DELTA=0.01 TUNE_SIGMA="$1" CTRDIR="$CTRDIR" \
        RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)
}
out="$(tune_variance 1)"
assert_rc "variance tune exits 0" "$?" "0"
assert_eq "variance gate rejects a within-noise win (#63)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "1"
out="$(tune_variance 0)"
assert_eq "TUNE_SIGMA=0 lets the same win through (#63 control)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"

# #54: when 1G HugePages ARE reserved, the 1gb-pages knob is swept and pinned in the overrides. Point
# HUGEPAGES_1G_NR at a fake sysfs node reporting reserved pages; the fake xmrig rewards 1gb-pages=true.
echo "== black-box: tune 1gb-pages knob when reserved (#54) =="
printf '4\n' >"$TN/nr_1g"
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
g=$(jq -r '.randomx."1gb-pages"' "$cfg" 2>/dev/null)
base=1000; [ "$g" = true ] && base=1100
echo "speed $base.0 H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto \
    TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 HUGEPAGES_1G_NR="$TN/nr_1g" \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "1gb tune exits 0" "$?" "0"
assert_absent "no skip note when 1G reserved" "$out" "skipping the 1gb-pages knob"
assert_eq "1gb-pages swept and pinned true" "$(J "$OVR" '.randomx["1gb-pages"]')" "true"

# #54: optional power/temperature recording for a hashrate-per-watt view (best-effort, via hooks).
echo "== black-box: tune power/temp recording (#54) =="
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "speed 1200.0 H/s max 1200.0 H/s"
EOF
chmod +x "$BD/xmrig"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto \
    TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 \
    TUNE_POWER_CMD='echo 100' TUNE_TEMP_CMD='echo 55' \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "power/temp tune exits 0" "$?" "0"
assert_eq "records watts" "$(J "$TLOG" '.results[0].watts')" "100"
assert_eq "records temperature" "$(J "$TLOG" '.results[0].temp_c')" "55"
assert_eq "computes hashrate-per-watt" "$(J "$TLOG" '.results[0].hs_per_watt')" "12"
assert_contains "reports best efficiency" "$out" "H/s per watt"

# #54: live tuning measures the running miner via the API instead of --bench, then applies the winner.
# API is stubbed to a constant so no knob wins; the search stays at the seed and the winner is applied.
echo "== black-box: tune --live (API-measured) (#54) =="
out="$(cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" \
    API_CMD='echo 1500' TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=1 \
    TUNE_SEEDS=auto TUNE_PREFETCH_MODES="0 1" TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --live </dev/null 2>&1)"
assert_rc "tune --live exits 0" "$?" "0"
assert_eq "live log records mode=live" "$(J "$TLOG" '.mode')" "live"
assert_contains "live tune applies the winner" "$out" "Applied the winning config to the live miner"
# --live measures the real pool algorithm, so it must NOT print the rx/0-only bench caveat.
assert_absent "live mode omits the rx/0 bench note" "$out" "measures Monero's RandomX"
# tune --live is Linux-only.
out="$(cd "$TN" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --live </dev/null 2>&1)"
assert_rc "tune --live rejected on non-Linux" "$?" "1"
assert_contains "tune --live non-Linux message" "$out" "only supported on Linux"

# #64: --confirm A/B-checks the bench winner against the previous config on the live miner, keeping it
# only if it genuinely wins live (else reverting). The bench search picks the winner (prefetch=2); a fake
# API then drives the live A/B — a counter returns the winner window first, the previous-config window
# second. The build config seeds prefetch=1, the fake bench rewards prefetch=2.
echo "== black-box: tune --confirm live A/B (#64) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
base=1000
case "$m" in 2) base=1100 ;; 1) base=1050 ;; *) base=1000 ;; esac
echo "speed $base.0 H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
ACTR="$TN/actr"
confirm_run() { # <api_cmd>; fresh overrides + counter each run
    rm -f "$OVR" "$ACTR" 2>/dev/null
    (cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" API_CMD="$1" ACTR="$ACTR" \
        TUNE_ITERS=1 TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=1 TUNE_SEEDS=auto \
        TUNE_PREFETCH_MODES='1 2' TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
        RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --confirm </dev/null 2>&1)
}
# Winner wins live (1st API reading high, 2nd low) -> kept.
out="$(confirm_run 'c=$(cat "$ACTR" 2>/dev/null||echo 0);c=$((c+1));echo $c>"$ACTR";[ "$c" = 1 ]&&echo 1200||echo 1000')"
assert_rc "tune --confirm exits 0" "$?" "0"
assert_contains "confirm keeps a real live win (#64)" "$out" "Confirmed:"
assert_eq "confirm kept the tuned prefetch (#64)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"
# Winner loses live (1st low, 2nd high) -> reverted; no prior overrides existed, so the file is removed.
out="$(confirm_run 'c=$(cat "$ACTR" 2>/dev/null||echo 0);c=$((c+1));echo $c>"$ACTR";[ "$c" = 1 ]&&echo 1000||echo 1200')"
assert_contains "confirm reverts a live regression (#64)" "$out" "Reverted:"
assert_eq "reverted -> previous (none) restored (#64)" "$([ -f "$OVR" ] && echo present || echo gone)" "gone"

# #62: thermal-throttle rejection. A LOW clock source makes every candidate's window "throttled" — a
# faster-but-throttled candidate must NOT be adopted (its number reflects the throttle, not the config),
# and the throttle must be recorded in the log. With TUNE_MIN_FREQ_MHZ=0 the skip is disabled.
echo "== black-box: tune thermal-throttle rejection (#62) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
base=1000
case "$m" in 2) base=1100 ;; 1) base=1000 ;; *) base=950 ;; esac
echo "speed $base.0 H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
mkdir -p "$TN/cpulow/cpu0/cpufreq"
printf '3000000\n' >"$TN/cpulow/cpu0/cpufreq/scaling_cur_freq" # 3.0 GHz vs 5.0 GHz max = 60% -> throttled
throttle_run() {                                               # <min_freq_mhz: 4000 trips on the 3 GHz reading, 0 disables>
    rm -f "$OVR" 2>/dev/null
    (cd "$TN" && PATH="$STUBS:$PATH" CPU_SYSFS="$TN/cpulow" CPUFREQ_MAX="$TN/cpu_max" TUNE_MIN_FREQ_MHZ="$1" \
        TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES="1 2" TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
        RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)
}
# Throttle ON (min 4000 MHz vs the 3 GHz reading): the faster prefetch=2 throttled -> skipped.
out="$(throttle_run 4000)"
assert_rc "throttle tune exits 0" "$?" "0"
assert_eq "throttle recorded in the log (#62)" "$(J "$TLOG" '[.results[]|select(.throttled)]|length>0')" "true"
assert_eq "throttled faster candidate not adopted (#62)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "1"
# Throttle OFF: the same faster candidate IS adopted.
out="$(throttle_run 0)"
assert_eq "TUNE_MIN_FREQ_MHZ=0 disables the throttle skip (#62 control)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"

# #66: the opt-in wrmsr knob sweeps MSR presets. A fake whose hashrate depends on randomx.wrmsr proves the
# knob is swept and the winner pinned; a single value leaves it off (not pinned, but still recorded).
echo "== black-box: tune wrmsr knob (#66) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true, "wrmsr": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
# Fake whose hashrate depends on randomx.wrmsr; WRMSR_WIN (env) chooses which value the fake rewards, so
# the SAME test can prove the *measured* winner is pinned in BOTH directions (not a fixed first/last value).
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
w=$(jq -r '.randomx.wrmsr' "$cfg" 2>/dev/null)
base=1000; [ "$w" = "${WRMSR_WIN:-false}" ] && base=1100
echo "speed $base.0 H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
wrmsr_run() { # <WRMSR_WIN> [tune_wrmsr value; OMIT the arg entirely to leave TUNE_WRMSR unset = default]
    rm -f "$OVR"
    (
        cd "$TN" || exit 1
        export WRMSR_WIN="$1" TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 \
            TUNE_YIELDS=false TUNE_THREADS=-1 RIGFORGE_HOME="$PWD"
        [ "$#" -ge 2 ] && export TUNE_WRMSR="$2" # quoted => a multi-value "true false" stays one var
        PATH="$STUBS:$PATH" bash "$SCRIPT" tune </dev/null 2>&1
    )
}
# Fake prefers wrmsr=false -> false is the measured winner and gets pinned.
out="$(wrmsr_run false "true false")"
assert_rc "wrmsr tune exits 0 (#66)" "$?" "0"
assert_eq "wrmsr: measured winner (false) is pinned (#66)" "$(J "$OVR" '.randomx.wrmsr')" "false"
assert_eq "wrmsr recorded per candidate (#66)" "$(J "$TLOG" '.results[0] | has("wrmsr")')" "true"
# Fake prefers wrmsr=true -> NOW true wins and is pinned. Proves the measurement drives the pin, not a
# fixed value (false happened to be the last candidate in the case above).
out="$(wrmsr_run true "true false")"
assert_eq "wrmsr: measured winner (true) is pinned (#66)" "$(J "$OVR" '.randomx.wrmsr')" "true"
# A single explicit value -> knob inactive -> not pinned (#7-style isolation).
out="$(wrmsr_run false "true")"
assert_eq "wrmsr not pinned when single-valued (#66)" "$(J "$OVR" '.randomx.wrmsr // "absent"')" "absent"
# OFF BY DEFAULT: with TUNE_WRMSR unset (arg omitted), _seed_wr yields a single token (the base value),
# so the knob is never swept and never pinned out of the box.
out="$(wrmsr_run false)"
assert_eq "wrmsr OFF by default (unset -> not swept/pinned) (#66)" "$(J "$OVR" '.randomx.wrmsr // "absent"')" "absent"
assert_absent "wrmsr default isn't in the active-knob set (#66)" "$out" "wrmsr="

# #65: reservation-aware thread exploration. With a small HugePages reservation, a thread count whose
# 2MB-page need exceeds it is recorded as hugepages_capped (ran without full backing = a floor reading),
# and tune prints an honest note + the documented resize path. need(1)=1168+1+50=1219 (no 1G), so a
# reservation of 1220 backs up to 2 threads; threads=8 is capped, threads=2 fits.
echo "== black-box: tune reservation-aware threads (#65) =="
printf 'HugePages_Total:    1220\n' >"$TN/meminfo_small"
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "speed 1000.0 H/s max 1000.0 H/s"
EOF
chmod +x "$BD/xmrig"
rm -f "$OVR"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto MEMINFO="$TN/meminfo_small" \
    TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS="2 8" TUNE_MAX_ROUNDS=1 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "reservation-aware tune exits 0" "$?" "0"
assert_contains "tune reports the reservation backing limit (#65)" "$out" "backs up to 2 threads"
assert_eq "threads=8 flagged HugePages-capped (#65)" "$(J "$TLOG" 'any(.results[]; .threads==8 and .hugepages_capped==true)')" "true"
assert_eq "threads=2 fits the reservation (#65)" "$(J "$TLOG" 'any(.results[]; .threads==2 and .hugepages_capped==true)')" "false"
assert_contains "tune warns about the capped optimum (#65)" "$out" "HugePages-capped: thread counts {8}"
assert_contains "tune gives the resize path (#65)" "$out" "RIGFORGE_THREADS=<n>"

# #65: the setup side of the tie-in — tune_kernel sizes the HugePages reservation for the tuned cpu.rx
# (read from tune-overrides.json) or an explicit RIGFORGE_THREADS, passing it to proposed-grub.sh via
# RX_THREADS. A fake proposed-grub records the RX_THREADS it received; GRUB_DEFAULT points nowhere so the
# reboot-bound GRUB block is skipped (covered by the Docker e2e on real Linux).
echo "== black-box: setup sizes the reservation for the tuned threads (#65) =="
TK="$(mktemp -d "$SANDBOX/tk.XXXXXX")"
mkdir -p "$TK/util" "$TK/home/worker"
cat >"$TK/util/proposed-grub.sh" <<'EOF'
#!/usr/bin/env bash
echo "RX_THREADS=[${RX_THREADS-}]" >>"$PG_CALLS"
echo 200
EOF
chmod +x "$TK/util/proposed-grub.sh"
printf '{ "cpu": { "rx": 24 } }\n' >"$TK/home/worker/tune-overrides.json"
run_tunekernel() { # <pg_calls_file>; reads RIGFORGE_THREADS from the env
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$TK"
        WORKER_ROOT="$TK/home/worker"
        MODULES_LOAD_DIR="$TK/nope"
        MODULES_FILE="$TK/nope/modules"
        GRUB_DEFAULT="$TK/nope/grub" # nonexistent -> the GRUB block is skipped
        export PG_CALLS="$1"
        set +e
        PATH="$STUBS:$PATH" tune_kernel 2>&1
    )
}
PGC="$TK/calls1"
: >"$PGC"
out="$(run_tunekernel "$PGC")"
assert_contains "setup sizes the reservation for the tuned cpu.rx (#65)" "$out" "Sizing the HugePages reservation for 24"
assert_contains "setup passes the tuned thread count to proposed-grub (#65)" "$(cat "$PGC")" "RX_THREADS=[24]"
PGC="$TK/calls2"
: >"$PGC"
out="$(RIGFORGE_THREADS=12 run_tunekernel "$PGC")"
assert_contains "RIGFORGE_THREADS overrides the reservation sizing (#65)" "$out" "Sizing the HugePages reservation for 12"
assert_contains "RIGFORGE_THREADS reaches proposed-grub (#65)" "$(cat "$PGC")" "RX_THREADS=[12]"
PGC="$TK/calls3"
: >"$PGC"
out="$(RIGFORGE_THREADS=abc run_tunekernel "$PGC")"
assert_absent "garbage RIGFORGE_THREADS is sanitized away (#65)" "$out" "Sizing the HugePages reservation"
assert_contains "sanitized RIGFORGE_THREADS -> empty RX_THREADS to proposed-grub (#65)" "$(cat "$PGC")" "RX_THREADS=[]"

# tune with no built worker fails clearly.
TN2="$(mktemp -d "$SANDBOX/tune2.XXXXXX")"
cp "$ROOT/VERSION" "$TN2/"
cat >"$TN2/config.json" <<EOF
{ "HOME_DIR": "$TN2/home", "pools": [{"url": "h:3333"}] }
EOF
out="$(cd "$TN2" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
rc=$?
assert_rc "tune without a build fails" "$rc" "1"
assert_contains "tune build-missing message" "$out" "Run 'setup' first"
# An unknown tune flag is rejected.
out="$(cd "$TN" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --bogus </dev/null 2>&1)"
assert_rc "unknown tune flag fails" "$?" "1"
assert_contains "unknown tune flag message" "$out" "Unknown tune option"

# #46: autotune does one live trial — reads the API (median of N samples), tries the next prefetch mode,
# keeps it only if faster. Crucially it MERGES the change into any existing overrides (#46 fix): a prior
# offline `tune` pinned threads + yield here, and they must survive an autotune run.
echo "== black-box: autotune live trial + merge (#46) =="
cat >"$OVR" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1 }, "cpu": { "rx": 4, "yield": false } }
EOF
# Fake API: hashrate depends on the OVERRIDES' prefetch, so the candidate (prefetch=2) beats the baseline
# (prefetch=1) and is kept. Median sampling with no sleeps (SAMPLES=1, INTERVAL=0).
ATAPI='jq -r "if (.randomx.scratchpad_prefetch_mode // 1) == 2 then 1300 else 1200 end" "$WORKER_ROOT/tune-overrides.json" 2>/dev/null'
out="$(cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" \
    API_CMD="$ATAPI" AUTOTUNE_WARMUP=0 AUTOTUNE_SAMPLES=1 AUTOTUNE_INTERVAL=0 AUTOTUNE_MARGIN=0.01 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" autotune </dev/null 2>&1)"
rc=$?
assert_rc "autotune exits 0" "$rc" "0"
assert_contains "autotune reads a median baseline" "$out" "median of 1"
assert_contains "autotune keeps the faster candidate" "$out" "keeping it"
assert_eq "autotune updated prefetch to next" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"
assert_eq "autotune PRESERVED tuned threads (#46 merge)" "$(J "$OVR" '.cpu.rx')" "4"
assert_eq "autotune PRESERVED tuned yield (#46 merge)" "$(J "$OVR" '.cpu.yield')" "false"
# autotune is Linux-only.
out="$(cd "$TN" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" autotune </dev/null 2>&1)"
assert_rc "autotune rejected on non-Linux" "$?" "1"

# #6: grid search exhaustively tries every knob combination (TUNE_SEARCH=grid). Reset the base + a
# prefetch-rewarding fake; only prefetch is active (4 values), so grid measures 4 combos and finds 2.
echo "== black-box: tune grid search (#6) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
base=1000; case "$m" in 2) base=1200 ;; 1) base=1100 ;; *) base=1000 ;; esac
echo "speed $base.0 H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEARCH=grid \
    TUNE_PREFETCH_MODES="0 1 2 3" TUNE_YIELDS=false TUNE_THREADS=-1 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "grid tune exits 0" "$?" "0"
assert_contains "grid search announced" "$out" "Grid search"
assert_contains "grid logs candidate combinations" "$out" "grid prefetch="
assert_eq "grid found the best prefetch" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"
assert_eq "log records search=grid" "$(J "$TLOG" '.search')" "grid"

# #7: huge-pages-jit is an off-by-default knob; enabling it (TUNE_HPJIT="false true") makes tune sweep
# and pin it when it wins. Fake rewards huge-pages-jit=true.
echo "== black-box: tune huge-pages-jit knob (#7) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1 }, "cpu": { "yield": false, "priority": 2, "huge-pages-jit": false } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
hj=$(jq -r '.cpu."huge-pages-jit"' "$cfg" 2>/dev/null)
base=1000; [ "$hj" = true ] && base=1100
echo "speed $base.0 H/s max $base.0 H/s"
EOF
chmod +x "$BD/xmrig"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto \
    TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_HPJIT="false true" \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "hpjit tune exits 0" "$?" "0"
assert_contains "hpjit knob is swept" "$out" "try hpjit="
assert_eq "huge-pages-jit pinned true when it wins" "$(J "$OVR" '.cpu["huge-pages-jit"]')" "true"

# #4: the thread-count search is SMT-aware — it includes the physical-core count and the logical-core
# count, not just a window around L3/2 MB. A richer fake lscpu exposes cores-per-socket so _physical_cores
# can resolve. (8 physical cores, 16 logical, 32 MiB L3 -> center 16.)
echo "== unit: _thread_candidates is SMT-aware (#4) =="
TC="$(mktemp -d "$SANDBOX/tc.XXXXXX")"
cat >"$TC/lscpu" <<'EOF'
#!/usr/bin/env bash
echo "Model name:            Test CPU"
echo "L3 cache:              32 MiB"
echo "Socket(s):             1"
echo "Core(s) per socket:    8"
EOF
printf '#!/usr/bin/env bash\necho 16\n' >"$TC/nproc"
chmod +x "$TC/lscpu" "$TC/nproc"
phys="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    PATH="$TC:$STUBS:$PATH" _physical_cores
)"
assert_eq "physical cores = cores-per-socket x sockets" "$phys" "8"
cands="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    PATH="$TC:$STUBS:$PATH" _thread_candidates 16
)"
assert_contains "candidates include XMRig auto (-1)" " $cands " " -1 "
assert_contains "candidates include physical-core count (SMT off)" " $cands " " 8 "
assert_contains "candidates include logical-core count (SMT on)" " $cands " " 16 "
assert_contains "candidates include the L3 window" " $cands " " 14 "

# backup snapshots config.json + tuning into ./backups; restore puts them back — on this machine after
# data loss, or onto another identical machine (tune once, roll out to a fleet). Round-trip across two
# sandboxes proves it's portable (DYNAMIC_HOME paths resolve per-machine).
echo "== black-box: backup / restore round-trip =="
BK="$(mktemp -d "$SANDBOX/bk.XXXXXX")"
cp "$ROOT/VERSION" "$BK/"
cat >"$BK/config.json" <<'EOF'
{ "DONATION": 7, "pools": [{"url": "poolbox.lan:3333"}] }
EOF
mkdir -p "$BK/data/worker"
printf '{ "randomx": { "scratchpad_prefetch_mode": 2 }, "cpu": { "rx": 4 } }\n' >"$BK/data/worker/tune-overrides.json"
out="$(cd "$BK" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" backup </dev/null 2>&1)"
assert_rc "backup exits 0" "$?" "0"
ARCHIVE="$(ls "$BK"/backups/rigforge-backup-*.tar.gz 2>/dev/null | head -n1)"
assert_eq "backup created an archive" "$([ -f "$ARCHIVE" ] && echo y || echo n)" "y"
contents="$(tar -tzf "$ARCHIVE" 2>/dev/null)"
assert_contains "archive holds config.json" "$contents" "config.json"
assert_contains "archive holds the tuning" "$contents" "tune-overrides.json"
# Restore onto a FRESH machine (different sandbox); DYNAMIC_HOME keeps the paths portable.
FR="$(mktemp -d "$SANDBOX/fr.XXXXXX")"
cp "$ROOT/VERSION" "$FR/"
out="$(cd "$FR" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y "$ARCHIVE" </dev/null 2>&1)"
assert_rc "restore exits 0" "$?" "0"
assert_eq "restore brought back config.json" "$(J "$FR/config.json" '.DONATION')" "7"
assert_eq "restore brought back the tuning" "$(J "$FR/data/worker/tune-overrides.json" '.randomx.scratchpad_prefetch_mode')" "2"
assert_contains "restore warns tuning is CPU-specific" "$out" "CPU-specific"
# Validation + safety.
out="$(cd "$FR" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y </dev/null 2>&1)"
assert_rc "restore without an archive fails" "$?" "1"
out="$(cd "$FR" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y "$BK/nope.tar.gz" </dev/null 2>&1)"
assert_rc "restore of a missing archive fails" "$?" "1"
out="$(printf 'n\n' | (cd "$FR" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore "$ARCHIVE" 2>&1))"
assert_rc "restore cancels cleanly on 'n'" "$?" "0"
assert_contains "restore cancel message" "$out" "cancelled"
# backup needs a config to snapshot.
NOC="$(mktemp -d "$SANDBOX/noc.XXXXXX")"
cp "$ROOT/VERSION" "$NOC/"
out="$(cd "$NOC" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" backup </dev/null 2>&1)"
assert_rc "backup without a config fails" "$?" "1"
assert_contains "backup no-config message" "$out" "No config.json"

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

# config.json.template is the copy-me starter (referenced by the docs and shipped in the release bundle).
# It must be valid JSON, carry an obvious unreplaced placeholder, and be REJECTED by parse_config unedited
# — so a user can't accidentally deploy the template and mine to a bogus host. (It can drift unnoticed
# otherwise: unlike config.advanced.example.json, nothing else validates it.)
echo "== unit: config.json.template (starter) =="
TPL="$ROOT/config.json.template"
if jq -e . "$TPL" >/dev/null 2>&1; then ok "config.json.template is valid JSON"; else bad "config.json.template is valid JSON" "jq parse failed"; fi
assert_contains "template carries an unreplaced pool placeholder" "$(jq -r '.pools[0].url' "$TPL")" "<YOUR_POOL_HOST>"
TT="$(mktemp -d "$SANDBOX/tpl.XXXXXX")"
cp "$TPL" "$TT/config.json"
out="$( (
    source "$SCRIPT"
    SCRIPT_DIR="$TT"
    CONFIG_JSON="$TT/config.json"
    set +e
    parse_config 2>&1
))"
assert_contains "parse_config rejects the unedited template (no accidental deploy)" "$out" "not a valid hostname"

# ---------------------------------------------------------------------------
echo ""
printf 'rigforge tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
