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
# Suites below run top to bottom (search for 'echo "== '); grouped:
#   parse_config & first-run config · field sanitization · append_once / remove_line
#   config-gen matrix (generic Linux · EPYC · Ryzen X3D · macOS · multi-pool)
#   util/proposed-grub.sh math · GRUB cmdline merge/strip · compile pin · build jobs & workspace
#   command surface (upgrade / help / apply / bench) · macOS process control & login agent
#   full deployment run + idempotency · doctor (health · capping · BIOS · MSR · service)
#   uninstall revert · tune (hill-climb · grid · noise/variance gates · power/efficiency · live/confirm)
#   reservation-aware threads · backup/restore · VERSION & config templates
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

# HARDWARE INDEPENDENCE. The suite must give identical results on ANY machine — a cloud CI VM, a dev
# laptop, or a real mining rig that actually has RAPL / DMI / SMT / reserved HugePages. So point every
# hardware + firmware probe rigforge reads at a non-existent path (or a missing command) by default: a
# test then reads NOTHING from the host's real hardware unless it explicitly supplies a fake. Individual
# tests override these with controlled fakes where they need a specific value. Exported so the black-box
# `bash "$SCRIPT" ...` runs inherit them; per-test `VAR=... run` prefixes and in-subshell sets still win.
NOHW="$SANDBOX/no-hardware" # nothing is created here on purpose — every path below is meant to not exist
export MEMINFO="$NOHW/meminfo"
export MSR_MODULE_DIR="$NOHW/msr-module"
export GOVERNOR_FILE="$NOHW/governor"
export HUGEPAGES_1G_NR="$NOHW/nr_1g"
export HUGEPAGES_1G_DIR="$NOHW/hugepages1G"
export CPUFREQ_MAX="$NOHW/cpufreq_max"
export CPU_SYSFS="$NOHW/cpu"
export RAPL_DIR="$NOHW/powercap"
export DMI_DIR="$NOHW/dmi"
export SMT_CONTROL="$NOHW/smt"
export THERMAL_ZONE="$NOHW/thermal"
export CPUINFO="$NOHW/cpuinfo"            # util/proposed-grub.sh
export DMIDECODE="$NOHW/dmidecode-absent" # absolute path that isn't an executable -> `command -v` fails
export RDMSR_BIN="$NOHW/rdmsr-absent"
# `setup` installs the `rigforge` command as a symlink in BIN_DIR. Redirect it at a real, writable
# sandbox dir (NOT $NOHW, which mustn't exist) so any black-box `setup` run links HERE — never into the
# host's real /usr/local/bin. Tests that assert on the link either read this dir or override it locally.
export BIN_DIR="$SANDBOX/usr-local-bin"
mkdir -p "$BIN_DIR"

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
# NUMA nodes can exceed sockets (NPS / L3-as-NUMA on EPYC); default to the socket count so existing
# single-value tests are unchanged, and let STUB_NUMA_NODES drive the multi-NUMA cases.
echo "NUMA node(s):          ${STUB_NUMA_NODES:-${STUB_SOCKETS:-1}}"
# Modern lscpu (as root) also prints a DMI-derived BIOS line; the model parse must NOT pick this up.
echo "BIOS Model name:       ${STUB_CPU_MODEL:-Generic CPU}            Unknown CPU @ 4.2GHz"
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
    # envsubst stub: substitute exactly the vars the systemd templates use (gettext may be absent on macOS).
    cat >"$bin/envsubst" <<'EOF'
#!/usr/bin/env bash
sed -e "s|\$BUILD_DIR|${BUILD_DIR:-}|g" -e "s|\$CPUPOWER_PATH|${CPUPOWER_PATH:-}|g" -e "s|\$WORKER_ROOT|${WORKER_ROOT:-}|g" \
    -e "s|\$SERVICE_NAME|${SERVICE_NAME:-}|g" -e "s|\$RIGFORGE_OPERATOR|${RIGFORGE_OPERATOR:-}|g" \
    -e "s|\$SCRIPT_DIR|${SCRIPT_DIR:-}|g" -e "s|\$AUTOTUNE_ONCALENDAR|${AUTOTUNE_ONCALENDAR:-}|g" \
    -e "s|\$AUTOTUNE_TARGET|${AUTOTUNE_TARGET:-}|g" -e "s|\$API_BIND|${API_BIND:-}|g" -e "s|\$API_PORT|${API_PORT:-}|g"
EOF
    # No-op recorders / package managers. dpkg/rpm/pacman exit 0 so "is this dep installed?" is always yes.
    local cmd
    for cmd in make cmake systemctl modprobe mount umount mountpoint update-grub apt-get apt-cache dpkg dnf rpm pacman brew cpupower journalctl python3; do
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
    # curl stub for the worker-API probe: record the invocation (so a test can assert whether an
    # Authorization header was passed) and emit an XMRig-style /2/summary body. Exits 0 like a real 200.
    cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >> "${CURL_LOG:-/dev/null}"
printf '{"hashrate":{"total":[%s,0,0]}}\n' "${STUB_API_HR:-1234.5}"
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
        printf '%s' "${!var}"
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
# A Pithead stratum password (p2pool.stratum_password) flows through verbatim as the pool pass — the
# cross-repo contract for an authenticated stack. Covers an auto-generated hex secret and a literal
# with the punctuation Pithead allows (. _ : @ -); both are valid XMRig passes.
c="$(mkconf p_pw "{ \"pools\": [{\"url\":\"stack:3333\",\"pass\":\"a1b2c3d4e5f6a7b8\"}] }")"
assert_eq "stratum password (hex) kept as pass" "$(PJ "$c" | jq -r '.[0].pass')" "a1b2c3d4e5f6a7b8"
c="$(mkconf p_pw2 "{ \"pools\": [{\"url\":\"stack:3333\",\"pass\":\"Stack_Pass.1:2@3-x\"}] }")"
assert_eq "stratum password (symbols) kept as pass" "$(PJ "$c" | jq -r '.[0].pass')" "Stack_Pass.1:2@3-x"
# (a pass with a space is rejected — see the validation block below.)
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
# #115: tls-fingerprint passes through verbatim (either case) and the key is absent when unset/null,
# so pre-#115 configs keep producing byte-identical POOLS_JSON.
c="$(mkconf p_fp "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}] }")"
assert_eq "tls-fingerprint passed through (#115)" "$(PJ "$c" | jq -r '.[0]."tls-fingerprint"')" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
c="$(mkconf p_fpu "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}] }")"
assert_eq "uppercase fingerprint accepted verbatim (#115)" "$(PJ "$c" | jq -r '.[0]."tls-fingerprint"')" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
c="$(mkconf p_nofp "{ \"pools\": [{\"url\":\"h:3333\"}] }")"
assert_eq "no fingerprint key when unset (#115)" "$(PJ "$c" | jq -c '.[0] | has("tls-fingerprint")')" "false"
c="$(mkconf p_nullfp "{ \"pools\": [{\"url\":\"h:3333\",\"tls-fingerprint\":null}] }")"
assert_eq "null fingerprint = absent (#115)" "$(PJ "$c" | jq -c '.[0] | has("tls-fingerprint")')" "false"
# Index alignment: a pin on the SECOND pool must land on the second pool, not the first.
c="$(mkconf p_fp2 "{ \"pools\": [{\"url\":\"plain:3333\"}, {\"url\":\"sec:443\",\"tls\":true,\"tls-fingerprint\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}] }")"
assert_eq "second-pool fingerprint stays on the second pool (#115)" "$(PJ "$c" | jq -c '[(.[0] | has("tls-fingerprint")), (.[1]."tls-fingerprint" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]')" "[false,true]"
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
# #115: fingerprint validation — wrong length, colon-separated openssl form, non-string, and the
# pin-without-tls footgun all fail fast; a valid pin + tls:true parses.
c="$(mkconf p_fpshort "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":\"abc123\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "short fingerprint rejected (#115)" "$?" "1"
c="$(mkconf p_fpcolon "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":\"AB:CD:EF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "colon-separated fingerprint rejected (#115)" "$?" "1"
c="$(mkconf p_fpbool "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":true}] }")"
parse_rc "$c" "$ROOT"
assert_rc "non-string fingerprint rejected (#115)" "$?" "1"
c="$(mkconf p_fpnotls "{ \"pools\": [{\"url\":\"h:443\",\"tls-fingerprint\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "fingerprint without tls:true rejected (#115)" "$?" "1"
c="$(mkconf p_fpok "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "valid fingerprint + tls accepted (#115)" "$?" "0"
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
# #135: catastrophic-but-syntactically-valid HOME_DIR values fail closed before any sudo rm -rf.
c="$(mkconf hd_slash "{ \"HOME_DIR\": \"//\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "HOME_DIR // (root) rejected (#135)" "$?" "1"
c="$(mkconf hd_etc "{ \"HOME_DIR\": \"/etc/\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "HOME_DIR /etc rejected (#135)" "$?" "1"
c="$(mkconf hd_home "{ \"HOME_DIR\": \"/home\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "bare /home HOME_DIR rejected (#135)" "$?" "1"
# ACCESS_TOKEN character set.
c="$(mkconf at_bad "{ \"ACCESS_TOKEN\": \"bad token\", $POOL }")"
parse_rc "$c" "$ROOT"
assert_rc "ACCESS_TOKEN with space rejected" "$?" "1"

# #138: unknown keys warn (never error) with a case-insensitive did-you-mean; `_`-prefixed keys and
# the reserved RIG_NAME never warn; warnings carry key NAMES only, never values.
lint_out() { # <config> -> parse_config's stderr+stdout
    (
        source "$SCRIPT"
        CONFIG_JSON="$1"
        SCRIPT_DIR="$ROOT"
        set +e
        parse_config 2>&1
    )
}
c="$(mkconf lint_typo "{ $POOL, \"donation\": 5 }")"
out="$(lint_out "$c")"
assert_contains "typo'd key warns with a did-you-mean (#138)" "$out" 'unknown key "donation" is ignored — did you mean "DONATION"?'
assert_contains "warnings end with the reference pointer (#138)" "$out" "See config.reference.json"
(
    source "$SCRIPT"
    CONFIG_JSON="$c"
    set +e
    parse_config >/dev/null 2>&1
)
assert_rc "unknown keys never fail the parse (#138)" "$?" "0"
c="$(mkconf lint_tok "{ $POOL, \"ACESS_TOKEN\": \"supersecret-value\" }")"
out="$(lint_out "$c")"
assert_contains "misspelled security key is named (#138)" "$out" 'unknown key "ACESS_TOKEN"'
assert_absent "the value never appears in the warning (#138)" "$out" "supersecret-value"
c="$(mkconf lint_pool "{ \"pools\": [{\"url\":\"h:3333\",\"keepAlive\":true}] }")"
out="$(lint_out "$c")"
assert_contains "pool-field typo warns with a did-you-mean (#138)" "$out" 'unknown pool field "keepAlive" is ignored — did you mean "keepalive"?'
c="$(mkconf lint_quiet "{ $POOL, \"_note\": \"comment\", \"RIG_NAME\": \"rig9\", \"api\": \"enabled\" }")"
out="$(lint_out "$c")"
assert_absent "underscore keys, RIG_NAME, and known keys stay quiet (#138)" "$out" "unknown key"
c="$(mkconf lint_novel "{ $POOL, \"frobnicate\": 1 }")"
out="$(lint_out "$c")"
assert_contains "novel key warns without a hint (#138)" "$out" 'unknown key "frobnicate" is ignored.'
assert_absent "no did-you-mean when nothing is close (#138)" "$out" "did you mean"

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
# config-gen). The HTTP API token is OPTIONAL and defaults to empty (an open, read-only API — the
# stock Pithead no-auth contract); an explicit ACCESS_TOKEN turns auth on.
echo "== unit: rig label = pool user; API token off by default (#22) =="
c="$(mkconf userset "{ \"pools\": [{\"url\":\"h:3333\",\"user\":\"rig-07\"}] }")"
assert_eq "pool user honoured" "$(parse_and_print "$c" "$ROOT" POOLS_JSON | jq -r '.[0].user')" "rig-07"
assert_eq "token empty (open API) by default" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" ""
c="$(mkconf userblank "{ $POOL }")"
assert_eq "token stays empty even when user blank" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" ""
c="$(mkconf usertok "{ \"pools\": [{\"url\":\"h:3333\",\"user\":\"rig-07\"}], \"ACCESS_TOKEN\": \"custom\" }")"
assert_eq "explicit token turns auth on" "$(parse_and_print "$c" "$ROOT" ACCESS_TOKEN)" "custom"

echo "== unit: parse_config — error paths =="
printf '{ not json ' >"$SANDBOX/bad.json"
parse_rc "$SANDBOX/bad.json" "$ROOT"
assert_rc "invalid JSON rejected" "$?" "1"
# #audit: a MISSING config (e.g. `apply`/`tune` before `setup`) is a clearer error than "not valid JSON".
miss="$( (
    source "$SCRIPT"
    CONFIG_JSON="$SANDBOX/nope-missing.json"
    set +e
    parse_config 2>&1
))"
assert_contains "missing config -> 'run setup first' (not bad-JSON) (#audit)" "$miss" "No configuration at"

# Interactive first-run: ensure_config_exists prompts (y, then the host:port pool URL) and writes a
# minimal { "pools": [{ "url": ... }] }. A blank, port-less, or host-less URL aborts and writes nothing
# (validating the host before the write keeps a broken config off disk so the prompt isn't suppressed).
echo "== unit: ensure_config_exists interactive first-run =="
ecd="$(mktemp -d "$SANDBOX/ec.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$ecd/config.json"
    set +eu
    printf 'y\nstack.lan:3333\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "first-run writes minimal pools config" "$(jq -c '.pools' "$ecd/config.json" 2>/dev/null)" '[{"url":"stack.lan:3333"}]'
# #131: the operator hand-edits this file to add a wallet/token before the first `apply`, so it must
# be owner-only from creation — not only after generate_xmrig_config's later chmod.
if [ "$(uname -s)" = Darwin ]; then ec_mode="$(stat -f '%Lp' "$ecd/config.json")"; else ec_mode="$(stat -c '%a' "$ecd/config.json")"; fi
assert_eq "bootstrap config.json is owner-only (0600) (#131)" "$ec_mode" "600"
# #113: the optional stratum-password prompt writes pools[0].pass; EOF/Enter at the prompt skips it
# (the run above hit EOF there, so its minimal config must stay byte-identical to pre-#113).
assert_eq "empty pass writes NO pass key (#113)" "$(jq -c '.pools[0] | has("pass")' "$ecd/config.json" 2>/dev/null)" "false"
ecp="$(mktemp -d "$SANDBOX/ecp.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$ecp/config.json"
    set +eu
    printf 'y\nstack.lan:3333\nS3cret.pass\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "first-run writes the entered stratum pass (#113)" "$(jq -r '.pools[0].pass' "$ecp/config.json" 2>/dev/null)" "S3cret.pass"
assert_eq "pass prompt keeps the URL intact (#113)" "$(jq -r '.pools[0].url' "$ecp/config.json" 2>/dev/null)" "stack.lan:3333"
ecb="$(mktemp -d "$SANDBOX/ecb.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$ecb/config.json"
    set +eu
    printf 'y\nstack.lan:3333\nbad pass\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "invalid stratum pass writes no config (#113)" "$([ -f "$ecb/config.json" ] && echo yes || echo no)" "no"
for bad in '' 'stack.lan' ':3333' '[zz]:3333'; do
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
# Security: the live config holds the pool/wallet + API token, so it must be owner-only (0600), not the
# world-readable 0644 a root jq redirect would otherwise leave. stat differs GNU vs BSD, so branch on OS.
if [ "$(uname -s)" = Darwin ]; then cfg_mode="$(stat -f '%Lp' "$cfg")"; else cfg_mode="$(stat -c '%a' "$cfg")"; fi
assert_eq "generated config is owner-only (0600)" "$cfg_mode" "600"
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
# from the stack host at http://<rig>:8080 (read-only; OPEN by default) — localhost would break that
# integration (issue #24). This generic profile sets an explicit ACCESS_TOKEN (tok123), so the
# access-token assertion below covers the opt-in auth path; the open default is asserted separately.
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

echo "== config-gen: open API by default (no ACCESS_TOKEN) =="
# Default (ACCESS_TOKEN unset/empty): the read-only API is left OPEN — access-token renders as null.
# This is the stock Pithead no-auth contract (the dashboard probes :8080 with no Authorization);
# setting ACCESS_TOKEN turns Bearer auth back on (the explicit-token render is asserted above).
export STUB_CPU_MODEL="Intel(R) Xeon(R) Silver 4310" STUB_NPROC=8 STUB_HOSTNAME=rigbox
d_open="$(mktemp -d "$SANDBOX/open.XXXXXX")"
(
    cd "$d_open" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$d_open"
    POOL_ADDRESS=myrig.local
    POOLS_JSON='[{"url":"myrig.local:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
    ACCESS_TOKEN=""
    DONATION=1
    LOGROTATE_DIR="$d_open"
    set +e
    PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
)
cfg_open="$d_open/config.json"
assert_eq "open API by default: access-token null" "$(J "$cfg_open" '.http."access-token"')" "null"
assert_eq "open API by default: still restricted (read-only)" "$(J "$cfg_open" '.http.restricted')" "true"

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

# #115: a pinned TLS pool's fingerprint survives config generation verbatim (generate only fills user).
echo "== config-gen: tls-fingerprint passthrough (#115) =="
export STUB_CPU_MODEL="Intel(R) Xeon" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1 SIM_POOLS='[{"url":"sec:443","user":"","pass":"x","keepalive":true,"tls":true,"enabled":true,"tls-fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
d="$(gen_config)"
cfg="$d/config.json"
unset SIM_POOLS STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME
assert_eq "tls-fingerprint survives generation (#115)" "$(J "$cfg" '.pools[0]."tls-fingerprint"')" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# #21/#24: fields that must survive generate_xmrig_config unmangled. parse_config-side acceptance is
# covered above; here we prove the EMITTED config.json (what XMRig actually loads) preserves them — a jq
# re-emit is exactly where a bracketed IPv6 host or a lone TLS flag could get dropped or reshaped.
echo "== config-gen: IPv6 host / single-pool TLS / empty-token round-trip =="
export STUB_CPU_MODEL="Intel(R) Xeon" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1
SIM_POOLS='[{"url":"[2001:db8::1]:3333","user":"","pass":"x","keepalive":true,"tls":true,"enabled":true}]'
d="$(gen_config)"
cfg="$d/config.json"
unset SIM_POOLS
assert_eq "bracketed IPv6 pool url round-trips unmangled" "$(J "$cfg" '.pools[0].url')" "[2001:db8::1]:3333"
assert_eq "single-pool tls:true reaches config.json" "$(J "$cfg" '.pools[0].tls')" "true"
# An empty ACCESS_TOKEN must emit JSON `null` (auth-disabled), not "" or the string "null". gen_config's
# `${SIM_TOK:-tok123}` can't express an empty token, so drive generate_xmrig_config directly.
dn="$(mktemp -d "$SANDBOX/tok.XXXXXX")"
(
    cd "$dn" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$dn"
    POOL_ADDRESS=myrig.local
    POOLS_JSON='[{"url":"myrig.local:3333","user":"r","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
    ACCESS_TOKEN=""
    DONATION=1
    LOGROTATE_DIR="$dn"
    set +e
    PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
)
assert_eq "empty token emits JSON null (not \"\" or \"null\")" "$(J "$dn/config.json" '.http."access-token" == null')" "true"
unset STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME

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

# --- NUMA-aware 1G sizing: RandomX keeps a NUMA-LOCAL dataset copy per node, so 1G pages scale with NUMA
# nodes, NOT sockets. A single-socket EPYC with 4 NUMA nodes needs 12 (3*4), not 3 — the bug that starved
# 3 of 4 nodes after a reboot. (256 MiB L3 -> threads 128 -> 2M scratchpads 128+128+10 = 266.)
out="$(PATH="$STUBS:$PATH" STUB_L3="256 MiB" STUB_SOCKETS=1 STUB_NUMA_NODES=4 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: 1G scales with NUMA nodes not sockets (1S/4N -> 12)" "$out" "hugepagesz=1G hugepages=12"
assert_contains "grub: 2M scratchpads are per-thread total, not NUMA-multiplied" "$out" "hugepagesz=2M hugepages=266"
# Verbose mode reports the NUMA node count it sized against (distinct from sockets).
out="$(PATH="$STUBS:$PATH" STUB_L3="256 MiB" STUB_SOCKETS=1 STUB_NUMA_NODES=4 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG")"
assert_contains "grub: verbose reports NUMA node count" "$out" "NUMA Nodes:    4"
assert_contains "grub: verbose still reports sockets separately" "$out" "CPU Sockets:   1"
# The pure-2M fallback (no pdpe1gb) also holds a dataset copy per node: 1168*4 + 128 + 50 = 4850.
out="$(PATH="$STUBS:$PATH" STUB_L3="256 MiB" STUB_SOCKETS=1 STUB_NUMA_NODES=4 CPUINFO="$SANDBOX/cpuinfo_no1g" bash "$PG" -q)"
assert_contains "grub: 2M fallback dataset scales per NUMA node (1168*4+...)" "$out" "hugepages=4850"
# Detection fallbacks when lscpu lacks a "NUMA node(s)" line: count sysfs nodes, then sockets, then 1.
mkdir -p "$SANDBOX/nonuma" "$SANDBOX/numa4/node0" "$SANDBOX/numa4/node1" "$SANDBOX/numa4/node2" "$SANDBOX/numa4/node3" "$SANDBOX/numa_empty"
cat >"$SANDBOX/nonuma/lscpu" <<'EOF'
#!/usr/bin/env bash
echo "Model name:            EPYC test"
echo "L3 cache:              ${STUB_L3:-256 MiB}"
echo "Socket(s):             ${STUB_SOCKETS:-1}"
EOF
chmod +x "$SANDBOX/nonuma/lscpu"
out="$(PATH="$SANDBOX/nonuma:$STUBS:$PATH" STUB_L3="256 MiB" STUB_SOCKETS=1 NODE_SYS="$SANDBOX/numa4" CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: NUMA from sysfs node count when lscpu silent (4 -> 12)" "$out" "hugepagesz=1G hugepages=12"
out="$(PATH="$SANDBOX/nonuma:$STUBS:$PATH" STUB_L3="256 MiB" STUB_SOCKETS=2 NODE_SYS="$SANDBOX/numa_empty" CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: NUMA falls back to sockets when undetectable (2 -> 6)" "$out" "hugepagesz=1G hugepages=6"

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

# #134: values interpolated into the GRUB sed REPLACEMENT must have \ & | escaped, or a legal
# pre-existing kernel param corrupts /etc/default/grub. The escaper is pure, so test it directly,
# then prove a real (non-in-place, so BSD-sed-safe) rewrite round-trips the characters literally.
echo "== unit: _sed_escape_replacement protects the GRUB rewrites (#134) =="
esc="$(
    source "$SCRIPT"
    _sed_escape_replacement 'quiet memmap=4G&2M weird\param a|b'
)"
assert_eq "escapes backslash, ampersand and pipe" "$esc" 'quiet memmap=4G\&2M weird\\param a\|b'
esc2="$(
    source "$SCRIPT"
    _sed_escape_replacement 'quiet splash'
)"
assert_eq "plain cmdline passes through unchanged" "$esc2" 'quiet splash'
GESC="$(mktemp -d "$SANDBOX/grubesc.XXXXXX")"
printf 'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="old"\n' >"$GESC/grub"
rewritten="$(
    source "$SCRIPT"
    val='quiet memmap=4G&2M weird\param a|b hugepages=100'
    sed "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$(_sed_escape_replacement "$val")\"|" "$GESC/grub"
)"
assert_contains "rewrite keeps & literal" "$rewritten" 'memmap=4G&2M'
assert_contains "rewrite keeps backslash literal" "$rewritten" 'weird\param'
assert_contains "rewrite keeps | literal" "$rewritten" 'a|b'
assert_contains "other lines untouched" "$rewritten" 'GRUB_TIMEOUT=5'

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
# The mismatch path also drops the clone (rm -rf xmrig) so the NEXT run starts clean instead of tripping
# git's "destination 'xmrig' already exists and is not empty" (#18). Assert the dir is gone — a regression
# that removed the cleanup would still print the mismatch error and pass every assertion above.
pc="$(mktemp -d "$SANDBOX/pinclean.XXXXXX")"
(
    cd "$pc" || exit 1
    source "$SCRIPT"
    OS_TYPE="$(uname -s)"
    DONATION=1
    WORKER_ROOT="$pc"
    export XMRIG_COMMIT="pinnedsha000000000000000000000000000000"
    export STUB_GIT_HEAD="tamperedsha1111111111111111111111111111"
    set +e
    PATH="$STUBS:$PATH" compile_xmrig >/dev/null 2>&1
)
assert_eq "commit mismatch removes the clone so the next run starts clean (#18)" "$([ -e "$pc/xmrig" ] && echo present || echo gone)" "gone"

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
# The `max < 1 -> 1` floor: a ~1.5 GB host computes max = 1/2 = 0, which must clamp to 1 job (not 0, which
# would make `make -j0` fail). The 2 GB case above lands on max=1 already, so it never exercises this clamp.
assert_eq "sub-2GB host floors to 1 job (never 0)" "$(
    source "$SCRIPT"
    MEMINFO="$(mk_meminfo 1572864 mi1_5)" compute_build_jobs 8
)" "1"

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
# #141: the binary's build-time SHA-256 joins the check — mismatch self-heals via rebuild, a
# missing record (older build) stays "built" so fleets aren't forced into a recompile.
(
    source "$SCRIPT"
    WORKER_ROOT="$b"
    XMRIG_COMMIT=ABC
    _sha256 "$b/xmrig/build/xmrig" >"$b/xmrig/.rigforge-sha256"
    set +e
    xmrig_already_built
)
assert_rc "matching commit + matching sha -> built (#141)" "$?" "0"
printf 'tampered' >>"$b/xmrig/build/xmrig"
(
    source "$SCRIPT"
    WORKER_ROOT="$b"
    XMRIG_COMMIT=ABC
    set +e
    xmrig_already_built
)
assert_rc "changed binary -> rebuild (self-healing) (#141)" "$?" "1"
rm -f "$b/xmrig/.rigforge-sha256"
(
    source "$SCRIPT"
    WORKER_ROOT="$b"
    XMRIG_COMMIT=ABC
    set +e
    xmrig_already_built
)
assert_rc "no sha record (legacy build) -> still built (#141)" "$?" "0"
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
assert_contains "upgrade nudges to re-tune when overrides exist (#10)" "$out" "re-run 'sudo"
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
# #audit A2/A4: assert the verbs not only exit 0 but print their success message (which is `&&`-gated on
# systemctl SUCCEEDING — an empty stub-passing function would not print it) AND record the matching
# systemctl/journalctl call. Previously these asserted rc only, so a no-op `return 0` would have passed.
for verb in start stop restart enable disable status logs; do
    clog="$U/svc-$verb.calls"
    : >"$clog"
    out="$(cd "$U" && PATH="$STUBS:$PATH" CALL_LOG="$clog" RIGFORGE_HOME="$PWD" bash "$SCRIPT" "$verb" </dev/null 2>&1)"
    assert_rc "$verb exits 0 (Linux + stubbed systemd)" "$?" "0"
    case "$verb" in
    start) assert_contains "start prints its message" "$out" "Started xmrig" ;;
    stop) assert_contains "stop prints its message" "$out" "Stopped xmrig" ;;
    restart) assert_contains "restart prints its message" "$out" "Restarted xmrig" ;;
    enable) assert_contains "enable prints its message" "$out" "Enabled xmrig (starts on boot)" ;;
    disable) assert_contains "disable prints its message" "$out" "Disabled xmrig (won't start on boot)" ;;
    esac
    case "$verb" in
    logs) assert_contains "logs invokes journalctl" "$(cat "$clog")" "journalctl] -u xmrig -f" ;;
    *) assert_contains "$verb invokes systemctl $verb" "$(cat "$clog")" "systemctl] $verb" ;;
    esac
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

# #95: a top-level `apply` reports the configured periodic-autotune target so the operator can see what
# the nightly run optimizes for. Linux-only (the timer is Linux-only). Drive the notice directly with
# OS_TYPE forced so the assertion is host-independent (the macOS suite runs this same file).
echo "== unit: apply reports the autotune target (#95) =="
apply_notice() { (
    source "$SCRIPT"
    OS_TYPE="${2:-Linux}"
    AUTOTUNE_MODE="$1"
    set +e
    _autotune_apply_notice 2>&1
); }
assert_contains "apply notice names the efficiency target (#95)" "$(apply_notice efficiency)" "efficiency"
assert_contains "apply notice names the performance target (#95)" "$(apply_notice performance)" "performance"
assert_contains "apply notice reports disabled (#95)" "$(apply_notice disabled)" "disabled"
assert_eq "apply notice is silent on non-Linux (#95)" "$(apply_notice efficiency Darwin)" ""

# #95 (regression): `apply` RECONCILES the autotune timer with config — so changing the target and running
# apply actually re-bakes the installed unit. Previously apply only PRINTED the new target while the timer
# kept the old one (config said efficiency, but tune --history still read the stale performance unit).
echo "== black-box: apply reconciles the autotune timer to config (#95) =="
ARC="$(mktemp -d "$SANDBOX/arec.XXXXXX")"
mkdir -p "$ARC/systemd"
cp "$ROOT/systemd/rigforge-autotune.service.template" "$ROOT/systemd/rigforge-autotune.timer.template" "$ARC/systemd/"
# A stale unit from a prior setup, baked as performance — the exact state behind the reported bug.
printf 'Environment=AUTOTUNE_TARGET=perf\n' >"$ARC/systemd/rigforge-autotune.service"
printf 'OnCalendar=monthly\n' >"$ARC/systemd/rigforge-autotune.timer"
arc_apply() {
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ARC"
        SYSTEMD_DIR="$ARC/systemd"
        SERVICE_NAME=xmrig
        REAL_USER=rfop
        AUTOTUNE_MODE=efficiency
        AUTOTUNE_TARGET=efficiency
        _apply_runtime() { :; } # skip the heavy config regen + restart; we're testing the reconcile
        sudo() { "$@"; }        # install_autotune writes the unit via sudo tee
        set +e
        PATH="$STUBS:$PATH" apply 2>&1
    )
}
arc_out="$(arc_apply)"
assert_contains "apply re-bakes the stale timer to the configured target (#95)" "$(cat "$ARC/systemd/rigforge-autotune.service")" "AUTOTUNE_TARGET=efficiency"
assert_contains "apply reports the reconciled target (#95)" "$arc_out" "Periodic autotune: efficiency"

# #99: apply is the config-change path for the sister API too — toggling `api` on/off via apply must
# install/remove the socket units without a full setup.
echo "== black-box: apply reconciles the sister API to config (#99) =="
cp "$ROOT/systemd/rigforge-api.service.template" "$ROOT/systemd/rigforge-api-refresh.service.template" "$ROOT/systemd/rigforge-api-refresh.timer.template" "$ARC/systemd/"
arc_api() { # <enabled|disabled>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ARC"
        SYSTEMD_DIR="$ARC/systemd"
        SERVICE_NAME=xmrig
        REAL_USER=rfop
        AUTOTUNE_MODE=disabled
        API_MODE="$1"
        API_BIND=0.0.0.0
        API_PORT=8081
        _apply_runtime() { :; }
        sudo() { "$@"; }
        set +e
        PATH="$STUBS:$PATH" apply 2>&1
    )
}
arc_api enabled >/dev/null
assert_eq "apply with api enabled installs the server (#99/#164)" "$([ -f "$ARC/systemd/rigforge-api.service" ] && echo y || echo n)" "y"
assert_eq "apply with api enabled installs the refresh timer (#99/#164)" "$([ -f "$ARC/systemd/rigforge-api-refresh.timer" ] && echo y || echo n)" "y"
arc_api disabled >/dev/null
assert_eq "apply with api disabled removes the server (#99)" "$([ -f "$ARC/systemd/rigforge-api.service" ] && echo y || echo n)" "n"
assert_eq "apply with api disabled removes the refresh timer (#99)" "$([ -f "$ARC/systemd/rigforge-api-refresh.timer" ] && echo y || echo n)" "n"

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

# The periodic-autotune systemd timer (#95): a non-"disabled" mode (performance|efficiency) writes the
# .service + .timer and bakes the target into the unit; "disabled" (files present) removes them — both via
# the SYSTEMD_DIR override the real units use.
echo "== black-box: install_autotune timer enable/disable (#95 tri-state) =="
AT="$(mktemp -d "$SANDBOX/at.XXXXXX")"
mkdir -p "$AT/systemd"
# install_autotune renders the unit TEMPLATES from systemd/ (like xmrig.service), so they must be present.
cp "$ROOT/systemd/rigforge-autotune.service.template" "$ROOT/systemd/rigforge-autotune.timer.template" "$AT/systemd/"
run_autotune() { # <disabled|performance|efficiency> [oncalendar]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$AT"
        SYSTEMD_DIR="$AT/systemd"
        REAL_USER=rfop # the operator captured at setup time; baked into the service unit
        AUTOTUNE_MODE="$1"
        case "$1" in efficiency) AUTOTUNE_TARGET=efficiency ;; *) AUTOTUNE_TARGET=perf ;; esac
        [ -n "${2:-}" ] && AUTOTUNE_ONCALENDAR="$2" # else leave unset to exercise the product default
        set +e
        PATH="$STUBS:$PATH" install_autotune 2>&1
    )
}
out="$(run_autotune performance hourly)"
assert_eq "autotune enable writes the .timer" "$([ -f "$AT/systemd/rigforge-autotune.timer" ] && echo y || echo n)" "y"
assert_eq "autotune enable writes the .service" "$([ -f "$AT/systemd/rigforge-autotune.service" ] && echo y || echo n)" "y"
assert_contains "autotune timer honours the OnCalendar override" "$(cat "$AT/systemd/rigforge-autotune.timer")" "OnCalendar=hourly"
assert_contains "autotune service invokes the autotune verb" "$(cat "$AT/systemd/rigforge-autotune.service")" "rigforge.sh autotune"
# #reown: the service bakes in the operator so the root timer hands files back to them (not to root).
assert_contains "autotune service bakes in RIGFORGE_OPERATOR (#reown)" "$(cat "$AT/systemd/rigforge-autotune.service")" "RIGFORGE_OPERATOR=rfop"
# #95: the chosen target is baked into the unit so scheduled runs match what the operator configured.
assert_contains "performance mode bakes AUTOTUNE_TARGET=perf (#95)" "$(cat "$AT/systemd/rigforge-autotune.service")" "AUTOTUNE_TARGET=perf"
out="$(run_autotune efficiency)" # no OnCalendar -> product default
assert_contains "efficiency mode bakes AUTOTUNE_TARGET=efficiency (#95)" "$(cat "$AT/systemd/rigforge-autotune.service")" "AUTOTUNE_TARGET=efficiency"
# #95: the default cadence is monthly (not daily) — once the tune converges it's stable, so re-tuning is
# event-driven (on upgrade); the timer is just a slow safety net.
assert_contains "default autotune cadence is monthly, not daily (#95)" "$(cat "$AT/systemd/rigforge-autotune.timer")" "OnCalendar=monthly"
out="$(run_autotune disabled)"
assert_eq "autotune disable removes the .timer" "$([ -f "$AT/systemd/rigforge-autotune.timer" ] && echo y || echo n)" "n"
assert_eq "autotune disable removes the .service" "$([ -f "$AT/systemd/rigforge-autotune.service" ] && echo y || echo n)" "n"

# #95: the tri-state `autotune` value normalizes to a mode (+ a perf|efficiency target). Legacy booleans
# still map (true->performance, false->disabled); an unknown value hard-errors so a typo can't silently
# disable scheduled tuning.
echo "== unit: parse_config — autotune tri-state (#95) =="
at_mode() { parse_and_print "$1" "$ROOT" AUTOTUNE_MODE; }
at_tgt() { parse_and_print "$1" "$ROOT" AUTOTUNE_TARGET; }
c="$(mkconf at_dis "{ $POOL, \"autotune\": \"disabled\" }")"
assert_eq "autotune disabled -> mode disabled" "$(at_mode "$c")" "disabled"
c="$(mkconf at_perf "{ $POOL, \"autotune\": \"performance\" }")"
assert_eq "autotune performance -> mode performance" "$(at_mode "$c")" "performance"
assert_eq "autotune performance -> target perf" "$(at_tgt "$c")" "perf"
c="$(mkconf at_eff "{ $POOL, \"autotune\": \"efficiency\" }")"
assert_eq "autotune efficiency -> mode efficiency" "$(at_mode "$c")" "efficiency"
assert_eq "autotune efficiency -> target efficiency" "$(at_tgt "$c")" "efficiency"
c="$(mkconf at_def "{ $POOL }")"
assert_eq "autotune omitted -> default disabled" "$(at_mode "$c")" "disabled"
c="$(mkconf at_true "{ $POOL, \"autotune\": true }")"
assert_eq "legacy autotune true -> performance" "$(at_mode "$c")" "performance"
c="$(mkconf at_false "{ $POOL, \"autotune\": false }")"
assert_eq "legacy autotune false -> disabled" "$(at_mode "$c")" "disabled"
c="$(mkconf at_bad "{ $POOL, \"autotune\": \"turbo\" }")"
parse_rc "$c" "$ROOT" && at_rc=0 || at_rc=$?
assert_eq "invalid autotune value hard-errors (#95)" "$([ "${at_rc:-0}" -ne 0 ] && echo errored || echo ok)" "errored"

# #95: the autotune TARGET decides the winner. Two modes where raw-fastest != most-efficient:
#   mode0 = 1000 H/s @ 100 W (10.0 H/s/W) ; mode1 = 1100 H/s @ 125 W (8.8 H/s/W).
# perf must pick mode1 (raw fastest); efficiency must keep mode0 (best H/s/W). The stubbed API + power
# read the active prefetch mode from the overrides file the sweep rewrites, so each mode reports its pair.
echo "== black-box: autotune ranks by target (#95) =="
ATD="$(mktemp -d "$SANDBOX/atd.XXXXXX")"
mkdir -p "$ATD/worker" "$ATD/no-rapl"
ovf="$ATD/worker/tune-overrides.json"
autotune_decide() { # <target> -> final prefetch mode
    printf '{"randomx":{"scratchpad_prefetch_mode":0}}\n' >"$ovf"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        WORKER_ROOT="$ATD/worker"
        AUTOTUNE_TARGET="$1"
        AUTOTUNE_MODES="0 1"
        AUTOTUNE_SAMPLES=1
        AUTOTUNE_INTERVAL=0
        AUTOTUNE_WARMUP=0
        AUTOTUNE_MARGIN=0.001
        API_CMD='[ "$(jq -r ".randomx.scratchpad_prefetch_mode" "'"$ovf"'")" = 1 ] && echo 1100 || echo 1000'
        TUNE_POWER_CMD='[ "$(jq -r ".randomx.scratchpad_prefetch_mode" "'"$ovf"'")" = 1 ] && echo 125 || echo 100'
        parse_config() { :; }   # keep the test's WORKER_ROOT/target; skip real config parsing
        _apply_runtime() { :; } # autotune applies each mode via _apply_runtime; no real restart
        sudo() { "$@"; }        # _autotune_set_prefetch uses `sudo cp`
        set +e
        PATH="$STUBS:$PATH" autotune >/dev/null 2>&1
    )
    jq -r '.randomx.scratchpad_prefetch_mode' "$ovf"
}
assert_eq "autotune perf picks the raw-fastest mode (#95)" "$(autotune_decide perf)" "1"
assert_eq "autotune efficiency keeps the most-efficient mode (#95)" "$(autotune_decide efficiency)" "0"

# #95: efficiency with NO power source warns and falls back to perf — it still optimizes (raw-fastest),
# rather than dividing by a missing watts reading.
printf '{"randomx":{"scratchpad_prefetch_mode":0}}\n' >"$ovf"
np_out="$(
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        WORKER_ROOT="$ATD/worker"
        AUTOTUNE_TARGET=efficiency
        AUTOTUNE_MODES="0 1"
        AUTOTUNE_SAMPLES=1
        AUTOTUNE_INTERVAL=0
        AUTOTUNE_WARMUP=0
        AUTOTUNE_MARGIN=0.001
        RAPL_DIR="$ATD/no-rapl" # empty -> _rapl_sum returns nothing
        unset TUNE_POWER_CMD
        API_CMD='[ "$(jq -r ".randomx.scratchpad_prefetch_mode" "'"$ovf"'")" = 1 ] && echo 1100 || echo 1000'
        parse_config() { :; }
        _apply_runtime() { :; }
        sudo() { "$@"; }
        set +e
        PATH="$STUBS:$PATH" autotune 2>&1
    )
)"
assert_contains "autotune efficiency warns + falls back without power (#95)" "$np_out" "none available"
assert_eq "autotune efficiency-no-power still picks raw-fastest (#95)" "$(jq -r '.randomx.scratchpad_prefetch_mode' "$ovf")" "1"

# `tune --now` is the on-demand spelling of the autotune engine: it must reach autotune() AND map the
# --perf/--efficiency flag onto the target. Drive the same stubbed sweep as above through `tune --now`.
tune_now_decide() { # <flags...> -> final prefetch mode
    printf '{"randomx":{"scratchpad_prefetch_mode":0}}\n' >"$ovf"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        WORKER_ROOT="$ATD/worker"
        AUTOTUNE_MODES="0 1"
        AUTOTUNE_SAMPLES=1
        AUTOTUNE_INTERVAL=0
        AUTOTUNE_WARMUP=0
        AUTOTUNE_MARGIN=0.001
        API_CMD='[ "$(jq -r ".randomx.scratchpad_prefetch_mode" "'"$ovf"'")" = 1 ] && echo 1100 || echo 1000'
        TUNE_POWER_CMD='[ "$(jq -r ".randomx.scratchpad_prefetch_mode" "'"$ovf"'")" = 1 ] && echo 125 || echo 100'
        parse_config() { :; }                # keep the test's WORKER_ROOT/target; skip real config parsing
        _apply_runtime() { :; }              # no real restart
        sudo() { "$@"; }                     # _autotune_set_prefetch uses `sudo cp`
        _tune_should_elevate() { return 1; } # non-interactive: never re-exec under sudo
        set +e
        PATH="$STUBS:$PATH" tune "$@" >/dev/null 2>&1
    )
    jq -r '.randomx.scratchpad_prefetch_mode' "$ovf"
}
assert_eq "tune --now delegates to autotune; --perf picks raw-fastest" "$(tune_now_decide --now --perf)" "1"
assert_eq "tune --now --efficiency keeps the most-efficient mode" "$(tune_now_decide --now --efficiency)" "0"
# '--short' is the explicit spelling of the default quick '--now' pass — same autotune delegation.
assert_eq "tune --short is the quick prefetch pass (alias of --now)" "$(tune_now_decide --short --perf)" "1"

# `tune --now` drives the live service, so it's Linux-only — refuse with a clear message elsewhere.
tune_now_mac="$(
    (
        source "$SCRIPT"
        OS_TYPE=Darwin
        _tune_should_elevate() { return 1; }
        set +e
        PATH="$STUBS:$PATH" tune --now 2>&1
    )
)"
assert_contains "tune --now is Linux-only off Linux" "$tune_now_mac" "Linux-only"

# #95: the efficiency sampler's RAPL path (efficiency target, no TUNE_POWER_CMD) brackets the live window
# with the CPU-package energy counter. Fake powercap tree; assert the hashrate field comes back (the watts
# field is timing-dependent on a static counter, so we don't pin its value — just that the path ran).
mkdir -p "$ATD/rapl/intel-rapl:0"
printf package-0 >"$ATD/rapl/intel-rapl:0/name"
printf 1000000 >"$ATD/rapl/intel-rapl:0/energy_uj"
printf 9000000 >"$ATD/rapl/intel-rapl:0/max_energy_range_uj"
rapl_smp="$(
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        RAPL_DIR="$ATD/rapl"
        unset TUNE_POWER_CMD
        API_CMD='echo 1234'
        set +e
        _autotune_sample 1 0 efficiency
    )
)"
assert_eq "autotune efficiency sampler reads RAPL + returns the hashrate (#95)" "$(printf '%s' "$rapl_smp" | cut -f1)" "1234"

# #95: `upgrade` re-tunes the new build — the real trigger, since the fastest knobs can shift between
# XMRig versions (the monthly timer is just a slow safety net). Exercise _post_upgrade_retune's decision
# logic with stubbed systemctl (service state), miner readiness, and autotune.
echo "== black-box: upgrade re-tunes the new build (#95) =="
PUR="$(mktemp -d "$SANDBOX/pur.XXXXXX")"
mkdir -p "$PUR/worker"
printf '{}' >"$PUR/worker/tune-overrides.json"
post_retune() { # <mode> <service_active:y|n> <miner_live:y|n>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SERVICE_NAME=xmrig
        WORKER_ROOT="$PUR/worker"
        AUTOTUNE_MODE="$1"
        _ACT="$2"
        _LIVE="$3"
        systemctl() { case "$*" in *is-active*) [ "$_ACT" = y ] ;; *) return 0 ;; esac }
        _wait_miner_live() { [ "$_LIVE" = y ]; }
        autotune() { echo "AUTOTUNE_RAN"; }
        set +e
        _post_upgrade_retune 2>&1
    )
}
o="$(post_retune performance y y)"
assert_contains "upgrade re-tunes when autotune enabled + miner live (#95)" "$o" "Re-tuning the new build"
assert_contains "upgrade actually invokes autotune (#95)" "$o" "AUTOTUNE_RAN"
o="$(post_retune performance y n)"
assert_eq "upgrade does not autotune a cold miner (#95)" "$(printf '%s' "$o" | grep -c AUTOTUNE_RAN)" "0"
assert_contains "upgrade explains the skipped re-tune (#95)" "$o" "skipping the post-upgrade re-tune"
o="$(post_retune disabled y y)"
assert_eq "upgrade does NOT re-tune when autotune disabled (#95)" "$(printf '%s' "$o" | grep -c AUTOTUNE_RAN)" "0"
assert_contains "upgrade warns to re-tune manually when disabled (#95)" "$o" "carried over from the previous build"
o="$(post_retune performance n y)"
assert_eq "upgrade does NOT re-tune when the service is inactive (#95)" "$(printf '%s' "$o" | grep -c AUTOTUNE_RAN)" "0"

# #95: _wait_miner_live polls the API until a live hashrate appears, so a freshly-restarted miner (still
# allocating the RandomX dataset) is warm before the post-upgrade re-tune measures it.
echo "== unit: _wait_miner_live (#95) =="
wlive="$( (
    source "$SCRIPT"
    _read_api_hashrate() { echo 10741; }
    set +e
    _wait_miner_live 2 && echo LIVE || echo DEAD
))"
assert_eq "_wait_miner_live: true once the API reports a hashrate (#95)" "$wlive" "LIVE"
wdead="$( (
    source "$SCRIPT"
    _read_api_hashrate() { echo 0; }
    set +e
    _wait_miner_live 1 && echo LIVE || echo DEAD
))"
assert_eq "_wait_miner_live: false while the API stays at 0 (#95)" "$wdead" "DEAD"

# The worker API is open (read-only) with no token by default (#125), so _read_api_hashrate must send a
# Bearer ONLY when ACCESS_TOKEN is set — else XMRig 401s a token it never asked for and curl -f (exit 22)
# aborts the caller under set -e, silently breaking live tuning. The rest of the suite stubs this via
# API_CMD, so this is the one place the real curl branch (the header logic) is exercised.
echo "== unit: _read_api_hashrate sends a Bearer only when ACCESS_TOKEN is set (#125) =="
clog="$SANDBOX/curl-calls.log"
: >"$clog"
hr_open="$( (
    source "$SCRIPT"
    unset API_CMD
    ACCESS_TOKEN=""
    PATH="$STUBS:$PATH" CURL_LOG="$clog" STUB_API_HR=1234.5 _read_api_hashrate
))"
assert_eq "_read_api_hashrate returns the hashrate on the open (no-token) API" "$hr_open" "1234.5"
assert_absent "no Authorization header sent when ACCESS_TOKEN is unset" "$(cat "$clog")" "Authorization"
: >"$clog"
hr_auth="$( (
    source "$SCRIPT"
    unset API_CMD
    ACCESS_TOKEN="miner-0"
    PATH="$STUBS:$PATH" CURL_LOG="$clog" STUB_API_HR=987.6 _read_api_hashrate
))"
assert_eq "_read_api_hashrate returns the hashrate when a token is set" "$hr_auth" "987.6"
assert_contains "Bearer <token> sent when ACCESS_TOKEN is set" "$(cat "$clog")" "Authorization: Bearer miner-0"

# #reown: REAL_USER is who root-written files are handed back to. The systemd autotune runs as root with
# no SUDO_USER, so its unit's RIGFORGE_OPERATOR must drive the re-own; interactive SUDO_USER still wins.
ru_op="$( (
    unset SUDO_USER
    export RIGFORGE_OPERATOR=opuser
    source "$SCRIPT"
    set +eu
    printf '%s' "$REAL_USER"
))"
assert_eq "REAL_USER uses RIGFORGE_OPERATOR when SUDO_USER is unset (#reown)" "$ru_op" "opuser"
ru_sudo="$( (
    export SUDO_USER=sudoer RIGFORGE_OPERATOR=opuser
    source "$SCRIPT"
    set +eu
    printf '%s' "$REAL_USER"
))"
assert_eq "REAL_USER prefers SUDO_USER over RIGFORGE_OPERATOR (#reown)" "$ru_sudo" "sudoer"

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

# The apt path adds the versioned kernel-tools package ONLY when `apt-cache show` finds it. The #74 test
# stubs apt-cache to exit 1 (absent), so the present-branch (dep list gains linux-tools-<rel>) is untested.
echo "== unit: install_dependencies adds versioned linux-tools when apt-cache has it (#74) =="
LT="$(mktemp -d "$SANDBOX/lt.XXXXXX")"
# Stubs use an ABSOLUTE `#!/bin/sh` shebang, not `#!/usr/bin/env bash`: these scenarios restrict PATH to
# the stub dir alone (so `command -v` picks the intended package manager), which would leave `env` unable
# to find bash on PATH. The stub bodies are POSIX-simple, so /bin/sh runs them directly.
printf '#!/bin/sh\nexit 1\n' >"$LT/dpkg"      # every dep "missing" -> all go to the install list
printf '#!/bin/sh\nexit 0\n' >"$LT/apt-cache" # linux-tools-<rel> IS available
printf '#!/bin/sh\necho "[apt-get] $*" >>"$CALL_LOG"\n' >"$LT/apt-get"
printf '#!/bin/sh\nwhile [ "${1#*=}" != "$1" ]; do export "$1"; shift; done\nexec "$@"\n' >"$LT/sudo"
printf '#!/bin/sh\necho 6.0.0-rig\n' >"$LT/uname"
chmod +x "$LT"/*
: >"$LT/calls.log"
(
    source "$SCRIPT"
    OS_TYPE=Linux REAL_USER=test
    PATH="$LT" CALL_LOG="$LT/calls.log" install_dependencies </dev/null
) >/dev/null 2>&1
assert_contains "apt install list includes linux-tools-<rel> (#74)" "$(cat "$LT/calls.log")" "linux-tools-6.0.0-rig"

# check_prerequisites (the jq bootstrap) had NO test. jq is deliberately kept OFF the scenario PATH so the
# install branch runs; each dir holds ONLY the package manager(s) under test, so `command -v` selects the
# intended per-distro branch from any host. sudo is a passthrough so the (stubbed) installer actually runs.
echo "== unit: check_prerequisites installs jq per package manager =="
mk_pm_bin() { # <dir> <cmd...>: a passthrough sudo (strips any VAR=val prefix) + a logging stub per command.
    # Absolute /bin/sh shebangs so the stubs run under a PATH restricted to <dir> alone (no bash/env lookup).
    local d="$1" c
    shift
    mkdir -p "$d"
    printf '#!/bin/sh\nwhile [ "${1#*=}" != "$1" ]; do export "$1"; shift; done\nexec "$@"\n' >"$d/sudo"
    for c in "$@"; do printf '#!/bin/sh\necho "[%s] $*" >>"$CALL_LOG"\nexit 0\n' "$c" >"$d/$c"; done
    chmod +x "$d"/*
}
prereq_run() { # <bin_dir> <os>: echoes the function output, an rc line, then the recorded calls
    local d="$1" os="$2" o rc
    : >"$d/calls.log"
    o="$(
        source "$SCRIPT"
        OS_TYPE="$os"
        set +e
        PATH="$d" CALL_LOG="$d/calls.log" check_prerequisites 2>&1
    )"
    rc=$?
    printf '%s\nrc=%s\n%s\n' "$o" "$rc" "$(cat "$d/calls.log")"
}
PB="$SANDBOX/prereq"
out="$(mk_pm_bin "$PB/apt" apt-get && prereq_run "$PB/apt" Linux)"
assert_contains "apt: installs jq via apt-get" "$out" "[apt-get] install"
assert_contains "apt: the installed package is jq" "$out" "jq"
out="$(mk_pm_bin "$PB/dnf" dnf && prereq_run "$PB/dnf" Linux)"
assert_contains "dnf: installs jq via dnf" "$out" "[dnf] install -y -q jq"
out="$(mk_pm_bin "$PB/pac" pacman && prereq_run "$PB/pac" Linux)"
assert_contains "pacman: installs jq via pacman" "$out" "[pacman] -Sy --noconfirm jq"
out="$(mk_pm_bin "$PB/none" && prereq_run "$PB/none" Linux)" # sudo only, no package manager
assert_contains "no package manager: hard error" "$out" "no supported package manager"
assert_contains "no package manager: exits non-zero" "$out" "rc=1"
out="$(mk_pm_bin "$PB/mac" brew && prereq_run "$PB/mac" Darwin)"
assert_contains "macOS with brew: installs jq via brew" "$out" "[brew] install jq"
out="$(mk_pm_bin "$PB/macnobrew" && prereq_run "$PB/macnobrew" Darwin)" # no brew
assert_contains "macOS without brew: hard error" "$out" "Homebrew is required"
# jq already present -> no install attempted at all.
out="$(mk_pm_bin "$PB/have" jq apt-get && prereq_run "$PB/have" Linux)"
assert_absent "jq present: does not reinstall it" "$out" "Installing prerequisite"
assert_absent "jq present: no package manager touched" "$out" "[apt-get]"

# install_dependencies only had the apt path tested (#74). The dnf and pacman branches — different package
# sets, different check/install commands — are our dispatch logic and were never run. apt-get is kept OFF
# PATH so `command -v` falls through to the intended manager; the check command reports every dep missing
# so the install command actually runs. (Third-party install internals aren't our concern — we assert only
# that the RIGHT command installs a distro-appropriate package.)
echo "== unit: install_dependencies dnf / pacman / no-manager branches =="
deps_run() { # <bin_dir> <os>: echoes the function output, an rc line, then the recorded calls
    local d="$1" os="$2" o rc
    : >"$d/calls.log"
    o="$(
        source "$SCRIPT"
        OS_TYPE="$os" REAL_USER=test
        set +e
        PATH="$d" CALL_LOG="$d/calls.log" install_dependencies </dev/null 2>&1
    )"
    rc=$?
    printf '%s\nrc=%s\n%s\n' "$o" "$rc" "$(cat "$d/calls.log")"
}
DB="$SANDBOX/deps"
# dnf: rpm is the check command (report missing), dnf the installer.
mkdir -p "$DB/dnf"
printf '#!/bin/sh\nexit 1\n' >"$DB/dnf/rpm" # `rpm -q <pkg>` -> missing
printf '#!/bin/sh\necho "[dnf] $*" >>"$CALL_LOG"\n' >"$DB/dnf/dnf"
printf '#!/bin/sh\nexec "$@"\n' >"$DB/dnf/sudo"
chmod +x "$DB/dnf"/*
out="$(deps_run "$DB/dnf" Linux)"
assert_contains "dnf: installs via 'dnf install -y'" "$out" "[dnf] install -y"
assert_contains "dnf: pulls a dnf-flavoured package (gcc-c++)" "$out" "gcc-c++"
# pacman is BOTH the check (`-Qi` -> missing) and the installer (`-Sy` -> log).
mkdir -p "$DB/pac"
cat >"$DB/pac/pacman" <<'EOF'
#!/bin/sh
case "$1" in -Qi) exit 1 ;; *) echo "[pacman] $*" >>"$CALL_LOG" ;; esac
EOF
printf '#!/bin/sh\nexec "$@"\n' >"$DB/pac/sudo"
chmod +x "$DB/pac"/*
out="$(deps_run "$DB/pac" Linux)"
assert_contains "pacman: installs via 'pacman -Sy --noconfirm --needed'" "$out" "[pacman] -Sy --noconfirm --needed"
assert_contains "pacman: pulls base-devel" "$out" "base-devel"
# No supported package manager: warn and return 0 (must NOT abort the whole setup run).
out="$(mk_pm_bin "$DB/none" && deps_run "$DB/none" Linux)"
assert_contains "no manager: warns instead of failing" "$out" "No supported package manager"
assert_contains "no manager: returns 0 (setup continues)" "$out" "rc=0"

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
# Bounded poll (the tests/e2e-real.sh pattern): wait up to ~6s for the backgrounded fake to record
# its args instead of hoping one fixed sleep is enough on a loaded CI runner. (#135)
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ -s "$MC/home/worker/xmrig.args" ]; then break; fi
    sleep 0.5
done
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

# Guard: `start` before `setup` (no built binary) must fail with a clear "run setup first", NOT spawn a
# broken PID. Uses a worker root with no build dir at all.
NOB="$(mktemp -d "$SANDBOX/nobuilt.XXXXXX")"
cp "$ROOT/VERSION" "$NOB/"
cat >"$NOB/config.json" <<EOF
{ "HOME_DIR": "$NOB/home", "pools": [{"url": "h:3333"}] }
EOF
out="$( (cd "$NOB" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin HOME="$NOB" RIGFORGE_HOME="$PWD" bash "$SCRIPT" start </dev/null 2>&1))"
assert_rc "macOS start with no built worker fails" "$?" "1"
assert_contains "macOS start with no worker points at setup" "$out" "Run 'setup' first"

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
: >"$LCL"
out="$(mac_lr bash "$SCRIPT" stop)"
assert_contains "stop delegates to launchctl when enabled" "$(cat "$LCL")" "[launchctl] stop"
out="$( (cd "$MC" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin HOME="$MC" CALL_LOG="$LCL" STUB_LAUNCHD_PID=4321 RIGFORGE_HOME="$PWD" bash "$SCRIPT" status </dev/null 2>&1))"
assert_contains "status reads the launchd PID" "$out" "pid 4321"
out="$(mac_lr bash "$SCRIPT" disable)"
assert_rc "macOS disable exits 0" "$?" "0"
assert_eq "disable removed the plist" "$([ -f "$PLIST" ] && echo y || echo n)" "n"
assert_contains "disable unloaded the agent" "$(cat "$LCL")" "[launchctl] unload"

# #audit A2: when a GRUB change pends a reboot, HugePages aren't reserved yet, so install_service must
# ENABLE the unit but NOT start it — starting now would run the miner degraded (no huge-page backing) and,
# with Restart=always, churn until the reboot. The full-deploy run enters this branch but its systemctl
# stub is a silent no-op, so nothing proved the start was withheld. Drive install_service directly and read
# the recorded systemctl calls for each of the three cases (reboot-pending / rebuilt / steady-state).
echo "== unit: install_service reboot-gates the start (#audit A2) =="
svc_run() { # <dir> <reboot_required> <xmrig_rebuild>: renders into <dir>, echoes the systemctl call log
    local d="$1"
    mkdir -p "$d/etc/systemd" "$d/xmrig/build"
    (
        cd "$d" || exit 1
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT" # so envsubst reads the real systemd/xmrig.service.template
        WORKER_ROOT="$d"
        SYSTEMD_DIR="$d/etc/systemd"
        REBOOT_REQUIRED="$2"
        XMRIG_REBUILD="$3"
        set +e
        PATH="$STUBS:$PATH" CALL_LOG="$d/calls.log" install_service >/dev/null 2>&1
    )
    cat "$d/calls.log"
}
SVC_RB="$(mktemp -d "$SANDBOX/svcrb.XXXXXX")"
log_reboot="$(svc_run "$SVC_RB" true false)"
assert_contains "reboot pending: service enabled" "$log_reboot" "[systemctl] enable xmrig.service"
assert_absent "reboot pending: NOT started (would run degraded) (#audit A2)" "$log_reboot" "start xmrig.service"
assert_absent "reboot pending: NOT restarted" "$log_reboot" "restart xmrig.service"
# CPUPOWER_PATH substitution: the ExecStartPre governor set is best-effort (leading `-`); a literal
# unexpanded $CPUPOWER_PATH there would break with Restart=always. Assert it resolved to a real path.
svc_rendered="$(cat "$SVC_RB/etc/systemd/xmrig.service")"
assert_contains "service: ExecStartPre governor set rendered" "$svc_rendered" "ExecStartPre=-"
assert_absent "service: no unexpanded CPUPOWER_PATH" "$svc_rendered" '$CPUPOWER_PATH'
log_rebuild="$(svc_run "$(mktemp -d "$SANDBOX/svcrbu.XXXXXX")" false true)"
assert_contains "rebuilt binary, no reboot: service restarted" "$log_rebuild" "[systemctl] restart xmrig.service"
log_steady="$(svc_run "$(mktemp -d "$SANDBOX/svcst.XXXXXX")" false false)"
assert_contains "no rebuild, no reboot: service (re)started, not restarted" "$log_steady" "[systemctl] start xmrig.service"
assert_absent "no rebuild: does not needlessly restart a running miner" "$log_steady" "restart xmrig.service"

# #133: SERVICE_NAME is a documented override and every other verb honors it — install_service must
# install/enable/start the SAME unit, not a hardcoded xmrig.service nothing else can see.
echo "== unit: install_service honors SERVICE_NAME override (#133) =="
SVC_OVR="$(mktemp -d "$SANDBOX/svcovr.XXXXXX")"
mkdir -p "$SVC_OVR/etc/systemd" "$SVC_OVR/xmrig/build"
(
    cd "$SVC_OVR" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$ROOT" # so envsubst reads the real systemd/xmrig.service.template
    WORKER_ROOT="$SVC_OVR"
    SYSTEMD_DIR="$SVC_OVR/etc/systemd"
    SERVICE_NAME=miner
    REBOOT_REQUIRED=false
    XMRIG_REBUILD=true
    set +e
    PATH="$STUBS:$PATH" CALL_LOG="$SVC_OVR/calls.log" install_service >/dev/null 2>&1
)
assert_eq "SERVICE_NAME=miner writes miner.service (#133)" "$([ -f "$SVC_OVR/etc/systemd/miner.service" ] && echo yes || echo no)" "yes"
assert_eq "SERVICE_NAME=miner writes NO xmrig.service (#133)" "$([ -f "$SVC_OVR/etc/systemd/xmrig.service" ] && echo yes || echo no)" "no"
assert_contains "enables miner.service (#133)" "$(cat "$SVC_OVR/calls.log")" "[systemctl] enable miner.service"
assert_contains "restarts miner.service (#133)" "$(cat "$SVC_OVR/calls.log")" "[systemctl] restart miner.service"

# ---------------------------------------------------------------------------
# Full end-to-end run of the REAL script with everything stubbed, executed TWICE to prove idempotency.
# Every /etc target is redirected into the work dir, and passthrough sudo lets the writes land there.
#
# The run uses the HOST's OS path: the Linux deploy path uses GNU `sed -i` (no suffix), which BSD/macOS
# sed rejects, so simulating Linux natively on a Mac is impossible. On Linux we exercise the full
# kernel/limits/service path here; on macOS we exercise the macOS deploy path natively, and the Linux
# /etc idempotency is validated from any host by the Docker E2E (tests/e2e/linux.sh) and by Linux CI.
HOST_OS="$(uname -s)"

e2e_setup() { # echoes the work dir
    local W
    W="$(mktemp -d "$SANDBOX/e2e.XXXXXX")"
    cp -R "$ROOT/systemd" "$ROOT/util" "$W/"
    mkdir -p "$W/etc/logrotate.d" "$W/etc/modules-load.d" "$W/etc/systemd" \
        "$W/etc/security" "$W/etc/default" "$W/home" "$W/proc" "$W/sys"
    : >"$W/etc/fstab"
    : >"$W/etc/security/limits.conf"
    # memmap=4G&2M: a legal param whose '&' is sed-replacement-special — must survive the rewrite (#134)
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash memmap=4G&2M"\n' >"$W/etc/default/grub"
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
# #cli: add_to_path defaults OFF — this config doesn't set it, so setup must NOT touch PATH. (BIN_DIR is
# the suite's sandbox; the opt-in install is covered by the add_to_path=true test below + the Docker e2e.)
assert_eq "cli: NOT on PATH by default — add_to_path off (#cli)" "$([ -L "$BIN_DIR/rigforge" ] && echo present || echo absent)" "absent"
if [ "$HOST_OS" = Linux ]; then
    assert_eq "deploy: EPYC numa applied" "$(J "$BUILD/config.json" '.randomx.numa')" "true"
    # #cpu: the lscpu stub emits a "BIOS Model name:" line (as root lscpu does). The detected-CPU line
    # must show the clean model, NOT concatenate the BIOS line's "Unknown CPU @ 4.2GHz" garbage.
    assert_contains "deploy: detected CPU is the clean model (#cpu)" "$E2E_OUT" "Detected CPU: AMD EPYC 7763 64-Core Processor —"
    assert_absent "deploy: detected CPU drops the BIOS-line garbage (#cpu)" "$E2E_OUT" "Unknown CPU @"
    svc="$(cat "$W/etc/systemd/xmrig.service")"
    assert_contains "service: rendered with build dir" "$svc" "$BUILD"
    # #13: hardening directives present, and ReadWritePaths got WORKER_ROOT substituted (not literal).
    assert_contains "service: NoNewPrivileges" "$svc" "NoNewPrivileges=true"
    assert_contains "service: ProtectSystem=full" "$svc" "ProtectSystem=full"
    assert_contains "service: LimitMEMLOCK=infinity" "$svc" "LimitMEMLOCK=infinity"
    # The rest of the defense-in-depth block was unchecked — a dropped line is a silent hardening regression.
    assert_contains "service: ProtectControlGroups" "$svc" "ProtectControlGroups=true"
    assert_contains "service: ProtectClock" "$svc" "ProtectClock=true"
    assert_contains "service: RestrictSUIDSGID" "$svc" "RestrictSUIDSGID=true"
    assert_contains "service: LockPersonality" "$svc" "LockPersonality=true"
    assert_contains "service: PrivateTmp" "$svc" "PrivateTmp=true"
    assert_contains "service: ReadWritePaths -> worker root" "$svc" "ReadWritePaths=$W/home/worker"
    assert_absent "service: no unexpanded WORKER_ROOT" "$svc" 'ReadWritePaths=$WORKER_ROOT'
    assert_contains "kernel: msr module enabled" "$(cat "$W/etc/modules-load.d/msr.conf")" "msr"
    assert_contains "limits: fstab 2M mount written" "$(cat "$W/etc/fstab")" "hugetlbfs /dev/hugepages"
    # The 1G mount line's content was only asserted in the uninstall pre-seed, never as produced by a fresh
    # configure_limits — so a regression in the line it WRITES would go unnoticed.
    assert_contains "limits: fstab 1G mount written (pagesize=1G)" "$(cat "$W/etc/fstab")" "pagesize=1G"
    # #13: memlock scoped to the mining user, NOT granted to every account ("*").
    assert_contains "limits: memlock unlimited written" "$(cat "$W/etc/security/limits.conf")" "soft memlock unlimited"
    assert_absent "limits: not wildcard memlock" "$(cat "$W/etc/security/limits.conf")" "* soft memlock unlimited"
    assert_contains "grub: hugepages params written" "$(cat "$W/etc/default/grub")" "default_hugepagesz=2M"
    assert_contains "grub: preserves existing params (#19)" "$(cat "$W/etc/default/grub")" "quiet splash"
    assert_contains "grub: sed-special & param survives the rewrite (#134)" "$(cat "$W/etc/default/grub")" 'memmap=4G&2M'
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

# #cli: the opt-in. With "add_to_path": true in config.json, setup installs the symlink (into a per-test
# BIN_DIR so it doesn't collide with the default-off run above). RIGFORGE_HOME=$CW -> target $CW/rigforge.sh.
echo "== black-box: setup installs the CLI only when add_to_path is enabled (#cli) =="
CW="$(e2e_setup)"
jq '.add_to_path = true' "$CW/config.json" >"$CW/config.json.tmp" && mv "$CW/config.json.tmp" "$CW/config.json"
CBIN="$CW/usr-local-bin"
mkdir -p "$CBIN"
BIN_DIR="$CBIN" e2e_run "$CW" "$HOST_OS"
assert_eq "cli: add_to_path=true links rigforge onto PATH (#cli)" "$(readlink "$CBIN/rigforge" 2>/dev/null)" "$CW/rigforge.sh"

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

# #135: doctor asserts the live config keeps the HTTP API read-only (http.restricted=true).
echo "== unit: doctor checks http.restricted in the live config (#135) =="
mkdir -p "$DOC/home/worker/xmrig/build"
printf '{ "http": { "restricted": true } }\n' >"$DOC/home/worker/xmrig/build/config.json"
out="$(run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: restricted=true passes (#135)" "$out" "HTTP API is read-only"
printf '{ "http": { "restricted": false } }\n' >"$DOC/home/worker/xmrig/build/config.json"
out="$(run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: restricted=false warns (#135)" "$out" "NOT read-only"
assert_contains "doctor: restricted=false counts as an issue (#135)" "$out" "issue(s) found"
# #141: binary tamper evidence — matching sha OK, changed binary is a counted issue, no record is
# advisory only.
mkdir -p "$DOC/home/worker/xmrig/build"
printf 'fakebinary' >"$DOC/home/worker/xmrig/build/xmrig"
out="$(run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: no sha record is advisory only (#141)" "$out" "no build-time checksum recorded"
(
    source "$SCRIPT"
    _sha256 "$DOC/home/worker/xmrig/build/xmrig" >"$DOC/home/worker/xmrig/.rigforge-sha256"
)
out="$(run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: unchanged binary passes the sha check (#141)" "$out" "matches its build-time SHA-256"
printf 'tampered' >>"$DOC/home/worker/xmrig/build/xmrig"
out="$(run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: changed binary warns (#141)" "$out" "CHANGED since it was built"
assert_contains "doctor: changed binary is a counted issue (#141)" "$out" "issue(s) found"
rm -rf "$DOC/home/worker/xmrig" # leave $DOC exactly as later doctor tests expect it
rm -rf "$DOC/home/worker/xmrig" # leave $DOC exactly as the later doctor tests expect it

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
# #108: server boards (EPYC/Threadripper) repeat one Bank Locator (`BANK 0`) for every DIMM and carry the
# channel in the Locator's letter group instead. 8 DIMMs across channels A..H must read as 8 channels, NOT
# a false single-channel warning. The fixture loops A..H so every DIMM shares `BANK 0` but has a distinct
# `DIMM_P0_<letter>0` Locator (mirrors a fully-populated 8-channel EPYC 7642).
cat >"$DOC/dmidecode_epyc" <<'EOF'
#!/usr/bin/env bash
for ch in A B C D E F G H; do
    printf 'Memory Device\n\tSize: 32 GB\n\tLocator: DIMM_P0_%s0\n\tBank Locator: BANK 0\n\tSpeed: 3200 MT/s\n\tConfigured Memory Speed: 3200 MT/s\n' "$ch"
done
EOF
# Desktop board that encodes the channel ONLY in the Locator (`DIMM A1`/`DIMM B1`) with an uninformative
# shared Bank Locator — proves the Locator path detects dual-channel independent of Bank Locator.
cat >"$DOC/dmidecode_loc2ch" <<'EOF'
#!/usr/bin/env bash
printf 'Memory Device\n\tSize: 16 GB\n\tLocator: DIMM A1\n\tBank Locator: BANK 0\n\tSpeed: 6000 MT/s\n\tConfigured Memory Speed: 6000 MT/s\nMemory Device\n\tSize: 16 GB\n\tLocator: DIMM B1\n\tBank Locator: BANK 0\n\tSpeed: 6000 MT/s\n\tConfigured Memory Speed: 6000 MT/s\n'
EOF
chmod +x "$DOC/dmidecode_epyc" "$DOC/dmidecode_loc2ch"
out="$(DMIDECODE="$DOC/dmidecode_epyc" CPUFREQ_MAX="$DOC/cpufreq_max" CPU_SYSFS="$DOC/cpu_ok" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: EPYC 8-channel counted from Locator (#108)" "$out" "8 modules across 8 channels"
assert_absent "doctor: no false single-channel warning on EPYC (#108)" "$out" "single-channel"
out="$(DMIDECODE="$DOC/dmidecode_loc2ch" CPUFREQ_MAX="$DOC/cpufreq_max" CPU_SYSFS="$DOC/cpu_ok" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: dual-channel detected from Locator field (#108)" "$out" "2 channels"
assert_absent "doctor: no single-channel warning when Locator shows 2 channels (#108)" "$out" "single-channel"
# dmidecode unavailable -> graceful advisory note (not a hard failure)
out="$(DMIDECODE="/nonexistent" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: degrades gracefully w/o dmidecode (#67)" "$out" "dmidecode not found"
# dmidecode present but empty output (e.g. run as non-root) -> "not readable" note, not a crash
printf '#!/usr/bin/env bash\n' >"$DOC/dmidecode_empty"
chmod +x "$DOC/dmidecode_empty"
out="$(DMIDECODE="$DOC/dmidecode_empty" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: RAM-unreadable note when dmidecode is empty (#67)" "$out" "RAM layout not readable"
# Regression: dmidecode needs root, so a non-root `doctor` makes `dmidecode | awk` FAIL (exit 1), not just
# return empty. In production doctor runs under `set -Eeuo pipefail`, so that non-zero pipeline (pipefail)
# would trip errexit and ABORT the whole health check. The sourced run_doctor above uses `set +e` and so
# can't catch it — run the REAL dispatch (real errexit) with a dmidecode that fails like a non-root run.
printf '#!/usr/bin/env bash\necho "dmidecode: /dev/mem: Permission denied" >&2\nexit 1\n' >"$DOC/dmidecode_denied"
chmod +x "$DOC/dmidecode_denied"
dout="$(cd "$DOC" && PATH="$STUBS:$PATH" STUB_UNAME_S=Linux \
    MEMINFO="$DOC/meminfo_ok" MSR_MODULE_DIR="$DOC/msrmod" GOVERNOR_FILE="$DOC/gov_perf" \
    HUGEPAGES_1G_NR="$DOC/nr1g" DMIDECODE="$DOC/dmidecode_denied" CPUFREQ_MAX="$DOC/none" CPU_SYSFS="$DOC/none" \
    RIGFORGE_HOME="$DOC" bash "$SCRIPT" doctor </dev/null 2>&1)"
drc=$?
assert_rc "doctor: a non-root dmidecode failure doesn't abort doctor (#67)" "$drc" "0"
assert_absent "doctor: no errexit abort on non-root dmidecode (#67)" "$dout" "aborted while"
assert_contains "doctor: graceful 'run as root' on non-root dmidecode (#67)" "$dout" "RAM layout not readable"

# #78: doctor's BIOS/firmware advisory — board/BIOS context, XMP/EXPO off (rated > configured RAM speed),
# and SMT off. Detect-and-recommend only (RigForge can't change BIOS from the OS), so it's all advisory
# and degrades gracefully when the sysfs/dmidecode probes aren't available. Fakes drive each path.
echo "== unit: doctor BIOS/firmware advisory (#78) =="
mkdir -p "$DOC/dmi"
printf 'ASUSTeK' >"$DOC/dmi/board_vendor"
printf 'TUF B650-E' >"$DOC/dmi/board_name"
printf '2613' >"$DOC/dmi/bios_version"
printf '04/12/2024' >"$DOC/dmi/bios_date"
printf 'off\n' >"$DOC/smt_off"
printf 'on\n' >"$DOC/smt_on"
# rated (Speed) > configured -> memory profile not enabled
cat >"$DOC/dmidecode_xmpoff" <<'EOF'
#!/usr/bin/env bash
printf 'Memory Device\n\tSize: 16 GB\n\tBank Locator: P0 CHANNEL A\n\tSpeed: 6000 MT/s\n\tConfigured Memory Speed: 4800 MT/s\nMemory Device\n\tSize: 16 GB\n\tBank Locator: P0 CHANNEL B\n\tSpeed: 6000 MT/s\n\tConfigured Memory Speed: 4800 MT/s\n'
EOF
# rated == configured -> profile on
cat >"$DOC/dmidecode_xmpon" <<'EOF'
#!/usr/bin/env bash
printf 'Memory Device\n\tSize: 16 GB\n\tBank Locator: P0 CHANNEL A\n\tSpeed: 6000 MT/s\n\tConfigured Memory Speed: 6000 MT/s\nMemory Device\n\tSize: 16 GB\n\tBank Locator: P0 CHANNEL B\n\tSpeed: 6000 MT/s\n\tConfigured Memory Speed: 6000 MT/s\n'
EOF
chmod +x "$DOC/dmidecode_xmpoff" "$DOC/dmidecode_xmpon"
# All three fire: context line, XMP/EXPO off, SMT off.
out="$(DMI_DIR="$DOC/dmi" SMT_CONTROL="$DOC/smt_off" DMIDECODE="$DOC/dmidecode_xmpoff" \
    CPUFREQ_MAX="$DOC/cpufreq_max" CPU_SYSFS="$DOC/cpu_ok" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: prints board/BIOS context (#78)" "$out" "BIOS 2613"
assert_contains "doctor: firmware advisory is manual-only (#78)" "$out" "RigForge can't change them from the OS"
assert_contains "doctor: XMP/EXPO off shows rated vs configured (#78)" "$out" "4800 MT/s but the modules are rated for 6000"
assert_contains "doctor: recommends enabling the memory profile (#78)" "$out" "enable the memory profile (XMP / EXPO / DOCP)"
assert_contains "doctor: SMT off -> recommend enabling (#78)" "$out" "SMT/Hyper-Threading is disabled"
assert_contains "doctor: context points to the items below when there ARE recs (#78)" "$out" "apply the BIOS/UEFI item(s) below"
# Profile on + SMT on -> neither warning fires, and the context line must NOT promise items below (none).
out="$(DMI_DIR="$DOC/dmi" SMT_CONTROL="$DOC/smt_on" DMIDECODE="$DOC/dmidecode_xmpon" \
    CPUFREQ_MAX="$DOC/cpufreq_max" CPU_SYSFS="$DOC/cpu_ok" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_absent "doctor: memory profile on -> no XMP warning (#78)" "$out" "enable the memory profile"
assert_absent "doctor: SMT on -> no SMT warning (#78)" "$out" "SMT/Hyper-Threading is disabled"
assert_contains "doctor: still prints the firmware context line (#78)" "$out" "BIOS 2613"
assert_contains "doctor: says 'no BIOS changes recommended' when all optimal (#78)" "$out" "no BIOS changes recommended"
assert_absent "doctor: no false 'items below' when nothing to apply (#78)" "$out" "items below"
# DMI + SMT unreadable -> no context line, no crash (graceful degradation).
out="$(DMI_DIR="/nonexistent-dmi" SMT_CONTROL="/nonexistent-smt" DMIDECODE="$DOC/dmidecode_xmpon" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_absent "doctor: no firmware context when DMI unreadable (#78)" "$out" "Firmware:"

# ---------------------------------------------------------------------------
# Guided BIOS flow (#80): detect -> guide -> save -> re-verify, against the #78 firmware fixtures.
# The detection expressions are doctor's, so the fixtures drive both the WARN and OK sides.
echo "== unit: guided BIOS flow (#80) =="
BIO="$(mktemp -d "$SANDBOX/bio.XXXXXX")"
run_bios() { # <extra env assignments as "VAR=val ..."> [args...]; sandbox WORKER_ROOT, Enter piped
    local envs="$1"
    shift
    printf '\n\n\n' | (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$BIO/config.json"
        WORKER_ROOT="$BIO"
        RIGFORGE_FORCE_ELEVATE=0
        DMI_DIR="$DOC/dmi"
        eval "$envs"
        parse_config() { WORKER_ROOT="$BIO"; }
        _reown_worker() { :; }
        set +e
        PATH="$STUBS:$PATH" bios "$@" 2>&1
    )
}
printf '{ "pools": [{"url": "h:3333"}] }\n' >"$BIO/config.json"
# 1. Guide pass: profile off + SMT off + throttled clock -> three pending items, saved state.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_off DMIDECODE=$DOC/dmidecode_xmpoff CPU_SYSFS=$DOC/cpu_throttle CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios: prints the firmware context (#80)" "$out" "Reading current firmware state"
assert_contains "bios: memory item shows the ASUS EXPO menu path (#80)" "$out" "Ai Overclock Tuner"
assert_contains "bios: SMT item present (#80)" "$out" "SMT / Hyper-Threading"
assert_contains "bios: PBO path for the perf target (#80)" "$out" "Precision Boost Overdrive"
assert_contains "bios: saved the pending items (#80)" "$out" "Saved 3 pending item(s)"
assert_eq "bios: state file holds 3 items (#80)" "$(jq -r '.items | length' "$BIO/rigforge-bios.json")" "3"
assert_eq "bios: memory first (RandomX impact order) (#80)" "$(jq -r '.items[0].id' "$BIO/rigforge-bios.json")" "memory_profile"
# 2. Verify pass (partial): profile + SMT took, clock still capped -> exactly power_boost kept.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_throttle CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: resumes from the saved state (#80)" "$out" "Resuming"
assert_eq "bios verify: two items took (#80)" "$(printf '%s' "$out" | grep -c "Took.")" "2"
assert_contains "bios verify: boost still pending with the re-check hint (#80)" "$out" "still"
assert_eq "bios verify: only power_boost kept (#80)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["power_boost"]'
# 3. Converged: clock now healthy -> state deleted, tune handoff printed.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: converged (#80)" "$out" "All BIOS items applied"
assert_contains "bios verify: hands off to a live re-tune (#80)" "$out" "tune --live"
assert_eq "bios verify: state file removed on convergence (#80)" "$([ -f "$BIO/rigforge-bios.json" ] && echo y || echo n)" "n"
# 4. Miner stopped at verify: boost is unverifiable -> stays pending with the honest note.
printf '%s\n' '{"target":"perf","saved":"2026-07-10 03:00","items":[{"id":"power_boost","status":"pending","before":"78% of max boost","menu":"PBO"}]}' >"$BIO/rigforge-bios.json"
BSTOP="$(mktemp -d "$SANDBOX/bstop.XXXXXX")"
printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 3\nexit 0\n' >"$BSTOP/systemctl"
chmod +x "$BSTOP/systemctl"
out="$(printf '\n' | (
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$ROOT"
    CONFIG_JSON="$BIO/config.json"
    WORKER_ROOT="$BIO"
    DMI_DIR="$DOC/dmi"
    SMT_CONTROL="$DOC/smt_on"
    DMIDECODE="$DOC/dmidecode_xmpon"
    parse_config() { WORKER_ROOT="$BIO"; }
    _reown_worker() { :; }
    set +e
    PATH="$BSTOP:$STUBS:$PATH" bios 2>&1
))"
assert_contains "bios verify: miner stopped -> can't verify boost (#80)" "$out" "can't verify with the miner stopped"
assert_eq "bios verify: unverifiable item stays pending (#80)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["power_boost"]'
rm -f "$BIO/rigforge-bios.json"
# 5. Nothing to do: all-good fixtures -> no state file, explicit all-set line, rc 0.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios: nothing to change -> says so (#80)" "$out" "already set"
assert_eq "bios: no state file when nothing pending (#80)" "$([ -f "$BIO/rigforge-bios.json" ] && echo y || echo n)" "n"
# 6. Efficiency target picks the low-power menu set.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_off DMIDECODE=$DOC/dmidecode_xmpoff CPU_SYSFS=$DOC/cpu_throttle CPUFREQ_MAX=$DOC/cpufreq_max' --efficiency)"
assert_contains "bios --efficiency: Eco Mode path (#80)" "$out" "Eco Mode"
assert_contains "bios --efficiency: Curve Optimizer path (#80)" "$out" "Curve Optimizer"
assert_absent "bios --efficiency: not the PBO-max path (#80)" "$out" "Precision Boost Overdrive"
assert_eq "bios --efficiency: target persisted in state (#80)" "$(jq -r '.target' "$BIO/rigforge-bios.json")" "efficiency"
rm -f "$BIO/rigforge-bios.json"
# 7. Vendor fallback: unknown board -> the generic menu line.
BVEND="$(mktemp -d "$SANDBOX/bvend.XXXXXX")"
mkdir -p "$BVEND"
printf 'SomeVendor' >"$BVEND/board_vendor"
printf 'SomeBoard' >"$BVEND/board_name"
printf '1.0' >"$BVEND/bios_version"
printf '2026-01-01' >"$BVEND/bios_date"
out="$(run_bios 'DMI_DIR='"$BVEND"' SMT_CONTROL=$DOC/smt_off DMIDECODE=$DOC/dmidecode_xmpoff CPU_SYSFS=$DOC/cpu_throttle CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios: unknown vendor gets the generic memory hint (#80)" "$out" "look for the memory profile setting"
rm -f "$BIO/rigforge-bios.json"
# 8. Non-root degrade: dmidecode unreadable -> memory item is honest, no crash.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on DMIDECODE=$NOHW/dmidecode-absent CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios: unreadable RAM state degrades honestly (#80)" "$out" "run as root so dmidecode can read"
# 9. Unknown flag errors on the house template; macOS refuses.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on' --wat)"
assert_contains "bios: unknown flag -> template error (#80)" "$out" "Unknown option for bios"
# 10. Coverage of the remaining branches (#80 / the #165 patch-coverage gap):
# --perf flag, the other vendor menu paths, missing SMT sysfs, elevation, bogus state ids,
# non-root memory verify, and the dispatch entry.
out="$(run_bios 'SMT_CONTROL=$DOC/smt_off DMIDECODE=$DOC/dmidecode_xmpoff CPU_SYSFS=$DOC/cpu_throttle CPUFREQ_MAX=$DOC/cpufreq_max' --perf)"
assert_contains "bios --perf: explicit perf flag honoured (#80)" "$out" "Precision Boost Overdrive"
menus="$(
    source "$SCRIPT"
    _bios_menu "ASRock" memory_profile perf
    _bios_menu "Gigabyte Technology" memory_profile perf
    _bios_menu "Micro-Star International" memory_profile perf
)"
assert_contains "menu: ASRock path (#80)" "$menus" "OC Tweaker"
assert_contains "menu: Gigabyte path (#80)" "$menus" "Extreme Memory Profile"
assert_contains "menu: MSI path (#80)" "$menus" "A-XMP"
out="$(run_bios 'SMT_CONTROL=$NOHW/smt DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_absent "bios: missing SMT sysfs -> no SMT judgment (#80)" "$out" "SMT / Hyper-Threading:"
# Elevation: FORCE_ELEVATE + a sudo stub that reports instead of re-executing.
BSUDO="$(mktemp -d "$SANDBOX/bsudo.XXXXXX")"
printf '#!/usr/bin/env bash\necho "ELEVATED-VIA-SUDO $*"\nexit 0\n' >"$BSUDO/sudo"
chmod +x "$BSUDO/sudo"
out="$( (
    source "$SCRIPT"
    OS_TYPE=Linux
    RIGFORGE_FORCE_ELEVATE=1
    set +e
    PATH="$BSUDO:$STUBS:$PATH" bios 2>&1
))"
assert_contains "bios: auto-elevates via sudo like tune (#80)" "$out" "needs root for the firmware probes"
assert_contains "bios: elevation re-execs through sudo (#80)" "$out" "ELEVATED-VIA-SUDO"
# A state file carrying an unknown id is skipped, not fatal; the real item still verifies.
printf '%s\n' '{"target":"perf","saved":"2026-07-10","items":[{"id":"flux_capacitor","status":"pending","before":"?","menu":"?"},{"id":"smt","status":"pending","before":"off","menu":"SMT"}]}' >"$BIO/rigforge-bios.json"
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: unknown state id skipped, real item verified (#80)" "$out" "SMT / Hyper-Threading — now"
rm -f "$BIO/rigforge-bios.json"
# Non-root memory verify: the saved memory item can't be re-read without dmidecode -> honest keep.
printf '%s\n' '{"target":"perf","saved":"2026-07-10","items":[{"id":"memory_profile","status":"pending","before":"4800 of 6000 MT/s","menu":"EXPO"}]}' >"$BIO/rigforge-bios.json"
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on DMIDECODE=$NOHW/dmidecode-absent CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: unreadable RAM keeps the item with the root hint (#80)" "$out" "can't verify (run as root"
assert_eq "bios verify: unverifiable memory item stays pending (#80)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["memory_profile"]'
rm -f "$BIO/rigforge-bios.json"
# Dispatch: the case entry shifts and forwards flags (any OS: the rc-1 proves the verb was reached).
out="$( (RIGFORGE_HOME="$BIO" bash "$SCRIPT" bios --wat </dev/null) 2>&1 || true)"
assert_contains "bios: dispatch forwards to the verb (#80)" "$out" "[ERROR]"
if [ "$(uname -s)" != Linux ]; then
    out="$( (RIGFORGE_HOME="$BIO" bash "$SCRIPT" bios </dev/null) 2>&1 || true)"
    assert_contains "bios: refuses off-Linux (#80)" "$out" "only supported on Linux"
fi

# #audit A3: doctor's "service is not active" WARN + issue branch, and the gating of the clock-under-load
# check on a RUNNING service. Every other doctor test uses the shared systemctl stub, which is always
# "active", so these paths were never exercised. A stub variant reports inactive (is-active -> exit 3).
echo "== unit: doctor service-inactive branch (#audit) =="
mkdir -p "$DOC/svc_inactive"
cat >"$DOC/svc_inactive/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in *is-active*) exit 3 ;; *) exit 0 ;; esac
EOF
chmod +x "$DOC/svc_inactive/systemctl"
out="$( (
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$ROOT"
    CONFIG_JSON="$DOC/config.json"
    MEMINFO="$DOC/meminfo_ok"
    MSR_MODULE_DIR="$DOC/msrmod"
    GOVERNOR_FILE="$DOC/gov_perf"
    HUGEPAGES_1G_NR="$DOC/nr1g"
    CPUFREQ_MAX="$DOC/cpufreq_max"
    CPU_SYSFS="$DOC/cpu_ok"
    set +e
    PATH="$DOC/svc_inactive:$STUBS:$PATH" doctor 2>&1
))"
assert_contains "doctor: inactive service -> WARN (#audit)" "$out" "is not active"
assert_contains "doctor: inactive service counts as an issue (#audit)" "$out" "issue(s) found"
assert_absent "doctor: clock-under-load check is skipped when the service is inactive (#audit)" "$out" "CPU clock under load"

# #audit: _reown_worker hands the files setup/tune/apply wrote as root back to the operator (so they can
# edit config.json + re-run without sudo). As root it chowns WORKER_ROOT + config.json to REAL_USER; not
# root, it's a no-op. (sudo is a passthrough stub, so the chown stub records the real call.)
echo "== unit: _reown_worker reconciles file ownership (#audit) =="
RW="$(mktemp -d "$SANDBOX/reown.XXXXXX")"
mkdir -p "$RW/worker" "$RW/asroot" "$RW/asuser"
printf '{}' >"$RW/config.json"
printf '#!/usr/bin/env bash\necho 0\n' >"$RW/asroot/id"
printf '#!/usr/bin/env bash\necho 1000\n' >"$RW/asuser/id"
printf '#!/usr/bin/env bash\necho "[chown] $*" >>"$CHOWN_LOG"\n' >"$RW/asroot/chown"
cp "$RW/asroot/chown" "$RW/asuser/chown"
chmod +x "$RW/asroot/id" "$RW/asuser/id" "$RW/asroot/chown" "$RW/asuser/chown"
reown() { # <asroot|asuser>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        REAL_USER=rfop
        WORKER_ROOT="$RW/worker"
        CONFIG_JSON="$RW/config.json"
        export CHOWN_LOG="$RW/chown-$1.log"
        : >"$CHOWN_LOG"
        set +e
        PATH="$RW/$1:$STUBS:$PATH" _reown_worker
        cat "$CHOWN_LOG"
    )
}
out="$(reown asroot)"
assert_contains "reown (root): chowns the worker root to the operator (#audit)" "$out" "[chown] -R rfop:rfop $RW/worker"
assert_contains "reown (root): chowns config.json to the operator (#audit)" "$out" "[chown] rfop:rfop $RW/config.json"
assert_eq "reown (non-root): no-op, nothing chowned (#audit)" "$(reown asuser)" ""
# macOS chowns to the user WITHOUT an explicit group; an unknown OS is a no-op.
reown_os() { # <OS_TYPE>
    (
        source "$SCRIPT"
        OS_TYPE="$1"
        REAL_USER=rfop
        WORKER_ROOT="$RW/worker"
        CONFIG_JSON="$RW/config.json"
        export CHOWN_LOG="$RW/chown-os.log"
        : >"$CHOWN_LOG"
        set +e
        PATH="$RW/asroot:$STUBS:$PATH" _reown_worker
        cat "$CHOWN_LOG"
    )
}
assert_contains "reown (macOS): chowns to the user without a group (#audit)" "$(reown_os Darwin)" "[chown] -R rfop $RW/worker"
assert_eq "reown (unknown OS): no-op (#audit)" "$(reown_os FreeBSD)" ""

# #cli: setup puts a `rigforge` command on PATH (a symlink in BIN_DIR -> this script), and the script
# resolves itself THROUGH that symlink so the repo (config/util/data) is still found when run as
# `rigforge`. _script_dir (the resolver) and link_cli (installer + guards) are unit-tested here; the
# end-to-end install-on-setup / remove-on-uninstall paths are covered by the black-box tests below.
echo "== unit: _script_dir resolves through symlinks (#cli) =="
SD="$(mktemp -d "$SANDBOX/scriptdir.XXXXXX")"
mkdir -p "$SD/repo" "$SD/bin"
: >"$SD/repo/rigforge.sh"
ln -s "../repo/rigforge.sh" "$SD/bin/rel"  # relative target
ln -s "$SD/repo/rigforge.sh" "$SD/bin/abs" # absolute target
sdir() { (
    source "$SCRIPT"
    set +eu
    _script_dir "$1"
); }
WANT="$(cd -P "$SD/repo" && pwd)"
assert_eq "_script_dir: relative symlink -> the repo dir (#cli)" "$(sdir "$SD/bin/rel")" "$WANT"
assert_eq "_script_dir: absolute symlink -> the repo dir (#cli)" "$(sdir "$SD/bin/abs")" "$WANT"
assert_eq "_script_dir: a plain file -> its own dir (#cli)" "$(sdir "$SD/repo/rigforge.sh")" "$WANT"

echo "== unit: link_cli installs + guards the rigforge command (#cli) =="
lc() { # <script_dir> <bin_dir> [add_to_path=true] -> runs link_cli with those, prints its output
    (
        source "$SCRIPT"
        SCRIPT_DIR="$1"
        BIN_DIR="$2"
        ADD_TO_PATH="${3:-true}"
        set +eu
        PATH="$STUBS:$PATH" link_cli 2>&1
    )
}
LC="$(mktemp -d "$SANDBOX/linkcli.XXXXXX")"
mkdir -p "$LC/repo" "$LC/bin"
: >"$LC/repo/rigforge.sh"
lc "$LC/repo" "$LC/bin" >/dev/null
assert_eq "link_cli: symlinks rigforge -> the script (#cli)" "$(readlink "$LC/bin/rigforge" 2>/dev/null)" "$LC/repo/rigforge.sh"
lc "$LC/repo" "$LC/bin" >/dev/null # second call
assert_eq "link_cli: idempotent — one entry (#cli)" "$(find "$LC/bin" -maxdepth 1 -name rigforge | wc -l | tr -d ' ')" "1"
assert_contains "link_cli: missing BIN_DIR warns, never fails (#cli)" "$(lc "$LC/repo" "$LC/nope")" "Skipped the 'rigforge' command"
mkdir -p "$LC/real"
: >"$LC/real/rigforge"
assert_contains "link_cli: refuses to clobber a non-symlink (#cli)" "$(lc "$LC/repo" "$LC/real")" "isn't a RigForge symlink"
assert_eq "link_cli: the pre-existing file is preserved (#cli)" "$([ -L "$LC/real/rigforge" ] && echo symlink || echo file)" "file"
# OFF by default: with add_to_path unset/false, link_cli is a silent no-op (no symlink created).
mkdir -p "$LC/off"
lc "$LC/repo" "$LC/off" false >/dev/null
assert_eq "link_cli: no-op when add_to_path is off (#cli)" "$([ -L "$LC/off/rigforge" ] && echo present || echo absent)" "absent"
# add_to_path is parsed from config.json, defaulting to false.
APP="$(mktemp -d "$SANDBOX/addpath.XXXXXX")"
printf '{ "pools":[{"url":"h:3333"}] }\n' >"$APP/off.json"
printf '{ "pools":[{"url":"h:3333"}], "add_to_path": true }\n' >"$APP/on.json"
assert_eq "add_to_path: defaults to false (#cli)" "$(parse_and_print "$APP/off.json" "$APP" ADD_TO_PATH)" "false"
assert_eq "add_to_path: reads true when set (#cli)" "$(parse_and_print "$APP/on.json" "$APP" ADD_TO_PATH)" "true"

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
        BIN_DIR="$UN/usr-local-bin" \
        RIGFORGE_HOME="$PWD" bash "$SCRIPT" uninstall --yes </dev/null 2>&1)
}
# setup would have linked $BIN_DIR/rigforge -> $UN/rigforge.sh (SCRIPT_DIR=$UN); uninstall must remove
# OUR symlink. (The target need not exist — a dangling symlink is still removed.)
mkdir -p "$UN/usr-local-bin"
ln -s "$UN/rigforge.sh" "$UN/usr-local-bin/rigforge"
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
assert_eq "cli: our 'rigforge' symlink removed (#cli)" "$([ -L "$UN/usr-local-bin/rigforge" ] && echo present || echo gone)" "gone"
# Safety: a `rigforge` we did NOT create (a real file, or a symlink elsewhere) must be left alone.
: >"$UN/usr-local-bin/rigforge"
# Idempotent: a second uninstall is a clean no-op.
out="$(un_run)"
assert_rc "second uninstall exits 0" "$?" "0"
assert_eq "cli: a non-RigForge 'rigforge' is preserved (#cli)" "$([ -f "$UN/usr-local-bin/rigforge" ] && [ ! -L "$UN/usr-local-bin/rigforge" ] && echo kept || echo removed)" "kept"

# Without --yes, uninstall PROMPTS; answering 'n' must abort cleanly and revert NOTHING (a mistyped
# uninstall shouldn't tear down a working rig). Every other uninstall test passes --yes, so this path was
# never taken.
echo "== black-box: uninstall without --yes aborts on 'n' (reverts nothing) =="
UNN="$(mktemp -d "$SANDBOX/uninstn.XXXXXX")"
cp "$ROOT/VERSION" "$UNN/"
mkdir -p "$UNN/etc/systemd/system"
: >"$UNN/etc/systemd/system/xmrig.service"
cat >"$UNN/config.json" <<EOF
{ "HOME_DIR": "$UNN/home", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
out="$(printf 'n\n' | (cd "$UNN" && PATH="$STUBS:$PATH" SYSTEMD_DIR="$UNN/etc/systemd/system" RIGFORGE_HOME="$PWD" bash "$SCRIPT" uninstall 2>&1))"
assert_rc "uninstall 'n' exits 0" "$?" "0"
assert_contains "uninstall 'n' reports it aborted" "$out" "Aborted"
assert_eq "uninstall 'n' left the service unit in place" "$([ -f "$UNN/etc/systemd/system/xmrig.service" ] && echo present || echo gone)" "present"

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

# #tunefix: the optimization target defaults to the `autotune` config value (overridable with
# --perf/--efficiency) and is announced at the start of the run. Isolated sandbox so it doesn't disturb the
# ordered $TN tests above. TUNE_POWER_CMD makes a power source available so efficiency doesn't fall back.
echo "== black-box: tune target follows autotune config + is announced (#tunefix) =="
TT="$(mktemp -d "$SANDBOX/tunetgt.XXXXXX")"
cp "$ROOT/VERSION" "$TT/"
mkdir -p "$TT/util" "$TT/home/worker/xmrig/build" "$TT/cpuok/cpu0/cpufreq"
cp "$ROOT/util/proposed-grub.sh" "$TT/util/" 2>/dev/null
printf '5000000\n' >"$TT/cpu_max"
printf '4800000\n' >"$TT/cpuok/cpu0/cpufreq/scaling_cur_freq"
printf '{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": false }, "cpu": { "yield": false, "priority": 2 } }\n' >"$TT/home/worker/xmrig/build/config.json"
printf '#!/usr/bin/env bash\necho "miner speed 10s 1100.0 H/s max 1100.0 H/s"\n' >"$TT/home/worker/xmrig/build/xmrig"
chmod +x "$TT/home/worker/xmrig/build/xmrig"
tune_target() { # <autotune-config-value> [tune-flags...]
    local atv="$1"
    shift
    printf '{ "HOME_DIR": "%s/home", "autotune": "%s", "pools": [{"url":"h:3333"}] }\n' "$TT" "$atv" >"$TT/config.json"
    (cd "$TT" && PATH="$STUBS:$PATH" CPUFREQ_MAX="$TT/cpu_max" CPU_SYSFS="$TT/cpuok" \
        TUNE_ITERS=1 TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
        TUNE_POWER_CMD='echo 90' RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune "$@" </dev/null 2>&1) | grep -i "Optimization target"
}
tt_eff="$(tune_target efficiency)"
assert_contains "tune defaults to efficiency from autotune=efficiency (#tunefix)" "$tt_eff" "Optimization target: efficiency"
assert_contains "tune notes the target came from config (#tunefix)" "$tt_eff" "from your autotune config"
assert_contains "tune defaults to performance from autotune=performance (#tunefix)" "$(tune_target performance)" "Optimization target: performance"
assert_contains "tune defaults to performance from autotune=disabled (#tunefix)" "$(tune_target disabled)" "Optimization target: performance"
tt_ovr="$(tune_target performance --efficiency)"
assert_contains "--efficiency overrides config performance (#tunefix)" "$tt_ovr" "Optimization target: efficiency"
assert_eq "an explicit target has no 'from config' note (#tunefix)" "$(printf '%s' "$tt_ovr" | grep -c 'from your autotune config')" "0"
assert_contains "--perf overrides config efficiency (#tunefix)" "$(tune_target efficiency --perf)" "Optimization target: performance"
# the sudo auto-elevate is gated on an interactive TTY, so a non-interactive (</dev/null) tune never re-execs.
assert_eq "non-interactive tune does not auto-elevate (#tunefix)" "$(tune_target performance | grep -c 're-running with sudo')" "0"
# Cover the interactive auto-elevate path. Run it as a real child process (so coverage sees the exec) with
# RIGFORGE_FORCE_ELEVATE=1 forcing the gate regardless of the runner's uid, and a PATH `sudo` stub so exec
# captures the re-exec instead of looping.
ELB="$(mktemp -d "$SANDBOX/elev.XXXXXX")"
printf '#!/usr/bin/env bash\necho "REEXEC: $*"\n' >"$ELB/sudo"
chmod +x "$ELB/sudo"
elev_out="$(cd "$TT" && PATH="$ELB:$STUBS:$PATH" RIGFORGE_FORCE_ELEVATE=1 STUB_UNAME_S=Linux \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --live </dev/null 2>&1)"
assert_contains "tune auto-elevates with sudo when interactive (#tunefix)" "$elev_out" "REEXEC:"
assert_contains "tune re-execs the same tune command (#tunefix)" "$elev_out" "tune --live"

# tune --history is read-only: it reports the applied tuning ($OVR) + the last full run ($TLOG) the tune
# above wrote. STUB_UNAME_S=Darwin skips the Linux-only periodic-autotune section (covered by the rig e2e).
hout="$(cd "$TN" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --history </dev/null 2>&1)"
assert_rc "tune --history exits 0 (#hist)" "$?" "0"
assert_contains "tune --history: shows applied prefetch_mode (#hist)" "$hout" "prefetch_mode=2"
assert_contains "tune --history: shows applied threads (#hist)" "$hout" "threads=4"
assert_contains "tune --history: shows the last full tune (#hist)" "$hout" "Last full tune"
assert_contains "tune --history: shows the candidate count (#hist)" "$hout" "candidate(s) tried"

# tune --clear removes the tuning state.
out="$(cd "$TN" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --clear </dev/null 2>&1)"
assert_rc "tune --clear exits 0" "$?" "0"
assert_eq "overrides removed by --clear" "$([ -f "$OVR" ] && echo y || echo n)" "n"
# After --clear, --history reports the un-tuned (auto-defaults) state instead of crashing on missing files.
hout="$(cd "$TN" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --history </dev/null 2>&1)"
assert_rc "tune --history after --clear exits 0 (#hist)" "$?" "0"
assert_contains "tune --history: 'none' once cleared (#hist)" "$hout" "none yet — running XMRig's auto defaults"

# tune --history on Linux: with an installed+active auto-tune timer (stubbed systemctl) and a journal of
# decisions (stubbed journalctl), it surfaces the periodic-autotune section — the Linux-only branch.
echo "== black-box: tune --history surfaces periodic auto-tune (Linux) (#hist) =="
HL="$(mktemp -d "$SANDBOX/histlinux.XXXXXX")"
cp "$ROOT/VERSION" "$HL/"
mkdir -p "$HL/home/worker" "$HL/bin"
cat >"$HL/config.json" <<EOF
{ "HOME_DIR": "$HL/home", "pools": [{"url":"h:3333"}] }
EOF
printf '{ "randomx": { "scratchpad_prefetch_mode": 1 } }\n' >"$HL/home/worker/tune-overrides.json"
printf '{ "best": { "hashrate": 10741 }, "target": "perf", "results": [1,2] }\n' >"$HL/home/worker/rigforge-tune.json"
cat >"$HL/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*"cat rigforge-autotune.service"*) printf 'Environment=AUTOTUNE_TARGET=perf\n' ;; # #95: drives the target line
*"cat rigforge-autotune.timer"*) echo "OnCalendar=daily" ;;
*"is-active"*) echo active ;;
*NextElapseUSecRealtime*) echo "Mon 2099-01-01 00:00:00 UTC" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nprintf "[INFO] autotune: prefetch_mode=2 not better (10758 vs 10741 H/s) — rolling back to 1.\\n"\n' >"$HL/bin/journalctl"
chmod +x "$HL/bin/systemctl" "$HL/bin/journalctl"
hout="$(cd "$HL" && PATH="$HL/bin:$STUBS:$PATH" STUB_UNAME_S=Linux RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --history </dev/null 2>&1)"
assert_rc "tune --history (Linux) exits 0 (#hist)" "$?" "0"
assert_contains "tune --history: autotune shown as enabled (#hist)" "$hout" "Periodic autotune: enabled"
# #95: the target reads in the config's vocabulary ("performance"), not the internal "perf".
assert_contains "tune --history: target in config vocabulary (#95)" "$hout" "optimizing for: performance (raw hashrate)"
assert_contains "tune --history: shows the schedule (#hist)" "$hout" "schedule: daily"
assert_contains "tune --history: shows the next scheduled run (#hist)" "$hout" "next run: Mon 2099-01-01"
assert_contains "tune --history: surfaces a recent decision (#hist)" "$hout" "rolling back to 1"
assert_contains "tune --history: last-tune summary on Linux (#hist)" "$hout" "candidate(s) tried"

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
# watts is now an under-load average (a float, e.g. 100.00), so compare numerically — jq 1.7 would
# otherwise preserve the literal "100.00". #81 samples it DURING the window, not at idle afterwards.
assert_eq "records watts" "$(J "$TLOG" '.results[0].watts == 100')" "true"
assert_eq "records temperature" "$(J "$TLOG" '.results[0].temp_c')" "55"
assert_eq "computes hashrate-per-watt" "$(J "$TLOG" '.results[0].hs_per_watt == 12')" "true"
assert_contains "reports best efficiency" "$out" "H/s per watt"

# #81: the built-in RAPL reader + the watts-from-energy arithmetic (the default power source, no
# TUNE_POWER_CMD). Pure helpers, tested directly with a fake powercap tree + fixed energy deltas.
echo "== unit: power measurement helpers (#81) =="
PWR="$(mktemp -d "$SANDBOX/pwr.XXXXXX")"
mkdir -p "$PWR/intel-rapl:0" "$PWR/intel-rapl:0:0" "$PWR/intel-rapl:1"
printf package-0 >"$PWR/intel-rapl:0/name"
printf 1000000 >"$PWR/intel-rapl:0/energy_uj"
printf 9000000 >"$PWR/intel-rapl:0/max_energy_range_uj"
printf core >"$PWR/intel-rapl:0:0/name" # a subzone that must NOT be counted
printf 500000 >"$PWR/intel-rapl:0:0/energy_uj"
printf package-1 >"$PWR/intel-rapl:1/name"
printf 2000000 >"$PWR/intel-rapl:1/energy_uj"
printf 9000000 >"$PWR/intel-rapl:1/max_energy_range_uj"
rapl() { (
    source "$SCRIPT"
    OS_TYPE=Linux
    RAPL_DIR="$PWR"
    _rapl_sum "$1"
); }
wfe() { (
    source "$SCRIPT"
    _watts_from_energy "$@"
); }
mean() { (
    source "$SCRIPT"
    _mean "$@"
); }
assert_eq "RAPL sums PACKAGE energy only, ignoring the core subzone (#81)" "$(rapl energy_uj)" "3000000"
assert_eq "RAPL sums the package wrap ranges (#81)" "$(rapl max_energy_range_uj)" "18000000"
assert_eq "watts = energy delta / time (1.00 W) (#81)" "$(wfe 1000000 4000000 18000000 3)" "1.00"
assert_eq "watts corrects a single counter wrap (#81)" "$(wfe 17000000 1000000 18000000 2)" "1.00"
assert_eq "watts empty on elapsed<=0 (no divide-by-zero) (#81)" "$(wfe 1 2 9 0)" ""
assert_eq "mean averages the samples (#81)" "$(mean 80 100 120)" "100.00"
# Degenerate inputs, from the missing-sensor / single-read paths that the fakes never reproduce: the stats
# helpers must stay well-defined (no blank garbage, no divide-by-zero) so a candidate with one usable read
# still ranks. med/sd source the same helpers the tune loop uses.
med() { (
    source "$SCRIPT"
    _median "$@"
); }
sd() { (
    source "$SCRIPT"
    _stddev "$@"
); }
assert_eq "median of a single sample is itself (#81)" "$(med 500)" "500"
assert_eq "median of no samples is empty, not 0 (#81)" "$(med)" ""
assert_eq "stddev needs >=2 samples, else 0 (#81)" "$(sd 500)" "0"
assert_eq "mean of no samples is empty (#81)" "$(mean)" ""
# A backwards energy counter with NO wrap-max (RAPL absent/mispaired) must yield empty, not negative watts.
# The existing wrap test always passes mx>0 (the correction branch), so the mx=0 give-up branch was unrun.
assert_eq "watts empty on a backwards counter with no wrap-max (#81)" "$(wfe 5000000 1000000 0 2)" ""

# #81: the BUG this fixes — watts must be sampled UNDER LOAD, not at idle after the bench. A fake xmrig
# stays alive for the poll window and marks DONE only on exit; TUNE_POWER_CMD returns 200 W while running,
# 50 W once DONE. The old code (read after the kill) recorded ~50; the fix records 200.
echo "== black-box: tune samples power under load, not idle (#81) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
trap 'touch "$PWR_DONE"' EXIT       # idle is marked only AFTER the run ends
echo "speed 1500.0 H/s max 1500.0 H/s"
sleep "${PWR_SLEEP:-0.6}"           # stay loaded long enough for the poll loop to sample power
EOF
chmod +x "$BD/xmrig"
rm -f "$OVR" "$TN/pwr_done"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false \
    TUNE_THREADS=-1 PWR_DONE="$TN/pwr_done" PWR_SLEEP=0.6 \
    TUNE_POWER_CMD='[ -f "$PWR_DONE" ] && echo 50 || echo 200' \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "power-under-load tune exits 0 (#81)" "$?" "0"
# Assert the load-vs-idle DISTINCTION, not an exact average: the window samples are ~200 (loaded), so the
# mean lands well above the 50 W idle floor. (An exact == would be timing-flaky — once the fake exits its
# PID can linger as a zombie that `kill -0` still sees, slipping one idle sample into the mean.) The old
# bug sampled only after the kill, so it recorded ~50; the fix records load-side power (>100).
assert_eq "watts sampled under load (>100), not idle (~50) (#81)" "$(J "$TLOG" '.results[0].watts > 100')" "true"
assert_eq "hs_per_watt reflects load power (1500/load < 15, vs 1500/50=30 idle) (#81)" "$(J "$TLOG" '.results[0].hs_per_watt < 15')" "true"

# #81: exercise the built-in RAPL path end-to-end with NO TUNE_POWER_CMD — the fake powercap tree ($PWR,
# from the helper unit test) makes the energy readable, so the energy-delta branch runs and records a
# watts field. (The arithmetic is unit-tested above; this proves the wiring is used by default and that a
# static counter — zero delta — degrades to null rather than erroring.)
echo "== black-box: tune built-in RAPL power path (#81) =="
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "speed 1300.0 H/s max 1300.0 H/s"
EOF
chmod +x "$BD/xmrig"
rm -f "$OVR"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false \
    TUNE_THREADS=-1 RAPL_DIR="$PWR" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_rc "RAPL-path tune exits 0 (#81)" "$?" "0"
assert_eq "RAPL path records a watts field without TUNE_POWER_CMD (#81)" "$(J "$TLOG" '.results[0] | has("watts")')" "true"

# #79: the efficiency target ranks candidates by hashrate-per-watt instead of raw H/s. Unit-test the gate
# directly: a slower-but-more-efficient candidate is rejected under perf and accepted under efficiency.
echo "== unit: efficiency-target acceptance gate (#79) =="
AT2="$(mktemp -d "$SANDBOX/acc.XXXXXX")"
printf 'cand\t0\nbest\t0\n' >"$AT2/sd" # zero sample noise so only the metric matters
: >"$AT2/thr"
printf 'cand\t10.0\nbest\t8.0\n' >"$AT2/hpw" # cand is slower (1000<1200) but more efficient (10>8 hpw)
acc() {                                      # <target>; cand=1000H/s/10hpw vs best=1200H/s/8hpw
    (
        source "$SCRIPT"
        TUNE_TARGET="$1"
        TUNE_MIN_DELTA=0.01
        TUNE_SIGMA=0
        MEMO_SD_FILE="$AT2/sd"
        MEMO_THROTTLE_FILE="$AT2/thr"
        MEMO_HPW_FILE="$AT2/hpw"
        set +e
        _accept_better 1000 cand 1200 best && echo accept || echo reject
    )
}
assert_eq "perf: a slower candidate is rejected (#79)" "$(acc perf)" "reject"
assert_eq "efficiency: a more-efficient candidate is accepted (#79)" "$(acc efficiency)" "accept"
# #79: if EITHER side lacks a power reading, efficiency ranking can't apply — it must fall back to the raw
# H/s comparison so the search still progresses. Here cand has NO hpw entry, so under efficiency the slower
# cand (1000 < 1200) is rejected on raw H/s, exactly as under perf. (The existing gate always has both.)
printf 'best\t8.0\n' >"$AT2/hpw-partial"
assert_eq "efficiency with a missing power reading falls back to raw H/s (#79)" "$(
    source "$SCRIPT"
    TUNE_TARGET=efficiency
    TUNE_MIN_DELTA=0.01
    TUNE_SIGMA=0
    MEMO_SD_FILE="$AT2/sd"
    MEMO_THROTTLE_FILE="$AT2/thr"
    MEMO_HPW_FILE="$AT2/hpw-partial"
    set +e
    _accept_better 1000 cand 1200 best && echo accept || echo reject
)" "reject"

# The scalar scorer used by the autotune log/ranking has the same no-power fallback (#95): efficiency
# ranks hs/W only when watts is present and > 0; otherwise it scores raw H/s. Only ever exercised
# indirectly (full autotune runs always supply watts) — unit-test the branch directly.
echo "== unit: _autotune_score efficiency needs watts, else raw H/s (#95) =="
asc() { (
    source "$SCRIPT"
    _autotune_score "$@"
); }
assert_eq "efficiency with watts scores hashrate-per-watt" "$(asc efficiency 1000 8)" "125.0000"
assert_eq "efficiency with zero watts falls back to raw H/s" "$(asc efficiency 1000 0)" "1000"
assert_eq "efficiency with empty watts falls back to raw H/s" "$(asc efficiency 1000 '')" "1000"
assert_eq "perf target always scores raw H/s" "$(asc perf 1000 8)" "1000"

# #79: end-to-end — with power that makes prefetch=1 more efficient (1000 H/s @ 100 W = 10 hpw) than
# prefetch=2 (1200 H/s @ 200 W = 6 hpw), perf picks the faster prefetch=2 and efficiency picks prefetch=1.
echo "== black-box: efficiency winner differs from perf winner (#79) =="
cat >"$BD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": true }, "cpu": { "yield": false, "priority": 2 } }
EOF
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
if [ "$m" = 2 ]; then echo 200 >"$PWF"; hr=1200; else echo 100 >"$PWF"; hr=1000; fi
echo "speed $hr.0 H/s max $hr.0 H/s"
sleep "${PWR_SLEEP:-0.8}" # stay loaded so the poll loop's (correct) power samples dominate the up-front one
EOF
chmod +x "$BD/xmrig"
PWF="$TN/pwf"
printf '150\n' >"$PWF"
effrun() { # <--perf|--efficiency>
    rm -f "$OVR"
    (cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES="1 2" TUNE_YIELDS=false \
        TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 PWF="$PWF" PWR_SLEEP=0.8 TUNE_POWER_CMD='cat "$PWF"' \
        RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune "$1" </dev/null 2>&1)
}
out="$(effrun --perf)"
assert_rc "perf tune exits 0 (#79)" "$?" "0"
assert_eq "perf picks the faster prefetch=2 (#79)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"
out="$(effrun --efficiency)"
assert_eq "efficiency picks the more-efficient prefetch=1 (#79)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "1"
assert_eq "efficiency tune records target=efficiency (#79)" "$(J "$TLOG" '.target')" "efficiency"

# #79: efficiency needs a power source — without RAPL or TUNE_POWER_CMD it warns and falls back to perf.
echo "== black-box: tune --efficiency falls back without a power source (#79) =="
cat >"$BD/xmrig" <<'EOF'
#!/usr/bin/env bash
echo "speed 1100.0 H/s max 1100.0 H/s"
EOF
chmod +x "$BD/xmrig"
rm -f "$OVR"
out="$(cd "$TN" && PATH="$STUBS:$PATH" TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false \
    TUNE_THREADS=-1 RAPL_DIR="/nonexistent-rapl" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --efficiency </dev/null 2>&1)"
assert_rc "efficiency-fallback tune exits 0 (#79)" "$?" "0"
assert_contains "efficiency without power warns + falls back (#79)" "$out" "needs a power source"
assert_eq "efficiency fallback records target=perf (#79)" "$(J "$TLOG" '.target')" "perf"

# #54: live tuning measures the running miner via the API instead of --bench, then applies the winner.
# API is stubbed to a constant so no knob wins; the search stays at the seed and the winner is applied.
echo "== black-box: tune --live (API-measured) (#54) =="
# RAPL_DIR points the built-in power reader at the fake powercap tree, so #81's live RAPL branch runs too.
out="$(cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" RAPL_DIR="$PWR" \
    API_CMD='echo 1500' TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=1 \
    TUNE_SEEDS=auto TUNE_PREFETCH_MODES="0 1" TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --live </dev/null 2>&1)"
assert_rc "tune --live exits 0" "$?" "0"
assert_eq "live log records mode=live" "$(J "$TLOG" '.mode')" "live"
assert_contains "live tune applies the winner" "$out" "Applied the winning config to the live miner"
# --live measures the real pool algorithm, so it must NOT print the rx/0-only bench caveat.
assert_absent "live mode omits the rx/0 bench note" "$out" "measures Monero's RandomX"
# 'tune --now --long' is the full all-knob LIVE sweep (vs '--now'/'--short''s quick prefetch pass): it
# must fall through to the full tune in live mode, not short-circuit to the quick autotune engine.
out="$(cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" RAPL_DIR="$PWR" \
    API_CMD='echo 1500' TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=1 \
    TUNE_SEEDS=auto TUNE_PREFETCH_MODES="0 1" TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --now --long </dev/null 2>&1)"
assert_rc "tune --now --long exits 0" "$?" "0"
assert_eq "tune --now --long runs the full live sweep (mode=live)" "$(J "$TLOG" '.mode')" "live"
assert_contains "tune --now --long applies the winner live" "$out" "Applied the winning config to the live miner"
# #81: live mode also samples power — with TUNE_POWER_CMD it averages watts alongside the API samples.
out="$(cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" \
    API_CMD='echo 1500' TUNE_POWER_CMD='echo 90' TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=2 \
    TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune --live </dev/null 2>&1)"
assert_rc "live power tune exits 0 (#81)" "$?" "0"
assert_eq "live mode records watts via TUNE_POWER_CMD (#81)" "$(J "$TLOG" '.results[0].watts == 90')" "true"
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
assert_contains "autotune live-sweeps every prefetch mode (#46)" "$out" "live-sweeping prefetch modes"
assert_contains "autotune measured a non-baseline mode (#46)" "$out" "prefetch_mode=0 measured"
assert_contains "autotune adopts the fastest mode (#46)" "$out" "best is prefetch_mode=2"
assert_eq "autotune updated prefetch to the winner" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "2"
assert_eq "autotune PRESERVED tuned threads (#46 merge)" "$(J "$OVR" '.cpu.rx')" "4"
assert_eq "autotune PRESERVED tuned yield (#46 merge)" "$(J "$OVR" '.cpu.yield')" "false"
# Noise guard: when no mode beats the baseline (a flat fake), autotune keeps the current mode.
cat >"$OVR" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1 }, "cpu": { "rx": 4 } }
EOF
out="$(cd "$TN" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$TN/logrotate" \
    API_CMD='echo 1200' AUTOTUNE_WARMUP=0 AUTOTUNE_SAMPLES=1 AUTOTUNE_INTERVAL=0 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" autotune </dev/null 2>&1)"
assert_rc "autotune (flat) exits 0 (#46)" "$?" "0"
assert_contains "autotune keeps current mode when nothing wins (#46)" "$out" "no mode beat the baseline"
assert_eq "autotune left prefetch at the current mode (#46)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "1"
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
# hash -r: earlier tests run lscpu via the generic $STUBS/lscpu (no "Core(s) per socket:" line), which
# bash may keep in its command hash. Some bash 3.2 builds then reuse that stale path instead of honoring
# the $TC-first PATH below, so _physical_cores would read no cores-per-socket and return empty. Clearing
# the hash forces a fresh PATH lookup so the richer $TC/lscpu wins — deterministic on every host.
phys="$(
    source "$SCRIPT"
    set +e
    hash -r 2>/dev/null || true
    OS_TYPE=Linux
    PATH="$TC:$STUBS:$PATH" _physical_cores
)"
assert_eq "physical cores = cores-per-socket x sockets" "$phys" "8"
cands="$(
    source "$SCRIPT"
    set +e
    hash -r 2>/dev/null || true
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
# A bad archive must fail LOUDLY and leave the existing good config.json untouched — a silent clobber here
# would destroy a working config. FR/config.json currently holds DONATION=7 (restored above); assert both
# the error AND that it survives. (1) not a tar/gzip at all:
printf 'this is not a tar archive\n' >"$FR/junk.tar.gz"
out="$(cd "$FR" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y "$FR/junk.tar.gz" </dev/null 2>&1)"
assert_rc "restore of a non-tar archive fails" "$?" "1"
assert_contains "restore of a non-tar archive is reported" "$out" "Could not extract"
assert_eq "corrupt archive did not clobber the existing config" "$(J "$FR/config.json" '.DONATION')" "7"
# (2) a valid tar that has no config.json (extracts fine, but isn't a RigForge backup):
NOCFG="$(mktemp -d "$SANDBOX/nocfg.XXXXXX")"
printf 'stray\n' >"$NOCFG/not-config.txt"
tar -czf "$FR/nocfg.tar.gz" -C "$NOCFG" not-config.txt
out="$(cd "$FR" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y "$FR/nocfg.tar.gz" </dev/null 2>&1)"
assert_rc "restore of a config-less archive fails" "$?" "1"
assert_contains "restore of a config-less archive is reported" "$out" "no config.json"
assert_eq "config-less archive did not clobber the existing config" "$(J "$FR/config.json" '.DONATION')" "7"
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
echo "== unit: config.reference.json (#23) =="
ADV="$ROOT/config.reference.json"
if jq -e . "$ADV" >/dev/null 2>&1; then ok "advanced example is valid JSON"; else bad "advanced example is valid JSON" "jq parse failed"; fi
# The advanced example documents exactly the user-facing keys. The rig label lives in pools[].user and
# the template is internal, so WORKER_NAME / WORKER_CONFIG_FILE / POOL_HOST must NOT appear.
for k in pools ACCESS_TOKEN DONATION HOME_DIR; do
    if jq -e --arg k "$k" 'has($k)' "$ADV" >/dev/null 2>&1; then ok "advanced example documents $k"; else bad "advanced example documents $k" "key missing"; fi
done
for k in POOL_HOST WORKER_NAME WORKER_CONFIG_FILE; do
    assert_absent "advanced example has no $k key" "$(cat "$ADV")" "\"$k\""
done

# config.minimal.json is the copy-me starter (referenced by the docs and shipped in the release bundle).
# It must be valid JSON, carry an obvious unreplaced placeholder, and be REJECTED by parse_config unedited
# — so a user can't accidentally deploy the template and mine to a bogus host. (It can drift unnoticed
# otherwise: unlike config.reference.json, nothing else validates it.)
echo "== unit: config.minimal.json (starter) =="
TPL="$ROOT/config.minimal.json"
if jq -e . "$TPL" >/dev/null 2>&1; then ok "config.minimal.json is valid JSON"; else bad "config.minimal.json is valid JSON" "jq parse failed"; fi
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
# Sister API (#99): config keys, the socket-unit install toggle, and the api-serve request handler.
echo "== unit: sister API config keys (#99) =="
api_mode() { parse_and_print "$1" "$ROOT" API_MODE; }
c="$(mkconf api_def "{ $POOL }")"
assert_eq "api omitted -> disabled" "$(api_mode "$c")" "disabled"
assert_eq "api_port default 8081" "$(parse_and_print "$c" "$ROOT" API_PORT)" "8081"
assert_eq "api_bind default 0.0.0.0" "$(parse_and_print "$c" "$ROOT" API_BIND)" "0.0.0.0"
c="$(mkconf api_on "{ $POOL, \"api\": \"enabled\", \"api_port\": 9000, \"api_bind\": \"192.168.1.5\" }")"
assert_eq "api enabled parses" "$(api_mode "$c")" "enabled"
assert_eq "api_port override honoured" "$(parse_and_print "$c" "$ROOT" API_PORT)" "9000"
assert_eq "api_bind override honoured" "$(parse_and_print "$c" "$ROOT" API_BIND)" "192.168.1.5"
c="$(mkconf api_bad "{ $POOL, \"api\": \"maybe\" }")"
parse_rc "$c" "$ROOT"
assert_rc "invalid api value rejected (typo must not silently disable)" "$?" "1"
c="$(mkconf api_p0 "{ $POOL, \"api_port\": 8080 }")"
parse_rc "$c" "$ROOT"
assert_rc "api_port 8080 collision rejected" "$?" "1"
c="$(mkconf api_pbig "{ $POOL, \"api_port\": 70000 }")"
parse_rc "$c" "$ROOT"
assert_rc "api_port out of range rejected" "$?" "1"
c="$(mkconf api_pstr "{ $POOL, \"api_port\": \"abc\" }")"
parse_rc "$c" "$ROOT"
assert_rc "non-numeric api_port rejected" "$?" "1"
c="$(mkconf api_bbad "{ $POOL, \"api_bind\": \"not an ip!\" }")"
parse_rc "$c" "$ROOT"
assert_rc "malformed api_bind rejected" "$?" "1"

echo "== black-box: install_api server/timer enable/disable (#99/#164) =="
APS="$(mktemp -d "$SANDBOX/aps.XXXXXX")"
mkdir -p "$APS/systemd"
cp "$ROOT/systemd/rigforge-api.service.template" "$ROOT/systemd/rigforge-api-refresh.service.template" "$ROOT/systemd/rigforge-api-refresh.timer.template" "$APS/systemd/"
cp -R "$ROOT/util" "$APS/" 2>/dev/null || true
run_api_install() { # <disabled|enabled> [port]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$APS"
        SYSTEMD_DIR="$APS/systemd"
        REAL_USER=rfop
        API_MODE="$1"
        API_BIND=0.0.0.0
        API_PORT="${2:-8081}"
        set +e
        PATH="$STUBS:$PATH" install_api 2>&1
    )
}
out="$(run_api_install enabled)"
assert_eq "api enable writes the persistent server unit" "$([ -f "$APS/systemd/rigforge-api.service" ] && echo y || echo n)" "y"
assert_eq "api enable writes the refresh service" "$([ -f "$APS/systemd/rigforge-api-refresh.service" ] && echo y || echo n)" "y"
assert_eq "api enable writes the refresh timer" "$([ -f "$APS/systemd/rigforge-api-refresh.timer" ] && echo y || echo n)" "y"
assert_contains "server unit runs the stdlib server with the configured bind/port" "$(cat "$APS/systemd/rigforge-api.service")" "api-server.py 0.0.0.0 8081"
assert_eq "server is maximally polite: exactly Nice=19 as a directive (#164)" "$(grep -c '^Nice=19$' "$APS/systemd/rigforge-api.service")" "1"
assert_eq "server is sandboxed read-only (#99 hardening)" "$(grep -c '^ProtectSystem=strict$' "$APS/systemd/rigforge-api.service")" "1"
assert_eq "refresh runs at idle priority off the request path (#164)" "$(grep -c '^IOSchedulingClass=idle$' "$APS/systemd/rigforge-api-refresh.service")" "1"
assert_contains "refresh timer fires every 15s" "$(cat "$APS/systemd/rigforge-api-refresh.timer")" "OnUnitActiveSec=15"
assert_contains "enable log reports token posture without any token value" "$out" "token: open"
# Port change re-renders + restarts the server (config re-read on restart).
APS_CALLS="$APS/calls.log"
(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$APS"
    SYSTEMD_DIR="$APS/systemd"
    REAL_USER=rfop
    API_MODE=enabled
    API_BIND=0.0.0.0
    API_PORT=9000
    set +e
    PATH="$STUBS:$PATH" CALL_LOG="$APS_CALLS" install_api >/dev/null 2>&1
)
assert_contains "port change re-renders the server unit (#99)" "$(cat "$APS/systemd/rigforge-api.service")" "api-server.py 0.0.0.0 9000"
assert_contains "port change restarts the server to re-read config (#99)" "$(cat "$APS_CALLS")" "[systemctl] restart rigforge-api.service"
# Legacy v1.2.x socket pair is removed on sight (upgrade convergence).
printf 'x' >"$APS/systemd/rigforge-api.socket"
printf 'x' >"$APS/systemd/rigforge-api@.service"
run_api_install enabled >/dev/null
assert_eq "legacy per-connection socket removed on upgrade (#164)" "$([ -f "$APS/systemd/rigforge-api.socket" ] && echo y || echo n)" "n"
assert_eq "legacy per-connection handler removed on upgrade (#164)" "$([ -f "$APS/systemd/rigforge-api@.service" ] && echo y || echo n)" "n"
out="$(run_api_install disabled)"
assert_eq "api disable removes the server unit" "$([ -f "$APS/systemd/rigforge-api.service" ] && echo y || echo n)" "n"
assert_eq "api disable removes the refresh service" "$([ -f "$APS/systemd/rigforge-api-refresh.service" ] && echo y || echo n)" "n"
assert_eq "api disable removes the refresh timer" "$([ -f "$APS/systemd/rigforge-api-refresh.timer" ] && echo y || echo n)" "n"

echo "== unit: api-refresh produces the response files (#99/#164) =="
APIQ="$(mktemp -d "$SANDBOX/apiq.XXXXXX")"
mkdir -p "$APIQ/home/worker"
printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "h:3333"}] }\n' "$APIQ" >"$APIQ/config.json"
run_refresh() { # [env pairs...]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$APIQ/config.json"
        RIGFORGE_API_DATA="$APIQ/data"
        eval "${1:-true}"
        set +e
        PATH="$STUBS:$PATH" api_refresh 2>/dev/null
    )
}
run_refresh # stub curl answers the xmrig probe
assert_eq "refresh writes all three response files" "$(ls "$APIQ/data" | sort | tr '\n' ' ')" "health.json summary.json tune.json "
assert_eq "summary: xmrig fields pass through unchanged (superset rule)" "$(jq -r '.hashrate.total[0]' "$APIQ/data/summary.json")" "1234.5"
assert_eq "summary: rigforge.version = the VERSION file" "$(jq -r '.rigforge.version' "$APIQ/data/summary.json")" "$(cat "$ROOT/VERSION")"
assert_eq "summary: provenance carries the full pinned commit" "$(jq -r '.rigforge.xmrig_commit | length' "$APIQ/data/summary.json")" "40"
assert_eq "/health wire contract: exact key set" "$(jq -cS 'keys' "$APIQ/data/health.json")" '["clock_pct_of_boost","firmware","governor","hugepages_1g","hugepages_total","msr","ram","service_active","smt","throttling","xmp"]'
assert_eq "/tune wire contract: exact key set" "$(jq -cS 'keys' "$APIQ/data/tune.json")" '["applied","autotune","candidates_tried","last_best_hs","target"]'
run_refresh 'API_CMD="printf %s \"\""'
assert_eq "xmrig down: summary still produced with the marker" "$(jq -r '.rigforge.xmrig_api' "$APIQ/data/summary.json")" "unreachable"
printf '{broken' >"$APIQ/home/worker/tune-overrides.json"
run_refresh
assert_eq "corrupt tune-overrides -> applied null, not a crash" "$(jq -r '.applied' "$APIQ/data/tune.json")" "null"
rm -f "$APIQ/home/worker/tune-overrides.json"
# The dispatch entry is wired (any OS: rc + message prove the verb was reached).
out="$( (RIGFORGE_HOME="$APIQ" bash "$SCRIPT" api-refresh </dev/null) 2>&1 || true)"
if [ "$(uname -s)" = Linux ]; then
    assert_contains "black-box api-refresh dispatch runs (Linux)" "$out" ""
else
    assert_contains "api-refresh refuses off-Linux" "$out" "Linux-only"
fi

echo "== black-box: the persistent api server (#164, the xmrig model) =="
# python3 is the server's runtime (stock on Ubuntu runners, macOS dev boxes, and the container
# e2e). The kcov coverage container is deliberately apt-free and lacks it — skip LOUDLY there;
# the suite still enforces this block in CI's Test suite, the macOS job, and locally, and
# api-server.py is python (outside kcov's bash coverage) so no coverage is lost by skipping.
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not present (kcov container) — the api-server wire suite runs in the other CI jobs"
    APISRV_SKIP=1
else
    APISRV_SKIP=0
fi
if [ "$APISRV_SKIP" = 0 ]; then
    python3 -m py_compile "$ROOT/util/api-server.py" && ok "api-server.py compiles" || bad "api-server.py does not compile" ""
    APISRV="$(mktemp -d "$SANDBOX/apisrv.XXXXXX")"
    printf '%s' '{"hashrate":{"total":[1234.5]},"rigforge":{"version":"t"}}' >"$APISRV/summary.json"
    printf '%s' '{"service_active":true}' >"$APISRV/health.json"
    printf '%s' '{"applied":null}' >"$APISRV/tune.json"
    STOK="tok-srv1"
    printf '{ "pools": [{"url": "h:3333"}], "ACCESS_TOKEN": "%s" }\n' "$STOK" >"$APISRV/config.json"
    APIPORT=$((20000 + RANDOM % 20000))
    python3 "$ROOT/util/api-server.py" 127.0.0.1 "$APIPORT" "$APISRV" "$APISRV/config.json" &
    APISRV_PID=$!
    srv_up=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$APIPORT/health" 2>/dev/null; then
            srv_up=1
            break
        fi
        sleep 0.3
    done
    assert_eq "server comes up" "$srv_up" "1"
    hdrs="$(curl -isS --max-time 5 -H "Authorization: Bearer $STOK" "http://127.0.0.1:$APIPORT/tune" 2>/dev/null | tr -d '\r' | sed -n '1,/^$/p')"
    assert_contains "server: 200 with the exact status line" "$hdrs" "HTTP/1.1 200 OK"
    assert_contains "server: application/json" "$hdrs" "Content-Type: application/json"
    assert_absent "server: no server banner to fingerprint" "$hdrs" "Server:"
    assert_absent "server: no date banner either" "$hdrs" "Date:"
    assert_eq "server: exactly 3 response headers" "$(printf '%s' "$hdrs" | grep -c ':')" "3"
    body="$(curl -fsS --max-time 5 -H "Authorization: Bearer $STOK" "http://127.0.0.1:$APIPORT/2/summary" 2>/dev/null)"
    assert_eq "server: serves the produced summary verbatim" "$(printf '%s' "$body" | jq -r '.hashrate.total[0]')" "1234.5"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$APIPORT/2/summary")"
    assert_eq "server: unauthed -> 401" "$code" "401"
    resp="$(curl -sS --max-time 5 "http://127.0.0.1:$APIPORT/2/summary" 2>/dev/null)"
    assert_absent "server: 401 body never echoes the token" "$resp" "$STOK"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer wrong" "http://127.0.0.1:$APIPORT/health")"
    assert_eq "server: wrong bearer -> 401" "$code" "401"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization:Bearer $STOK" "http://127.0.0.1:$APIPORT/health")"
    assert_eq "server: bearer without a space after the colon -> 200" "$code" "200"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $STOK" "http://127.0.0.1:$APIPORT/health?verbose=1")"
    assert_eq "server: query string stripped, route matches" "$code" "200"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $STOK" "http://127.0.0.1:$APIPORT/nope")"
    assert_eq "server: unknown route -> 404" "$code" "404"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X PUT -H "Authorization: Bearer $STOK" "http://127.0.0.1:$APIPORT/1/config")"
    assert_eq "server: non-GET -> 405 (read-only)" "$code" "405"
    rm -f "$APISRV/health.json"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $STOK" "http://127.0.0.1:$APIPORT/health")"
    assert_eq "server: missing state file -> 503 warming up" "$code" "503"
    kill "$APISRV_PID" 2>/dev/null || true
    # Fail-closed: a config that exists but cannot be parsed must refuse to start (a dropped token
    # would silently open the API).
    printf '{broken' >"$APISRV/config.json"
    python3 "$ROOT/util/api-server.py" 127.0.0.1 "$APIPORT" "$APISRV" "$APISRV/config.json" 2>/dev/null &
    BROKEN_PID=$!
    sleep 1
    if kill -0 "$BROKEN_PID" 2>/dev/null; then
        bad "server started despite an unreadable config (token posture unknown)" ""
        kill "$BROKEN_PID" 2>/dev/null || true
    else
        ok "server refuses to start on an unreadable config (fail closed)"
    fi
fi # APISRV_SKIP

# ---------------------------------------------------------------------------
echo ""
printf 'rigforge tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
