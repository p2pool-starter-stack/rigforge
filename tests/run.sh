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

# #418: keep the suite's own bytecode cache out of the tracked tree. The two `python3 -m py_compile`
# checks below write `util/__pycache__/*.pyc` next to the source, and that debris outlives the run:
# `git status` then reads dirty on a clean checkout and the PR-opening warning cries wolf, in exactly
# the signal a reader uses to decide whether it is safe to commit. `-B` / PYTHONDONTWRITEBYTECODE
# does NOT suppress it — py_compile writes the cache file explicitly rather than through the import
# machinery those disable. PYTHONPYCACHEPREFIX relocates the whole cache tree instead, so the compile
# checks still compile and still write, but into the sandbox the trap above removes. Python < 3.8
# ignores it, which leaves such a host exactly where it is today rather than breaking it.
export PYTHONPYCACHEPREFIX="$SANDBOX/pycache"

# Read BEFORE anything else runs, so the tree-hygiene check at the end of this file judges what THIS
# run created rather than what some earlier tool left behind.
PYCACHE_PRE=absent
[ -e "$ROOT/util/__pycache__" ] && PYCACHE_PRE=present

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
# #333: absent by default -> lockdown reads "unknown", never the real host's securityfs state.
export LOCKDOWN_FILE="$NOHW/lockdown"
export NODE_SYSFS="$NOHW/node" # _nps_suspect's NUMA-node count (#201)
export THERMAL_ZONE="$NOHW/thermal"
export HWMON_DIR="$NOHW/hwmon"            # _read_temp's k10temp/coretemp fallback (#208)
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
    # The `{ } 2>/dev/null` is load-bearing (#419), not tidiness: every real consumer of lscpu here
    # closes the pipe at its FIRST match (`lscpu | awk '/L3 cache/{print $3$4; exit}'` in
    # util/proposed-grub.sh, `lscpu | sed -n ... | head -1` in rigforge.sh), so this stub is mid-write
    # when the reader goes away. At SIGPIPE's default disposition it dies silently — which is why the
    # problem never reproduces locally — but a harness that passes SIGPIPE down as IGNORED, as CI's
    # does, turns the same write into an EPIPE that bash reports as `echo: write error: Broken pipe`
    # on stderr, one line per failed write. That lands on the stderr of the script under test, and
    # three #410 controls assert that stderr is EMPTY: a fixture's noise read as the subject's output,
    # timing-dependent, and a red control invalidates the block that reads against it. Any stub that
    # writes more than one line to stdout needs the same guard. Pinned by the #419 test below.
    cat >"$bin/lscpu" <<'EOF'
#!/usr/bin/env bash
{
echo "Model name:            ${STUB_CPU_MODEL:-Generic CPU}"
echo "L3 cache:              ${STUB_L3:-8 MiB}"
echo "Socket(s):             ${STUB_SOCKETS:-1}"
# NUMA nodes can exceed sockets (NPS / L3-as-NUMA on EPYC); default to the socket count so existing
# single-value tests are unchanged, and let STUB_NUMA_NODES drive the multi-NUMA cases.
echo "NUMA node(s):          ${STUB_NUMA_NODES:-${STUB_SOCKETS:-1}}"
# Modern lscpu (as root) also prints a DMI-derived BIOS line; the model parse must NOT pick this up.
echo "BIOS Model name:       ${STUB_CPU_MODEL:-Generic CPU}            Unknown CPU @ 4.2GHz"
} 2>/dev/null
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
    # Keep this var list in lockstep with rigforge.sh:1009's real envsubst allowlist — a var dropped
    # from ONE and not the other lets a stub-rendered unit keep a literal, undetected $VAR (#275).
    cat >"$bin/envsubst" <<'EOF'
#!/usr/bin/env bash
sed -e "s|\$BUILD_DIR|${BUILD_DIR:-}|g" -e "s|\$CPUPOWER_PATH|${CPUPOWER_PATH:-}|g" -e "s|\$WORKER_ROOT|${WORKER_ROOT:-}|g" \
    -e "s|\$NFT_PATH|${NFT_PATH:-}|g" \
    -e "s|\$SERVICE_NAME|${SERVICE_NAME:-}|g" -e "s|\$RIGFORGE_OPERATOR|${RIGFORGE_OPERATOR:-}|g" \
    -e "s|\$SCRIPT_DIR|${SCRIPT_DIR:-}|g" -e "s|\$AUTOTUNE_ONCALENDAR|${AUTOTUNE_ONCALENDAR:-}|g" \
    -e "s|\$AUTOTUNE_TARGET|${AUTOTUNE_TARGET:-}|g" -e "s|\$API_BIND|${API_BIND:-}|g" -e "s|\$API_PORT|${API_PORT:-}|g" \
    -e "s|\$MINER_USER_EFFECTIVE|${MINER_USER_EFFECTIVE:-}|g" -e "s|\$MSR_APPLY_LINE|${MSR_APPLY_LINE:-}|g" \
    -e "s|\${WATCHDOG_INTERVAL_MIN}|${WATCHDOG_INTERVAL_MIN:-}|g" \
    -e "s|\$CONTROL_BIND|${CONTROL_BIND:-}|g" -e "s|\$CONTROL_PORT|${CONTROL_PORT:-}|g"
EOF
    # No-op recorders / package managers. dpkg/rpm/pacman exit 0 so "is this dep installed?" is always yes.
    # cc: the appliance-mode tool check (pithead#797 R1) probes `command -v cc` — stub it so black-box
    # runs don't depend on whether the host has a compiler.
    local cmd
    for cmd in make cmake cc systemctl modprobe mount umount mountpoint update-grub apt-get apt-cache dpkg dnf rpm pacman brew cpupower journalctl python3 nft useradd; do
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
    # hugepages is the real /2/summary shape — a [loaded, total] pages ARRAY, not a bool; the old
    # bool-shaped fixture is exactly how the @tsv array crash (#341) slipped past this suite.
    cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >> "${CURL_LOG:-/dev/null}"
printf '{"hashrate":{"total":[%s,0,0]},"connection":{"pool":"poolbox.lan:3333","uptime":93700,"failures":0,"accepted":42,"rejected":1},"uptime":93780,"hugepages":[1248,1248]}\n' "${STUB_API_HR:-1234.5}"
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
# #265: jq `//` treats explicit false the same as null/missing — an operator's false must survive.
c="$(mkconf p_falsebool "{ \"pools\": [{\"url\":\"h:3333\",\"enabled\":false,\"keepalive\":false}] }")"
assert_eq "explicit enabled:false kept (#265)" "$(PJ "$c" | jq -c '.[0].enabled')" "false"
assert_eq "explicit keepalive:false kept (#265)" "$(PJ "$c" | jq -c '.[0].keepalive')" "false"
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
# #400: socks5 passes through as host:port and the key is absent when unset/null, so a pre-#400
# config keeps producing byte-identical POOLS_JSON.
c="$(mkconf p_s5 "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"127.0.0.1:9050\"}] }")"
assert_eq "socks5 passed through (#400)" "$(PJ "$c" | jq -r '.[0].socks5')" "127.0.0.1:9050"
c="$(mkconf p_nos5 "{ \"pools\": [{\"url\":\"h:3333\"}] }")"
assert_eq "no socks5 key when unset (#400)" "$(PJ "$c" | jq -c '.[0] | has("socks5")')" "false"
c="$(mkconf p_nulls5 "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":null}] }")"
assert_eq "null socks5 = absent (#400)" "$(PJ "$c" | jq -c '.[0] | has("socks5")')" "false"
# The point of the issue: an onion stratum reached through a local Tor SOCKS port.
c="$(mkconf p_s5onion "{ \"pools\": [{\"url\":\"vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd.onion:3333\",\"socks5\":\"127.0.0.1:9050\"}] }")"
assert_eq "onion pool + socks5 parses (#400)" "$(PJ "$c" | jq -r '[.[0].url, .[0].socks5] | join(" ")')" "vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd.onion:3333 127.0.0.1:9050"
# Index alignment: a proxy on the SECOND pool must land on the second pool, not the first.
c="$(mkconf p_s52 "{ \"pools\": [{\"url\":\"plain:3333\"}, {\"url\":\"onion:3333\",\"socks5\":\"127.0.0.1:9050\"}] }")"
assert_eq "second-pool socks5 stays on the second pool (#400)" "$(PJ "$c" | jq -c '[(.[0] | has("socks5")), (.[1].socks5 == "127.0.0.1:9050")]')" "[false,true]"
# A pool may carry BOTH a pin and a proxy — the two re-attach passes must not clobber each other.
c="$(mkconf p_s5fp "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"socks5\":\"127.0.0.1:9050\"}] }")"
assert_eq "socks5 and tls-fingerprint coexist (#400)" "$(PJ "$c" | jq -c '[(.[0]."tls-fingerprint" != null), (.[0].socks5 == "127.0.0.1:9050")]')" "[true,true]"
# #400 validation: the socks5 address gets the SAME host:port rules as the pool url. Each of these
# is rejected for the pool url already; assert the proxy is judged by the same standard.
c="$(mkconf p_s5noport "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"127.0.0.1\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "socks5 without a port rejected (#400)" "$?" "1"
c="$(mkconf p_s5badhost "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"evil;rm:9050\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "socks5 with a bad host rejected (#400)" "$?" "1"
c="$(mkconf p_s5badport "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"127.0.0.1:70000\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "socks5 port above 65535 rejected (#400)" "$?" "1"
c="$(mkconf p_s5bad6 "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"[not:hex:zz]:9050\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "socks5 with an invalid IPv6 literal rejected (#400)" "$?" "1"
c="$(mkconf p_s6ok "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"[::1]:9050\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "socks5 as a bracketed IPv6 literal accepted (#400)" "$?" "0"
# #408: an empty string is not "unset". The emit predicate is jq truthiness, so `""` WAS written
# into the generated config, while the validator's `// empty` read it as absent and skipped every
# check. Both keys now reject it. The tls-fingerprint case is the security-relevant one: xmrig
# v6.26.0 skips verification only for a NULL pin, and `""` is a non-null empty String, so
# Tls.cpp:186 compares it against every cert and matches none — the pool silently never connects.
# Rejecting is therefore correct where DROPPING the key would be a downgrade to "verify nothing".
c="$(mkconf p_s5empty "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "empty-string socks5 rejected, not silently emitted (#408)" "$?" "1"
c="$(mkconf p_fpempty "{ \"pools\": [{\"url\":\"h:443\",\"tls\":true,\"tls-fingerprint\":\"\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "empty-string tls-fingerprint rejected, not silently emitted (#408)" "$?" "1"
# Rejected on its own merits, before the pin-without-tls guard can reach it — so deleting either
# guard cannot leave the other silently covering for it.
c="$(mkconf p_fpemptynotls "{ \"pools\": [{\"url\":\"h:3333\",\"tls-fingerprint\":\"\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "empty-string tls-fingerprint rejected without tls:true too (#408)" "$?" "1"
# The controls that must NOT move: absent and null stay accepted and stay out of the config, so
# the new guards cannot be passing by rejecting everything.
c="$(mkconf p_s5nullok "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":null,\"tls-fingerprint\":null}] }")"
parse_rc "$c" "$ROOT"
assert_rc "null socks5 + null tls-fingerprint still accepted (#408)" "$?" "0"
assert_eq "neither null key reaches the config (#408)" "$(PJ "$c" | jq -c '[(.[0]|has("socks5")),(.[0]|has("tls-fingerprint"))]')" "[false,false]"
# #415: `pass` must be a STRING. The charset rule alone cannot catch a JSON object, because `jq -r`
# renders one as its JSON text and the empty object `{}` is two graph characters on one line — so it
# passed every check and became the rig's literal password. The masked-secret marker the API feed
# serves is the object that would actually get here if any writer forgot to resolve it.
c="$(mkconf p_passmarker '{ "pools": [{"url":"h:3333","pass":{"__secret__":true}}] }')"
parse_rc "$c" "$ROOT"
assert_rc "a masked-secret marker is not a password (#415)" "$?" "1"
c="$(mkconf p_passempty_obj '{ "pools": [{"url":"h:3333","pass":{}}] }')"
parse_rc "$c" "$ROOT"
assert_rc "an empty object pass rejected — it used to pass the charset rule (#415)" "$?" "1"
c="$(mkconf p_passnum '{ "pools": [{"url":"h:3333","pass":1234}] }')"
parse_rc "$c" "$ROOT"
assert_rc "a numeric pass rejected (#415)" "$?" "1"
# The control that must NOT move: a real string password, and an absent one, both still parse.
c="$(mkconf p_passok '{ "pools": [{"url":"h:3333","pass":"realpw"}] }')"
parse_rc "$c" "$ROOT"
assert_rc "a string pass still accepted (#415)" "$?" "0"
assert_eq "an absent pass still defaults to x, unchanged (#415)" "$(PJ "$(mkconf p_passnone '{ "pools": [{"url":"h:3333"}] }')" | jq -r '.[0].pass')" "x"
# #405: a port with more digits than bash can evaluate as an integer used to PASS. `[ "$_p" -lt 1 ]`
# returns 2 — not false — on such a value, so the `if` took its else branch, no error fired, and an
# unusable port reached the generated config behind a raw `[: integer expression expected` on stderr.
# The digit-count guard short-circuits before the arithmetic, so the comparison only ever sees a
# value bash can evaluate. Assert it on BOTH keys the shared validator serves.
c="$(mkconf p_hugeport "{ \"pools\": [{\"url\":\"h:99999999999999999999\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "url port too large for bash to evaluate rejected (#405)" "$?" "1"
c="$(mkconf p_s5hugeport "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"127.0.0.1:99999999999999999999\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "socks5 port too large for bash to evaluate rejected (#405)" "$?" "1"
# The guard must not over-tighten: 65535 is the largest legal port and is five digits, so it sits
# directly against the digit-count cut. Without this, a fix that rejected anything long would pass.
c="$(mkconf p_65535 "{ \"pools\": [{\"url\":\"h:65535\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "url port 65535 still accepted (#405)" "$?" "0"
c="$(mkconf p_s565535 "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"127.0.0.1:65535\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "socks5 port 65535 still accepted (#405)" "$?" "0"
# The digit-count guard is a real tightening on exactly one shape: a value padded PAST five digits.
# `[ 065535 -lt 1 ]` evaluates as decimal, so the old range test kept it. Pinned here because the
# CHANGELOG tells operators about it — an undocumented incidental rejection is how a fix surprises.
c="$(mkconf p_over5 "{ \"pools\": [{\"url\":\"h:065535\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "port of more than five digits rejected (#405)" "$?" "1"
# Two guards, two messages: assert each on the sentence ONLY it writes, and that it does NOT emit the
# other's. Sharing one string is how deleting a guard outright leaves a suite green.
out="$( (
    source "$SCRIPT"
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    parse_config 2>&1
))"
assert_contains "over-five-digit port names the digit count (#405)" "$out" "has more than five digits"
assert_absent "over-five-digit port does not borrow the range guard's wording (#405)" "$out" "must be between 1 and 65535"
# The guard keys on LENGTH, not on padding. A padded port WITHIN five digits is accepted exactly as
# it was before the fix. Pinned so the CHANGELOG's scope is tested rather than asserted in prose, and
# so tightening it later is a deliberate act with a red test, not a silent behaviour change.
c="$(mkconf p_pad_in5 "{ \"pools\": [{\"url\":\"h:08080\"}] }")"
parse_rc "$c" "$ROOT"
assert_rc "padding within five digits still accepted — the guard is length, not padding (#405)" "$?" "0"
# A fat-fingered extra digit is the likeliest input to reach this guard, and it carries no padding at
# all. It must get the digit-count message, never one telling it to remove padding it does not have.
c="$(mkconf p_fatfinger "{ \"pools\": [{\"url\":\"h:999999\"}] }")"
out="$( (
    source "$SCRIPT"
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    parse_config 2>&1
))"
assert_contains "an unpadded over-long port names the digit count (#405)" "$out" "has more than five digits"
assert_absent "an unpadded over-long port is not told to remove padding (#405)" "$out" "padding"
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
# #265: the has() guard must still let bogus values through to validation, not swallow them.
c="$(mkconf p_enstr "{ \"pools\": [{\"url\":\"h:3333\",\"enabled\":\"yes\"}] }")"
out="$( (
    source "$SCRIPT"
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    parse_config 2>&1
))"
assert_contains "non-boolean string enabled still rejected by validation (#265)" "$out" "Pool enabled must be true or false"
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
# #400: socks5 is a KNOWN pool field now — the warning that used to tell operators it was ignored
# was the visible half of the defect, so assert it is gone rather than only that the value survives.
c="$(mkconf lint_s5 "{ \"pools\": [{\"url\":\"h:3333\",\"socks5\":\"127.0.0.1:9050\"}] }")"
out="$(lint_out "$c")"
assert_absent "socks5 no longer warns as an unknown pool field (#400)" "$out" 'unknown pool field "socks5"'
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

# #344 (item 4): a bad pool URL now re-prompts (bounded, SETUP_URL_TRIES, default 3) instead of
# exiting the whole script — nothing above wrote a config on a bad first try, so a retry costs the
# operator three lines, not a restart.
ecr="$(mktemp -d "$SANDBOX/ecr.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$ecr/config.json"
    set +eu
    printf 'y\n\nstack.lan\nstack.lan:3333\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "#344: re-prompts past a blank then a portless URL to a valid one" "$(jq -c '.pools' "$ecr/config.json" 2>/dev/null)" '[{"url":"stack.lan:3333"}]'
ecr6="$(mktemp -d "$SANDBOX/ecr6.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$ecr6/config.json"
    set +eu
    printf 'y\n[zz]:3333\n[::1]:3333\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "#344: re-prompts past an invalid IPv6 literal to a valid one" "$(jq -c '.pools' "$ecr6/config.json" 2>/dev/null)" '[{"url":"[::1]:3333"}]'
# Bounded, not until-valid: SETUP_URL_TRIES genuinely invalid entries (not an EOF short-circuit) still
# give up and write nothing, with a message naming the bound.
ece="$(mktemp -d "$SANDBOX/ece.XXXXXX")"
ece_err="$( (
    source "$SCRIPT"
    CONFIG_JSON="$ece/config.json"
    set +eu
    printf 'y\nbad1\nbad2\nbad3\n' | PATH="$STUBS:$PATH" ensure_config_exists 2>&1 >/dev/null
))"
assert_eq "#344: exhausting every retry with real bad input still writes no config" "$([ -f "$ece/config.json" ] && echo yes || echo no)" "no"
assert_contains "#344: the give-up message names the attempt bound" "$ece_err" "giving up after 3 attempt(s)"
# SETUP_URL_TRIES overrides the bound (matches this file's APPLY_POOL_TRIES/CONTROL_LIVE_TRIES idiom):
# with only 1 try allowed, a single bad entry exhausts it even though a valid URL was queued right
# behind it — proves the retry is genuinely bounded, not incidentally working via EOF.
ec1="$(mktemp -d "$SANDBOX/ec1.XXXXXX")"
(
    source "$SCRIPT"
    CONFIG_JSON="$ec1/config.json"
    SETUP_URL_TRIES=1
    set +eu
    printf 'y\nbad\nstack.lan:3333\n' | PATH="$STUBS:$PATH" ensure_config_exists >/dev/null 2>&1
)
assert_eq "#344: SETUP_URL_TRIES=1 leaves no room for a retry" "$([ -f "$ec1/config.json" ] && echo yes || echo no)" "no"

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
        MINER_USER="${SIM_MINER_USER:-}"
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

# #400: the proxy has to reach the GENERATED xmrig config, not just POOLS_JSON — that is the file
# the miner actually reads, and a key that stops at the mapper would mine direct while looking set.
echo "== config-gen: socks5 passthrough (#400) =="
export STUB_CPU_MODEL="Intel(R) Xeon" STUB_NPROC=8 STUB_HOSTNAME=rigbox
SIM_OS=Linux SIM_DON=1 SIM_POOLS='[{"url":"vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd.onion:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true,"socks5":"127.0.0.1:9050"}]'
d="$(gen_config)"
cfg="$d/config.json"
unset SIM_POOLS STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME
assert_eq "socks5 survives generation (#400)" "$(J "$cfg" '.pools[0].socks5')" "127.0.0.1:9050"
assert_eq "the onion pool url survives generation (#400)" "$(J "$cfg" '.pools[0].url')" "vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd.onion:3333"

echo "== config-gen: miner_user disables in-process MSR writes (#140) =="
export STUB_CPU_MODEL="AMD Ryzen 9 7950X" STUB_NPROC=8 STUB_HOSTNAME=rigbox
d="$(SIM_OS=Linux SIM_DON=1 SIM_MINER_USER=xmrig gen_config)"
cfg="$d/config.json"
unset STUB_CPU_MODEL STUB_NPROC STUB_HOSTNAME
assert_eq "miner_user: randomx.wrmsr forced off (#140)" "$(J "$cfg" '.randomx.wrmsr')" "false"
assert_eq "miner_user: randomx.rdmsr forced off (#140)" "$(J "$cfg" '.randomx.rdmsr')" "false"

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
# #305: co-resident reservation headroom + first-class thread cap.
echo "== unit: proposed-grub.sh co-resident headroom + thread cap (#305) =="
# RESERVE_EXTRA_MB adds ceil(MB/2) 2MB pages to BOTH the reservation and the runtime pool so the kernel's
# shared pool covers stack + miner. 2874 MB -> 1437 pages. 1G box base 2M = 154 -> 1591; fallback 1234 -> 2671.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RESERVE_EXTRA_MB=2874 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: headroom adds 2M pages (1G box, 154+1437)" "$out" "hugepagesz=2M hugepages=1591"
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RESERVE_EXTRA_MB=2874 CPUINFO="$SANDBOX/cpuinfo_no1g" bash "$PG" -q)"
assert_contains "grub: headroom adds 2M pages (fallback, 1234+1437)" "$out" "hugepages=2671"
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RESERVE_EXTRA_MB=2874 HUGEPAGES_1G_NR="$SANDBOX/nr_none" bash "$PG" --runtime)"
assert_eq "grub --runtime: headroom grows the shared pool too (1234+1437)" "$out" "2671"
# Odd MB rounds UP to whole 2MB pages (1 MB -> 1 page); zero (default) leaves sizing untouched.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RESERVE_EXTRA_MB=1 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: odd headroom MB rounds up (154+1)" "$out" "hugepagesz=2M hugepages=155"
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RESERVE_EXTRA_MB=0 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: zero headroom = miner-only sizing (154)" "$out" "hugepagesz=2M hugepages=154"
# THREADS_CAP is a CEILING: 32 MiB L3 -> 16 threads; cap 8 -> 2M = 128+8+10 = 146. A cap ABOVE the
# computed count is a no-op (never a raise). It also clamps a tuned RX_THREADS: min(24,8) -> 8.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 THREADS_CAP=8 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: thread cap clamps sizing (16->8 -> 146)" "$out" "hugepagesz=2M hugepages=146"
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 THREADS_CAP=100 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q)"
assert_contains "grub: cap above computed is a no-op (stays 154)" "$out" "hugepagesz=2M hugepages=154"
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 RX_THREADS=24 THREADS_CAP=8 HUGEPAGES_1G_NR="$SANDBOX/nr_none" bash "$PG" --runtime)"
assert_eq "grub --runtime: cap clamps a tuned RX_THREADS (min(24,8) -> 1226)" "$out" "1226"

# _cmdline_reserved_2mb: total HugePages a cmdline reserves, in 2MB-equivalents (1G page = 512 × 2M).
echo "== unit: _cmdline_reserved_2mb (#305) =="
r="$(
    source "$SCRIPT"
    _cmdline_reserved_2mb "quiet splash hugepagesz=2M hugepages=3072 transparent_hugepage=never"
)"
assert_eq "reserved: pure-2M pool" "$r" "3072"
r="$(
    source "$SCRIPT"
    _cmdline_reserved_2mb "hugepagesz=1G hugepages=6 hugepagesz=2M hugepages=200"
)"
assert_eq "reserved: 1G counts as 512x2M (6*512+200)" "$r" "3272"
r="$(
    source "$SCRIPT"
    _cmdline_reserved_2mb "quiet default_hugepagesz=2M hugepages=1234"
)"
assert_eq "reserved: default_hugepagesz used when no explicit hugepagesz" "$r" "1234"
r="$(
    source "$SCRIPT"
    _cmdline_reserved_2mb "default_hugepagesz=1G hugepages=4"
)"
assert_eq "reserved: default_hugepagesz=1G -> 4*512" "$r" "2048"
r="$(
    source "$SCRIPT"
    _cmdline_reserved_2mb "quiet splash nomodeset"
)"
assert_eq "reserved: nothing reserved -> 0" "$r" "0"

# #419: the fixture's own EPIPE noise must not land on the stderr the #410 controls below assert is
# EMPTY. See the guard on the lscpu stub in make_stubs for the mechanism; this pins it, because the
# failure it prevents shows up as a #410 control going red for a reason that has nothing to do with
# #410 — which is exactly the shape that gets "fixed" in the wrong file.
#
# The instrument is deterministic in BOTH directions, which the CI failure was not: `trap '' PIPE`
# reproduces the ignored-SIGPIPE disposition CI hands down, and the reader is made to exit BEFORE the
# writer starts, so the 64K pipe buffer cannot absorb the writes the way it does when the two race.
echo "== fixture: the lscpu stub stays silent when its reader closes early (#419) =="
stub_epipe_stderr() { # <stub path> -> only what the stub wrote to STDERR
    # Written as `{ (…) >/dev/null; } 2>&1` rather than the shorter `(…) 2>&1 1>/dev/null`: both
    # capture stderr and discard stdout, but shellcheck flags the second as SC2069 because the order
    # reads like a stdout+stderr merge that has been written backwards. The two forms were measured
    # byte-identical here, on a stub that writes to stderr and one that does not.
    { (
        trap '' PIPE
        {
            command sleep 0.3
            bash "$1"
        } | awk 'BEGIN { exit }'
    ) >/dev/null; } 2>&1
}
assert_eq "the lscpu stub writes nothing to stderr when its reader closes early (#419)" \
    "$(stub_epipe_stderr "$STUBS/lscpu")" ""
# Control: the same instrument against the pre-#419 stub body MUST fire, or the assertion above is
# green because the instrument sees nothing rather than because the guard works.
EPS="$(mktemp -d "$SANDBOX/eps.XXXXXX")"
cat >"$EPS/lscpu" <<'STUBEOF'
#!/usr/bin/env bash
echo "Model name:            ${STUB_CPU_MODEL:-Generic CPU}"
echo "L3 cache:              ${STUB_L3:-8 MiB}"
STUBEOF
chmod +x "$EPS/lscpu"
assert_contains "control: an UNGUARDED stub does report the broken pipe (#419)" \
    "$(stub_epipe_stderr "$EPS/lscpu")" "write error: Broken pipe"
# And the guard must not change what the stub says — asserted through the exact parse
# util/proposed-grub.sh performs, rather than through the stub's own spacing.
assert_eq "the guarded stub still parses as proposed-grub.sh reads it (#419)" \
    "$(STUB_L3='32 MiB' bash "$STUBS/lscpu" | awk '/L3 cache/{print $3$4; exit}')" "32MiB"
assert_eq "the guarded stub still reports its socket count (#419)" \
    "$(STUB_SOCKETS=2 bash "$STUBS/lscpu" | awk '/Socket\(s\):/{print $2; exit}')" "2"
assert_contains "the guarded stub still prints the BIOS line the model parse must skip (#419)" \
    "$(bash "$STUBS/lscpu")" "BIOS Model name:"

# ---------------------------------------------------------------------------
# #410: hugepages_pool_ceiling_mb has to reach the PERSISTED reservation, not only the runtime write.
# Before this fix the key was consumed by _ensure_hugepages alone: GRUB was rewritten from the
# UNCAPPED page math, the next boot brought the 2MB pool up above the declared ceiling, and
# _ensure_hugepages — grow-only, and now seeing current > ceiling_pages — took its already-at-ceiling
# branch and returned without writing. The box stayed over the ceiling permanently while the runtime
# guard reported that everything was fine.
#
# Baseline for every case below (the same fixture the #65/#305 blocks use): 32 MiB L3, 1 socket ->
# threads 16; 1G branch 2M total 128+16+10 = 154 with 3 x 1G; pure-2M fallback 1168+16+50 = 1234.
echo "== unit: proposed-grub.sh honours the declared pool ceiling (#410) =="
PGERR="$SANDBOX/pg410.err"
PG_NOCEIL_1G="quiet splash hugepagesz=1G hugepages=3 hugepagesz=2M hugepages=154 default_hugepagesz=2M msr.allow_writes=on"
PG_NOCEIL_FB="quiet splash default_hugepagesz=2M hugepages=1234 msr.allow_writes=on"

# Control FIRST: with no ceiling declared the rendered cmdline is exactly the pre-#410 string. Every
# clamp assertion below is read against these two, so a drift here invalidates the block rather than
# hiding inside it.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q 2>"$PGERR")"
assert_eq "grub: no ceiling declared -> unchanged cmdline (1G branch, #410 control)" "$out" "$PG_NOCEIL_1G"
assert_eq "grub: no ceiling declared -> nothing on stderr (#410 control)" "$(cat "$PGERR")" ""
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=0 CPUINFO="$SANDBOX/cpuinfo_no1g" bash "$PG" -q 2>"$PGERR")"
assert_eq "grub: POOL_CEILING_MB=0 is inert (fallback branch, #410 control)" "$out" "$PG_NOCEIL_FB"
assert_eq "grub: POOL_CEILING_MB=0 says nothing on stderr (#410 control)" "$(cat "$PGERR")" ""

# The fix: a 200MB ceiling is 100 2MB pages, below the computed 154, so the PERSISTED 2M entry is
# capped at 100. Mutation kill: dropping the `TOTAL_2MB_PAGES=$(_cap_2mb ...)` line renders 154 again
# and this assertion goes red — it is the whole defect, stated as a string.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=200 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q 2>"$PGERR")"
assert_eq "grub: ceiling caps the persisted 2M reservation (154 -> 100, #410)" "$out" "quiet splash hugepagesz=1G hugepages=3 hugepagesz=2M hugepages=100 default_hugepagesz=2M msr.allow_writes=on"
assert_contains "grub: the cap is NOTEd on stderr naming the ceiling (#410)" "$(cat "$PGERR")" "capping the persisted 2MB HugePages reservation at 100 pages (200MB"

# SCOPE, pinned deliberately: the clamp bounds the 2MB pool only — the quantity vm.nr_hugepages names
# and _ensure_hugepages measures its ceiling against. The 1G dataset reservation is a different pool
# the key has never described, and clamping it would silently cost RandomX fast mode. So `hugepages=3`
# of 1G survives a 200MB ceiling. If this assertion is ever "fixed" to 0, read the scope comment in
# util/proposed-grub.sh first: it is a deliberate limit of the key, documented in the PR and CHANGELOG.
assert_contains "grub: the 1G dataset reservation is NOT clamped (documented scope, #410)" "$out" "hugepagesz=1G hugepages=3 "

# The pure-2M fallback branch: here the clamp bounds the ENTIRE reservation (1234 -> 100).
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=200 CPUINFO="$SANDBOX/cpuinfo_no1g" bash "$PG" -q 2>"$PGERR")"
assert_eq "grub: ceiling caps the pure-2M fallback too (1234 -> 100, #410)" "$out" "quiet splash default_hugepagesz=2M hugepages=100 msr.allow_writes=on"
assert_contains "grub: fallback cap is NOTEd with the value it replaced (#410)" "$(cat "$PGERR")" "instead of 1234"

# A ceiling ABOVE the computed reservation is a no-op, and says nothing — it is a ceiling, not a
# target. Mutation kill: replacing the `-gt` in _cap_2mb with `-ge`/`-lt` breaks one of these two.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=4000 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q 2>"$PGERR")"
assert_eq "grub: ceiling above the computed reservation is a no-op (#410)" "$out" "$PG_NOCEIL_1G"
assert_eq "grub: a non-binding ceiling is silent (#410)" "$(cat "$PGERR")" ""

# An ODD declared ceiling FLOORS to the 2MB page below, exactly as _ensure_hugepages does — a cap
# rounds toward LESS memory, never more. 201MB -> 100 pages (200MB), never 101 (202MB, a page past
# what was declared). Mutation kill: `((POOL_CEILING_MB + 1) / 2)` — the rounding the #398 security
# review already rejected once on the runtime half — renders 101 here and flips this red.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=201 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q 2>"$PGERR")"
assert_contains "grub: odd ceiling (201MB) floors to 100 pages, not 101 (#410)" "$out" "hugepagesz=2M hugepages=100 "
assert_absent "grub: odd ceiling never rounds up past itself (#410 mutation kill)" "$out" "hugepages=101"

# A ceiling smaller than one 2MB page floors to ZERO pages and still BINDS — it is not silently
# re-read as "no ceiling". That is why the no-ceiling sentinel is an empty CEILING_2MB_PAGES rather
# than 0: with 0 as the sentinel a declared 1MB ceiling would be indistinguishable from an absent
# key. It matches the runtime half, which computes ceiling_pages=0 for 1MB and declines to write.
# Pathological as a config, reachable as a value (parse_config accepts 0-65536), so it is pinned
# rather than left to whichever branch happens to catch it.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=1 CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q 2>"$PGERR")"
assert_eq "grub: a sub-page ceiling (1MB) floors to 0 pages and still binds (#410)" "$out" "quiet splash hugepagesz=1G hugepages=3 hugepagesz=2M hugepages=0 default_hugepagesz=2M msr.allow_writes=on"
assert_contains "grub: the sub-page clamp is NOTEd, not silent (#410)" "$(cat "$PGERR")" "at 0 pages (1MB"

# --runtime is NOT clamped, deliberately: it is the miner's REQUIREMENT, which _ensure_hugepages
# weighs against availability before clamping the WRITE. Clamping it here would move the "pool
# already covers the miner" decision and suppress the #398 warning that fires when the requirement
# genuinely exceeds the ceiling. Same 200MB ceiling that capped the cmdline to 100 above.
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=200 HUGEPAGES_1G_NR="$SANDBOX/nr_none" bash "$PG" --runtime 2>"$PGERR")"
assert_eq "grub --runtime: the ceiling does NOT clamp the requirement (#410)" "$out" "1234"
assert_eq "grub --runtime: and says nothing about a ceiling (#410)" "$(cat "$PGERR")" ""
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB=200 HUGEPAGES_1G_NR="$SANDBOX/nr_4" bash "$PG" --runtime 2>/dev/null)"
assert_eq "grub --runtime: unclamped on the 1G-allocated branch too (#410)" "$out" "154"

# A garbage ceiling cannot abort the calculation or leak a shell diagnostic into the cmdline: the
# arithmetic guard is `[ "$POOL_CEILING_MB" -gt 0 ] 2>/dev/null`, so a non-numeric value is treated
# as no ceiling. (rigforge#412 is the separate defect that such a value is accepted by parse_config
# in the first place; this only pins that proposed-grub.sh does not compound it.)
out="$(PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 POOL_CEILING_MB="1+1" CPUINFO="$SANDBOX/cpuinfo_1g" bash "$PG" -q 2>/dev/null)"
assert_eq "grub: a non-numeric ceiling is ignored, not evaluated (#410)" "$out" "$PG_NOCEIL_1G"

# ---------------------------------------------------------------------------
# #410, the wiring half — and the half the defect actually lived in. util/proposed-grub.sh above can
# be perfect and the ceiling still never bound, because _grub_proposed never passed it. A fake
# proposed-grub records the env each invocation received.
echo "== unit: _grub_proposed passes the declared ceiling to proposed-grub (#410) =="
GC="$(mktemp -d "$SANDBOX/gc410.XXXXXX")"
mkdir -p "$GC/util"
cat >"$GC/util/proposed-grub.sh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [ "$a" = "--runtime" ]; then
        echo "RUNTIME POOL_CEILING_MB=[${POOL_CEILING_MB-}]" >>"$PG_CALLS"
        echo 200
        exit 0
    fi
done
echo "QUIET POOL_CEILING_MB=[${POOL_CEILING_MB-}]" >>"$PG_CALLS"
echo "quiet splash hugepagesz=2M hugepages=100 msr.allow_writes=on"
EOF
chmod +x "$GC/util/proposed-grub.sh"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nomodeset"\n' >"$GC/grub"

run_grub_proposed410() { # <pg_calls_file> <ceiling_mb> [reserve_extra_mb]
    (
        source "$SCRIPT"
        SCRIPT_DIR="$GC"
        GRUB_DEFAULT="$GC/grub"
        RX_SETUP_THREADS=""
        THREADS_CAP=""
        HUGEPAGES_POOL_CEILING_MB="$2"
        HUGEPAGES_RESERVE_EXTRA_MB="${3:-0}"
        export PG_CALLS="$1"
        set +e
        PATH="$STUBS:$PATH" _grub_proposed
        echo "MERGED=[$MERGED]"
    )
}

# THE regression for #410: the declared ceiling reaches the cmdline-generating call. Mutation kill:
# removing `POOL_CEILING_MB="${HUGEPAGES_POOL_CEILING_MB:-0}"` from _grub_proposed's MANAGED
# assignment records `POOL_CEILING_MB=[]` and turns this red — that missing assignment IS the bug.
GPC="$GC/calls1"
: >"$GPC"
out="$(run_grub_proposed410 "$GPC" 5120)"
assert_contains "the declared ceiling reaches proposed-grub's cmdline call (#410)" "$(cat "$GPC")" "QUIET POOL_CEILING_MB=[5120]"
assert_contains "and the capped cmdline is what gets merged (#410)" "$out" "MERGED=[quiet splash nomodeset hugepagesz=2M hugepages=100 msr.allow_writes=on]"

# No ceiling declared: the call is made with an explicit 0, which proposed-grub.sh treats as no
# ceiling — the key stays inert for every config that does not set it.
GPC="$GC/calls2"
: >"$GPC"
out="$(run_grub_proposed410 "$GPC" 0)"
assert_contains "an undeclared ceiling passes 0, not an empty value (#410)" "$(cat "$GPC")" "QUIET POOL_CEILING_MB=[0]"

# The --runtime call inside the #305 co-resident guard must NOT receive the ceiling — it asks for the
# requirement, not the write. Headroom > 0 is what makes that call happen at all.
GPC="$GC/calls3"
: >"$GPC"
out="$(run_grub_proposed410 "$GPC" 5120 2874)"
assert_contains "the cmdline call still gets the ceiling with headroom set (#410)" "$(cat "$GPC")" "QUIET POOL_CEILING_MB=[5120]"
assert_contains "the #305 --runtime requirement call does NOT get it (#410)" "$(cat "$GPC")" "RUNTIME POOL_CEILING_MB=[]"

# parse_config: the two new keys parse, default, and reject bad values.
echo "== unit: parse_config hugepages_reserve_extra_mb + threads (#305) =="
c305="$SANDBOX/c305.json"
printf '{"pools":[{"url":"h:3333"}],"hugepages_reserve_extra_mb":2874,"threads":6}\n' >"$c305"
assert_eq "hugepages_reserve_extra_mb parsed" "$(parse_and_print "$c305" "$ROOT" HUGEPAGES_RESERVE_EXTRA_MB)" "2874"
assert_eq "threads parsed" "$(parse_and_print "$c305" "$ROOT" THREADS_CAP)" "6"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$c305"
assert_eq "hugepages_reserve_extra_mb defaults to 0" "$(parse_and_print "$c305" "$ROOT" HUGEPAGES_RESERVE_EXTRA_MB)" "0"
assert_eq "threads defaults to empty (auto)" "$(parse_and_print "$c305" "$ROOT" THREADS_CAP)" ""
printf '{"pools":[{"url":"h:3333"}],"hugepages_reserve_extra_mb":-5}\n' >"$c305"
out="$(
    source "$SCRIPT"
    CONFIG_JSON="$c305"
    SCRIPT_DIR="$ROOT"
    PATH="$STUBS:$PATH" parse_config 2>&1
)"
assert_contains "negative headroom rejected" "$out" "hugepages_reserve_extra_mb must be"
printf '{"pools":[{"url":"h:3333"}],"threads":0}\n' >"$c305"
out="$(
    source "$SCRIPT"
    CONFIG_JSON="$c305"
    SCRIPT_DIR="$ROOT"
    PATH="$STUBS:$PATH" parse_config 2>&1
)"
assert_contains "threads 0 rejected (min 1)" "$out" "threads must be"

# parse_config: hugepages_pool_ceiling_mb (#398) — parses, defaults to 0 (no ceiling), rejects bad
# values the same way hugepages_reserve_extra_mb does.
echo "== unit: parse_config hugepages_pool_ceiling_mb (#398) =="
c398="$SANDBOX/c398.json"
printf '{"pools":[{"url":"h:3333"}],"hugepages_pool_ceiling_mb":5120}\n' >"$c398"
assert_eq "hugepages_pool_ceiling_mb parsed" "$(parse_and_print "$c398" "$ROOT" HUGEPAGES_POOL_CEILING_MB)" "5120"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$c398"
assert_eq "hugepages_pool_ceiling_mb defaults to 0 (no ceiling, #398)" "$(parse_and_print "$c398" "$ROOT" HUGEPAGES_POOL_CEILING_MB)" "0"
printf '{"pools":[{"url":"h:3333"}],"hugepages_pool_ceiling_mb":-5}\n' >"$c398"
out="$(
    source "$SCRIPT"
    CONFIG_JSON="$c398"
    SCRIPT_DIR="$ROOT"
    PATH="$STUBS:$PATH" parse_config 2>&1
)"
assert_contains "negative ceiling rejected (#398)" "$out" "hugepages_pool_ceiling_mb must be"
printf '{"pools":[{"url":"h:3333"}],"hugepages_pool_ceiling_mb":99999999}\n' >"$c398"
out="$(
    source "$SCRIPT"
    CONFIG_JSON="$c398"
    SCRIPT_DIR="$ROOT"
    PATH="$STUBS:$PATH" parse_config 2>&1
)"
assert_contains "oversized ceiling rejected (#398)" "$out" "hugepages_pool_ceiling_mb must be"

# #412: the SAME defect as #405, in every numeric key parse_config validates. Each guard was written
# `! [[ $v =~ ^[0-9]+$ ]] || [ "$v" -gt MAX ]`; on a value with more digits than bash can evaluate `[`
# returns 2 — an ERROR, not "false" — the `if` reads any non-zero as false, and the value is ACCEPTED.
# For hugepages_pool_ceiling_mb the cost is the key's whole purpose: `_ensure_hugepages` then skipped
# its ceiling block (its own comparison failed the same way, behind a `2>/dev/null`) and grew the pool
# uncapped while the config declared a cap. `_uint_in_range` short-circuits on digit count first, so
# the arithmetic only ever sees a value bash can evaluate.
#
# Every key gets THREE assertions, and the third is the one that makes the first mean anything: an
# out-of-range value one past the maximum must be REJECTED. Without it a fixture that never reaches
# the guard at all — rejected upstream for an unrelated missing key — reads exactly like a working
# guard. That is not hypothetical: the control_port fixture below needs ACCESS_TOKEN *and*
# api_allow_from before the port guard is reachable, and the first draft of this test had neither and
# "passed".
echo "== unit: parse_config rejects a bash-inevaluable value in every numeric key (#412) =="
BIG412=99999999999999999999
uint412() { # <extra-config-json-body> -> ACCEPTED|REJECTED
    local f="$SANDBOX/u412.json"
    printf '{"pools":[{"url":"h:3333"}],%s}\n' "$1" >"$f"
    if parse_rc "$f" "$ROOT"; then echo ACCEPTED; else echo REJECTED; fi
}
# The armed prefix for control_port: `control: enabled` is refused outright without both of these, so
# without them the port guard below is never reached and every verdict here would be a false pass.
CTL412='"ACCESS_TOKEN":"tok","api_allow_from":"10.0.0.5","control":"enabled"'
# key | the too-long value | the maximum (must stay accepted) | one past it (must be rejected)
assert_eq "hugepages_pool_ceiling_mb: inevaluable rejected (#412)" "$(uint412 "\"hugepages_pool_ceiling_mb\":$BIG412")" "REJECTED"
assert_eq "hugepages_pool_ceiling_mb: 65536 max still accepted (#412 over-tightening control)" "$(uint412 '"hugepages_pool_ceiling_mb":65536')" "ACCEPTED"
assert_eq "hugepages_pool_ceiling_mb: 65537 rejected — the guard is reached (#412 arming control)" "$(uint412 '"hugepages_pool_ceiling_mb":65537')" "REJECTED"
assert_eq "hugepages_reserve_extra_mb: inevaluable rejected (#412)" "$(uint412 "\"hugepages_reserve_extra_mb\":$BIG412")" "REJECTED"
assert_eq "hugepages_reserve_extra_mb: 65536 max still accepted (#412)" "$(uint412 '"hugepages_reserve_extra_mb":65536')" "ACCEPTED"
assert_eq "hugepages_reserve_extra_mb: 65537 rejected — the guard is reached (#412)" "$(uint412 '"hugepages_reserve_extra_mb":65537')" "REJECTED"
assert_eq "DONATION: inevaluable rejected (#412)" "$(uint412 "\"DONATION\":$BIG412")" "REJECTED"
assert_eq "DONATION: 100 max still accepted (#412)" "$(uint412 '"DONATION":100')" "ACCEPTED"
assert_eq "DONATION: 101 rejected — the guard is reached (#412)" "$(uint412 '"DONATION":101')" "REJECTED"
assert_eq "watchdog_interval_min: inevaluable rejected (#412)" "$(uint412 "\"watchdog_interval_min\":$BIG412")" "REJECTED"
assert_eq "watchdog_interval_min: 1440 max still accepted (#412)" "$(uint412 '"watchdog_interval_min":1440')" "ACCEPTED"
assert_eq "watchdog_interval_min: 1441 rejected — the guard is reached (#412)" "$(uint412 '"watchdog_interval_min":1441')" "REJECTED"
assert_eq "max_temp_c: inevaluable rejected (#412)" "$(uint412 "\"max_temp_c\":$BIG412")" "REJECTED"
assert_eq "max_temp_c: 110 max still accepted (#412)" "$(uint412 '"max_temp_c":110')" "ACCEPTED"
assert_eq "max_temp_c: 111 rejected — the guard is reached (#412)" "$(uint412 '"max_temp_c":111')" "REJECTED"
assert_eq "threads: inevaluable rejected (#412)" "$(uint412 "\"threads\":$BIG412")" "REJECTED"
assert_eq "threads: 1024 max still accepted (#412)" "$(uint412 '"threads":1024')" "ACCEPTED"
assert_eq "threads: 1025 rejected — the guard is reached (#412)" "$(uint412 '"threads":1025')" "REJECTED"
assert_eq "api_port: inevaluable rejected (#412)" "$(uint412 "\"api\":\"enabled\",\"api_port\":$BIG412")" "REJECTED"
assert_eq "api_port: 65535 max still accepted (#412)" "$(uint412 '"api":"enabled","api_port":65535')" "ACCEPTED"
assert_eq "api_port: 65536 rejected — the guard is reached (#412)" "$(uint412 '"api":"enabled","api_port":65536')" "REJECTED"
assert_eq "control_port: inevaluable rejected (#412)" "$(uint412 "$CTL412,\"control_port\":$BIG412")" "REJECTED"
assert_eq "control_port: 65535 max still accepted (#412)" "$(uint412 "$CTL412,\"control_port\":65535")" "ACCEPTED"
assert_eq "control_port: 65536 rejected — the guard is reached (#412)" "$(uint412 "$CTL412,\"control_port\":65536")" "REJECTED"
# The guard keys on LENGTH, exactly as #405's does, so it tightens on precisely one further shape: a
# value zero-padded PAST the maximum's digit width, which the old range test evaluated as decimal and
# kept. Padding WITHIN the width is untouched and still accepted.
#
# That shape is only reachable when the value is given as a JSON STRING. As a JSON number, jq
# normalises the padding away before bash ever sees it (`065536` -> `65536`), so the guard is handed
# an unpadded value and nothing changes — asserted below rather than reasoned about, because the
# first draft of this test used the number form, expected a rejection, and went red for that reason.
# All three are pinned so the CHANGELOG's scope is TESTED rather than asserted in prose.
assert_eq "ceiling padded past five digits as a STRING rejected — same trade as #405 (#412)" "$(uint412 '"hugepages_pool_ceiling_mb":"065536"')" "REJECTED"
assert_eq "ceiling padded within five digits as a string still accepted — length, not padding (#412)" "$(uint412 '"hugepages_pool_ceiling_mb":"05120"')" "ACCEPTED"
assert_eq "ceiling padded past five digits as a NUMBER is unaffected — jq normalises it (#412)" "$(uint412 '"hugepages_pool_ceiling_mb":065536')" "ACCEPTED"
# The message must still be the key's OWN. A shared guard that also shared one message would name
# neither the key nor its units, and would go green here while telling an operator nothing.
printf '{"pools":[{"url":"h:3333"}],"hugepages_pool_ceiling_mb":%s}\n' "$BIG412" >"$SANDBOX/u412msg.json"
out="$( (
    source "$SCRIPT"
    CONFIG_JSON="$SANDBOX/u412msg.json"
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" parse_config 2>&1
))"
assert_contains "inevaluable ceiling names its own key and range (#412)" "$out" "hugepages_pool_ceiling_mb must be"
assert_absent "inevaluable ceiling no longer leaks bash's raw complaint (#412)" "$out" "integer expression expected"

# generate_xmrig_config: the thread cap clamps cpu.rx AFTER any tune overlay (a stale tuned count can't
# exceed the operator's headroom); a valid count at/under the cap is left alone.
echo "== config-gen: threads cap clamps cpu.rx (#305) =="
gen_capped() { # <cap> <tuned-rx-or-empty> -> echoes config dir
    local d
    d="$(mktemp -d "$SANDBOX/cap.XXXXXX")"
    [ -n "$2" ] && printf '{"cpu":{"rx":%s}}\n' "$2" >"$d/tune-overrides.json"
    (
        # Scope the CPU stubs to THIS subshell — a top-level `export` would leak into later tests (e.g.
        # the #296 bios-verify cases that rely on lscpu NOT reporting an EPYC).
        export STUB_CPU_MODEL="AMD EPYC 7642 48-Core Processor" STUB_NPROC=48 STUB_HOSTNAME=rigbox
        cd "$d" || exit 1
        source "$SCRIPT"
        OS_TYPE=Linux
        WORKER_ROOT="$d"
        LOGROTATE_DIR="$d"
        POOLS_JSON='[{"url":"h:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
        ACCESS_TOKEN=""
        DONATION=1
        THREADS_CAP="$1"
        set +e
        PATH="$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1
    )
    echo "$d"
}
assert_eq "cap pins cpu.rx from auto (-1 -> 6)" "$(J "$(gen_capped 6 "")/config.json" '.cpu.rx')" "6"
assert_eq "cap clamps a tuned rx above it (16 -> 6)" "$(J "$(gen_capped 6 16)/config.json" '.cpu.rx')" "6"
assert_eq "cap leaves a tuned rx at/under it alone (4 stays 4)" "$(J "$(gen_capped 6 4)/config.json" '.cpu.rx')" "4"

# _grub_proposed's keep-existing guard: in co-resident mode, an ambient reservation that already covers
# miner + headroom is left untouched (MERGED := CURRENT -> no reboot); an insufficient one still gets the
# new sizing merged in. This is the load-bearing pithead#593 "no reboot on a box that already fits" case.
echo "== unit: _grub_proposed co-resident keep-existing guard (#305) =="
gd="$SANDBOX/grub_default_305"
run_grub_proposed() { # <current-cmdline> <headroom-mb> -> echoes resulting MERGED
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$1" >"$gd"
    (
        export PATH="$STUBS:$PATH" STUB_L3="32 MiB" STUB_SOCKETS=1 CPUINFO="$SANDBOX/cpuinfo_no1g" HUGEPAGES_1G_NR="$SANDBOX/nr_none"
        source "$SCRIPT"
        SCRIPT_DIR="$ROOT"
        GRUB_DEFAULT="$gd"
        RX_SETUP_THREADS=""
        HUGEPAGES_RESERVE_EXTRA_MB="$2"
        THREADS_CAP=""
        _grub_proposed
        printf '%s\n' "$MERGED"
    )
}
# 32 MiB L3 -> 16 threads; no-1G fallback + 2874MB headroom (1437 pages) -> need 1168+16+50+1437 = 2671.
# Ambient 3072 >= 2671: guard keeps the cmdline verbatim (no reboot).
assert_eq "guard: sufficient ambient reservation left unchanged" \
    "$(run_grub_proposed "quiet splash hugepagesz=2M hugepages=3072 transparent_hugepage=never" 2874)" \
    "quiet splash hugepagesz=2M hugepages=3072 transparent_hugepage=never"
# Ambient 100 < 2671: guard does NOT fire; the new sizing is merged in (quiet/splash preserved).
m305="$(run_grub_proposed "quiet splash hugepagesz=2M hugepages=100" 2874)"
assert_contains "guard: insufficient reservation gets the new sizing (2671)" "$m305" "hugepages=2671"
assert_contains "guard: insufficient case still preserves non-managed params" "$m305" "quiet splash"
# Headroom 0 (normal host): guard is inert even when the ambient reservation would have sufficed —
# a normal host keeps its existing sizing/MSR/reboot behaviour, so the proposal is merged as before.
assert_contains "guard: inert when headroom is 0 (normal host merges proposal)" \
    "$(run_grub_proposed "quiet splash hugepagesz=2M hugepages=3072" 0)" "msr.allow_writes=on"

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
# #277: a sub-1GB host truncates mem_gb to 0 too, which used to be mistaken for "unreadable meminfo" and
# skip the cap entirely (all cores, the exact OOM scenario the cap exists for). mem_kb is still readable
# and nonzero here, so it must hit the same max<1 floor and cap at 1 job even with many cores available.
assert_eq "sub-1GB host caps to 1 job even with many cores (#277)" "$(
    source "$SCRIPT"
    MEMINFO="$(mk_meminfo 900000 mi900)" compute_build_jobs 32
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

# #353 (1): CURRENT_STEP used to be set only inside main() (setup) — an unexpected failure in ANY
# other verb reported the stale "starting up" default. Force a real dispatch-time failure (a
# systemctl that dies, uncaught by svc_start's `&&`) and check on_err names the actual verb.
echo "== black-box: on_err names the running verb, not the stale setup default (#353) =="
CSV="$(mktemp -d "$SANDBOX/current-step-verb.XXXXXX")"
mkdir -p "$CSV/bin"
cat >"$CSV/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$CSV/bin/systemctl"
csv_out="$(cd "$CSV" && PATH="$CSV/bin:$STUBS:$PATH" STUB_UNAME_S=Linux RIGFORGE_HOME="$PWD" bash "$SCRIPT" start </dev/null 2>&1)"
assert_contains "on_err names the 'start' verb on an unexpected failure (#353)" "$csv_out" "aborted while running 'start'"
assert_absent "on_err no longer falls back to the stale setup default (#353)" "$csv_out" "aborted while starting up"

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
# #413: the NO-REBUILD upgrade — the only kind any published release pair has ever produced, the
# XMRig pin being byte-identical at all 25 tags v1.0.0..v1.16.0. `upgrade` used to return early here,
# so it regenerated no config, reinstalled no unit, re-tuned nothing, restarted nothing, and exited 0.
# Each of the four steps is asserted by its EFFECT on the rig rather than by a log line, because this
# repo's own e2e has already found that a "changed" report and a changed rig are different things.
mk_upgrade_rig() { # <dir> <commit marker> — a rig at the pinned commit, with a STALE generated config
    local d="$1"
    mkdir -p "$d/home/worker/xmrig/build" "$d/logrotate" "$d/etc-systemd"
    cp "$ROOT/VERSION" "$d/"
    cp -R "$ROOT/systemd" "$d/"
    : >"$d/home/worker/xmrig/build/xmrig"
    chmod +x "$d/home/worker/xmrig/build/xmrig"
    printf '%s\n' "$2" >"$d/home/worker/xmrig/.rigforge-commit"
    printf '{ "pools": [{ "url": "stale.invalid:1111" }] }\n' >"$d/home/worker/xmrig/build/config.json"
    cat >"$d/config.json" <<EOF
{ "HOME_DIR": "$d/home", "DONATION": 1, "pools": [{"url": "poolbox.lan:3333"}] }
EOF
}
run_upgrade_rig() { # <dir> [PATH prefix, to override a stub]
    (
        cd "$1" || exit 1
        PATH="${2:+$2:}$STUBS:$PATH" LOGROTATE_DIR="$1/logrotate" SYSTEMD_DIR="$1/etc-systemd" \
            CALL_LOG="$1/calls.log" STUB_UNAME_S=Linux XMRIG_COMMIT=ABC \
            RIGFORGE_HOME="$PWD" bash "$SCRIPT" upgrade </dev/null 2>&1
    )
}
UPN="$(mktemp -d "$SANDBOX/upg-norebuild.XXXXXX")"
mk_upgrade_rig "$UPN" ABC
out="$(run_upgrade_rig "$UPN")"
rc=$?
assert_rc "upgrade exits 0 when the pin is unchanged" "$rc" "0"
assert_absent "upgrade no longer returns early on an unchanged pin (#413)" "$out" "nothing to upgrade"
assert_contains "upgrade reports the build was reused (#413)" "$out" "was already built"
assert_absent "upgrade claims no XMRig upgrade it did not perform (#413)" "$out" "Upgraded to XMRig"
assert_eq "no-rebuild upgrade regenerates the live config (#413)" \
    "$(J "$UPN/home/worker/xmrig/build/config.json" '.pools[0].url')" "poolbox.lan:3333"
# The trap compile_xmrig's cd exists to prevent: generate_xmrig_config writes a RELATIVE config.json,
# so a wrong cwd drops it in WORKER_ROOT where nothing reads it — the same silent drift, one layer down.
assert_eq "no-rebuild upgrade writes the config where the unit reads it (#413)" \
    "$([ -f "$UPN/home/worker/config.json" ] && echo stray || echo ok)" "ok"
assert_eq "no-rebuild upgrade reinstalls the systemd unit (#413)" \
    "$([ -f "$UPN/etc-systemd/xmrig.service" ] && echo installed || echo missing)" "installed"
assert_contains "no-rebuild upgrade reloads systemd (#413)" "$(cat "$UPN/calls.log")" "[systemctl] daemon-reload"
assert_contains "no-rebuild upgrade restarts so the new config takes effect (#413)" \
    "$(cat "$UPN/calls.log")" "[systemctl] restart xmrig.service"
assert_eq "no-rebuild upgrade restarts exactly once (#413)" \
    "$(grep -c 'systemctl\] restart' "$UPN/calls.log")" "1"
assert_absent "no-rebuild upgrade does not also 'start' the unit (#413)" "$(cat "$UPN/calls.log")" "[systemctl] start"

# A miner the operator stopped — or the watchdog's thermal cutoff stopped — must come out of an upgrade
# still stopped, with the new config and unit on disk for its next deliberate start (#413, #396's class).
echo "== black-box: upgrade leaves a stopped miner stopped (#413) =="
UPS="$(mktemp -d "$SANDBOX/upg-stopped.XXXXXX")"
mk_upgrade_rig "$UPS" ABC
mkdir -p "$UPS/bin"
cat >"$UPS/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl] $*" >>"${CALL_LOG:-/dev/null}"
case "$*" in *is-active*) exit 3 ;; esac
exit 0
EOF
chmod +x "$UPS/bin/systemctl"
out="$(run_upgrade_rig "$UPS" "$UPS/bin")"
rc=$?
assert_rc "upgrade on a stopped rig exits 0 (#413)" "$rc" "0"
assert_contains "upgrade says it left the stopped miner stopped (#413)" "$out" "left stopped"
assert_eq "upgrade still reinstalls the unit on a stopped rig (#413)" \
    "$([ -f "$UPS/etc-systemd/xmrig.service" ] && echo installed || echo missing)" "installed"
assert_eq "upgrade still regenerates the config on a stopped rig (#413)" \
    "$(J "$UPS/home/worker/xmrig/build/config.json" '.pools[0].url')" "poolbox.lan:3333"
assert_absent "upgrade does not restart a miner the operator stopped (#413)" "$(cat "$UPS/calls.log")" "] restart"
assert_absent "upgrade does not start a miner the operator stopped (#413)" "$(cat "$UPS/calls.log")" "] start"
# The macOS branch of the same decision: no systemd, so it can only tell the operator.
o="$(
    source "$SCRIPT"
    OS_TYPE=Darwin
    set +e
    _upgrade_restart yes 2>&1
)"
assert_contains "upgrade on macOS points at a manual restart (#413)" "$o" "Restart the miner to apply"

echo "== black-box: upgrade / help / unknown command (#4), rebuild path =="
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
    CALL_LOG="$UPG/calls.log" STUB_UNAME_S="$UPG_OS" XMRIG_VERSION=vNEW XMRIG_COMMIT=NEWCOMMIT \
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
# #413 moved the restart decision out of install_service and into upgrade(); a restart left behind in
# install_service would show up here as TWO on the rebuild path, which is the regression this pins.
if [ "$UPG_OS" = Linux ]; then
    assert_eq "upgrade rebuild restarts exactly once (#413)" \
        "$(grep -c 'systemctl\] restart' "$UPG/calls.log")" "1"
fi
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" help 2>&1)"
rc=$?
assert_rc "help exits 0" "$rc" "0"
assert_contains "help shows usage" "$out" "Usage:"
assert_contains "help lists upgrade" "$out" "upgrade"
assert_contains "help lists control-upgrade as internal (#312)" "$out" "control-upgrade (internal)"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" frobnicate 2>&1)"
rc=$?
assert_rc "unknown command fails" "$rc" "1"
assert_contains "unknown command message" "$out" "Unknown command"

# #148: upgrade --check — on-demand release check against GitHub's releases API. It must NEVER exit
# nonzero (an update hint can't be allowed to break an operator's script), never suggest a downgrade,
# and accept both `v1.2.3` and `1.2.3` tag shapes. Driven with test-local curl stubs; the sort -V
# canary fails loudly if a host's sort can't version-order (instead of silently mis-comparing).
echo "== unit: upgrade --check (#148) =="
assert_eq "sort -V canary: 1.9.0 < 1.10.0" "$(printf '1.9.0\n1.10.0\n' | sort -V | tail -n1)" "1.10.0"
UPC="$(mktemp -d "$SANDBOX/upc.XXXXXX")"
mkdir -p "$UPC/bin"
printf '1.4.0\n' >"$UPC/VERSION"
run_upgrade_check() { # curl behavior comes from $UPC/bin/curl (rewritten per case)
    (
        source "$SCRIPT"
        SCRIPT_DIR="$UPC"
        set +e
        PATH="$UPC/bin:$STUBS:$PATH" _upgrade_check 2>&1
        echo "rc=$?"
    )
}
stub_curl() { printf '#!/usr/bin/env bash\n%s\n' "$1" >"$UPC/bin/curl" && chmod +x "$UPC/bin/curl"; }
stub_curl 'printf "{\"tag_name\":\"v9.9.9\",\"html_url\":\"https://github.com/p2pool-starter-stack/rigforge/releases/tag/v9.9.9\"}"'
out="$(run_upgrade_check)"
assert_contains "check: newer version reported" "$out" "9.9.9 (you have 1.4.0)"
assert_contains "check: release URL printed" "$out" "releases/tag/v9.9.9"
assert_contains "check: upgrade recipe printed" "$out" "git pull"
assert_contains "check: tag-pinned recipe printed" "$out" "git checkout v9.9.9"
assert_contains "check: newer exits 0" "$out" "rc=0"
stub_curl 'printf "{\"tag_name\":\"v9.9.9\"}"'
out="$(run_upgrade_check)"
assert_contains "check: newer without html_url still reports" "$out" "9.9.9 (you have 1.4.0)"
assert_eq "check: no notes line when html_url missing" "$(printf '%s' "$out" | grep -c 'Release notes')" "0"
stub_curl 'printf "{\"tag_name\":\"v1.4.0\"}"'
out="$(run_upgrade_check)"
assert_contains "check: up to date (v-prefixed tag)" "$out" "RigForge 1.4.0 is the latest release"
assert_contains "check: up-to-date exits 0" "$out" "rc=0"
stub_curl 'printf "{\"tag_name\":\"1.4.0\"}"'
out="$(run_upgrade_check)"
assert_contains "check: up to date (bare tag)" "$out" "RigForge 1.4.0 is the latest release"
stub_curl 'printf "{\"tag_name\":\"v0.0.1\"}"'
out="$(run_upgrade_check)"
assert_contains "check: ahead of latest (develop build)" "$out" "ahead of the latest release (0.0.1)"
assert_eq "check: ahead never suggests a downgrade" "$(printf '%s' "$out" | grep -c 'git pull')" "0"
assert_contains "check: ahead exits 0" "$out" "rc=0"
stub_curl 'exit 22' # curl -f on a 403 rate-limit / offline
out="$(run_upgrade_check)"
assert_contains "check: offline warns" "$out" "try again later"
assert_contains "check: offline exits 0" "$out" "rc=0"
stub_curl 'printf "{}"' # API shape changed / rate-limit body that slipped past -f
out="$(run_upgrade_check)"
assert_contains "check: missing tag_name warns" "$out" "try again later"
assert_contains "check: missing tag_name exits 0" "$out" "rc=0"
rm "$UPC/VERSION"
out="$(run_upgrade_check)"
assert_contains "check: missing VERSION warns" "$out" "No VERSION file"
assert_contains "check: missing VERSION exits 0" "$out" "rc=0"
# Black-box through the dispatcher: --check reaches _upgrade_check (the shared curl stub answers with
# an XMRig summary body — no tag_name — so it lands on the warn arm), and unknown flags error.
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" upgrade --check </dev/null 2>&1)"
rc=$?
assert_rc "upgrade --check exits 0 via dispatcher" "$rc" "0"
assert_contains "upgrade --check reaches the check" "$out" "try again later"
out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" upgrade --bogus </dev/null 2>&1)"
rc=$?
assert_rc "upgrade rejects unknown flags" "$rc" "1"
assert_contains "upgrade unknown-flag message" "$out" "Unknown option for upgrade"

# #149 consistency sweep: uninstall joins the prompt-EOF guard and the arg-loop convention; extra
# args to no-arg verbs error instead of being silently swallowed; one unknown-option template; no
# error ends in "Aborting." (error() already announces the exit).
echo "== black-box: consistency sweep — flags, prompts, templates (#149) =="
out="$(cd "$U" && printf '' | PATH="$STUBS:$PATH" STUB_UNAME_S=Linux RIGFORGE_HOME="$PWD" bash "$SCRIPT" uninstall 2>&1)"
rc=$?
assert_rc "piped uninstall (EOF, no -y) aborts cleanly" "$rc" "0"
assert_contains "piped uninstall takes the default-No path" "$out" "Aborted"
assert_absent "piped uninstall does not die via the ERR trap" "$out" "aborted while"
out="$(cd "$U" && PATH="$STUBS:$PATH" STUB_UNAME_S=Linux RIGFORGE_HOME="$PWD" bash "$SCRIPT" uninstall --frobnicate </dev/null 2>&1)"
rc=$?
assert_rc "uninstall rejects unknown flags" "$rc" "1"
assert_contains "uninstall unknown-flag template" "$out" "Unknown option for uninstall: '--frobnicate'"
# #314: every unknown-option message names the verb's valid flags AND points at help.
for v in backup restore support-bundle; do
    out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" "$v" --frobnicate </dev/null 2>&1)"
    rc=$?
    assert_rc "$v rejects unknown flags (#314)" "$rc" "1"
    assert_contains "$v unknown-flag template (#314)" "$out" "Unknown option for $v: '--frobnicate'"
    assert_contains "$v unknown-flag message points at help (#314)" "$out" "help"
done
assert_eq "every unknown-option message enumerates flags or says it takes none (#314)" \
    "$(grep -c "Unknown option for [a-z-]*: '[^']*'\. " "$SCRIPT")" "0"
for v in doctor status bench apply setup; do
    out="$(cd "$U" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" "$v" --skip-deps </dev/null 2>&1)"
    rc=$?
    assert_rc "$v rejects an unexpected extra argument" "$rc" "1"
    assert_contains "$v extra-arg message points at help" "$out" "help"
done
assert_eq "no error message ends in 'Aborting.'" "$(grep -c 'Aborting\."' "$SCRIPT")" "0"
assert_eq "every verb arg-loop shares the unknown-option template" "$(grep -c 'Unexpected argument for [a-z$]' "$SCRIPT")" "1"

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
# #276 (item 3): `apply` wires _stamp_config_meta local (rigforge.sh:3599) — every #254 test above drives
# _stamp_config_meta directly, so this black-box apply run is the only thing that would catch that call
# site going missing. Assert the sidecar it writes, not just the helper's own unit behavior.
assert_eq "apply stamps the config-meta sidecar with source=local (#276)" "$([ -f "$U/.rigforge-config-meta.json" ] && echo y || echo n)" "y"
assert_eq "apply's config-meta sidecar source is 'local' (#276)" "$(J "$U/.rigforge-config-meta.json" '.source')" "local"
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

# #343: apply's post-reconcile summary asks the miner itself whether a pool connection came up.
# Connected (the stock curl stub's body) reports it; a disconnected miner draws a WARN naming the
# pool — but apply still exits 0 (warn, never refuse: the pool may be legitimately down); an
# unreachable API warns that it couldn't confirm. APPLY_POOL_IVL=0 keeps the retry loop instant.
echo "== black-box: apply reports the miner's pool connection (#343) =="
out="$(cd "$U" && PATH="$STUBS:$PATH" LOGROTATE_DIR="$U/logrotate" APPLY_POOL_IVL=0 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply </dev/null 2>&1)"
assert_rc "apply exits 0 when connected (#343)" "$?" "0"
assert_contains "apply reports the live pool connection (#343)" "$out" "live pool connection to poolbox.lan:3333"
APC="$(mktemp -d "$SANDBOX/apc.XXXXXX")"
cat >"$APC/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"connection":{"pool":"nosuch.host:3333","uptime":0,"failures":4,"accepted":0}}'
EOF
cat >"$APC/curl_dead" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$APC/curl" "$APC/curl_dead"
out="$(cd "$U" && PATH="$APC:$STUBS:$PATH" LOGROTATE_DIR="$U/logrotate" APPLY_POOL_TRIES=2 APPLY_POOL_IVL=0 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply </dev/null 2>&1)"
assert_rc "apply still exits 0 on a disconnected miner (#343: warn, not refuse)" "$?" "0"
assert_contains "apply warns on no live pool connection (#343)" "$out" "NO live pool connection"
assert_contains "apply's warn names the pool + failure count (#343)" "$out" "nosuch.host:3333, 4 failed attempt(s)"
APDEAD="$(mktemp -d "$SANDBOX/apdead.XXXXXX")"
cp "$APC/curl_dead" "$APDEAD/curl"
chmod +x "$APDEAD/curl"
out="$(cd "$U" && PATH="$APDEAD:$STUBS:$PATH" LOGROTATE_DIR="$U/logrotate" APPLY_POOL_TRIES=1 APPLY_POOL_IVL=0 \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply </dev/null 2>&1)"
assert_rc "apply exits 0 when the API can't confirm (#343)" "$?" "0"
assert_contains "apply warns when the API can't confirm the connection (#343)" "$out" "confirm a pool connection"

# #396: an `apply` must not START a rig that is deliberately stopped. Two ways a rig is legitimately
# offline — the watchdog's thermal cutoff (`systemctl stop` plus a watchdog.thermal-hold marker) and an
# operator's manual stop (no marker at all) — and _apply_runtime's unconditional `systemctl restart`
# overrode both, bypassing the hold's cool-down entirely. The decision reads the RUN-STATE, not the
# marker, which is what covers the manual stop too.
echo "== unit: _miner_deliberately_stopped — the predicate the #396 decision turns on =="
MDS="$(mktemp -d "$SANDBOX/mds.XXXXXX")"
mds() { # <word `is-active` prints> <unit installed: y|n> [OS_TYPE]
    mkdir -p "$MDS/bin"
    cat >"$MDS/bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
*"is-active"*)
    echo "$1"
    [ "$1" = active ] && exit 0 || exit 3
    ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$MDS/bin/systemctl"
    rm -rf "$MDS/systemd"
    mkdir -p "$MDS/systemd"
    if [ "$2" = y ]; then : >"$MDS/systemd/xmrig.service"; fi
    (
        source "$SCRIPT"
        OS_TYPE="${3:-Linux}"
        SYSTEMD_DIR="$MDS/systemd"
        SERVICE_NAME=xmrig
        set +e
        PATH="$MDS/bin:$STUBS:$PATH" _miner_deliberately_stopped
        echo "rc=$?"
    )
}
assert_eq "an installed unit reporting 'inactive' IS a deliberate stop (#396)" "$(mds inactive y)" "rc=0"
assert_eq "a running miner is not a deliberate stop (#396)" "$(mds active y)" "rc=1"
# A crashed unit systemd has given up on is nobody's decision — `apply` must still revive it, exactly as
# it did before #396. Mutation this catches: reading `is-active` by EXIT STATUS instead of by the word,
# which lumps `failed` in with `inactive`.
assert_eq "a FAILED unit is not a deliberate stop (#396)" "$(mds failed y)" "rc=1"
# `systemctl is-active` prints `inactive` for a unit that does not exist either, so without the
# unit-file half an `apply` before `setup` would report "left stopped" instead of failing loudly on the
# restart the way it does today — a quiet success in place of a loud failure.
assert_eq "no installed unit -> not a deliberate stop, whatever is-active says (#396)" "$(mds inactive n)" "rc=1"
assert_eq "macOS has no systemd run-state to preserve (#396)" "$(mds inactive y Darwin)" "rc=1"

echo "== unit: _apply_runtime preserve-run-state — the held rig stays stopped, tune's bare call does not (#396) =="
ARS="$(mktemp -d "$SANDBOX/ars.XXXXXX")"
ars_run() { # <preserve|bare> <word `is-active` prints> [thermal-hold marker: y|n]
    rm -rf "$ARS"
    mkdir -p "$ARS/bin" "$ARS/systemd" "$ARS/worker/xmrig/build"
    : >"$ARS/systemd/xmrig.service"
    cat >"$ARS/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "[systemctl] \$*" >>"$ARS/calls.log"
case "\$*" in
*"is-active"*)
    echo "$2"
    [ "$2" = active ] && exit 0 || exit 3
    ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$ARS/bin/systemctl"
    if [ "${3:-n}" = y ]; then : >"$ARS/worker/watchdog.thermal-hold"; fi
    (
        source "$SCRIPT"
        # The regen and the re-own are covered by the black-box apply tests; what is under test here is
        # purely which service action this function takes, so both are stubbed out.
        parse_config() { :; }
        generate_xmrig_config() { :; }
        _reown_worker() { :; }
        OS_TYPE=Linux
        SYSTEMD_DIR="$ARS/systemd"
        SERVICE_NAME=xmrig
        WORKER_ROOT="$ARS/worker"
        set +e
        export PATH="$ARS/bin:$STUBS:$PATH"
        if [ "$1" = preserve ]; then _apply_runtime preserve-run-state 2>&1; else _apply_runtime 2>&1; fi
    )
}
out="$(ars_run preserve inactive)"
assert_contains "apply's _apply_runtime says it left the stopped miner stopped (#396)" "$out" "was stopped, so it was left stopped"
assert_absent "apply's _apply_runtime does NOT restart a deliberately stopped miner (#396)" "$(cat "$ARS/calls.log")" "] restart"
assert_absent "apply's _apply_runtime does NOT start it either (#396)" "$(cat "$ARS/calls.log")" "] start"
# The marker is named only to explain the stop; the DECISION above never reads it, which is why the
# no-marker (manual stop) case one assertion up takes the very same branch.
out="$(ars_run preserve inactive y)"
assert_contains "a thermal hold is named in the message when the marker is there (#396)" "$out" "watchdog is holding it"
out="$(ars_run preserve active)"
assert_contains "a RUNNING miner is still restarted by apply (#396)" "$out" "Applied config and restarted"
assert_contains "and the restart really is issued (#396)" "$(cat "$ARS/calls.log")" "] restart xmrig"
# The negative control that scopes the fix: tune/autotune/_restore_overrides call _apply_runtime with no
# argument and MUST keep the unconditional restart — tune's --bench leg stops the service itself and
# relies on the re-apply to bring it back, so a blanket preserve would strand a tune run, not a held rig.
out="$(ars_run bare inactive)"
assert_contains "a BARE _apply_runtime still restarts a stopped miner — tune/autotune depend on it (#396)" "$(cat "$ARS/calls.log")" "] restart xmrig"
assert_absent "a bare _apply_runtime never claims it left anything stopped (#396)" "$out" "left stopped"

echo "== black-box: apply on a deliberately stopped rig regenerates and holds (#396) =="
AST="$(mktemp -d "$SANDBOX/apply-stopped.XXXXXX")"
cp "$ROOT/VERSION" "$AST/"
cp -R "$ROOT/systemd" "$AST/"
mkdir -p "$AST/home/worker/xmrig/build" "$AST/logrotate" "$AST/etc-systemd" "$AST/bin"
: >"$AST/home/worker/xmrig/build/xmrig"
chmod +x "$AST/home/worker/xmrig/build/xmrig"
printf 'ABC\n' >"$AST/home/worker/xmrig/.rigforge-commit"
: >"$AST/etc-systemd/xmrig.service" # the unit IS installed — the miner is simply stopped
cat >"$AST/config.json" <<EOF
{ "HOME_DIR": "$AST/home", "DONATION": 1, "pools": [{"url": "poolbox.lan:3333"}] }
EOF
ast_systemctl() { # <word `is-active` prints>
    cat >"$AST/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "[systemctl] \$*" >>"\${CALL_LOG:-/dev/null}"
case "\$*" in
*"is-active"*)
    echo "$1"
    [ "$1" = active ] && exit 0 || exit 3
    ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$AST/bin/systemctl"
}
ast_apply() { # <extra args...>
    : >"$AST/calls.log"
    (cd "$AST" && PATH="$AST/bin:$STUBS:$PATH" LOGROTATE_DIR="$AST/logrotate" SYSTEMD_DIR="$AST/etc-systemd" \
        CALL_LOG="$AST/calls.log" APPLY_POOL_IVL=0 RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply "$@" </dev/null 2>&1)
}
ast_systemctl inactive
out="$(ast_apply)"
rc=$?
assert_rc "apply on a stopped rig exits 0 (#396)" "$rc" "0"
assert_eq "apply still regenerates the config on a stopped rig (#396)" \
    "$(J "$AST/home/worker/xmrig/build/config.json" '.pools[0].url')" "poolbox.lan:3333"
assert_contains "apply says it left the stopped miner stopped (#396)" "$out" "so it was left stopped"
assert_absent "apply does not restart a rig the operator or the watchdog stopped (#396)" "$(cat "$AST/calls.log")" "] restart"
assert_absent "apply does not start it either (#396)" "$(cat "$AST/calls.log")" "] start"
# The rest of the reconcile is unchanged — the unit is still re-rendered and reloaded, so the held rig
# comes up on the new config at its next deliberate start.
assert_contains "apply still reloads the re-rendered unit on a stopped rig (#396)" "$(cat "$AST/calls.log")" "daemon-reload"
assert_eq "apply still stamps the config-meta sidecar on a stopped rig (#396)" \
    "$(J "$AST/.rigforge-config-meta.json" '.source')" "local"
# #146's plan must state the decision the run will actually make — "and restart" while the run holds the
# rig is the same class of lie as reporting a skipped step as applied. Both arms are exercised.
out="$(ast_apply --dry-run)"
assert_contains "apply --dry-run says a stopped rig stays stopped (#396)" "$out" "stays stopped"
assert_absent "apply --dry-run on a stopped rig does not promise a restart (#396)" "$out" "and restart xmrig"
ast_systemctl active
out="$(ast_apply --dry-run)"
assert_contains "apply --dry-run still promises the restart on a running rig (#396)" "$out" "and restart xmrig"

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

# #236/#273: apply is the config-change path for the writable control server too — toggling `control`
# on/off via apply must install/remove its units without a full setup, the same as the sister API above.
# install_control's disabled branch only tears down units that already exist (confirmed by reading
# install_control, rigforge.sh:1194-1220 — same idempotent shape as install_api's disabled branch).
echo "== black-box: apply reconciles the writable control path to config (#236) =="
cp "$ROOT/systemd/rigforge-control.service.template" "$ROOT/systemd/rigforge-control-apply.service.template" "$ROOT/systemd/rigforge-control-apply.path.template" "$ARC/systemd/"
arc_control() { # <enabled|disabled>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ARC"
        SYSTEMD_DIR="$ARC/systemd"
        SERVICE_NAME=xmrig
        REAL_USER=rfop
        AUTOTUNE_MODE=disabled
        API_MODE=disabled
        CONTROL_MODE="$1"
        CONTROL_BIND=0.0.0.0
        CONTROL_PORT=8082
        API_PORT=8081
        # parse_config (always run by the real _apply_runtime, stubbed out below to skip the heavy
        # config regen) is what normally assigns API_ALLOW_FROM before install_control reads it —
        # mirror that here rather than leaving it unbound.
        API_ALLOW_FROM=10.0.0.5
        _apply_runtime() { :; }
        sudo() { "$@"; }
        set +e
        PATH="$STUBS:$PATH" apply 2>&1
    )
}
arc_control enabled >/dev/null
assert_eq "apply with control enabled installs the server unit (#236)" "$([ -f "$ARC/systemd/rigforge-control.service" ] && echo y || echo n)" "y"
assert_eq "apply with control enabled installs the applier unit (#236)" "$([ -f "$ARC/systemd/rigforge-control-apply.service" ] && echo y || echo n)" "y"
assert_eq "apply with control enabled installs the path watcher (#236)" "$([ -f "$ARC/systemd/rigforge-control-apply.path" ] && echo y || echo n)" "y"
arc_control disabled >/dev/null
assert_eq "apply with control disabled removes the server unit (#236)" "$([ -f "$ARC/systemd/rigforge-control.service" ] && echo y || echo n)" "n"
assert_eq "apply with control disabled removes the applier unit (#236)" "$([ -f "$ARC/systemd/rigforge-control-apply.service" ] && echo y || echo n)" "n"
assert_eq "apply with control disabled removes the path watcher (#236)" "$([ -f "$ARC/systemd/rigforge-control-apply.path" ] && echo y || echo n)" "n"

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

# #139: install_watchdog mirrors install_autotune — enabled renders both units (only the cadence is
# baked in; max_temp_c/ACCESS_TOKEN are re-read from config.json each run so no token lands in a
# unit file), disabled removes both cleanly.
echo "== black-box: install_watchdog timer enable/disable (#139) =="
WDI="$(mktemp -d "$SANDBOX/wdi.XXXXXX")"
mkdir -p "$WDI/systemd"
cp "$ROOT/systemd/rigforge-watchdog.service.template" "$ROOT/systemd/rigforge-watchdog.timer.template" "$WDI/systemd/"
run_install_watchdog() { # <disabled|enabled> [interval_min]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$WDI"
        SYSTEMD_DIR="$WDI/systemd"
        REAL_USER=rfop
        SERVICE_NAME=xmrig
        ACCESS_TOKEN=tok-123 # must NOT appear in any rendered unit
        WATCHDOG_MODE="$1"
        [ -n "${2:-}" ] && WATCHDOG_INTERVAL_MIN="$2"
        set +e
        PATH="$STUBS:$PATH" install_watchdog 2>&1
    )
}
out="$(run_install_watchdog enabled 7)"
assert_eq "watchdog enable writes the .timer" "$([ -f "$WDI/systemd/rigforge-watchdog.timer" ] && echo y || echo n)" "y"
assert_eq "watchdog enable writes the .service" "$([ -f "$WDI/systemd/rigforge-watchdog.service" ] && echo y || echo n)" "y"
assert_contains "watchdog timer honours the interval override" "$(cat "$WDI/systemd/rigforge-watchdog.timer")" "OnUnitActiveSec=7min"
assert_contains "watchdog service invokes the watchdog verb" "$(cat "$WDI/systemd/rigforge-watchdog.service")" "rigforge.sh watchdog"
assert_contains "watchdog service bakes in RIGFORGE_OPERATOR (#reown)" "$(cat "$WDI/systemd/rigforge-watchdog.service")" "RIGFORGE_OPERATOR=rfop"
assert_absent "no token in the watchdog service unit" "$(cat "$WDI/systemd/rigforge-watchdog.service")" "tok-123"
assert_absent "no token in the watchdog timer unit" "$(cat "$WDI/systemd/rigforge-watchdog.timer")" "tok-123"
out="$(run_install_watchdog enabled)" # no interval -> product default
assert_contains "watchdog default cadence is 5min" "$(cat "$WDI/systemd/rigforge-watchdog.timer")" "OnUnitActiveSec=5min"
out="$(run_install_watchdog disabled)"
assert_eq "watchdog disable removes the .timer" "$([ -f "$WDI/systemd/rigforge-watchdog.timer" ] && echo y || echo n)" "n"
assert_eq "watchdog disable removes the .service" "$([ -f "$WDI/systemd/rigforge-watchdog.service" ] && echo y || echo n)" "n"

# #395: install_watchdog used to end on `systemctl enable ... || true`, so it returned 0 whatever had
# happened above it — and both apply-path callers run it under `|| true`, which suppresses `set -e`
# for the whole dynamic extent of the call, so an earlier failure neither aborted nor showed. A
# caller therefore could not distinguish "watchdog re-rendered" from "watchdog untouched". These pin
# the honest return value at the source, which is what every other #395 assertion below builds on.
# Mutation each case catches: turning that step's `|| rc=1` back into a bare call, or dropping the
# closing `return "$rc"` — either restores always-0 and reddens the rc assertion here.
echo "== unit: install_watchdog returns non-zero when it could not render (#395) =="
WDF="$(mktemp -d "$SANDBOX/wdf.XXXXXX")"
mkdir -p "$WDF/systemd" "$WDF/bin"
cp "$ROOT/systemd/rigforge-watchdog.service.template" "$ROOT/systemd/rigforge-watchdog.timer.template" "$WDF/systemd/"
wdf_stub() { # <daemon-reload rc> <rm rc>
    cat >"$WDF/bin/systemctl" <<EOF
#!/usr/bin/env bash
[ "\$1" = daemon-reload ] && exit $1
exit 0
EOF
    cat >"$WDF/bin/rm" <<EOF
#!/usr/bin/env bash
[ $2 -eq 0 ] && exec /bin/rm "\$@"
exit $2
EOF
    # Fail ONE named unit write, so each write's guard is asserted on a failure only it can see. An
    # unwritable SYSTEMD_DIR breaks both writes at once, which would let either guard alibi the other:
    # revert one and the second still sets rc, and the suite stays green over a real deletion.
    cat >"$WDF/bin/tee" <<'TEOF'
#!/usr/bin/env bash
if [ -n "${WDF_TEE_FAIL:-}" ] && [ "${*/$WDF_TEE_FAIL/}" != "$*" ]; then
    cat >/dev/null
    exit 1
fi
exec /usr/bin/tee "$@"
TEOF
    chmod +x "$WDF/bin/systemctl" "$WDF/bin/rm" "$WDF/bin/tee"
}
wdf_run() { # <systemd-dir> <enabled|disabled> <daemon-reload rc> <rm rc> -> "rc=<n>"
    wdf_stub "$3" "$4"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$WDF"
        SYSTEMD_DIR="$1"
        REAL_USER=rfop
        SERVICE_NAME=xmrig
        WATCHDOG_MODE="$2"
        WATCHDOG_INTERVAL_MIN=7
        set +e
        PATH="$WDF/bin:$STUBS:$PATH" install_watchdog >/dev/null 2>&1
        echo "rc=$?"
    )
}
# The healthy case first — without it the failure assertions below would also pass on a function that
# simply always returns 1, which proves nothing about honesty.
assert_eq "install_watchdog returns 0 when every step succeeds (#395)" "$(wdf_run "$WDF/systemd" enabled 0 0)" "rc=0"
assert_eq "a unit write that cannot land -> non-zero (#395)" "$(wdf_run "$WDF/absent/systemd" enabled 0 0)" "rc=1"
assert_eq "the .service write alone failing -> non-zero (#395)" "$(WDF_TEE_FAIL=rigforge-watchdog.service wdf_run "$WDF/systemd" enabled 0 0)" "rc=1"
assert_eq "the .timer write alone failing -> non-zero (#395)" "$(WDF_TEE_FAIL=rigforge-watchdog.timer wdf_run "$WDF/systemd" enabled 0 0)" "rc=1"
assert_eq "a failed daemon-reload -> non-zero (#395)" "$(wdf_run "$WDF/systemd" enabled 1 0)" "rc=1"
# The disabled branch is the same lie in the other direction: a timer that could not be REMOVED is
# still firing on the old cadence while config.json says the watchdog is off.
assert_eq "disable returns 0 when the units are actually removed (#395)" "$(wdf_run "$WDF/systemd" disabled 0 0)" "rc=0"
wdf_run "$WDF/systemd" enabled 0 0 >/dev/null # re-render so there is something to fail to remove
assert_eq "a unit that cannot be removed -> non-zero (#395)" "$(wdf_run "$WDF/systemd" disabled 0 1)" "rc=1"

# #139: the watchdog config keys. Typo hard-errors (a recovery mechanism must not be silently
# disabled); the interval and cutoff validate as bounded integers; max_temp_c empty = cutoff off.
echo "== unit: parse_config — watchdog keys (#139) =="
wd_mode() { parse_and_print "$1" "$ROOT" WATCHDOG_MODE; }
c="$(mkconf wd_dis "{ $POOL, \"watchdog\": \"disabled\" }")"
assert_eq "watchdog disabled -> mode disabled" "$(wd_mode "$c")" "disabled"
c="$(mkconf wd_def "{ $POOL }")"
assert_eq "watchdog absent -> mode disabled" "$(wd_mode "$c")" "disabled"
assert_eq "watchdog interval defaults to 5" "$(parse_and_print "$c" "$ROOT" WATCHDOG_INTERVAL_MIN)" "5"
assert_eq "max_temp_c defaults to empty (cutoff off)" "$(parse_and_print "$c" "$ROOT" MAX_TEMP_C)" ""
c="$(mkconf wd_en "{ $POOL, \"watchdog\": \"enabled\", \"watchdog_interval_min\": 15, \"max_temp_c\": 85 }")"
assert_eq "watchdog enabled -> mode enabled" "$(wd_mode "$c")" "enabled"
assert_eq "watchdog interval honours the override" "$(parse_and_print "$c" "$ROOT" WATCHDOG_INTERVAL_MIN)" "15"
assert_eq "max_temp_c honours the override" "$(parse_and_print "$c" "$ROOT" MAX_TEMP_C)" "85"
c="$(mkconf wd_true "{ $POOL, \"watchdog\": true }")"
assert_eq "watchdog legacy true -> enabled" "$(wd_mode "$c")" "enabled"
parse_fails() { (source "$SCRIPT" && CONFIG_JSON="$1" SCRIPT_DIR="$ROOT" && set +e && PATH="$STUBS:$PATH" parse_config 2>&1); }
c="$(mkconf wd_typo "{ $POOL, \"watchdog\": \"enbaled\" }")"
assert_contains "watchdog typo hard-errors" "$(parse_fails "$c")" 'Invalid "watchdog" value'
c="$(mkconf wd_iv0 "{ $POOL, \"watchdog_interval_min\": 0 }")"
assert_contains "interval 0 rejected" "$(parse_fails "$c")" "watchdog_interval_min must be"
c="$(mkconf wd_iv9k "{ $POOL, \"watchdog_interval_min\": 9000 }")"
assert_contains "interval 9000 rejected" "$(parse_fails "$c")" "watchdog_interval_min must be"
c="$(mkconf wd_t30 "{ $POOL, \"max_temp_c\": 30 }")"
assert_contains "max_temp_c 30 rejected (never restarts)" "$(parse_fails "$c")" "max_temp_c must be"
c="$(mkconf wd_thot "{ $POOL, \"max_temp_c\": \"hot\" }")"
assert_contains "max_temp_c non-integer rejected" "$(parse_fails "$c")" "max_temp_c must be"

# #139: the watchdog() check itself. One check per run; restart only on the SECOND consecutive
# unhealthy check (0 H/s and API-unreachable both count); thermal stop above max_temp_c with a
# 5°C-hysteresis restart; unreadable temp or empty max_temp_c skips thermal entirely. systemctl
# calls asserted via CALL_LOG; parse_config is shadowed so the test drives state directly.
echo "== unit: watchdog health check (#139) =="
WDR="$(mktemp -d "$SANDBOX/wdr.XXXXXX")"
run_watchdog() { # <temp_cmd> <api_cmd> <max_temp_c> [active=y|n]
    (
        source "$SCRIPT"
        parse_config() { :; }
        OS_TYPE=Linux
        WORKER_ROOT="$WDR"
        SERVICE_NAME=xmrig
        MAX_TEMP_C="$3"
        _ACT="${4:-y}"
        sudo() { "$@"; }
        systemctl() {
            echo "[systemctl] $*" >>"$WDR/calls.log"
            case "$*" in *is-active*) [ "$_ACT" = y ] ;; *) return 0 ;; esac
        }
        set +e
        TUNE_TEMP_CMD="$1" API_CMD="$2" watchdog 2>&1
        echo "rc=$?"
    )
}
wd_calls() { grep -c "$1" "$WDR/calls.log" 2>/dev/null || true; }
# Healthy: counter stays clear, no restart.
: >"$WDR/calls.log"
out="$(run_watchdog 'echo 60' 'echo 12345.6' '')"
assert_contains "healthy check logs the hashrate" "$out" "healthy (12345.6 H/s)"
assert_contains "healthy check exits 0" "$out" "rc=0"
assert_eq "healthy check never restarts" "$(wd_calls 'restart xmrig')" "0"
assert_eq "healthy check leaves no strike file" "$([ -f "$WDR/watchdog.fails" ] && echo y || echo n)" "n"
# Strike 1 (0 H/s): no restart yet.
: >"$WDR/calls.log"
out="$(run_watchdog 'echo 60' 'echo 0' '')"
assert_contains "first unhealthy check is a strike" "$out" "1/2"
assert_eq "one blip does not restart" "$(wd_calls 'restart xmrig')" "0"
assert_eq "strike file records 1" "$(cat "$WDR/watchdog.fails")" "1"
# Strike 2 (API unreachable — the other unhealthy shape): restart fires, counter resets.
out="$(run_watchdog 'echo 60' 'false' '')"
assert_contains "second consecutive fail restarts" "$out" "wedged"
assert_eq "restart fired on the second strike" "$(wd_calls 'restart xmrig')" "1"
assert_eq "strike file reset after restart" "$([ -f "$WDR/watchdog.fails" ] && echo y || echo n)" "n"
# A healthy check between strikes resets the counter.
out="$(run_watchdog 'echo 60' 'echo 0' '')"
out="$(run_watchdog 'echo 60' 'echo 9999' '')"
assert_eq "healthy check resets the strike counter" "$([ -f "$WDR/watchdog.fails" ] && echo y || echo n)" "n"
# Thermal cutoff: above max_temp_c -> stop + marker, even with a healthy hashrate.
: >"$WDR/calls.log"
out="$(run_watchdog 'echo 92.5' 'echo 12345' '85')"
assert_contains "over-temp stops the miner" "$out" "above max_temp_c=85"
assert_eq "over-temp issued systemctl stop" "$(wd_calls 'stop xmrig')" "1"
assert_eq "over-temp leaves the hold marker" "$([ -f "$WDR/watchdog.thermal-hold" ] && echo y || echo n)" "y"
# Hold + still warm (81 > 85-5): stays stopped, no start.
: >"$WDR/calls.log"
out="$(run_watchdog 'echo 81' 'echo 0' '85' n)"
assert_contains "hold above the hysteresis floor stays stopped" "$out" "stays stopped"
assert_eq "no start while still warm" "$(wd_calls 'start xmrig')" "0"
# Hold + cooled below max_temp_c - 5: starts exactly once, marker cleared.
: >"$WDR/calls.log"
out="$(run_watchdog 'echo 79.9' 'echo 0' '85' n)"
assert_contains "cooled rig lifts the hold" "$out" "thermal hold lifted"
assert_eq "cooled rig starts the miner once" "$(wd_calls 'start xmrig')" "1"
assert_eq "hold marker cleared after the start" "$([ -f "$WDR/watchdog.thermal-hold" ] && echo y || echo n)" "n"
# max_temp_c empty: thermal logic fully skipped even at 92°C (healthy path runs).
: >"$WDR/calls.log"
out="$(run_watchdog 'echo 92' 'echo 12345' '')"
assert_contains "no max_temp_c -> thermal skipped" "$out" "healthy"
assert_eq "no max_temp_c -> no stop" "$(wd_calls 'stop xmrig')" "0"
# Unreadable temp must not stop a healthy miner.
out="$(run_watchdog 'true' 'echo 12345' '85')"
assert_contains "unreadable temp skips thermal" "$out" "healthy"
# Stale hold after the operator removed max_temp_c: lifted (a skipped check must not strand the miner).
touch "$WDR/watchdog.thermal-hold"
out="$(run_watchdog 'echo 92' 'echo 0' '' n)"
assert_contains "hold with max_temp_c removed is lifted" "$out" "no longer set"
assert_eq "stale hold cleared" "$([ -f "$WDR/watchdog.thermal-hold" ] && echo y || echo n)" "n"
# Service not active (and no hold): systemd Restart= owns it; state resets, exit 0.
printf '1\n' >"$WDR/watchdog.fails"
out="$(run_watchdog 'echo 60' 'echo 0' '' n)"
assert_contains "inactive service is left to systemd" "$out" "not active"
assert_contains "inactive service exits 0" "$out" "rc=0"
assert_eq "inactive service clears the strike file" "$([ -f "$WDR/watchdog.fails" ] && echo y || echo n)" "n"
# Black-box: the dispatcher reaches watchdog(), which is Linux-only.
out="$(cd "$U" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" watchdog </dev/null 2>&1)"
rc=$?
assert_rc "watchdog on macOS fails loudly" "$rc" "1"
assert_contains "watchdog macOS message" "$out" "only supported on Linux"
# #210: the failure the live wedge test caught on miner-0 — curl's timeout (exit 28) rode
# pipefail out of _read_api_hashrate and errexit killed the whole check before the strike logic.
# Reproduce through the REAL dispatch (ERR trap + errexit live, unlike the set +e unit runs above)
# with a curl that fails exactly like a frozen miner's API.
WDB="$(mktemp -d "$SANDBOX/wdb.XXXXXX")"
mkdir -p "$WDB/bin" "$WDB/home/worker"
cat >"$WDB/config.json" <<EOF
{ "HOME_DIR": "$WDB/home", "pools": [{"url": "h:3333"}] }
EOF
printf '#!/usr/bin/env bash\nexit 28\n' >"$WDB/bin/curl"
chmod +x "$WDB/bin/curl"
out="$(cd "$WDB" && PATH="$WDB/bin:$STUBS:$PATH" STUB_UNAME_S=Linux CALL_LOG="$WDB/calls.log" RIGFORGE_HOME="$PWD" bash "$SCRIPT" watchdog </dev/null 2>&1)"
rc=$?
assert_rc "watchdog: curl timeout is a strike, not a crash (#210)" "$rc" "0"
assert_absent "watchdog: no ERR-trap abort on curl 28 (#210)" "$out" "aborted while"
assert_contains "watchdog: unreachable API counts a strike (#210)" "$out" "1/2"
assert_eq "watchdog: strike file written through real dispatch (#210)" "$(cat "$WDB/home/worker/watchdog.fails")" "1"
out="$(cd "$WDB" && PATH="$WDB/bin:$STUBS:$PATH" STUB_UNAME_S=Linux CALL_LOG="$WDB/calls.log" RIGFORGE_HOME="$PWD" bash "$SCRIPT" watchdog </dev/null 2>&1)"
rc=$?
assert_rc "watchdog: second tick exits 0 (#210)" "$rc" "0"
assert_contains "watchdog: two timeouts restart the miner (#210)" "$out" "wedged"
assert_eq "watchdog: restart reached systemctl (#210)" "$(grep -c "restart xmrig" "$WDB/calls.log")" "1"
# Same trap-in-subshell shape in upgrade --check (#210): an offline curl must produce ONE warn,
# not ERR-trap noise ahead of it — asserted through the real dispatch, where the trap is live.
cp "$ROOT/VERSION" "$WDB/"
out="$(cd "$WDB" && PATH="$WDB/bin:$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" upgrade --check </dev/null 2>&1)"
rc=$?
assert_rc "upgrade --check offline exits 0 via dispatch (#210)" "$rc" "0"
assert_contains "upgrade --check offline warns once (#210)" "$out" "try again later"
assert_absent "upgrade --check offline has no ERR-trap noise (#210)" "$out" "aborted while"

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

# #147: support-bundle — everything a maintainer needs, nothing secret. The redaction is
# structural (jq paths), and THE test is the whole-bundle grep: with fixture secrets planted in
# both configs, neither may appear anywhere in the extracted archive.
echo "== black-box: support-bundle collects + redacts (#147) =="
SB="$(mktemp -d "$SANDBOX/support.XXXXXX")"
mkdir -p "$SB/home/worker/xmrig/build"
cat >"$SB/config.json" <<EOF
{ "HOME_DIR": "$SB/home", "ACCESS_TOKEN": "FAKETOKEN_ce7a11", "pools": [{"url": "pool.lan:3333", "user": "4AbCdEfGh1234567890abcdefFAKEWALLETxyz9", "pass": "FAKEPASS_b0a7"}] }
EOF
cat >"$SB/home/worker/xmrig/build/config.json" <<EOF
{ "http": {"access-token": "FAKETOKEN_ce7a11"}, "pools": [{"url": "pool.lan:3333", "user": "4AbCdEfGh1234567890abcdefFAKEWALLETxyz9", "pass": "FAKEPASS_b0a7"}] }
EOF
printf 'net      use pool pool.lan:3333\nmsr      preset ok\nspeed 10s 1234.5 H/s\n' >"$SB/home/worker/xmrig.log"
printf '{"randomx":{"scratchpad_prefetch_mode":2}}\n' >"$SB/home/worker/tune-overrides.json"
sb_out="$(cd "$SB" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" support-bundle </dev/null 2>&1)"
sb_rc=$?
assert_rc "support-bundle exits 0 (#147)" "$sb_rc" "0"
sb_archive="$(find "$SB" -name 'rigforge-support-*.tar.gz' | head -1)"
assert_eq "support-bundle wrote an archive (#147)" "$([ -n "$sb_archive" ] && echo y || echo n)" "y"
assert_contains "archive is mode 600 (#147)" "$(ls -l "$sb_archive" | cut -c1-10)" "rw-------"
SBX="$SB/extracted"
mkdir -p "$SBX"
tar -xzf "$sb_archive" -C "$SBX"
assert_eq "CRITICAL: token appears nowhere in the bundle (#147)" "$(grep -rl "FAKETOKEN_ce7a11" "$SBX" | wc -l | tr -d ' ')" "0"
assert_eq "CRITICAL: pool pass appears nowhere in the bundle (#147)" "$(grep -rl "FAKEPASS_b0a7" "$SBX" | wc -l | tr -d ' ')" "0"
assert_eq "wallet masked to first-4…last-4 (#147)" "$(J "$SBX/config.redacted.json" '.pools[0].user')" "4AbC…xyz9"
assert_eq "generated config token redacted structurally (#147)" "$(J "$SBX/xmrig-config.redacted.json" '.http."access-token"')" "<redacted>"
assert_eq "log tail collected (#147)" "$([ -f "$SBX/xmrig.log.tail" ] && echo y || echo n)" "y"
assert_eq "tune overrides collected (#147)" "$([ -f "$SBX/tune-overrides.json" ] && echo y || echo n)" "y"
assert_eq "manifest lists collected files (#147)" "$(J "$SBX/manifest.json" '.files | length > 3')" "true"
assert_contains "manifest names what is NOT collected (#147)" "$(J "$SBX/manifest.json" '.not_collected | join(",")')" "journalctl"
assert_contains "closing output tells the user to review (#147)" "$sb_out" "Review the extracted contents"
# Short pool user: fully redacted, never partially masked.
cat >"$SB/config.json" <<EOF
{ "HOME_DIR": "$SB/home", "pools": [{"url": "pool.lan:3333", "user": "worker1", "pass": "x"}] }
EOF
rm -f "$SB"/rigforge-support-*.tar.gz
(cd "$SB" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" support-bundle </dev/null >/dev/null 2>&1)
sb_archive="$(find "$SB" -name 'rigforge-support-*.tar.gz' | head -1)"
rm -rf "$SBX" && mkdir -p "$SBX" && tar -xzf "$sb_archive" -C "$SBX"
assert_eq "short pool user fully redacted (#147)" "$(J "$SBX/config.redacted.json" '.pools[0].user')" "<redacted>"
# No config: clear error, rc 1.
SB2="$(mktemp -d "$SANDBOX/support2.XXXXXX")"
sb2_rc=0
(cd "$SB2" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" support-bundle </dev/null >/dev/null 2>&1) || sb2_rc=$?
assert_rc "support-bundle without a config errors (#147)" "$sb2_rc" "1"
# Unknown arg: hard error (house style).
sba_rc=0
(cd "$SB" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" support-bundle --bogus </dev/null >/dev/null 2>&1) || sba_rc=$?
assert_rc "support-bundle rejects unknown args (#147)" "$sba_rc" "1"
# Fail closed: a config jq can't parse is SKIPPED, never shipped unredacted. Seed a malformed
# generated config; the redacted file must be absent and the manifest must say so.
cat >"$SB/config.json" <<EOF
{ "HOME_DIR": "$SB/home", "pools": [{"url": "pool.lan:3333"}] }
EOF
printf 'this is NOT json {{{\n' >"$SB/home/worker/xmrig/build/config.json"
rm -f "$SB"/rigforge-support-*.tar.gz
(cd "$SB" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" support-bundle </dev/null >/dev/null 2>&1)
sb_archive="$(find "$SB" -name 'rigforge-support-*.tar.gz' | head -1)"
rm -rf "$SBX" && mkdir -p "$SBX" && tar -xzf "$sb_archive" -C "$SBX"
assert_eq "unparseable generated config is NOT in the bundle (fail closed) (#147)" "$([ -f "$SBX/xmrig-config.redacted.json" ] && echo present || echo absent)" "absent"
assert_contains "manifest flags the skipped file (#147)" "$(J "$SBX/manifest.json" '.not_collected | join(",")')" "unparseable"
# macOS system-info branch: sysctl reads instead of lscpu/free.
rm -f "$SB"/rigforge-support-*.tar.gz
(cd "$SB" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" support-bundle </dev/null >/dev/null 2>&1)
sb_archive="$(find "$SB" -name 'rigforge-support-*.tar.gz' | head -1)"
rm -rf "$SBX" && mkdir -p "$SBX" && tar -xzf "$sb_archive" -C "$SBX"
assert_eq "macOS bundle still collects system.txt (#147)" "$([ -f "$SBX/system.txt" ] && echo y || echo n)" "y"

# #146: `setup --dry-run` prints a numbered read-only plan and touches NOTHING — no sudo, no writes,
# no modprobe. The drift guard is the load-bearing test: every CURRENT_STEP phrase in main() must
# appear in the plan, so a new pipeline step can't ship without a plan line.
echo "== black-box: setup --dry-run plan + no-mutation guard (#146) =="
DR="$(mktemp -d "$SANDBOX/dryrun.XXXXXX")"
mkdir -p "$DR/etc"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$DR/etc/grub"
printf 'proc /proc proc defaults 0 0\n' >"$DR/etc/fstab"
cat >"$DR/config.json" <<EOF
{ "HOME_DIR": "$DR/home", "pools": [{"url": "poolbox.lan:3333"}], "autotune": "performance", "api": "enabled", "add_to_path": true }
EOF
# RIGFORGE_HOME points SCRIPT_DIR at the sandbox, so seed a DETERMINISTIC stand-in for our own
# util/proposed-grub.sh — the unit suite pins the plan's rendering; the container e2e runs the
# real probe against a real kernel.
mkdir -p "$DR/util"
cat >"$DR/util/proposed-grub.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--runtime) echo 2514 ;;
-q) echo "quiet splash default_hugepagesz=2M hugepages=2514 msr.allow_writes=on" ;;
esac
EOF
chmod +x "$DR/util/proposed-grub.sh"
# MEMINFO is pinned (0 free) so the grow-only preview (#328) renders the same on any host —
# a runner with a real, large HugePages_Free would otherwise flip the plan line to "no change".
printf 'HugePages_Free:        0\n' >"$DR/etc/meminfo"
dr_out="$(cd "$DR" && PATH="$STUBS:$PATH" CALL_LOG="$DR/calls.log" GRUB_DEFAULT="$DR/etc/grub" FSTAB="$DR/etc/fstab" \
    MEMINFO="$DR/etc/meminfo" RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
dr_rc=$?
assert_rc "dry-run exits 0 (#146)" "$dr_rc" "0"
assert_contains "plan: build line names the pinned version (#146)" "$dr_out" "build XMRig"
assert_contains "plan: dependency probe ran (#146)" "$dr_out" "installing dependencies"
assert_contains "plan: computed HugePages count, grow-only wording (#146/#328)" "$dr_out" "grow the pool so 2514 2MB HugePages are available"
assert_contains "plan: GRUB before -> after diff (#146)" "$dr_out" "GRUB cmdline: 'quiet splash' -> 'quiet splash default_hugepagesz=2M hugepages=2514 msr.allow_writes=on'"
assert_contains "plan: reboot called out when GRUB changes (#146)" "$dr_out" "a reboot WILL be required"
assert_contains "plan: fstab append lines (#146)" "$dr_out" "hugetlbfs /dev/hugepages"
assert_contains "plan: autotune timer with the configured target (#146)" "$dr_out" "target: performance"
assert_contains "plan: sister API units (#146)" "$dr_out" "install rigforge-api.service"
assert_contains "plan: add_to_path symlink (#146)" "$dr_out" "symlink"
assert_contains "plan: footer says nothing changed (#146)" "$dr_out" "Dry run — nothing was changed"
# Grow-only preview, covered branch (#328): with plenty of free pages the plan says "no change"
# instead of the grow line — same availability check the mutation runs.
printf 'HugePages_Free:    99999\n' >"$DR/etc/meminfo_full"
dr_out_full="$(cd "$DR" && PATH="$STUBS:$PATH" CALL_LOG="$DR/calls2.log" GRUB_DEFAULT="$DR/etc/grub" FSTAB="$DR/etc/fstab" \
    MEMINFO="$DR/etc/meminfo_full" RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
assert_contains "plan: covered pool renders the no-change line (#328)" "$dr_out_full" "HugePages pool already covers the miner (2514 pages needed) — no change"
# No-mutation guard: none of the stubbed mutating commands were invoked (the stubs log every call).
for mut in apt-get modprobe tee mount sysctl; do
    assert_absent "dry-run never invokes $mut (#146)" "$(cat "$DR/calls.log" 2>/dev/null)" "[$mut]"
done
assert_absent "dry-run never enables units (#146)" "$(cat "$DR/calls.log" 2>/dev/null)" "enable"
# Drift guard: every CURRENT_STEP phrase in main() appears in the plan.
main_steps="$(sed -n '/^main()/,/^}/p' "$SCRIPT" | grep -o 'CURRENT_STEP="[^"]*"' | cut -d'"' -f2)"
# If extraction ever comes back empty (main() renamed/reformatted), the loop below would run once
# with an empty $step and assert_contains with an empty needle always passes — silently defanging
# the guard. Fail loudly instead.
[ -n "$main_steps" ] || bad "could not extract CURRENT_STEP list from main()" "sed/grep extraction was empty"
while IFS= read -r step; do
    assert_contains "plan covers main() step '$step' (#146)" "$dr_out" "$step"
done <<<"$main_steps"
# No config: says it would create one, exits 0, creates nothing.
DR2="$(mktemp -d "$SANDBOX/dryrun2.XXXXXX")"
dr2_out="$(cd "$DR2" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
assert_rc "no-config dry-run exits 0 (#146)" "$?" "0"
assert_contains "no-config dry-run says a config would be created (#146)" "$dr2_out" "would create"
assert_eq "no-config dry-run creates nothing (#146)" "$([ -f "$DR2/config.json" ] && echo y || echo n)" "n"
# Opposite-config arms: prebuilt worker (skip-build lines), autotune/api absent (disabled arms),
# add_to_path off, api_allow_from set (firewall-scoping arm), fstab pre-seeded (already-configured).
DR3="$(mktemp -d "$SANDBOX/dryrun3.XXXXXX")"
mkdir -p "$DR3/etc" "$DR3/home/worker/xmrig/build"
printf 'hugetlbfs /dev/hugepages hugetlbfs defaults 0 0\nhugetlbfs_1g %s hugetlbfs pagesize=1G 0 0\n' "${HUGEPAGES_1G_DIR:-/dev/hugepages1G}" >"$DR3/etc/fstab"
cat >"$DR3/config.json" <<EOF
{ "HOME_DIR": "$DR3/home", "pools": [{"url": "poolbox.lan:3333"}], "api_allow_from": "10.0.0.9" }
EOF
touch "$DR3/home/worker/tune-overrides.json"
# A genuinely "already built" worker: executable + matching commit marker (no sha record = legacy build).
printf '#!/bin/sh\n' >"$DR3/home/worker/xmrig/build/xmrig"
chmod +x "$DR3/home/worker/xmrig/build/xmrig"
printf 'dr3commit000\n' >"$DR3/home/worker/xmrig/.rigforge-commit"
mkdir -p "$DR3/util"
cp "$DR/util/proposed-grub.sh" "$DR3/util/proposed-grub.sh"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash default_hugepagesz=2M hugepages=2514 msr.allow_writes=on"\n' >"$DR3/etc/grub"
dr3_out="$(cd "$DR3" && PATH="$STUBS:$PATH" FSTAB="$DR3/etc/fstab" GRUB_DEFAULT="$DR3/etc/grub" \
    XMRIG_COMMIT="dr3commit000" RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
assert_rc "opposite-config dry-run exits 0 (#146)" "$?" "0"
assert_contains "plan: autotune disabled arm (#146)" "$dr3_out" "autotune disabled"
assert_contains "plan: sister API disabled arm (#146)" "$dr3_out" "disabled — installed units would be removed"
assert_contains "plan: firewall scoping arm (#146)" "$dr3_out" "scoping the API port(s) to 10.0.0.9"
assert_contains "plan: add_to_path off arm (#146)" "$dr3_out" "no symlink"
assert_contains "plan: fstab already configured arm (#146)" "$dr3_out" "fstab already configured"
assert_contains "plan: tune overlay note (#146)" "$dr3_out" "overlay tune-overrides.json"
assert_contains "plan: skip-build arm when already built (#146)" "$dr3_out" "skip the build"
assert_contains "plan: compile-skipped arm (#146)" "$dr3_out" "skipped (already built"
assert_contains "plan: GRUB already-configured arm (#146)" "$dr3_out" "GRUB already configured"
# Every package missing (dpkg forced to fail) -> the exact-list arm renders.
mkdir -p "$DR3/badpkg"
printf '#!/usr/bin/env bash\nexit 1\n' >"$DR3/badpkg/dpkg"
chmod +x "$DR3/badpkg/dpkg"
drm_out="$(cd "$DR3" && PATH="$DR3/badpkg:$STUBS:$PATH" XMRIG_COMMIT="dr3commit000" RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
assert_contains "plan: names the missing packages when dpkg says so (#146)" "$drm_out" "install packages: git build-essential"
# Darwin arms: brew deps, kernel/limits/service skips, apply's manual-restart line.
drd_out="$(cd "$DR3" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
assert_rc "Darwin dry-run exits 0 (#146)" "$?" "0"
assert_contains "plan: brew dependency arm (#146)" "$drd_out" "install/verify via brew"
assert_contains "plan: macOS kernel-tuning skip (#146)" "$drd_out" "no HugePages/MSR here"
assert_contains "plan: macOS no-service arm (#146)" "$drd_out" "none on macOS"
apd_out="$(cd "$DR3" && PATH="$STUBS:$PATH" STUB_UNAME_S=Darwin RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply --dry-run </dev/null 2>&1)"
assert_contains "apply plan: macOS manual-restart arm (#146)" "$apd_out" "restart the miner manually"

# apply --dry-run: plan lines, no restart.
: >"$DR/calls.log"
ap_out="$(cd "$DR" && PATH="$STUBS:$PATH" CALL_LOG="$DR/calls.log" RIGFORGE_HOME="$PWD" bash "$SCRIPT" apply --dry-run </dev/null 2>&1)"
assert_rc "apply --dry-run exits 0 (#146)" "$?" "0"
assert_contains "apply plan: config regen target (#146)" "$ap_out" "regenerate"
assert_contains "apply plan: reconcile line (#146)" "$ap_out" "autotune: performance"
assert_absent "apply --dry-run never restarts (#146)" "$(cat "$DR/calls.log" 2>/dev/null)" "restart"
# #353 (2): drift guard — every install_* apply() actually reconciles must be named in _apply_plan's
# line 3, or the plan under-reports what apply does (found: watchdog + control were called but never
# named). Hand-maintained map from function name -> plan wording, same shape as the #207 FLAGMAP below
# (reconciles change rarely; the failure message says exactly where to add the plan line) since the
# plan's prose can't be derived from the function names automatically.
apply_reconciles="$(sed -n '/^apply() {/,/^}/p' "$SCRIPT" | grep -oE 'install_[a-z_]+' | sort -u)"
[ -n "$apply_reconciles" ] || bad "could not extract install_* calls from apply() (#353)" "sed/grep extraction was empty"
while IFS= read -r _fn; do
    case "$_fn" in
    install_autotune) _word="autotune" ;;
    install_watchdog) _word="watchdog" ;;
    install_api) _word="sister API" ;;
    install_control) _word="control path" ;;
    install_api_firewall) _word="firewall" ;;
    *)
        bad "apply --dry-run plan drift guard (#353)" "apply() now calls $_fn but the map above doesn't know its plan wording — add it"
        _word=""
        ;;
    esac
    [ -n "$_word" ] && assert_contains "apply --dry-run plan covers apply()'s $_fn (#353)" "$ap_out" "$_word"
done <<<"$apply_reconciles"
# Unknown setup arg: hard error, house style.
bash "$SCRIPT" setup --bogus >/dev/null 2>&1 || setup_arg_rc=$?
assert_rc "unknown setup arg errors (#146)" "${setup_arg_rc:-0}" "1"

# #145: `completion` prints a static tab-completion script. Static means drift is the one real risk,
# so this diffs the script's verb list against the dispatch case itself — adding a verb without
# updating _rigforge_verbs fails here. Hyphenated internal verbs (api-refresh, msr-apply) and the
# -v/-h flag spellings are deliberately excluded by the ^[a-z]+$ filter.
echo "== black-box: completion script + verb-list drift guard (#145) =="
comp_out="$(bash "$SCRIPT" completion bash)"
# Hyphenated operator verbs (support-bundle) complete; the two INTERNAL hyphenated verbs (run by
# systemd, not operators) are excluded by name.
# sort -u: the #149 no-arg pre-check case names the same verbs a second time before dispatch.
dispatch_verbs="$(sed -n '/_RIGFORGE_SOURCED" = "0" \]; then/,/^fi$/p' "$SCRIPT" | grep -oE '^    [a-z |-]+\)' | tr -d ' )' | tr '|' '\n' | grep -E '^[a-z][a-z-]*$' | grep -vE '^(api-refresh|msr-apply|control-apply|control-upgrade)$' | sort -u | tr '\n' ' ')"
completed_verbs="$(printf '%s\n' "$comp_out" | sed -n 's/^_rigforge_verbs="\(.*\)"$/\1/p' | tr ' ' '\n' | sort | tr '\n' ' ')"
assert_eq "completion verbs match the dispatch case exactly (#145)" "$completed_verbs" "$dispatch_verbs"
assert_contains "completion: all ten tune flags (#145)" "$comp_out" '--now --short --long --live --bench --confirm --efficiency --perf --history --clear'
# #207: per-verb FLAG drift guard — hand-maintained map (verbs gain flags rarely; the failure
# message says exactly where to add one). The verb-level guard above can't see flags.
while IFS=: read -r cverb cflags; do
    for cf in $cflags; do
        case "$comp_out" in
        *"$cf"*) ok "completion: $cverb offers $cf (#207)" ;;
        *) bad "completion: $cverb offers $cf (#207)" "add '$cf' to the $cverb) COMPREPLY case in _completion_bash" ;;
        esac
    done
done <<'FLAGMAP'
setup:--dry-run
apply:--dry-run
upgrade:--check
bios:--perf --efficiency
uninstall:-y --yes
FLAGMAP
assert_contains "completion zsh: bashcompinit shim first (#145)" "$(bash "$SCRIPT" completion zsh | head -1)" "bashcompinit"
printf '%s\n' "$comp_out" >"$SANDBOX/rigforge-completion.bash"
bash -c "source '$SANDBOX/rigforge-completion.bash' && type _rigforge >/dev/null" && ok "completion script sources cleanly (#145)" || bad "completion script failed to source (#145)"
comp_rc=0
bash "$SCRIPT" completion >/dev/null 2>&1 || comp_rc=$?
assert_rc "completion without a shell errors with usage (#145)" "$comp_rc" "1"

# #353 (6): _read_api_summary + _xmrig_summary_json were near-identical readers, merged into one
# function with a mode argument. #364 then deleted that mode: "propagate" let curl's exit escape so an
# unreachable API would "surface upstream", but no caller ever read the status (every one branches on
# an empty body) and letting it escape fired the inherited ERR trap inside the $( ) each caller reads
# through. Both readers now ALWAYS return 0 with an empty body — the contract the callers assume.
echo "== unit: the API readers never let a curl failure escape (#353/#364) =="
rap_out="$( (
    source "$SCRIPT"
    unset API_CMD
    curl() { return 7; } # simulate an unreachable worker API
    set +e
    printf 'summary:[%s] rc=%s\n' "$(_read_api_summary)" "$?"
    printf 'hashrate:[%s] rc=%s\n' "$(_read_api_hashrate)" "$?"
    # NB: no apostrophes in comments inside this $( ) — bash 3.2 (macOS) opens a quote on one and
    # swallows the rest of the file. The override is how the suite stands in for the worker API, and
    # a FAILING one is how the watchdog strike-2 case simulates "unreachable". It must honour the
    # same contract as the curl path, or the never-fails guarantee callers lean on has a hole there.
    API_CMD=false
    printf 'summary-cmd:[%s] rc=%s\n' "$(_read_api_summary)" "$?"
    printf 'hashrate-cmd:[%s] rc=%s\n' "$(_read_api_hashrate)" "$?"
) 2>&1)"
assert_contains "_read_api_summary swallows a curl failure (rc 0, empty body)" "$rap_out" "summary:[] rc=0"
assert_contains "_read_api_hashrate swallows a curl failure (rc 0, empty body)" "$rap_out" "hashrate:[] rc=0"
assert_contains "_read_api_summary swallows a failing API_CMD (rc 0, empty body)" "$rap_out" "summary-cmd:[] rc=0"
assert_contains "_read_api_hashrate swallows a failing API_CMD (rc 0, empty body)" "$rap_out" "hashrate-cmd:[] rc=0"

# #143: `status` prepends a one-glance live summary from ONE /2/summary fetch — facts, no ✓/! markers,
# never sudo. Unreachable API (miner stopped / http off) degrades to a single explanatory line and the
# untouched platform block; a bad config can't crash it (parse_config runs in a subshell).
echo "== unit: status live summary (#143) =="
ST="$(mktemp -d "$SANDBOX/status.XXXXXX")"
cat >"$ST/config.json" <<EOF
{ "HOME_DIR": "$ST/home", "pools": [{"url": "h:3333"}] }
EOF
run_status() { # <curl-mode: ok|fail>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SERVICE_NAME=xmrig
        CONFIG_JSON="$ST/config.json"
        unset API_CMD
        [ "$1" = fail ] && curl() { return 7; }
        set +e
        PATH="$STUBS:$PATH" CALL_LOG="$ST/calls.log" svc_status 2>&1
    )
}
: >"$ST/calls.log"
out="$(run_status ok)"
assert_contains "status: hashrate line (#143)" "$out" "Hashrate:  1234.5 H/s"
assert_contains "status: pool line (#143)" "$out" "Pool:      poolbox.lan:3333"
assert_contains "status: uptime rendered as d/h/m (#143)" "$out" "Uptime:    1d 2h 3m"
assert_contains "status: shares line (#143)" "$out" "42 accepted / 1 rejected"
assert_contains "status: hugepages line when the field exists (#143)" "$out" "HugePages: 1248/1248"
assert_contains "status: platform block still follows (#143)" "$(cat "$ST/calls.log")" "[systemctl] status xmrig"
: >"$ST/calls.log"
out="$(run_status fail)"
assert_contains "status: unreachable API -> one explanatory line (#143)" "$out" "worker API not reachable at 127.0.0.1:8080"
assert_contains "status: platform block untouched when API is down (#143)" "$(cat "$ST/calls.log")" "[systemctl] status xmrig"

# #364: the same unreachable API through the REAL dispatch, where errexit and the ERR trap are live.
# `run_status fail` above cannot catch this — shadowing curl inside a `set +e` subshell disarms the
# very path that produced the bug, which is how it shipped. Here curl is a real failing BINARY on
# PATH, so its exit rides out of _read_api_summary exactly as it does against a stopped miner. It
# used to print "[ERROR] rigforge aborted while running 'status'" TWICE: set -E inherits the trap
# into the $( ) _status_api_summary reads through, and bash does NOT carry svc_status's suppressed
# errexit (`( ... ) || true`) into that child, so the trap fired once per frame the failure unwound.
echo "== black-box: unreachable worker API is quiet, not an abort (#364) =="
STE="$(mktemp -d "$SANDBOX/statuserr.XXXXXX")"
mkdir -p "$STE/bin" "$STE/home/worker"
cat >"$STE/config.json" <<EOF
{ "HOME_DIR": "$STE/home", "pools": [{"url": "h:3333"}] }
EOF
printf '#!/usr/bin/env bash\nexit 7\n' >"$STE/bin/curl"
chmod +x "$STE/bin/curl"
out="$(cd "$STE" && PATH="$STE/bin:$STUBS:$PATH" STUB_UNAME_S=Linux CALL_LOG="$STE/calls.log" RIGFORGE_HOME="$PWD" bash "$SCRIPT" status </dev/null 2>&1)"
rc=$?
assert_rc "status: unreachable API exits 0 through real dispatch (#364)" "$rc" "0"
assert_absent "status: no ERR-trap abort on a real curl failure (#364)" "$out" "aborted while"
assert_eq "status: the unreachable line prints exactly once (#364)" \
    "$(printf '%s\n' "$out" | grep -c "worker API not reachable")" "1"
assert_contains "status: platform block still follows (#364)" "$(cat "$STE/calls.log")" "[systemctl] status xmrig"

# The same root cause on the tune/autotune side, which reads through _read_api_hashrate — and the
# shape that bites on a RIG, not just a dev laptop: an UNGUARDED read under errexit. Verified against
# both bashes with the API refusing connections (miner-0, Linux 5.2 / this box, macOS 3.2): the old
# reader killed the run outright and printed four abort lines, the current one returns empty and the
# sampling loop runs to the end. So an API that went away mid-sweep — the miner restarting under you
# — used to take the sweep with it.
#
# Driven as a SEPARATE bash process on purpose. Running it in a subshell here would inherit this
# suite's own errexit context, and bash 5.2 carries a suppressed context into a $( ) (3.2 does not),
# which silently disarms the very failure under test on one platform or the other — a green that
# means nothing. A child process starts from a clean top-level context on both.
echo "== black-box: an unreachable API never aborts a tune sampling read (#364) =="
cat >"$STE/drive.sh" <<DRV
source "$SCRIPT"
set -Eeuo pipefail
trap on_err ERR
CURRENT_STEP="running 'tune'"
unset API_CMD
sleep() { :; }            # drop the retry delay; curl stays a real failing binary
hr=\$(_read_api_hashrate) # unguarded on purpose: the reader itself must not fail
echo "SURVIVED hr=[\$hr]"
_wait_miner_live 3 >/dev/null || true # returns 1 once it gives up; that is not a failure
echo "LOOP-DONE"
DRV
wml_out="$(cd "$STE" && PATH="$STE/bin:$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$STE/drive.sh" 2>&1 || true)"
assert_contains "tune: an unreachable API never aborts the reader (#364)" "$wml_out" "SURVIVED hr=[]"
assert_contains "tune: the sampling loop runs to the end (#364)" "$wml_out" "LOOP-DONE"
assert_absent "tune: no ERR-trap noise while the API is down (#364)" "$wml_out" "aborted while"
: >"$ST/calls.log"
out="$(
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SERVICE_NAME=xmrig
        CONFIG_JSON="$ST/nonexistent.json"
        set +e
        PATH="$STUBS:$PATH" CALL_LOG="$ST/calls.log" svc_status 2>&1
        echo "rc=$?"
    )
)"
assert_contains "status: missing config degrades to the platform block (#143)" "$(cat "$ST/calls.log")" "[systemctl] status xmrig"
assert_contains "status: missing config still exits 0 (#143)" "$out" "rc=0"

# #341: XMRig's /2/summary reports hugepages as a [loaded, total] pages ARRAY; @tsv refuses nested
# arrays (jq exit 5), which killed the whole stats row — and with it every line above — on every
# healthy rig. The render must serialize the array, and keep the scalar/absent shapes working.
echo "== unit: status hugepages shapes (#341) =="
run_status_body() { # <summary-json>: svc_status with curl faked to return exactly this body
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SERVICE_NAME=xmrig
        CONFIG_JSON="$ST/config.json"
        unset API_CMD
        # Distinct name on purpose: _status_api_summary's own `local body` would shadow a `body`
        # here through bash's dynamic scoping, and the fake would print the empty local instead.
        STUB_BODY_341="$1"
        curl() { printf '%s' "$STUB_BODY_341"; }
        set +e
        PATH="$STUBS:$PATH" CALL_LOG="$ST/calls.log" svc_status 2>&1
    )
}
out="$(run_status_body '{"hashrate":{"total":[321.0,0,0]},"connection":{"pool":"h:3333","accepted":7,"rejected":0},"uptime":60,"hugepages":[0,1280]}')"
assert_contains "status: array hugepages render loaded/total (#341)" "$out" "HugePages: 0/1280"
assert_contains "status: stats row survives the array (#341)" "$out" "Hashrate:  321.0 H/s"
out="$(run_status_body '{"hashrate":{"total":[321.0,0,0]},"uptime":60,"hugepages":true}')"
assert_contains "status: scalar hugepages still renders (#341)" "$out" "HugePages: true"
out="$(run_status_body '{"hashrate":{"total":[321.0,0,0]},"uptime":60}')"
assert_absent "status: absent hugepages -> no line (#341)" "$out" "HugePages:"
assert_contains "status: stats row renders without hugepages (#341)" "$out" "Hashrate:  321.0 H/s"

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
# The same run doubles as the Ubuntu cpupower shape (#327): apt-cache says linux-tools-common
# exists, so it's picked and the Debian name never enters the list.
assert_contains "Ubuntu shape: cpupower via linux-tools-common (#327)" "$(cat "$LT/calls.log")" "linux-tools-common"
assert_absent "Ubuntu shape: linux-cpupower stays out (#327)" "$(cat "$LT/calls.log")" "linux-cpupower"

# #327: cpupower's apt package is distro-dependent — linux-tools-common (Ubuntu) vs linux-cpupower
# (Debian) — and apt's all-or-nothing transaction means one unknown name kills the ENTIRE dependency
# install (gcc/cmake included). The probe must pick the name the distro ships, and a double miss must
# warn without touching the toolchain install. Ubuntu shape is asserted on the #74 run above.
echo "== unit: apt cpupower package probe — Debian / neither exists (#327) =="
DEB="$(mktemp -d "$SANDBOX/deb327.XXXXXX")"
printf '#!/bin/sh\nexit 1\n' >"$DEB/dpkg" # every dep "missing" -> all go to the install list
cat >"$DEB/apt-cache" <<'EOF'
#!/bin/sh
# Debian trixie shape: linux-cpupower exists; linux-tools-common and linux-tools-<rel> do not.
case "$*" in *linux-cpupower*) exit 0 ;; *) exit 1 ;; esac
EOF
printf '#!/bin/sh\necho "[apt-get] $*" >>"$CALL_LOG"\n' >"$DEB/apt-get"
printf '#!/bin/sh\nwhile [ "${1#*=}" != "$1" ]; do export "$1"; shift; done\nexec "$@"\n' >"$DEB/sudo"
printf '#!/bin/sh\necho 6.0.0-rig\n' >"$DEB/uname"
chmod +x "$DEB"/*
: >"$DEB/calls.log"
(
    source "$SCRIPT"
    OS_TYPE=Linux REAL_USER=test
    PATH="$DEB" CALL_LOG="$DEB/calls.log" install_dependencies </dev/null
) >/dev/null 2>&1
assert_contains "Debian shape: cpupower via linux-cpupower (#327)" "$(cat "$DEB/calls.log")" "linux-cpupower"
assert_absent "Debian shape: linux-tools-common stays out (#327)" "$(cat "$DEB/calls.log")" "linux-tools-common"

# Neither name exists (apt-cache always says no): warn, keep going, and the toolchain still installs.
NC="$(mktemp -d "$SANDBOX/nc327.XXXXXX")"
printf '#!/bin/sh\nexit 1\n' >"$NC/dpkg"
printf '#!/bin/sh\nexit 1\n' >"$NC/apt-cache" # no cpupower package under ANY name
printf '#!/bin/sh\necho "[apt-get] $*" >>"$CALL_LOG"\n' >"$NC/apt-get"
printf '#!/bin/sh\nwhile [ "${1#*=}" != "$1" ]; do export "$1"; shift; done\nexec "$@"\n' >"$NC/sudo"
printf '#!/bin/sh\necho 6.0.0-rig\n' >"$NC/uname"
chmod +x "$NC"/*
: >"$NC/calls.log"
nc_out="$( (
    source "$SCRIPT"
    OS_TYPE=Linux REAL_USER=test
    PATH="$NC" CALL_LOG="$NC/calls.log" install_dependencies </dev/null
) 2>&1)"
rc=$?
assert_rc "no cpupower package never fails the install (#327)" "$rc" "0"
assert_contains "warns when no cpupower package exists (#327)" "$nc_out" "No cpupower package found"
assert_contains "toolchain still installs without a cpupower package (#327)" "$(cat "$NC/calls.log")" "build-essential"
assert_absent "no cpupower name reaches apt when neither exists (#327)" "$(cat "$NC/calls.log")" "linux-tools-common"
assert_absent "linux-cpupower also stays out when absent (#327)" "$(cat "$NC/calls.log")" "linux-cpupower"

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
assert_contains "service: ExecStartPre governor set rendered (root-prefixed since #140)" "$svc_rendered" "ExecStartPre=+-"
# #140 default path: no miner_user -> the unit runs root and carries NO msr-apply pre-step.
assert_contains "service: runs as root by default (#140)" "$svc_rendered" "User=root"
assert_eq "service: no msr-apply pre-step without miner_user (#140)" "$(printf '%s' "$svc_rendered" | grep -c '^ExecStartPre=.*msr-apply')" "0"
assert_absent "service: no unexpanded CPUPOWER_PATH" "$svc_rendered" '$CPUPOWER_PATH'
log_rebuild="$(svc_run "$(mktemp -d "$SANDBOX/svcrbu.XXXXXX")" false true)"
assert_contains "rebuilt binary, no reboot: service restarted" "$log_rebuild" "[systemctl] restart xmrig.service"
log_steady="$(svc_run "$(mktemp -d "$SANDBOX/svcst.XXXXXX")" false false)"
assert_contains "no rebuild, no reboot: service (re)started, not restarted" "$log_steady" "[systemctl] start xmrig.service"
assert_absent "no rebuild: does not needlessly restart a running miner" "$log_steady" "restart xmrig.service"

# #140: miner_user renders the unit unprivileged, creates the system user, and disables xmrig's
# own MSR writes in the generated config.
echo "== unit: install_service with miner_user (#140) =="
MU="$(mktemp -d "$SANDBOX/mu.XXXXXX")"
mkdir -p "$MU/etc/systemd" "$MU/xmrig/build"
(
    cd "$MU" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$ROOT"
    WORKER_ROOT="$MU"
    SYSTEMD_DIR="$MU/etc/systemd"
    MINER_USER=rf-test-miner
    REBOOT_REQUIRED=false
    XMRIG_REBUILD=false
    set +e
    PATH="$STUBS:$PATH" CALL_LOG="$MU/calls.log" install_service >/dev/null 2>&1
)
mu_unit="$(cat "$MU/etc/systemd/xmrig.service")"
assert_contains "miner_user: unit runs unprivileged (#140)" "$mu_unit" "User=rf-test-miner"
assert_contains "miner_user: root-side msr-apply pre-step present (#140)" "$mu_unit" "ExecStartPre=+$ROOT/rigforge.sh msr-apply"
assert_contains "miner_user: LimitNICE for cpu.priority (#140)" "$mu_unit" "LimitNICE=-20"
assert_contains "miner_user: absent system user is created (#140)" "$(cat "$MU/calls.log")" "[useradd] --system --no-create-home --shell /usr/sbin/nologin rf-test-miner"

echo "== unit: msr-apply preset detection + masked RMW (#140) =="
MSRT="$(mktemp -d "$SANDBOX/msrt.XXXXXX")"
mkdir -p "$MSRT/bin" "$MSRT/cpu/cpu0" "$MSRT/cpu/cpu1"
cat >"$MSRT/bin/lscpu" <<'EOF'
#!/usr/bin/env bash
echo "Vendor ID:             ${T_VENDOR:-AuthenticAMD}"
echo "CPU family:            ${T_FAMILY:-25}"
echo "Model:                 ${T_MODEL:-97}"
EOF
printf '#!/usr/bin/env bash
echo "[wrmsr] $*" >> "$CALL_LOG"
exit 0
' >"$MSRT/bin/wrmsr"
printf '#!/usr/bin/env bash
echo 001c000200000065
' >"$MSRT/bin/rdmsr"
printf '#!/usr/bin/env bash
exit 0
' >"$MSRT/bin/modprobe"
printf '#!/usr/bin/env bash
echo 0
' >"$MSRT/bin/id"
chmod +x "$MSRT/bin"/*
det() { # <vendor> <family> <model>
    (
        source "$SCRIPT"
        set +e
        T_VENDOR="$1" T_FAMILY="$2" T_MODEL="$3" PATH="$MSRT/bin:$PATH" _msr_detect_preset
    )
}
assert_eq "detect: Zen4 (fam 25 model 97) (#140)" "$(det AuthenticAMD 25 97)" "ryzen_19h_zen4"
assert_eq "detect: Zen3 (fam 25 model 33) (#140)" "$(det AuthenticAMD 25 33)" "ryzen_19h"
assert_eq "detect: Zen2 (fam 23) (#140)" "$(det AuthenticAMD 23 49)" "ryzen_17h"
assert_eq "detect: Zen5 (fam 26) (#140)" "$(det AuthenticAMD 26 68)" "ryzen_1Ah_zen5"
assert_eq "detect: Intel (#140)" "$(det GenuineIntel 6 85)" "intel"
assert_eq "detect: unknown vendor -> empty (#140)" "$(det UnknownCorp 1 1)" ""
out="$(
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        CONFIG_JSON="$MSRT/config.json"
        parse_config() { WORKER_ROOT="$MSRT"; }
        CPU_SYSFS="$MSRT/cpu"
        RDMSR_BIN="$MSRT/bin/rdmsr"
        set +e
        T_VENDOR=AuthenticAMD T_FAMILY=25 T_MODEL=97 PATH="$MSRT/bin:$PATH" CALL_LOG="$MSRT/calls.log" msr_apply 2>&1
    )
)"
assert_contains "msr-apply: applies and logs the preset (#140)" "$out" "MSR preset 'ryzen_19h_zen4' applied"
assert_eq "msr-apply: preset recorded for doctor (#140)" "$(cat "$MSRT/.rigforge-msr-preset")" "ryzen_19h_zen4"
assert_contains "msr-apply: unmasked registers written whole via -a (#140)" "$(cat "$MSRT/calls.log")" "[wrmsr] -a 0xc0011020 0x0004400000000000"
# Masked RMW: mask ffffffffffffffdf means only bit 5 is PRESERVED from the old value
# (old=…65 -> bit5 set -> 0x20); everything else comes from the preset value (…40).
# Expected (old & ~mask) | (val & mask) = 0x0004000000000060 on every CPU.
assert_contains "msr-apply: masked register read-modify-written per CPU (#140)" "$(cat "$MSRT/calls.log")" "[wrmsr] -p0 0xc0011021 0x0004000000000060"
assert_contains "msr-apply: second CPU covered too (#140)" "$(cat "$MSRT/calls.log")" "[wrmsr] -p1 0xc0011021 0x0004000000000060"
out="$(
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        parse_config() { WORKER_ROOT="$MSRT"; }
        set +e
        T_VENDOR=UnknownCorp T_FAMILY=1 T_MODEL=1 PATH="$MSRT/bin:$PATH" msr_apply 2>&1
    )
)"
assert_rc "msr-apply: unknown family exits 0 (never wedges Restart=always) (#140)" "$?" "0"
assert_contains "msr-apply: unknown family says so (#140)" "$out" "no MSR preset for this CPU family"
# wrmsr (msr-tools) missing: warn + exit 0 — the miner still starts, just without the boost.
# PATH here must NOT inherit the host's: on a bench box with msr-tools installed the real
# /usr/sbin/wrmsr leaks through and msr_apply finds it (then dies on a real MSR write), so the
# "missing" branch under test never runs. Pin the tail to bin dirs that carry no wrmsr.
mkdir -p "$MSRT/nowr"
cp "$MSRT/bin/lscpu" "$MSRT/bin/modprobe" "$MSRT/bin/id" "$MSRT/nowr/"
out="$(
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        parse_config() { WORKER_ROOT="$MSRT"; }
        set +e
        T_VENDOR=AuthenticAMD T_FAMILY=25 T_MODEL=97 PATH="$MSRT/nowr:$STUBS:/usr/bin:/bin" msr_apply 2>&1
        echo "rc=$?"
    )
)"
assert_contains "msr-apply: missing wrmsr warns, never fails the unit (#140)" "$out" "wrmsr (msr-tools) not found"
assert_contains "msr-apply: missing wrmsr exits 0 (#140)" "$out" "rc=0"
mkdir -p "$MSRT/nonroot"
printf '#!/usr/bin/env bash\ncase "$*" in *-un*) echo tester ;; *) echo 1000 ;; esac\n' >"$MSRT/nonroot/id"
chmod +x "$MSRT/nonroot/id"
# Dispatch: the msr-apply verb reaches msr_apply through the real arg dispatcher. Non-root (or
# non-Linux) is the guaranteed-safe path everywhere the suite runs; both gates name the verb.
out="$(cd "$SANDBOX" && PATH="$MSRT/nonroot:$STUBS:$PATH" bash "$SCRIPT" msr-apply </dev/null 2>&1)"
rc=$?
assert_rc "msr-apply verb: gated exit 1 outside root+Linux (#140)" "$rc" "1"
assert_contains "msr-apply verb: dispatch reaches the gate (#140)" "$out" "msr-apply"

echo "== unit: _reown_worker hands config+log back to the miner user (#140) =="
ROW="$(mktemp -d "$SANDBOX/reown.XXXXXX")"
mkdir -p "$ROW/bin" "$ROW/home/worker/xmrig/build"
: >"$ROW/home/worker/xmrig/build/config.json"
: >"$ROW/home/worker/xmrig.log"
printf '#!/usr/bin/env bash\necho "[chown] $*" >>"$CALL_LOG"\n' >"$ROW/bin/chown"
printf '#!/usr/bin/env bash\necho 0\n' >"$ROW/bin/id"
chmod +x "$ROW/bin"/*
(
    source "$SCRIPT"
    OS_TYPE=Linux
    MINER_USER=rf-test-miner
    REAL_USER=rfop
    WORKER_ROOT="$ROW/home/worker"
    CONFIG_JSON="$ROW/nonexistent.json"
    sudo() { "$@"; }
    set +e
    PATH="$ROW/bin:$STUBS:$PATH" CALL_LOG="$ROW/calls.log" _reown_worker >/dev/null 2>&1
)
assert_contains "reown: blanket re-own to the operator first (#140)" "$(cat "$ROW/calls.log")" "[chown] -R rfop:rfop $ROW/home/worker"
assert_contains "reown: miner user keeps config.json + log writable (#140)" "$(cat "$ROW/calls.log")" "[chown] rf-test-miner:rf-test-miner $ROW/home/worker/xmrig/build/config.json $ROW/home/worker/xmrig.log"

# apply is the config-change path (#140): with an installed unit, apply re-renders it from config —
# so toggling miner_user actually lands (User= flips) without a re-setup. The stale unit here says
# User=root; config says rf-appuser.
echo "== unit: apply re-renders the installed unit to the configured miner_user (#140) =="
APR="$(mktemp -d "$SANDBOX/apprr.XXXXXX")"
mkdir -p "$APR/sysd" "$APR/home/worker/xmrig/build"
printf 'User=root\n' >"$APR/sysd/xmrig.service"
cat >"$APR/config.json" <<EOF
{ "HOME_DIR": "$APR/home", "miner_user": "rf-appuser", "pools": [{"url": "h:3333"}] }
EOF
(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$ROOT" # real systemd/xmrig.service.template
    SYSTEMD_DIR="$APR/sysd"
    SERVICE_NAME=xmrig
    CONFIG_JSON="$APR/config.json"
    _apply_runtime() { :; }
    install_autotune() { :; }
    install_api() { :; }
    install_api_firewall() { :; }
    _autotune_apply_notice() { :; }
    sudo() { "$@"; }
    set +e
    PATH="$STUBS:$PATH" CALL_LOG="$APR/calls.log" apply >/dev/null 2>&1
)
apr_unit="$(cat "$APR/sysd/xmrig.service")"
assert_contains "apply: unit re-rendered to the configured user (#140)" "$apr_unit" "User=rf-appuser"
assert_contains "apply: re-rendered unit carries the msr-apply pre-step (#140)" "$apr_unit" "rigforge.sh msr-apply"
# No leftover unexpanded $VAR placeholders (#275): catches a var dropped from the envsubst stub
# above without being dropped from rigforge.sh's real allowlist (rigforge.sh:1009), or vice versa.
assert_eq "apply: re-rendered unit has no unexpanded \$VAR placeholders (#275)" \
    "$(grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' <<<"$apr_unit" | sort -u | tr '\n' ' ')" ""
# Regression (caught live on miner-0, v1.4.0 gate): apply is the documented path for TOGGLING
# miner_user, so it must also CREATE the user — a unit saying User=<absent user> crash-loops with
# status=217/USER. The real `id` reports rf-appuser absent, so apply must call useradd.
assert_contains "apply: absent miner user is created, not just rendered (#140)" "$(cat "$APR/calls.log" 2>/dev/null)" "[useradd] --system --no-create-home --shell /usr/sbin/nologin rf-appuser"

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
echo "== black-box: no ANSI escapes off-terminal (#144) =="
out="$(bash "$SCRIPT" version 2>&1)"
assert_absent "no ANSI escapes when piped/captured (#144)" "$out" "$(printf '\033')"
# NO_COLOR wins regardless of tty; captured output is never a tty, so both asserts are stable.
out="$(NO_COLOR=1 bash "$SCRIPT" version 2>&1)"
assert_absent "NO_COLOR=1 output is colorless (#144)" "$out" "$(printf '\033')"

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
: >"$DOC/curl.log"
out="$(CURL_LOG="$DOC/curl.log" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: prints version" "$out" "RigForge "
assert_contains "doctor: HugePages OK" "$out" "HugePages reserved"
assert_contains "doctor: 1GB pages OK" "$out" "1GB HugePages reserved"
assert_contains "doctor: msr module OK" "$out" "msr kernel module loaded"
assert_contains "doctor: governor OK" "$out" "governor = performance"
assert_contains "doctor: log HUGE PAGES 100%" "$out" "HUGE PAGES 100%"
assert_contains "doctor: all passed" "$out" "all critical checks passed"
assert_contains "doctor: all-clear mentions upgrade --check (#148)" "$out" "upgrade --check"
assert_eq "doctor: zero releases-API calls (#148)" "$(grep -c 'api.github.com' "$DOC/curl.log")" "0"
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

# #149: doctor exits non-zero when critical issues are found (cron-friendly, matching Pithead's
# health verb) — and cleanly, via the dispatcher's `|| exit 1`, never through the ERR trap.
dout="$(cd "$DOC" && PATH="$STUBS:$PATH" STUB_UNAME_S=Linux \
    MEMINFO="$DOC/meminfo_zero" MSR_MODULE_DIR="$DOC/nope-missing" GOVERNOR_FILE="$DOC/gov_ps" \
    HUGEPAGES_1G_NR="$DOC/nr1g_zero" DMIDECODE=/nonexistent CPUFREQ_MAX=/nonexistent CPU_SYSFS=/nonexistent \
    RIGFORGE_HOME="$DOC" bash "$SCRIPT" doctor </dev/null 2>&1)" && drc=0 || drc=$?
assert_rc "doctor: unhealthy exits 1 (#149)" "$drc" "1"
assert_contains "doctor: unhealthy still prints the report (#149)" "$dout" "issue(s) found"
assert_absent "doctor: unhealthy exit is clean, no ERR trap (#149)" "$dout" "aborted while"

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

# #333: kernel lockdown denies /dev/cpu/*/msr writes, so the MSR mod (~5-15% RandomX) silently can't
# apply. doctor must DETECT it from securityfs rather than infer it after a downstream failure, and must
# not offer msr.allow_writes=on as the remedy — the kernel checks lockdown BEFORE that filter
# (arch/x86/kernel/msr.c). Fakes drive every level, so one run covers all of them on any machine.
echo "== unit: doctor kernel-lockdown detection (#333) =="
printf 'none [integrity] confidentiality\n' >"$DOC/lockdown_integrity"
printf 'none integrity [confidentiality]\n' >"$DOC/lockdown_conf"
printf '[none] integrity confidentiality\n' >"$DOC/lockdown_none"
: >"$DOC/lockdown_empty"

# --- the two pure helpers, exercised directly ---
ld_state() { (source "$SCRIPT" && LOCKDOWN_FILE="$1" _lockdown_state); }
assert_eq "lockdown: parses the bracketed level (integrity) (#333)" "$(ld_state "$DOC/lockdown_integrity")" "integrity"
assert_eq "lockdown: parses the bracketed level (confidentiality) (#333)" "$(ld_state "$DOC/lockdown_conf")" "confidentiality"
assert_eq "lockdown: parses the bracketed level (none) (#333)" "$(ld_state "$DOC/lockdown_none")" "none"
assert_eq "lockdown: unreadable file -> unknown, not 'none' (#333)" "$(ld_state "/nonexistent-lockdown")" ""
assert_eq "lockdown: empty file -> unknown (#333)" "$(ld_state "$DOC/lockdown_empty")" ""
ld_blocks() { (source "$SCRIPT" && _lockdown_blocks_msr "$1" && echo yes || echo no); }
assert_eq "lockdown: integrity blocks MSR writes (#333)" "$(ld_blocks integrity)" "yes"
assert_eq "lockdown: confidentiality blocks MSR writes (#333)" "$(ld_blocks confidentiality)" "yes"
assert_eq "lockdown: none permits MSR writes (#333)" "$(ld_blocks none)" "no"
assert_eq "lockdown: unknown is not treated as blocking (#333)" "$(ld_blocks "")" "no"

# --- doctor, one level per run ---
# Active lockdown: named, counted, with the ASUS-specific menu path and the allow_writes correction.
out="$(LOCKDOWN_FILE="$DOC/lockdown_integrity" DMI_DIR="$DOC/dmi" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: names the active lockdown level (#333)" "$out" "kernel lockdown is ACTIVE ('integrity')"
assert_contains "doctor: says lockdown denies MSR writes (#333)" "$out" "denies every /dev/cpu/*/msr write"
assert_contains "doctor: corrects the allow_writes remedy (#333)" "$out" "msr.allow_writes=on does NOT override it"
assert_contains "doctor: gives the board-specific Secure Boot path (#333)" "$out" "Boot ▸ Secure Boot ▸ OS Type ▸ Other OS"
assert_contains "doctor: active lockdown counts as an issue (#333)" "$out" "issue(s) found"
# Confidentiality blocks MSR writes too — it is strictly above integrity.
out="$(LOCKDOWN_FILE="$DOC/lockdown_conf" DMI_DIR="$DOC/dmi" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: confidentiality also flagged (#333)" "$out" "kernel lockdown is ACTIVE ('confidentiality')"
# lockdown=none: a clean pass, and no scare text.
out="$(LOCKDOWN_FILE="$DOC/lockdown_none" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: lockdown none passes (#333)" "$out" "kernel lockdown: none"
assert_absent "doctor: no lockdown warning when inactive (#333)" "$out" "lockdown is ACTIVE"
# Unreadable: advisory only. An unverifiable probe must never manufacture an issue (the #67/#78 rule).
out="$(LOCKDOWN_FILE="/nonexistent-lockdown" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: unknown lockdown is advisory (#333)" "$out" "kernel lockdown state unknown"
assert_absent "doctor: unknown lockdown raises no false alarm (#333)" "$out" "lockdown is ACTIVE"

# The msr-module hint no longer blames Secure Boot: Secure Boot does not stop the in-tree signed `msr`
# module from loading, so that advice sent people to the wrong screen.
out="$(LOCKDOWN_FILE="$DOC/lockdown_none" run_doctor "$DOC/meminfo_ok" "$DOC/nope-missing" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: missing msr module points at modprobe (#333)" "$out" "check 'sudo modprobe msr'"
assert_absent "doctor: missing msr module no longer blames Secure Boot (#333)" "$out" "msr module not loaded — the MSR mod won't apply; if it persists, disable Secure Boot"

# XMRig's own MSR failure is attributed to lockdown when lockdown is active, and only then.
printf 'net use pool ...\nmsr   register values for "ryzen_19h_zen4" preset have FAILED to set\n' >"$DOC/home/worker/xmrig.log"
out="$(LOCKDOWN_FILE="$DOC/lockdown_integrity" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: MSR failure attributed to lockdown (#333)" "$out" "kernel lockdown ('integrity') is denying the write"
out="$(LOCKDOWN_FILE="$DOC/lockdown_none" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: MSR failure without lockdown keeps the allow_writes hint (#333)" "$out" "check msr.allow_writes=on"
assert_absent "doctor: no lockdown blame when lockdown is off (#333)" "$out" "is denying the write"
printf 'net use pool ...\n* HUGE PAGES 100%%\n' >"$DOC/home/worker/xmrig.log" # restore the shared fixture

# Per-vendor Secure Boot menu paths (#333), mirroring the #80 memory_profile coverage.
bm_sb() { (source "$SCRIPT" && _bios_menu "$1" secure_boot perf); }
assert_contains "bios menu: ASUS Secure Boot path (#333)" "$(bm_sb ASUSTeK)" "OS Type ▸ Other OS"
assert_contains "bios menu: ASRock Secure Boot path (#333)" "$(bm_sb ASRock)" "Security ▸ Secure Boot"
assert_contains "bios menu: Gigabyte Secure Boot path (#333)" "$(bm_sb "Gigabyte Technology")" "Secure Boot Enable"
assert_contains "bios menu: MSI Secure Boot path (#333)" "$(bm_sb "Micro-Star International")" "Windows OS Configuration"
assert_contains "bios menu: unknown vendor falls back generically (#333)" "$(bm_sb "Some OEM")" "usually under Boot or Security"

# #338 (the last #1 acceptance criterion): missing AES-NI/AVX2 must be SURFACED — soft-AES mining is
# ~4x slower with no error anywhere. AES-NI missing = counted doctor issue + setup warn; AVX2 missing =
# advisory only; no x86 "flags" line (macOS, ARM's "Features", stubs) = unknown = silence, never an issue.
echo "== unit: CPU ISA preflight — AES-NI / AVX2 surfaced (#338) =="
printf 'processor : 0\nflags     : fpu vme aes avx avx2 vaes\n' >"$DOC/cpuinfo_full"
# vaes but NOT the standalone aes word: proves the -w match can't be satisfied by a neighbor flag.
printf 'processor : 0\nflags     : fpu vme avx avx2 vaes\n' >"$DOC/cpuinfo_noaes"
printf 'processor : 0\nflags     : fpu vme aes avx\n' >"$DOC/cpuinfo_noavx2"
printf 'processor : 0\nflags     : fpu vme avx\n' >"$DOC/cpuinfo_neither"
printf 'processor : 0\nFeatures  : fp asimd aes\n' >"$DOC/cpuinfo_arm" # ARM shape: no "flags" line

# --- the pure helper, exercised directly ---
isa_miss() { (source "$SCRIPT" && CPUINFO="$1" _cpu_missing_isa); }
assert_eq "isa: full flags -> nothing missing (#338)" "$(isa_miss "$DOC/cpuinfo_full")" ""
assert_eq "isa: vaes does not satisfy the aes word-match (#338)" "$(isa_miss "$DOC/cpuinfo_noaes")" "aes"
assert_eq "isa: missing avx2 reported alone (#338)" "$(isa_miss "$DOC/cpuinfo_noavx2")" "avx2"
assert_eq "isa: both missing, space-separated (#338)" "$(isa_miss "$DOC/cpuinfo_neither")" "aes avx2"
assert_eq "isa: ARM Features line -> unknown, not unsupported (#338)" "$(isa_miss "$DOC/cpuinfo_arm")" ""
assert_eq "isa: absent cpuinfo -> unknown (#338)" "$(isa_miss "/nonexistent-cpuinfo")" ""

# --- doctor: counted for aes, advisory for avx2, silent on unknown ---
out="$(CPUINFO="$DOC/cpuinfo_noaes" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: missing AES-NI named (#338)" "$out" "CPU has no AES-NI"
assert_contains "doctor: missing AES-NI is a counted issue (#338)" "$out" "issue(s) found"
out="$(CPUINFO="$DOC/cpuinfo_noavx2" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: missing AVX2 is advisory (#338)" "$out" "CPU has no AVX2"
assert_contains "doctor: missing AVX2 alone still passes (#338)" "$out" "all critical checks passed"
out="$(CPUINFO="$DOC/cpuinfo_full" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: AES-NI present reported ok (#338)" "$out" "CPU supports AES-NI"
out="$(CPUINFO="$DOC/cpuinfo_arm" run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_absent "doctor: unknown ISA raises no alarm (#338)" "$out" "AES-NI"

# --- setup path: generate_xmrig_config warns at configure time, and never aborts ---
export STUB_CPU_MODEL="Old Xeon E5405" STUB_NPROC=4 STUB_HOSTNAME=rigbox
ISA338="$(mktemp -d "$SANDBOX/isa338.XXXXXX")"
gen338_out="$(
    cd "$ISA338" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$ISA338"
    POOL_ADDRESS=myrig.local
    POOLS_JSON='[{"url":"myrig.local:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
    ACCESS_TOKEN=tok123
    DONATION=1
    LOGROTATE_DIR="$ISA338"
    CPUINFO="$DOC/cpuinfo_neither"
    set +e
    PATH="$STUBS:$PATH" generate_xmrig_config 2>&1
)"
assert_rc "config-gen still succeeds on unsupported hardware (#338)" "$?" "0"
assert_contains "config-gen warns about missing AES-NI (#338)" "$gen338_out" "no AES-NI"
assert_contains "config-gen warns about missing AVX2 (#338)" "$gen338_out" "no AVX2"
assert_contains "config-gen: the config was still generated (#338)" "$(J "$ISA338/config.json" '.pools[0].url')" "myrig.local:3333"
# A fully-capable CPU stays quiet — the warn must not become noise on normal rigs.
QUIET338="$(mktemp -d "$SANDBOX/isaq338.XXXXXX")"
genq_out="$(
    cd "$QUIET338" || exit 1
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$QUIET338"
    POOL_ADDRESS=myrig.local
    POOLS_JSON='[{"url":"myrig.local:3333","user":"","pass":"x","keepalive":true,"tls":false,"enabled":true}]'
    ACCESS_TOKEN=tok123
    DONATION=1
    LOGROTATE_DIR="$QUIET338"
    CPUINFO="$DOC/cpuinfo_full"
    set +e
    PATH="$STUBS:$PATH" generate_xmrig_config 2>&1
)"
assert_absent "config-gen: no ISA warning on a capable CPU (#338)" "$genq_out" "AES-NI"

# #278: doctor reports control receiver health when `control` is enabled. Active + responding (200 or
# 503, per util/control-server.py) is ok; enabled-but-down (service inactive, or active but not
# answering) warns with a hint and counts as an issue; disabled prints no control-receiver lines at all.
echo "== unit: doctor control receiver health (#278) =="
cat >"$DOC/config_ctl_on.json" <<EOF
{ "HOME_DIR": "$DOC/home", "pools": [{"url": "h:3333"}], "control": "enabled", "control_port": 8082, "ACCESS_TOKEN": "ctl-test-token", "api_allow_from": "10.0.0.5" }
EOF
run_ctl_doctor() { # <config_file> <rigforge-control active:y|n> <curl /status http code>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$1"
        MEMINFO="$DOC/meminfo_ok"
        MSR_MODULE_DIR="$DOC/msrmod"
        GOVERNOR_FILE="$DOC/gov_perf"
        HUGEPAGES_1G_NR="$DOC/nr1g"
        DMIDECODE="/nonexistent"
        CPUFREQ_MAX="/nonexistent"
        CPU_SYSFS="/nonexistent"
        _ACT="$2"
        _CODE="$3"
        systemctl() { case "$*" in *"is-active --quiet rigforge-control"*) [ "$_ACT" = y ] ;; *) return 0 ;; esac }
        curl() { printf '%s' "$_CODE"; }
        set +e
        PATH="$STUBS:$PATH" doctor 2>&1
    )
}
out="$(run_ctl_doctor "$DOC/config_ctl_on.json" y 200)"
assert_contains "control: enabled+active+200 -> ok (#278)" "$out" "control receiver is active and responding"
assert_absent "control: token never appears in doctor output (#278)" "$out" "ctl-test-token"
out="$(run_ctl_doctor "$DOC/config_ctl_on.json" n 000)"
assert_contains "control: enabled+inactive -> warn (#278)" "$out" "control: enabled but rigforge-control is inactive"
assert_contains "control: enabled+inactive counts as an issue (#278)" "$out" "issue(s) found"
out="$(run_ctl_doctor "$DOC/config_ctl_on.json" y 401)"
assert_contains "control: enabled+active but not responding -> warn (#278)" "$out" "isn't responding"
out="$(run_ctl_doctor "$DOC/config.json" y 200)"
assert_absent "control: disabled prints no control-receiver ok line (#278)" "$out" "control receiver"
assert_absent "control: disabled prints no control-receiver warn line either (#278)" "$out" "rigforge-control is inactive"

# #343: doctor's pool-connection check — the miner's own /2/summary is the signal while the service
# runs (connected ok / disconnected counted issue / silent API advisory); a stopped service falls
# back to one TCP dial of pools[0]. Fixture bodies mirror XMRig's connection object shapes.
echo "== unit: doctor pool connection (#343) =="
printf '{"connection":{"pool":"poolbox.lan:3333","uptime":345,"failures":0,"accepted":7}}\n' >"$DOC/api_connected.json"
printf '{"connection":{"pool":"nosuch.host:3333","uptime":0,"failures":9,"accepted":0}}\n' >"$DOC/api_disconnected.json"
run_pool_doctor() { # <xmrig active y|n> <API_CMD> [extra eval, e.g. a _tcp_probe override]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$DOC/config.json"
        MEMINFO="$DOC/meminfo_ok"
        MSR_MODULE_DIR="$DOC/msrmod"
        GOVERNOR_FILE="$DOC/gov_perf"
        HUGEPAGES_1G_NR="$DOC/nr1g"
        DMIDECODE="/nonexistent"
        CPUFREQ_MAX="/nonexistent"
        CPU_SYSFS="/nonexistent"
        _ACT="$1"
        API_CMD="$2"
        systemctl() { case "$*" in *"is-active --quiet xmrig"*) [ "$_ACT" = y ] ;; *) return 0 ;; esac }
        eval "${3:-}"
        set +e
        PATH="$STUBS:$PATH" doctor 2>&1
    )
}
out="$(run_pool_doctor y "cat \"$DOC/api_connected.json\"")"
assert_contains "pool: connected miner -> ok line with pool + shares (#343)" "$out" "pool connection live: poolbox.lan:3333"
assert_contains "pool: connected stays all-clear (#343)" "$out" "all critical checks passed"
out="$(run_pool_doctor y "cat \"$DOC/api_disconnected.json\"")"
assert_contains "pool: running but disconnected -> warn (#343)" "$out" "NO live pool connection"
assert_contains "pool: warn names the miner's pool + failure count (#343)" "$out" "nosuch.host:3333, 9 failed attempt(s)"
assert_contains "pool: disconnected counts as an issue (#343)" "$out" "issue(s) found"
out="$(run_pool_doctor y 'printf %s ""')"
assert_contains "pool: silent API -> advisory only (#343)" "$out" "can't verify the pool connection"
assert_contains "pool: silent API is not a counted issue (#343)" "$out" "all critical checks passed"
# A disconnected miner that hasn't picked a pool yet reports connection.pool "" — the warn falls
# back to naming config's pools[0], so the operator still sees which pool to go fix.
printf '{"connection":{"pool":"","uptime":0,"failures":2,"accepted":0}}\n' >"$DOC/api_nopool.json"
out="$(run_pool_doctor y "cat \"$DOC/api_nopool.json\"")"
assert_contains "pool: empty pool name falls back to config's pools[0] (#343)" "$out" "pool: h:3333, 2 failed attempt(s)"
# Service stopped: the miner can't testify, so pools[0] gets one TCP dial (overridden here — the
# real dial is a /dev/tcp connect, exercised by the closed-port probe below and by e2e-real).
out="$(run_pool_doctor n "" '_tcp_probe() { return 0; }')"
assert_contains "pool: stopped + reachable pool -> advisory with host:port (#343)" "$out" "pool h:3333 accepts TCP"
out="$(run_pool_doctor n "" '_tcp_probe() { return 1; }')"
assert_contains "pool: stopped + unreachable pool -> warn (#343)" "$out" "pool h:3333 is unreachable"
assert_contains "pool: unreachable pool counts as an issue (#343)" "$out" "issue(s) found"
# The real probe against a loopback port nothing listens on: refused, so rc != 0, instantly.
prb="$( (source "$SCRIPT" && set +e && _tcp_probe 127.0.0.1 1 && echo open || echo closed))"
assert_eq "tcp probe: closed loopback port reads closed (#343)" "$prb" "closed"

# #201: NPS regression detection — an EPYC reporting ONE NUMA node is NPS1 (a BIOS reset ate the
# NPS4 setting); desktop parts correctly report one node and must never be flagged; a missing
# node sysfs is unverifiable, not suspect. Advisory only, shared by doctor and `bios`.
echo "== unit: EPYC NPS detection (#201) =="
NPS="$(mktemp -d "$SANDBOX/nps.XXXXXX")"
mkdir -p "$NPS/one/node0" "$NPS/four/node0" "$NPS/four/node1" "$NPS/four/node2" "$NPS/four/node3"
nps_sus() { (source "$SCRIPT" && set +e && NODE_SYSFS="$2" _nps_suspect "$1"); }
assert_eq "EPYC + 1 node -> suspect (#201)" "$(nps_sus "AMD EPYC 7642 48-Core Processor" "$NPS/one")" "1"
assert_eq "EPYC + 4 nodes -> fine (#201)" "$(nps_sus "AMD EPYC 7642 48-Core Processor" "$NPS/four")" ""
assert_eq "desktop + 1 node -> never flagged (#201)" "$(nps_sus "AMD Ryzen 7 7800X3D 8-Core Processor" "$NPS/one")" ""
assert_eq "EPYC + missing sysfs -> unverifiable, not suspect (#201)" "$(nps_sus "AMD EPYC 7642 48-Core Processor" "$NPS/nowhere")" ""
out="$(STUB_CPU_MODEL="AMD EPYC 7642 48-Core Processor" NODE_SYSFS="$NPS/one" DMI_DIR="$DOC/dmi" SMT_CONTROL="$DOC/smt_on" DMIDECODE="$DOC/dmidecode_xmpon" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_contains "doctor: NPS1 EPYC gets the advisory (#201)" "$out" "single NUMA node (NPS1)"
assert_contains "doctor: advisory names the AMD CBS menu (#201)" "$out" "NUMA nodes per socket"
out="$(STUB_CPU_MODEL="AMD EPYC 7642 48-Core Processor" NODE_SYSFS="$NPS/four" DMI_DIR="$DOC/dmi" SMT_CONTROL="$DOC/smt_on" DMIDECODE="$DOC/dmidecode_xmpon" \
    run_doctor "$DOC/meminfo_ok" "$DOC/msrmod" "$DOC/gov_perf" "$DOC/nr1g")"
assert_absent "doctor: NPS4 EPYC stays quiet (#201)" "$out" "NPS1"
bd_nps() { (
    source "$SCRIPT" && OS_TYPE=Linux && set +e && NODE_SYSFS="$1" STUB_CPU_MODEL="$2" PATH="$STUBS:$PATH" _bios_detect >/dev/null 2>&1
    echo "$B_NPS_STATUS"
); }
assert_eq "bios detect: NPS1 EPYC pending (#201)" "$(bd_nps "$NPS/one" "AMD EPYC 7642 48-Core Processor")" "pending"
assert_eq "bios detect: NPS4 EPYC ok (#201)" "$(bd_nps "$NPS/four" "AMD EPYC 7642 48-Core Processor")" "ok"
assert_eq "bios detect: desktop unknown — never listed (#201)" "$(bd_nps "$NPS/one" "Generic CPU")" "unknown"
assert_contains "bios menu: NPS item names the CBS path (#201)" "$( (source "$SCRIPT" && _bios_menu generic numa_nps perf))" "NPS4"
assert_contains "bios menu: generic power_boost speaks EPYC too (#201)" "$( (source "$SCRIPT" && _bios_menu generic power_boost perf))" "cTDP"

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

# #333: Secure Boot joins the guided BIOS walk-through. It leads the checklist (cheapest change, and it
# gates the MSR mod outright), persists like every other item, and — unlike the others — is verifiable
# purely from securityfs, so the reboot loop can confirm it took.
# Guide pass with lockdown active: secure_boot is pending and comes FIRST.
out="$(run_bios 'LOCKDOWN_FILE=$DOC/lockdown_integrity SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios: flags active lockdown (#333)" "$out" "lockdown=integrity (MSR writes denied)"
assert_contains "bios: names the Secure Boot item (#333)" "$out" "Secure Boot (kernel lockdown)"
assert_eq "bios: Secure Boot leads the checklist (#333)" "$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^  1\. ' | head -1)" "  1. Secure Boot (kernel lockdown)"
assert_eq "bios: Secure Boot persisted as pending (#333)" "$(jq -r '[.items[].id] | index("secure_boot") != null' "$BIO/rigforge-bios.json")" "true"
assert_contains "bios: persisted item carries the vendor menu path (#333)" "$(jq -r '.items[] | select(.id=="secure_boot") | .menu' "$BIO/rigforge-bios.json")" "OS Type ▸ Other OS"
# Verify pass after the operator disabled Secure Boot: lockdown reads none -> the item took.
out="$(run_bios 'LOCKDOWN_FILE=$DOC/lockdown_none SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: Secure Boot change took (#333)" "$out" "Secure Boot (kernel lockdown) — now lockdown=none"
rm -f "$BIO/rigforge-bios.json"
# Unverifiable securityfs must keep the item rather than claim success (the #80 honesty rule).
printf '%s\n' '{"target":"perf","saved":"2026-07-10","items":[{"id":"secure_boot","status":"pending","before":"lockdown=integrity","menu":"Boot"}]}' >"$BIO/rigforge-bios.json"
out="$(run_bios 'LOCKDOWN_FILE=/nonexistent-lockdown SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: unreadable securityfs is honest, not a pass (#333)" "$out" "isn't readable; re-run as root"
assert_eq "bios verify: unverifiable Secure Boot item stays pending (#333)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["secure_boot"]'
rm -f "$BIO/rigforge-bios.json"
# Dispatch: the case entry shifts and forwards flags (any OS: the rc-1 proves the verb was reached).
out="$( (RIGFORGE_HOME="$BIO" bash "$SCRIPT" bios --wat </dev/null) 2>&1 || true)"
assert_contains "bios: dispatch forwards to the verb (#80)" "$out" "[ERROR]"
if [ "$(uname -s)" != Linux ]; then
    out="$( (RIGFORGE_HOME="$BIO" bash "$SCRIPT" bios </dev/null) 2>&1 || true)"
    assert_contains "bios: refuses off-Linux (#80)" "$out" "only supported on Linux"
fi

# #268: numa_nps was detected and persisted (#201) but never walked or verified — a pending-only NPS
# item silently fell through both the guide loop and the verify case. Reuses the $NPS/one and $NPS/four
# node-count fixtures from the #201 detection tests above.
# 11. Guide: NPS is the only pending item -> it renders in the walk, and the early-out must not fire.
out="$(run_bios 'export STUB_CPU_MODEL="AMD EPYC 7642 48-Core Processor"; NODE_SYSFS=$NPS/one SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios: NPS-only pending renders the NPS step (#268)" "$out" "NUMA per socket (NPS)"
assert_absent "bios: NPS-only pending is not 'already set' (#268)" "$out" "already set"
assert_eq "bios: NPS-only pending saves exactly one item (#268)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["numa_nps"]'
rm -f "$BIO/rigforge-bios.json"
# 12. Verify (still wrong): detection still reports NPS1 -> stays pending, not counted applied, state survives.
printf '%s\n' '{"target":"perf","saved":"2026-07-10","items":[{"id":"numa_nps","status":"pending","before":"1 NUMA node (NPS1)","menu":"AMD CBS"}]}' >"$BIO/rigforge-bios.json"
out="$(run_bios 'export STUB_CPU_MODEL="AMD EPYC 7642 48-Core Processor"; NODE_SYSFS=$NPS/one SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: NPS still wrong stays pending (#268)" "$out" "still 1 NUMA node (NPS1)"
assert_absent "bios verify: NPS still pending -> not 'All BIOS items applied' (#268)" "$out" "All BIOS items applied"
assert_eq "bios verify: NPS still pending -> state survives (#268)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["numa_nps"]'
rm -f "$BIO/rigforge-bios.json"
# 13. Verify (fixed): detection now reports NPS4 -> counted applied; nothing else pending -> state removed.
printf '%s\n' '{"target":"perf","saved":"2026-07-10","items":[{"id":"numa_nps","status":"pending","before":"1 NUMA node (NPS1)","menu":"AMD CBS"}]}' >"$BIO/rigforge-bios.json"
out="$(run_bios 'export STUB_CPU_MODEL="AMD EPYC 7642 48-Core Processor"; NODE_SYSFS=$NPS/four SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: NPS fixed counts as applied (#268)" "$out" "NUMA per socket (NPS) — now multiple NUMA nodes"
assert_contains "bios verify: NPS fixed -> all applied (#268)" "$out" "All BIOS items applied"
assert_eq "bios verify: NPS fixed removes the state file (#268)" "$([ -f "$BIO/rigforge-bios.json" ] && echo y || echo n)" "n"

# #296: an item whose fresh probe comes back 'unknown' at verify time (unverifiable, not merely still
# wrong) vanished from the resumable state — _bios_state_write only persists 'pending' items and there
# was no unknown->pending resurrection for numa_nps/smt (mem/boost already had one). The fallback hint
# was also dmidecode-only, wrong for NPS (lscpu/sysfs) and SMT (sysfs).
# 14. NPS unreadable at verify (lscpu doesn't report an EPYC model): item survives as pending, lscpu hint.
printf '%s\n' '{"target":"perf","saved":"2026-07-10","items":[{"id":"numa_nps","status":"pending","before":"1 NUMA node (NPS1)","menu":"AMD CBS"}]}' >"$BIO/rigforge-bios.json"
out="$(run_bios 'SMT_CONTROL=$DOC/smt_on DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: NPS unreadable keeps the item with the lscpu hint (#296)" "$out" "can't verify (lscpu didn't report an EPYC"
assert_eq "bios verify: unverifiable NPS item stays pending (#296)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["numa_nps"]'
rm -f "$BIO/rigforge-bios.json"
# 15. SMT unreadable at verify (no SMT control in sysfs): item survives as pending, SMT-specific hint.
printf '%s\n' '{"target":"perf","saved":"2026-07-10","items":[{"id":"smt","status":"pending","before":"off","menu":"SMT"}]}' >"$BIO/rigforge-bios.json"
out="$(run_bios 'SMT_CONTROL=$NOHW/smt DMIDECODE=$DOC/dmidecode_xmpon CPU_SYSFS=$DOC/cpu_ok CPUFREQ_MAX=$DOC/cpufreq_max')"
assert_contains "bios verify: SMT unreadable keeps the item with the SMT-specific hint (#296)" "$out" "can't verify (no SMT control exposed"
assert_eq "bios verify: unverifiable SMT item stays pending (#296)" "$(jq -c '[.items[].id]' "$BIO/rigforge-bios.json")" '["smt"]'
rm -f "$BIO/rigforge-bios.json"

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

# #367: the MSR guard's inputs — config resolution, then the log path — must be distinguishable when
# either one comes up empty, so a skipped block never reads the same as a failed check (the flake that
# broke both #66 e2e assertions on a healthy rig).
echo "== unit: doctor MSR unverifiable — guard-input failures named (#367) =="
UNV="$DOC/unv"
mkdir -p "$UNV/home" # HOME_DIR resolves; worker/xmrig.log is deliberately never created
cat >"$UNV/config.json" <<EOF
{ "HOME_DIR": "$UNV/home", "pools": [{"url": "h:3333"}] }
EOF
run_doctor_cfg() { # <config.json path, possibly nonexistent>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$1"
        MEMINFO="$DOC/meminfo_ok"
        MSR_MODULE_DIR="$DOC/msrmod"
        GOVERNOR_FILE="$DOC/gov_perf"
        HUGEPAGES_1G_NR="$DOC/nr1g"
        set +e
        PATH="$DOC/asroot:$STUBS:$PATH" doctor 2>&1
    )
}
# (a) unresolved config: no config.json at all -> the worker root never resolves.
out="$(run_doctor_cfg "$DOC/nonexistent-config-367.json")"
assert_contains "doctor: MSR unverifiable names an unresolved config (#367)" "$out" \
    "MSR unverifiable — no config.json, so the worker root couldn't be resolved"
assert_absent "doctor: unresolved-config is advisory, not a counted issue (#367)" "$out" "issue(s) found"
# (b) resolved root, log absent: config parses fine, but nothing is logged at the resolved path yet
# (fresh install, or a copytruncate rotation window on an otherwise healthy rig).
out="$(run_doctor_cfg "$UNV/config.json")"
assert_contains "doctor: MSR unverifiable names the missing log path (#367)" "$out" \
    "MSR unverifiable — no xmrig.log at $UNV/home/worker/xmrig.log"
assert_absent "doctor: resolved-root-no-log is advisory, not a counted issue (#367)" "$out" "issue(s) found"
# (c) line present: once the log resolves and holds an msr line, neither unverifiable wording appears.
msr_log ryzen_19h_zen4
assert_absent "doctor: MSR unverifiable does not leak once the log has a line (#367)" \
    "$(run_doctor_msr "$DOC/rdmsr_ok")" "MSR unverifiable"

# #140: with miner_user set, doctor (a) compares config against the unit's actual User= and (b)
# verifies the root-side preset recorded by msr-apply via the same rdmsr read-back.
echo "== unit: doctor miner_user + root-side MSR preset (#140) =="
MUD="$DOC/mud"
mkdir -p "$MUD/home/worker" "$DOC/svc_mu" "$DOC/svc_root"
printf 'net      use pool ...\n* HUGE PAGES 100%%\n' >"$MUD/home/worker/xmrig.log"
printf 'ryzen_19h_zen4\n' >"$MUD/home/worker/.rigforge-msr-preset"
cat >"$MUD/config.json" <<EOF
{ "HOME_DIR": "$MUD/home", "miner_user": "rf-miner", "pools": [{"url": "h:3333"}] }
EOF
printf '#!/usr/bin/env bash\ncase "$*" in show*User*) echo rf-miner ;; *) exit 0 ;; esac\n' >"$DOC/svc_mu/systemctl"
printf '#!/usr/bin/env bash\ncase "$*" in show*User*) echo root ;; *) exit 0 ;; esac\n' >"$DOC/svc_root/systemctl"
chmod +x "$DOC/svc_mu/systemctl" "$DOC/svc_root/systemctl"
run_doctor_mu() { # <rdmsr_bin> <svc stub dir>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$MUD/config.json"
        MEMINFO="$DOC/meminfo_ok"
        MSR_MODULE_DIR="$DOC/msrmod"
        GOVERNOR_FILE="$DOC/gov_perf"
        HUGEPAGES_1G_NR="$DOC/nr1g"
        RDMSR_BIN="$1"
        set +e
        PATH="$2:$DOC/asroot:$STUBS:$PATH" doctor 2>&1
    )
}
# Unit runs as the configured user + all 4 registers hold the recorded preset's values.
out="$(run_doctor_mu "$DOC/rdmsr_ok" "$DOC/svc_mu")"
assert_contains "doctor: confirms the unit runs unprivileged (#140)" "$out" "miner runs unprivileged as 'rf-miner'"
assert_contains "doctor: root-side preset verified by read-back (#140)" "$out" "root-side MSR preset 'ryzen_19h_zen4' verified by register read-back (4/4)"
# Config/unit disagree (apply not re-run): WARN with the fix hint.
out="$(run_doctor_mu "$DOC/rdmsr_ok" "$DOC/svc_root")"
assert_contains "doctor: warns when the unit still runs as root (#140)" "$out" "but the unit runs as 'root'"
# Registers unreadable (no root / module unloaded): advisory, never a false mismatch.
out="$(run_doctor_mu "$DOC/rdmsr_empty" "$DOC/svc_mu")"
assert_contains "doctor: unreadable read-back -> advisory (#140)" "$out" "recorded — run doctor as root"
# Readable but WRONG values (dropped write): WARN with the bad count.
out="$(run_doctor_mu "$DOC/rdmsr_bad" "$DOC/svc_mu")"
assert_contains "doctor: dropped root-side write -> WARN (#140)" "$out" "only 0/4 registers match"

# Combined exposure advisory (#sec): tokenless AND unscoped is the designed LAN default but gets
# one loud info line; either control set flips it to the ok line. Never a counted issue.
echo "== unit: doctor exposure posture advisory (#sec) =="
EXP="$DOC/exposure"
mkdir -p "$EXP/home/worker"
exp_doctor() { # <config-body>
    printf '%s' "$1" >"$EXP/config.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$ROOT"
        CONFIG_JSON="$EXP/config.json"
        MEMINFO="$DOC/meminfo_ok"
        MSR_MODULE_DIR="$DOC/msrmod"
        GOVERNOR_FILE="$DOC/gov_perf"
        HUGEPAGES_1G_NR="$DOC/nr1g"
        set +e
        PATH="$DOC/asroot:$STUBS:$PATH" doctor 2>&1
    )
}
out="$(exp_doctor "{ \"HOME_DIR\": \"$EXP/home\", \"pools\": [{\"url\": \"h:3333\"}] }")"
assert_contains "doctor: open+unscoped gets the LAN advisory (#sec)" "$out" "fine on a trusted LAN"
assert_absent "doctor: the advisory is not a counted issue (#sec)" "$out" "issue(s) found"
out="$(exp_doctor "{ \"HOME_DIR\": \"$EXP/home\", \"ACCESS_TOKEN\": \"tok-sec\", \"pools\": [{\"url\": \"h:3333\"}] }")"
assert_contains "doctor: a token flips the posture line to ok (#sec)" "$out" "API exposure is limited (token)"
out="$(exp_doctor "{ \"HOME_DIR\": \"$EXP/home\", \"api_allow_from\": \"10.0.0.9\", \"pools\": [{\"url\": \"h:3333\"}] }")"
assert_contains "doctor: a firewall scope flips the posture line to ok (#sec)" "$out" "API exposure is limited (firewall scope)"

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
# #273: pre-seed every optional unit uninstall's removal branches (rigforge.sh:1750-1759 area) are
# responsible for — the full set the sandbox has never installed before, so those branches never ran in
# any test. Cross-checked 1:1 against systemd/*.template (minus xmrig.service.template, already seeded
# above) so this list can't silently drift from what setup/install_* actually ship. One list, reused
# below for the post-uninstall removal assertions, so the two can't drift from EACH OTHER either.
UN_OPT_UNITS="rigforge-api.service rigforge-api-refresh.service rigforge-api-refresh.timer
rigforge-control.service rigforge-control-apply.service rigforge-control-apply.path
rigforge-autotune.service rigforge-autotune.timer rigforge-watchdog.service rigforge-watchdog.timer"
for _u in $UN_OPT_UNITS; do
    : >"$UN/etc/systemd/system/$_u"
done
printf 'proc /proc proc defaults 0 0\nhugetlbfs /dev/hugepages hugetlbfs defaults 0 0\nhugetlbfs_1g %s/dev/hp1g hugetlbfs pagesize=1G 0 0\n' "$UN" >"$UN/etc/fstab"
printf 'root hard nofile 1024\n%s soft memlock unlimited\n%s hard memlock unlimited\n* soft memlock unlimited\n' "$ME" "$ME" >"$UN/etc/security/limits.conf"
printf 'loop\nmsr\n' >"$UN/etc/modules"
cat >"$UN/config.json" <<EOF
{ "HOME_DIR": "$UN/home", "miner_user": "$ME", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
un_run() {
    (cd "$UN" && PATH="$STUBS:$PATH" \
        SYSTEMD_DIR="$UN/etc/systemd/system" LOGROTATE_DIR="$UN/etc/logrotate.d" \
        FSTAB="$UN/etc/fstab" LIMITS_CONF="$UN/etc/security/limits.conf" \
        MODULES_LOAD_DIR="$UN/etc/modules-load.d" MODULES_FILE="$UN/etc/modules" \
        HUGEPAGES_1G_DIR="$UN/dev/hp1g" GRUB_DEFAULT="$UN/nonexistent-grub" \
        BIN_DIR="$UN/usr-local-bin" CALL_LOG="$UN/calls.log" \
        RIGFORGE_HOME="$PWD" bash "$SCRIPT" uninstall --yes </dev/null 2>&1)
}
# setup would have linked $BIN_DIR/rigforge -> $UN/rigforge.sh (SCRIPT_DIR=$UN); uninstall must remove
# OUR symlink. (The target need not exist — a dangling symlink is still removed.)
mkdir -p "$UN/usr-local-bin"
ln -s "$UN/rigforge.sh" "$UN/usr-local-bin/rigforge"
out="$(un_run)"
rc=$?
assert_rc "uninstall exits 0" "$rc" "0"
assert_contains "uninstall leaves the miner user in place with a userdel hint (#140)" "$out" "Left system user '$ME' in place"
assert_eq "service unit removed" "$([ -f "$UN/etc/systemd/system/xmrig.service" ] && echo y || echo n)" "n"
assert_eq "logrotate policy removed" "$([ -f "$UN/etc/logrotate.d/xmrig" ] && echo y || echo n)" "n"
assert_eq "msr.conf removed" "$([ -f "$UN/etc/modules-load.d/msr.conf" ] && echo y || echo n)" "n"
assert_eq "worker build/logs removed" "$([ -d "$UN/home/worker" ] && echo y || echo n)" "n"
# #273: every optional unit uninstall is responsible for must actually be gone, not just the always-on
# xmrig.service above.
for _u in $UN_OPT_UNITS; do
    assert_eq "$_u removed" "$([ -f "$UN/etc/systemd/system/$_u" ] && echo y || echo n)" "n"
done
# The worse regression the issue calls out: a broken control removal branch would leave the
# token-authed writable server running after "uninstall". Assert uninstall actually reached systemctl
# for the control units, not just that the unit files are gone.
assert_contains "uninstall disables+stops the control server unit (#273)" "$(cat "$UN/calls.log" 2>/dev/null)" "[systemctl] disable --now rigforge-control.service rigforge-control-apply.path"
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

# #353 (4): appliance disable must mirror appliance enable — verified empirically against a real
# systemd (255): a plain `disable` only ever removes the /etc-side wants-symlink, silently leaving a
# --runtime-enabled unit's /run symlink in place (`is-enabled` still reports "enabled-runtime", rc
# 0). Same sandbox shape as the uninstall test above (reuses UN_OPT_UNITS so the seeded unit list
# can't drift from it), just under RIGFORGE_APPLIANCE=1 with SYSTEMD_DIR standing in for /run —
# mirrors the #797 "every enable is --runtime" guard, on the disable side.
echo "== black-box: appliance uninstall disables with --runtime too (#353) =="
UNA="$(mktemp -d "$SANDBOX/uninst-appliance.XXXXXX")"
cp "$ROOT/VERSION" "$UNA/"
mkdir -p "$UNA/run-systemd" "$UNA/dev/hp1g" "$UNA/home/worker/xmrig/build" "$UNA/usr-local-bin"
: >"$UNA/run-systemd/xmrig.service"
for _u in $UN_OPT_UNITS; do
    : >"$UNA/run-systemd/$_u"
done
cat >"$UNA/config.json" <<EOF
{ "HOME_DIR": "$UNA/home", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
una_out="$(cd "$UNA" && RIGFORGE_APPLIANCE=1 PATH="$STUBS:$PATH" \
    SYSTEMD_DIR="$UNA/run-systemd" LOGROTATE_DIR="$UNA/nonexistent-logrotate" \
    FSTAB="$UNA/nonexistent-fstab" LIMITS_CONF="$UNA/nonexistent-limits" \
    MODULES_LOAD_DIR="$UNA/nonexistent-modules-load.d" MODULES_FILE="$UNA/nonexistent-modules" \
    HUGEPAGES_1G_DIR="$UNA/dev/hp1g" GRUB_DEFAULT="$UNA/nonexistent-grub" \
    BIN_DIR="$UNA/usr-local-bin" CALL_LOG="$UNA/calls.log" \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" uninstall --yes </dev/null 2>&1)"
assert_rc "appliance uninstall exits 0 (#353)" "$?" "0"
disable_calls="$(grep -F '[systemctl] disable' "$UNA/calls.log" 2>/dev/null)"
# If the sandbox seeding ever drifts from what uninstall() actually disables, an empty $disable_calls
# would make the grep -c below vacuously pass (0 non---runtime lines out of 0 total) — fail loudly
# instead, same principle as the CURRENT_STEP extraction guard above.
[ -n "$disable_calls" ] || bad "appliance uninstall drift guard (#353)" "no '[systemctl] disable' calls were logged — the guard below would vacuously pass"
assert_eq "appliance uninstall: every systemctl disable is --runtime (#353)" \
    "$(printf '%s\n' "$disable_calls" | grep -cv -- --runtime)" "0"

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

# #277: a bench candidate whose xmrig stub emits no H/s line must not spam the ERR trap. _bench_once's
# hashrate grep is allowed to find nothing under pipefail — the run records that candidate as 0 H/s and
# carries on; only the run's own failures should ever look like an abort. Discriminates on the swept
# prefetch value (same config-reading idiom as the stub in the #54 block above) so the seed reads 0 H/s
# but the swept prefetch=2 candidate hashes for real, letting the search finish with a winner (rc 0) — a
# run that legitimately never hashes is a separate, correctly-reported failure, not what this test is
# after. No TUNE_POWER_CMD override here: RAPL_DIR is the suite-wide no-hardware fake (line 65), so this
# run also exercises _xmrig_bench's RAPL sampling with no powercap sysfs present — the same ERR-trap class
# #277 fixed for the hashrate grep, fixed for RAPL sampling by #290.
# Linux-gated (#292): the cpufreq/bench-window plumbing this drives is Linux sysfs — on a real Mac the
# path never runs, and the simulated fixture proved timing-flaky on the slow bash-3.2 macOS CI runner.
# The Linux CI job + the kcov container still run it on every push.
if [ "$(uname -s)" != Linux ]; then
    echo "  SKIP: tune bench black-box timing tests run in the Linux CI jobs (#292)"
else
    echo "== black-box: zero-hashrate bench iteration stays quiet (#277) =="
    ZH="$(mktemp -d "$SANDBOX/tunezero.XXXXXX")"
    cp "$ROOT/VERSION" "$ZH/"
    mkdir -p "$ZH/util" "$ZH/home/worker/xmrig/build" "$ZH/cpuok/cpu0/cpufreq"
    cp "$ROOT/util/proposed-grub.sh" "$ZH/util/" && chmod +x "$ZH/util/proposed-grub.sh"
    printf '5000000\n' >"$ZH/cpu_max"
    printf '4800000\n' >"$ZH/cpuok/cpu0/cpufreq/scaling_cur_freq"
    printf '{ "randomx": { "scratchpad_prefetch_mode": 1, "1gb-pages": false }, "cpu": { "yield": false, "priority": 2 } }\n' >"$ZH/home/worker/xmrig/build/config.json"
    cat >"$ZH/home/worker/xmrig/build/xmrig" <<'EOF'
#!/usr/bin/env bash
cfg=""
for a in "$@"; do case "$a" in --config=*) cfg="${a#--config=}" ;; esac; done
m=$(jq -r '.randomx.scratchpad_prefetch_mode' "$cfg" 2>/dev/null)
if [ "$m" = "1" ]; then
    echo "miner speed 10s/60s/15m n/a n/a n/a"
else
    echo "miner speed 10s/60s/15m 1000.0 n/a n/a H/s max 1000.0 H/s"
fi
EOF
    chmod +x "$ZH/home/worker/xmrig/build/xmrig"
    printf '{ "HOME_DIR": "%s/home", "pools": [{"url":"h:3333"}] }\n' "$ZH" >"$ZH/config.json"
    ZTLOG="$ZH/home/worker/rigforge-tune.json"
    out="$(cd "$ZH" && PATH="$STUBS:$PATH" CPUFREQ_MAX="$ZH/cpu_max" CPU_SYSFS="$ZH/cpuok" \
        TUNE_ITERS=1 TUNE_PREFETCH_MODES="1 2" TUNE_YIELDS=false TUNE_THREADS=-1 \
        TUNE_MAX_ROUNDS=1 RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
    assert_rc "zero-hashrate iteration doesn't stop the run (#277)" "$?" "0"
    assert_eq "zero-hashrate iteration recorded 0 H/s in the log (#277)" \
        "$(J "$ZTLOG" '[.results[].samples[]] | any(. == 0)')" "true"
    assert_absent "zero-hashrate iteration logs no [ERROR] (#277)" "$out" "[ERROR]"
    assert_absent "zero-hashrate iteration logs no abort (#277)" "$out" "aborted"
fi

# #276 (item 2): a bench candidate that crashes (xmrig-style nonzero exit, no hashrate line) must still
# leave the miner service restarted — _tune_bench_cleanup is wired as an EXIT trap (rigforge.sh:2713)
# precisely so a mid-run failure can't strand a rig at 0 H/s after a failed nightly tune. Single-knob
# sweep (prefetch only, one seed) makes "candidate 2" deterministic: the fake xmrig exits nonzero without
# emitting a hashrate line on its 2nd invocation.
echo "== black-box: tune restarts the service after a mid-run bench crash (#276) =="
TC="$(mktemp -d "$SANDBOX/tunecrash.XXXXXX")"
cp "$ROOT/VERSION" "$TC/"
mkdir -p "$TC/util" "$TC/cpuok/cpu0/cpufreq"
cp "$ROOT/util/proposed-grub.sh" "$TC/util/" && chmod +x "$TC/util/proposed-grub.sh"
TCBD="$TC/home/worker/xmrig/build"
mkdir -p "$TCBD"
printf '5000000\n' >"$TC/cpu_max"
printf '4800000\n' >"$TC/cpuok/cpu0/cpufreq/scaling_cur_freq"
cat >"$TCBD/config.json" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1 }, "cpu": { "yield": false } }
EOF
cat >"$TCBD/xmrig" <<'EOF'
#!/usr/bin/env bash
[ -n "${BENCH_LOG:-}" ] && echo call >>"$BENCH_LOG"
n=$(wc -l <"${BENCH_LOG:-/dev/null}" 2>/dev/null | tr -d ' ')
if [ "$n" = "2" ]; then
    echo "fatal error" >&2
    exit 1
fi
echo "miner speed 10s/60s/15m 1000.0 n/a n/a H/s max 1000.0 H/s"
EOF
chmod +x "$TCBD/xmrig"
cat >"$TC/config.json" <<EOF
{ "HOME_DIR": "$TC/home", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
TCBENCHLOG="$TC/bench.log"
: >"$TCBENCHLOG"
TCCALLLOG="$TC/call.log"
: >"$TCCALLLOG"
tc_out="$(cd "$TC" && PATH="$STUBS:$PATH" CPUFREQ_MAX="$TC/cpu_max" CPU_SYSFS="$TC/cpuok" \
    TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES="1 2 3" TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
    BENCH_LOG="$TCBENCHLOG" CALL_LOG="$TCCALLLOG" RIGFORGE_HOME="$PWD" bash "$SCRIPT" tune </dev/null 2>&1)"
assert_contains "tune still restarts the service after a mid-run bench crash (#276)" "$tc_out" "Restarting the 'xmrig' service"
assert_contains "systemctl start is actually invoked after the crash (#276)" "$(cat "$TCCALLLOG")" "[systemctl] start xmrig"

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
# #208: _read_temp falls back to the CPU hwmon (k10temp/coretemp temp1_input) when no thermal
# zone exists — the shape of every rig in the production fleet. Non-CPU hwmons are skipped,
# nothing readable stays empty (thermal consumers must skip, never stop a miner on a missing
# sensor), and an existing thermal zone still wins.
echo "== unit: _read_temp hwmon fallback (#208) =="
RT="$(mktemp -d "$SANDBOX/rt.XXXXXX")"
mkdir -p "$RT/hwmon/hwmon0" "$RT/hwmon/hwmon1" "$RT/hwmon/hwmon2"
printf 'nvme\n' >"$RT/hwmon/hwmon0/name"
printf '44000\n' >"$RT/hwmon/hwmon0/temp1_input"
printf 'k10temp\n' >"$RT/hwmon/hwmon1/name"
printf '89500\n' >"$RT/hwmon/hwmon1/temp1_input"
printf 'gpu\n' >"$RT/hwmon/hwmon2/name"
read_temp_with() { # <thermal_zone_path> <hwmon_dir>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        set +e
        THERMAL_ZONE="$1" HWMON_DIR="$2" TUNE_TEMP_CMD="" _read_temp
    )
}
assert_eq "hwmon fallback skips non-CPU sensors, reads k10temp (#208)" "$(read_temp_with "$RT/nozone" "$RT/hwmon")" "89.5"
printf '72000\n' >"$RT/zone"
assert_eq "an existing thermal zone still wins (#208)" "$(read_temp_with "$RT/zone" "$RT/hwmon")" "72.0"
assert_eq "no zone + no CPU hwmon -> empty (#208)" "$(read_temp_with "$RT/nozone" "$RT/empty-hwmon")" ""
rm "$RT/hwmon/hwmon1/temp1_input"
assert_eq "k10temp present but unreadable input -> empty (#208)" "$(read_temp_with "$RT/nozone" "$RT/hwmon")" ""

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

# #347: an INTERRUPTED live sweep must not persist the mid-sweep candidate. _measure_live applies every
# candidate straight into tune-overrides.json and restarts the miner on it; the EXIT trap must restore
# the pre-sweep overrides and restart the miner on THEM. The fake API touches a flag when a candidate
# window is in flight and then blocks — the test kills tune there (mid-iteration, candidate in the file)
# and asserts the file came back byte-identical and the miner saw a post-kill restart. `exec` makes the
# backgrounded PID the rigforge process itself, so the kill lands on the shell that owns the trap.
echo "== black-box: aborted tune --live restores the pre-sweep overrides (#347) =="
cat >"$OVR" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 3 }, "cpu": { "rx": 4 } }
EOF
PRE347="$(cat "$OVR")"
FLAG347="$TN/flag347"
CL347="$TN/calls347.log"
rm -f "$FLAG347"
: >"$CL347"
(cd "$TN" && RIGFORGE_HOME="$PWD" PATH="$STUBS:$PATH" CALL_LOG="$CL347" LOGROTATE_DIR="$TN/logrotate" \
    FLAG347="$FLAG347" API_CMD='touch "$FLAG347"; sleep 60; echo 1500' \
    TUNE_LIVE_WARMUP=0 TUNE_LIVE_INTERVAL=0 TUNE_LIVE_SAMPLES=1 \
    TUNE_SEEDS=auto TUNE_PREFETCH_MODES="0 1" TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
    exec bash "$SCRIPT" tune --live </dev/null >"$TN/abort347.out" 2>&1) &
PID347=$!
for _ in $(seq 1 100); do
    [ -f "$FLAG347" ] && break
    sleep 0.1
done
assert_eq "abort test reached a live candidate window (#347)" "$([ -f "$FLAG347" ] && echo y || echo n)" "y"
# The candidate is in the file RIGHT NOW — prove the pre-state was actually clobbered mid-sweep, so the
# restore assert below can't pass vacuously.
assert_eq "mid-sweep: overrides hold the candidate, not the pre-state (#347)" \
    "$([ "$(cat "$OVR")" = "$PRE347" ] && echo same || echo differs)" "differs"
RESTARTS_PRE347="$(grep -c '\[systemctl\] restart' "$CL347")"
kill "$PID347" 2>/dev/null
wait "$PID347" 2>/dev/null
assert_contains "aborted live sweep announces the restore (#347)" "$(cat "$TN/abort347.out")" "restoring the pre-tune overrides"
assert_eq "aborted live sweep: overrides byte-identical to pre-sweep (#347)" "$(cat "$OVR")" "$PRE347"
RESTARTS_POST347="$(grep -c '\[systemctl\] restart' "$CL347")"
assert_eq "aborted live sweep: the miner saw a final restart on the restored config (#347)" \
    "$([ "$RESTARTS_POST347" -gt "$RESTARTS_PRE347" ] && echo y || echo n)" "y"

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

# #266: unit-style — an even sample count whose middle pair sums to an ODD kHz total makes awk print the
# median in scientific notation (e.g. 4.6275e+06 for 4627000/4628001 kHz, real DVFS jitter between reads).
# The freq writer at rigforge.sh:2120 must floor that back to whole kHz, not leave it for the consumer's
# `.`-floor to truncate into a stray "4" that reads as 0 MHz and false-trips the #62 throttle guard.
echo "== unit: tune bench freq writer floors a sci-notation median to whole kHz (#266) =="
FQDONE="$SANDBOX/freq266.done"
export FQDONE
FQBIN="$SANDBOX/freq266-xmrig"
# The fake prints 'benchmark finished' once released: the bench poll loop greps for that line and breaks,
# so no extra clock sample sneaks in after the replayed ones (a just-exited fake can linger as a zombie
# that `kill -0` still sees, which would otherwise buy the loop one more iteration).
cat >"$FQBIN" <<'EOF'
#!/usr/bin/env bash
echo "speed 1000.0 H/s max 1000.0 H/s"
for _ in $(seq 1 500); do [ -f "$FQDONE" ] && break; sleep 0.02; done # bounded: never outlive the test
echo "benchmark finished"
EOF
chmod +x "$FQBIN"
freqwrite() { ( # <freq sample kHz>... -> BENCH_FREQ_FILE content, via the real _xmrig_bench freq-write path
    source "$SCRIPT"
    local vals=("$@") n=$# fqout="$SANDBOX/freq266.out" ctr="$SANDBOX/freq266.ctr"
    rm -f "$FQDONE" "$fqout"
    printf 0 >"$ctr"
    [ "$n" -eq 0 ] && touch "$FQDONE" # no samples to serve -> release the fake immediately
    # Deterministic clock reader: replay exactly the given samples, one per call, then signal the fake
    # xmrig to finish and go silent — no reliance on real hardware jitter or wall-clock timing.
    # The call counter lives in a FILE: each sample is read via $(...), a subshell where a plain shell
    # variable increment would not persist. `return 0` keeps set -e happy on the non-final sample.
    _cpu_eff_khz() {
        local i
        i=$(cat "$ctr")
        if [ "$i" -ge "$n" ]; then return 0; fi # exhausted -> empty reading, which the sampler skips
        printf '%s' "${vals[$i]}"
        printf '%s' "$((i + 1))" >"$ctr"
        if [ "$((i + 1))" -ge "$n" ]; then touch "$FQDONE"; fi
        return 0
    }
    BENCH_FREQ_FILE="$fqout" _xmrig_bench "$FQBIN" 1M "" >/dev/null
    cat "$fqout"
); }
assert_eq "bench freq median floors a sci-notation kHz average to whole kHz, not a stray digit (#266)" \
    "$(freqwrite 4627000 4628001)" "4627500"
# No clock samples (VM/container without cpufreq): the file must stay EMPTY — "no reading" disables the
# #62 check. A coerced literal 0 would read as "throttled to 0 MHz" and reject every candidate.
assert_eq "bench freq writer leaves the file empty when no clock was readable (#266 follow-up)" \
    "$(freqwrite)" ""

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

# #266: regression — a HEALTHY (~4.6 GHz) candidate whose clock jitters by 1 kHz between two reads gets a
# fractional kHz median (4627500.5) that awk printed as 4.6275e+06; the consumer's `.`-floor mangled that
# into "4" -> 0 MHz -> the #62 guard falsely flagged the candidate as throttled and refused to adopt it.
# scaling_cur_freq is a FIFO fed exactly one odd-sum pair per bench window (reads block until fed), so the
# window always sees an even sample count with a fractional median — no reliance on poll-loop timing.
# Linux-gated (#292): same rationale as the #277 block above — Linux-sysfs plumbing, flaked on the slow
# macOS CI runner; the deterministic freq-writer unit test above still runs everywhere.
if [ "$(uname -s)" != Linux ]; then
    echo "  SKIP: tune bench freq-median black-box runs in the Linux CI jobs (#292)"
else
    echo "== black-box: tune bench freq median doesn't false-trip the #62 throttle guard (#266) =="
    mkdir -p "$TN/cpu266/cpu0/cpufreq"
    FF266="$TN/cpu266/cpu0/cpufreq/scaling_cur_freq"
    DONE266="$TN/done266"
    # #424: the handshake below is a blocking FIFO and nothing in its path has a timeout. When the
    # reader asks for one more sample than the feeder is positioned to serve, it parks in the FIFO's
    # open()/read() and the enclosing `out="$( ... )"` never closes, because a command substitution
    # ends only when every holder of the write end does. One run wedged that way for 53 minutes.
    # T266 bounds the run under test so a wedge FAILS this block (rc 124) instead of hanging the
    # suite. Killing the FEEDER is not an alternative and was tried: a reader blocked in open() waits
    # for a writer to APPEAR, so dropping the last one leaves it exactly where it was.
    T266="${T266:-120}"
    rm -f "$FF266" "$DONE266"
    mkfifo "$FF266"
    # Feeder: serve the pair, then release the fake xmrig so the bench window closes after exactly 2 samples.
    (while :; do printf '4627000\n' >"$FF266" && printf '4628001\n' >"$FF266" && touch "$DONE266" || exit; done) &
    FEED266=$!
    # #425: the feeder is a background job stopped only by the straight-line `kill` below, which sits
    # AFTER the command substitution — so anything that leaves the block early skips it. It then
    # blocks inside open() on a FIFO with no reader, and unlinking the FIFO does NOT wake a writer
    # already blocked on it: the line-49 sandbox trap deletes the FIFO and leaves the process at 0%
    # CPU with no live parent, invisible to every load, disk and pane-children check. Reap it from the
    # EXIT trap, which every exit path that runs traps at all reaches; the kill below stays as the
    # fast path and disarms this. The EXIT trap also runs when bash is KILLED by SIGTERM or SIGHUP,
    # so `kill <suite>` and a dropped SSH are covered too — the realistic escalation path, and the
    # reason this is worth more than an orderly-exit cleanup. SIGINT is the one that is not covered,
    # and not because the trap skips it: with the shell blocked inside the command substitution a
    # Ctrl-C does not terminate the suite at all, so there is nothing for a trap to run.
    trap 'kill "$FEED266" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
    cat >"$BD/xmrig" <<EOF
#!/usr/bin/env bash
echo "speed 1000.0 H/s max 1000.0 H/s"
for _ in \$(seq 1 500); do [ -f "$DONE266" ] && break; sleep 0.02; done # bounded wait
rm -f "$DONE266"
echo "benchmark finished" # breaks the bench poll loop BEFORE a zombie-pid extra iteration samples a 3rd clock
EOF
    chmod +x "$BD/xmrig"
    out="$(cd "$TN" && PATH="$STUBS:$PATH" CPU_SYSFS="$TN/cpu266" CPUFREQ_MAX="$TN/cpu_max" TUNE_MIN_FREQ_MHZ=4000 \
        TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 \
        RIGFORGE_HOME="$PWD" timeout "$T266" bash "$SCRIPT" tune </dev/null 2>&1)"
    rc=$?
    kill "$FEED266" 2>/dev/null
    wait "$FEED266" 2>/dev/null
    trap 'rm -rf "$SANDBOX"' EXIT
    rm -f "$FF266" "$DONE266"
    assert_rc "healthy fractional-median tune exits 0 (#266)" "$rc" "0"
    assert_absent "healthy candidate NOT flagged as throttled (#266)" "$out" "throttled to"
    assert_eq "healthy candidate recorded as not throttled, eligible for adoption (#266)" "$(J "$TLOG" '.results[0].throttled')" "false"
fi

# #265: _seed_wr / _seed_g must keep an explicit base-config false instead of jq `//` flipping it to
# the true default; with the key absent, the true default still applies.
echo "== unit: tune seeds keep explicit false (#265) =="
seed_base() { # <fn> <TUNE_BASE json>
    local f="$SANDBOX/seed_base.json"
    printf '%s' "$2" >"$f"
    (
        source "$SCRIPT"
        TUNE_BASE="$f"
        "$1"
    )
}
assert_eq "_seed_wr keeps explicit wrmsr:false (#265)" "$(seed_base _seed_wr '{"randomx":{"wrmsr":false}}')" "false"
assert_eq "_seed_g keeps explicit 1gb-pages:false (#265)" "$(seed_base _seed_g '{"randomx":{"1gb-pages":false}}')" "false"
assert_eq "_seed_wr defaults to true when wrmsr absent (#265)" "$(seed_base _seed_wr '{"randomx":{}}')" "true"
assert_eq "_seed_g defaults to true when 1gb-pages absent (#265)" "$(seed_base _seed_g '{"randomx":{}}')" "true"

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

# #328: the runtime HugePages write is grow-only — it must never shrink a pool another consumer
# (a co-hosted pithead stack) already reserved. The proposed-grub stub above says the miner needs
# 200 pages; MEMINFO/NR_HUGEPAGES_FILE fake the live pool and a recording sysctl captures writes.
echo "== black-box: runtime HugePages reservation is grow-only (#328) =="
HP="$(mktemp -d "$SANDBOX/hp328.XXXXXX")"
mkdir -p "$HP/bin"
cat >"$HP/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SYSCTL_CALLS"
EOF
chmod +x "$HP/bin/sysctl"
run_tk328() { # <sysctl_calls_file> <HugePages_Free> <pool_total> [miner_held_pages]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$TK"
        WORKER_ROOT="$TK/home/worker"
        MODULES_LOAD_DIR="$TK/nope"
        MODULES_FILE="$TK/nope/modules"
        GRUB_DEFAULT="$TK/nope/grub" # nonexistent -> the GRUB block is skipped
        printf 'HugePages_Free:    %s\n' "$2" >"$HP/meminfo"
        printf '%s\n' "$3" >"$HP/nr_hugepages"
        MEMINFO="$HP/meminfo"
        NR_HUGEPAGES_FILE="$HP/nr_hugepages"
        # The held-pages credit has its own seam: a running miner is out of scope for a sandbox.
        [ -n "${4:-}" ] && eval "_miner_held_hugepages() { echo $4; }"
        export PG_CALLS="$HP/pg_calls" SYSCTL_CALLS="$1"
        set +e
        PATH="$HP/bin:$STUBS:$PATH" tune_kernel 2>&1
    )
}
SC="$HP/calls1"
: >"$SC"
out="$(run_tk328 "$SC" 0 3072)"
assert_contains "co-resident pool grows by the shortfall, never shrinks (#328)" "$(cat "$SC")" "vm.nr_hugepages=3272"
SC="$HP/calls2"
: >"$SC"
out="$(run_tk328 "$SC" 500 3072)"
assert_absent "enough free pages -> no write at all (#328)" "$(cat "$SC")" "vm.nr_hugepages"
assert_contains "enough free pages -> says it left the pool alone (#328)" "$out" "leaving it as-is"
SC="$HP/calls3"
: >"$SC"
out="$(run_tk328 "$SC" 0 0)"
assert_contains "fresh box -> plain requirement, unchanged behavior (#328)" "$(cat "$SC")" "vm.nr_hugepages=200"
SC="$HP/calls4"
: >"$SC"
out="$(run_tk328 "$SC" 50 1300 180)"
assert_absent "a running miner's held pages count as available — idempotent re-run (#328)" "$(cat "$SC")" "vm.nr_hugepages"
# The real held-pages probe (no seam): a stub systemctl reports this test shell as the miner's
# MainPID. On Linux /proc/$$/status exists with HugetlbPages: 0 kB — the probe reads it and
# credits 0; on macOS there is no /proc, the guard falls through to the same 0. Either way the
# outcome matches calls1: grow by the full shortfall.
cat >"$HP/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo $$
EOF
chmod +x "$HP/bin/systemctl"
SC="$HP/calls5"
: >"$SC"
out="$(run_tk328 "$SC" 0 3072)"
assert_contains "real MainPID probe -> zero credit for a page-less process (#328)" "$(cat "$SC")" "vm.nr_hugepages=3272"
rm -f "$HP/bin/systemctl"
# proposed-grub.sh missing -> the 3072 fallback goes through the same grow-only path.
run_tk328_nopg() { # <sysctl_calls_file>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$HP/empty" # no util/proposed-grub.sh here
        WORKER_ROOT="$TK/home/worker"
        MODULES_LOAD_DIR="$TK/nope"
        MODULES_FILE="$TK/nope/modules"
        GRUB_DEFAULT="$TK/nope/grub"
        printf 'HugePages_Free:    0\n' >"$HP/meminfo"
        printf '0\n' >"$HP/nr_hugepages"
        MEMINFO="$HP/meminfo"
        NR_HUGEPAGES_FILE="$HP/nr_hugepages"
        export SYSCTL_CALLS="$1"
        set +e
        PATH="$HP/bin:$STUBS:$PATH" tune_kernel 2>&1
    )
}
mkdir -p "$HP/empty"
SC="$HP/calls6"
: >"$SC"
out="$(run_tk328_nopg "$SC")"
assert_contains "fallback (no proposed-grub.sh) is grow-only too (#328)" "$(cat "$SC")" "vm.nr_hugepages=3072"

# ---------------------------------------------------------------------------
# #398: hugepages_pool_ceiling_mb bounds the grow-only write to a declared ceiling instead of
# letting a co-resident stack's declared headroom double-count into the write (rigforge#398). The
# fixture below is the worked example from rigforge#398 / pithead#1103: an 8 GB reduced-tier
# appliance box with NUMA_NODES=1, THREADS=4, hugepages_reserve_extra_mb=5120 (the tier's own 5 GiB
# reservation, declared as the co-located miner's headroom), a pool already at 2560 pages (5 GiB)
# of which the stack holds ~2336 (HugePages_Free=224), and no miner running yet (held=0).
# util/proposed-grub.sh's real fallback formula (1168*NUMA + THREADS + 50 + ceil(extra_mb/2)) gives
# required=3782 2MB pages for these inputs (re-derived independently in rigforge#398 — NOT the 3870
# both pithead#1103 and pithead#1306 quote, which conflates proposed-grub.sh's two formula branches
# into one call that never actually happens). `_ensure_hugepages` is exercised directly (not
# through tune_kernel) so the ceiling logic is pinned in isolation from proposed-grub.sh's own
# math, already covered by the #65/#305 suites above.
echo "== unit: hugepages pool ceiling bounds the grow-only write (#398) =="
HPC="$(mktemp -d "$SANDBOX/hpc398.XXXXXX")"
mkdir -p "$HPC/bin"
cat >"$HPC/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SYSCTL_CALLS"
EOF
chmod +x "$HPC/bin/sysctl"
run_ensure_hp398() { # <sysctl_calls_file> <required> <HugePages_Free> <pool_total> [ceiling_mb]
    (
        source "$SCRIPT"
        printf 'HugePages_Free:    %s\n' "$3" >"$HPC/meminfo"
        printf '%s\n' "$4" >"$HPC/nr_hugepages"
        MEMINFO="$HPC/meminfo"
        NR_HUGEPAGES_FILE="$HPC/nr_hugepages"
        _miner_held_hugepages() { echo 0; } # out of scope here — #328 above covers the held-pages credit
        HUGEPAGES_POOL_CEILING_MB="${5:-0}"
        export SYSCTL_CALLS="$1"
        set +e
        PATH="$HPC/bin:$STUBS:$PATH" _ensure_hugepages "$2" 2>&1
    )
}

# No ceiling declared: the 8 GB fixture's required/avail math is BYTE-FOR-BYTE the pre-#398
# arithmetic — the conservative "no declaration, no behavior change" pin. (This unavoidably also
# reproduces the double count itself: fixing that is what declaring the ceiling below does, not a
# change to this arithmetic.)
SC="$HPC/calls1"
: >"$SC"
out="$(run_ensure_hp398 "$SC" 3782 224 2560)"
assert_contains "no ceiling declared -> unchanged pre-#398 arithmetic (8 GB fixture, #398)" "$(cat "$SC")" "vm.nr_hugepages=6118"

# Ceiling declared, above current but below the uncapped target: the write is CAPPED at the
# ceiling instead of the double-counted 6118. Mutation kill: respelling _ensure_hugepages back to
# its pre-#398 body (`sudo sysctl -w vm.nr_hugepages=$((current + required - avail))`, no ceiling
# clamp) turns both assertions below red — the write goes back to 6118 regardless of the declared
# ceiling. Confirmed by hand against that exact reverted body before this test was written.
SC="$HPC/calls2"
: >"$SC"
out="$(run_ensure_hp398 "$SC" 3782 224 2560 6400)"
assert_contains "ceiling above current caps the write, not the double count (#398)" "$(cat "$SC")" "vm.nr_hugepages=3200"
assert_absent "capped write is no longer the double-counted 6118 (#398 mutation kill)" "$(cat "$SC")" "6118"
assert_contains "capping is logged with the ceiling reason (#398)" "$out" "capping the write"

# #412, the write side. Fed a ceiling bash cannot evaluate, `[ "$CEILING" -gt 0 ] 2>/dev/null` returned
# 2, the `if` read that as false, and the ENTIRE ceiling block was skipped — with the redirect eating
# the only tell, so the pool grew to the uncapped 6118 in total silence while config.json declared a
# cap. parse_config now rejects such a value, so this backstop should be unreachable in practice; it
# is asserted anyway because "unreachable" is a claim about the caller, and a cap that can be dropped
# silently is not a cap. The discriminating assertion is the sysctl call log being EMPTY: a revert to
# the silent-skip body leaves `vm.nr_hugepages=6118` in it and reddens on that line alone, whether or
# not the message ever changes.
SC="$HPC/calls412"
: >"$SC"
out="$(run_ensure_hp398 "$SC" 3782 224 2560 99999999999999999999)"
assert_eq "inevaluable ceiling writes NOTHING — no silent uncapped grow (#412)" "$(cat "$SC")" ""
assert_absent "inevaluable ceiling does not reach the uncapped 6118 write (#412 mutation kill)" "$(cat "$SC")" "6118"
assert_contains "inevaluable ceiling is refused out loud, not skipped (#412)" "$out" "unenforceable ceiling"
# The control that keeps the assertion above honest: a VALID ceiling must still reach the write and
# still cap. Without it, a change that made _ensure_hugepages refuse everything would pass all three.
SC="$HPC/calls412ok"
: >"$SC"
out="$(run_ensure_hp398 "$SC" 3782 224 2560 6400)"
assert_contains "a valid ceiling still caps the write (#412 over-tightening control)" "$(cat "$SC")" "vm.nr_hugepages=3200"

# Ceiling declared AT the tier's own already-committed reservation (2560 pages / 5120 MB, the real
# reduced-tier number from pithead#1103): the pool is already at the ceiling, so the write is
# skipped entirely rather than growing it — the miner gets zero extra pages, but the box is never
# pushed past its declared honest capacity.
SC="$HPC/calls3"
: >"$SC"
out="$(run_ensure_hp398 "$SC" 3782 224 2560 5120)"
assert_absent "ceiling already met -> no write at all (#398)" "$(cat "$SC")" "vm.nr_hugepages"
assert_contains "ceiling-already-met is a WARN naming the ceiling (#398)" "$out" "already at its declared ceiling"

# An ODD declared ceiling must FLOOR to the 2MB page below, never round up past itself (security
# review finding on the first version of this fix: `(HUGEPAGES_POOL_CEILING_MB + 1) / 2` rounds an
# odd MB value UP, so 5121MB became 2561 pages = 5122MB — one page past the declared ceiling,
# violating "never grown past the ceiling"). 5121 floors to the SAME 2560 pages as the even 5120MB
# case above, so with current already at 2560 the pool is already at-or-past the (floored) ceiling
# and the write is skipped, exactly like calls3. Mutation kill: restoring the `+ 1` rounds 5121MB
# up to 2561 pages instead, which is > current(2560) — the code takes the CAP branch instead of the
# already-met branch and WRITES `vm.nr_hugepages=2561` (5122MB, over the declared 5121MB), flipping
# both assertions below red.
SC="$HPC/calls_odd"
: >"$SC"
out="$(run_ensure_hp398 "$SC" 3782 224 2560 5121)"
assert_absent "odd ceiling (5121MB) floors to 2560 pages -> no write, not 2561 (#398 mutation kill)" "$(cat "$SC")" "vm.nr_hugepages"
assert_contains "odd-ceiling floor is a WARN naming the ceiling (#398)" "$out" "already at its declared ceiling"

# Regression: no headroom and no ceiling at all still behaves like plain #328 grow-only sizing,
# through the SAME direct-call path used above — proves #398 didn't reshape the ceiling-absent
# code path.
SC="$HPC/calls4"
: >"$SC"
out="$(run_ensure_hp398 "$SC" 200 0 0)"
assert_contains "no headroom, no ceiling -> plain requirement, unchanged (#328 x #398)" "$(cat "$SC")" "vm.nr_hugepages=200"

# ---------------------------------------------------------------------------
# Appliance mode (pithead#797 R1): RIGFORGE_APPLIANCE=1 runs setup on the Pithead appliance image —
# read-only root, volatile /etc overlay, a boot leg re-runs setup every boot. Under the flag setup
# must: never install packages (fail naming missing tools instead), skip the GRUB leg, render units
# into /run and enable them --runtime, mount hugetlbfs at runtime with no fstab/limits.conf writes —
# while runtime tuning (modprobe msr, grow-only sysctl) stays byte-identical.
echo "== black-box: appliance mode (pithead#797 R1) =="
AP="$(mktemp -d "$SANDBOX/appliance.XXXXXX")"

# The flag presets SYSTEMD_DIR to /run and flips enablement to --runtime; an explicit override and
# the no-flag defaults are unchanged.
out="$( (unset SYSTEMD_DIR && RIGFORGE_APPLIANCE=1 && source "$SCRIPT" && printf '%s|%s' "$SYSTEMD_DIR" "$ENABLE_RUNTIME"))"
assert_eq "flag presets /run/systemd/system + --runtime (#797)" "$out" "/run/systemd/system|--runtime"
out="$( (unset SYSTEMD_DIR && source "$SCRIPT" && printf '%s|%s' "$SYSTEMD_DIR" "$ENABLE_RUNTIME"))"
assert_eq "no flag: /etc/systemd/system + persistent enable (#797)" "$out" "/etc/systemd/system|"
out="$( (SYSTEMD_DIR="$AP/custom-sd" && RIGFORGE_APPLIANCE=1 && source "$SCRIPT" && printf '%s' "$SYSTEMD_DIR"))"
assert_eq "explicit SYSTEMD_DIR still wins under the flag (#797)" "$out" "$AP/custom-sd"

# Dependency handling: tools verified (command -v), never installed. The toolchain is only required
# while a build is pending; a prebuilt tree needs envsubst alone (the R0 bench re-ran with a broken
# compiler). PATH is restricted to purpose-built bins so the host's real toolchain can't leak in.
mkbin_ap() { # <dir> <cmd...>: a dir of exit-0 fakes
    local d="$1" c
    shift
    mkdir -p "$d"
    for c in "$@"; do
        printf '#!/bin/sh\nexit 0\n' >"$d/$c"
        chmod +x "$d/$c"
    done
}
mkbin_ap "$AP/bin-all" git cmake make cc envsubst
mkbin_ap "$AP/bin-envsubst" envsubst
run_apdeps() { # <bin_dir> <xmrig_rebuild>; echoes output, exits with install_dependencies' rc
    (
        RIGFORGE_APPLIANCE=1
        source "$SCRIPT"
        OS_TYPE=Linux
        XMRIG_REBUILD="$2"
        set +e
        # PATH is ONLY the purpose-built bin dir — no $STUBS (it fakes the whole toolchain, which
        # would mask the missing-tool case) and no real PATH (a host compiler would too). The
        # appliance branch itself needs nothing but shell builtins.
        PATH="$1" CALL_LOG="$AP/deps-calls.log" install_dependencies </dev/null 2>&1
    )
}
: >"$AP/deps-calls.log"
out="$(run_apdeps "$AP/bin-all" true)"
assert_rc "all tools baked -> deps step passes (#797)" "$?" "0"
assert_contains "deps step says baked, skipping install (#797)" "$out" "skipping package install"
assert_absent "no package manager is ever invoked (#797)" "$(cat "$AP/deps-calls.log")" "[apt-get]"
out="$(run_apdeps "$AP/bin-envsubst" true)"
assert_rc "missing toolchain while a build pends -> hard fail (#797)" "$?" "1"
assert_contains "failure names the missing tools (#797)" "$out" "missing from the image: git cmake make cc"
assert_contains "failure points at image build, not runtime install (#797)" "$out" "baked at image build"
out="$(run_apdeps "$AP/bin-envsubst" false)"
assert_rc "prebuilt tree needs no compiler — envsubst alone passes (#797)" "$?" "0"

# tune_kernel: GRUB file present and update-grub available, yet the appliance skip branch runs —
# no cmdline edit, no backup, no update-grub, no modules-load drop-in. Runtime tuning unchanged:
# modprobe msr still runs and the grow-only sysctl still writes the shortfall.
APK="$AP/kernel"
mkdir -p "$APK/util" "$APK/home/worker" "$APK/mld" "$APK/bin"
cat >"$APK/util/proposed-grub.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--runtime) echo 200 ;;
-q) echo "quiet splash default_hugepagesz=2M hugepages=200 msr.allow_writes=on" ;;
esac
EOF
chmod +x "$APK/util/proposed-grub.sh"
cat >"$APK/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SYSCTL_CALLS"
EOF
chmod +x "$APK/bin/sysctl"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$APK/grub"
printf 'HugePages_Free:    0\n' >"$APK/meminfo"
printf '0\n' >"$APK/nr_hugepages"
out="$(
    (
        RIGFORGE_APPLIANCE=1
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$APK"
        WORKER_ROOT="$APK/home/worker"
        MODULES_LOAD_DIR="$APK/mld" # exists — the non-appliance path WOULD drop msr.conf here
        GRUB_DEFAULT="$APK/grub"    # exists — the non-appliance path WOULD edit it
        MEMINFO="$APK/meminfo"
        NR_HUGEPAGES_FILE="$APK/nr_hugepages"
        export SYSCTL_CALLS="$APK/sysctl-calls.log"
        set +e
        PATH="$APK/bin:$STUBS:$PATH" CALL_LOG="$APK/calls.log" tune_kernel 2>&1
    )
)"
assert_contains "GRUB leg skipped with the image-owned message (#797)" "$out" "skipping GRUB updates — the kernel cmdline is image-owned"
assert_eq "GRUB file untouched (#797)" "$(cat "$APK/grub")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
assert_eq "no GRUB backup written (#797)" "$([ -e "$APK/grub.bak" ] && echo present || echo absent)" "absent"
assert_absent "update-grub never runs (#797)" "$(cat "$APK/calls.log")" "[update-grub]"
assert_eq "no modules-load drop-in (#797)" "$([ -e "$APK/mld/msr.conf" ] && echo present || echo absent)" "absent"
assert_contains "modprobe msr still runs — runtime tuning unchanged (#797)" "$(cat "$APK/calls.log")" "[modprobe] msr"
assert_contains "grow-only HugePages sysctl still writes (#797/#328)" "$(cat "$APK/sysctl-calls.log")" "vm.nr_hugepages=200"

# configure_limits: hugetlbfs mounted at runtime (both page sizes), fstab and limits.conf never
# touched. mountpoint is faked not-mounted so the mount calls are observable; the second run fakes
# already-mounted and must mount nothing (idempotent re-run, the every-boot path).
APL="$AP/limits"
mkdir -p "$APL/bin"
printf '#!/bin/sh\nexit 1\n' >"$APL/bin/mountpoint"
chmod +x "$APL/bin/mountpoint"
printf 'seeded\n' >"$APL/fstab"
printf 'seeded\n' >"$APL/limits.conf"
run_aplimits() { # <bin_dir> <call_log>
    (
        RIGFORGE_APPLIANCE=1
        source "$SCRIPT"
        OS_TYPE=Linux
        FSTAB="$APL/fstab"
        LIMITS_CONF="$APL/limits.conf"
        HUGEPAGES_1G_DIR="$APL/hp1g"
        set +e
        PATH="$1:$STUBS:$PATH" CALL_LOG="$2" configure_limits 2>&1
    )
}
out="$(run_aplimits "$APL/bin" "$APL/calls.log")"
assert_contains "2MB hugetlbfs mounted at runtime (#797)" "$(cat "$APL/calls.log")" "[mount] -t hugetlbfs hugetlbfs /dev/hugepages"
assert_contains "1G hugetlbfs mounted at runtime (#797)" "$(cat "$APL/calls.log")" "[mount] -t hugetlbfs -o pagesize=1G hugetlbfs_1g $APL/hp1g"
assert_eq "fstab untouched (#797)" "$(cat "$APL/fstab")" "seeded"
assert_eq "limits.conf untouched (#797)" "$(cat "$APL/limits.conf")" "seeded"
out="$(run_aplimits "$STUBS" "$APL/calls2.log")" # stub mountpoint exits 0 = already mounted
assert_absent "already mounted -> no mount calls (#797)" "$(cat "$APL/calls2.log")" "[mount]"

# install_service: unit rendered into the (appliance-preset) systemd dir, enabled with --runtime.
APS="$AP/svc"
mkdir -p "$APS/run-systemd" "$APS/xmrig/build"
(
    cd "$APS" || exit 1
    RIGFORGE_APPLIANCE=1
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$ROOT" # real systemd/xmrig.service.template
    WORKER_ROOT="$APS"
    SYSTEMD_DIR="$APS/run-systemd"
    REBOOT_REQUIRED=false
    XMRIG_REBUILD=true
    set +e
    PATH="$STUBS:$PATH" CALL_LOG="$APS/calls.log" install_service >/dev/null 2>&1
)
assert_eq "unit rendered into the runtime systemd dir (#797)" "$([ -f "$APS/run-systemd/xmrig.service" ] && echo yes || echo no)" "yes"
assert_contains "unit enabled with --runtime (#797)" "$(cat "$APS/calls.log")" "[systemctl] enable --runtime xmrig.service"

# setup --dry-run previews the SAME appliance decisions (shared logic, #146): baked deps, GRUB skip,
# runtime-only msr and mounts, --runtime enablement — and still covers every main() step.
APDR="$AP/dryrun"
mkdir -p "$APDR/etc" "$APDR/util"
cp "$APK/util/proposed-grub.sh" "$APDR/util/proposed-grub.sh"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$APDR/etc/grub"
printf 'HugePages_Free:    0\n' >"$APDR/etc/meminfo"
cat >"$APDR/config.json" <<EOF
{ "HOME_DIR": "$APDR/home", "pools": [{"url": "poolbox.lan:3333"}] }
EOF
apdr_out="$(cd "$APDR" && PATH="$STUBS:$PATH" CALL_LOG="$APDR/calls.log" RIGFORGE_APPLIANCE=1 \
    GRUB_DEFAULT="$APDR/etc/grub" FSTAB="$APDR/etc/fstab" LIMITS_CONF="$APDR/etc/limits.conf" \
    MEMINFO="$APDR/etc/meminfo" RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
assert_rc "appliance dry-run exits 0 (#797/#146)" "$?" "0"
assert_contains "plan: baked-deps arm (#797)" "$apdr_out" "appliance mode: baked into the image — no package install"
assert_contains "plan: GRUB skip arm (#797)" "$apdr_out" "skipping GRUB updates (appliance: the kernel cmdline is image-owned)"
assert_contains "plan: runtime-only msr arm (#797)" "$apdr_out" "modprobe msr at runtime only (appliance: no modules-load drop-in)"
assert_contains "plan: runtime mounts, no fstab/limits writes (#797)" "$apdr_out" "appliance mode: mount hugetlbfs at runtime"
assert_contains "plan: unit goes to /run with --runtime (#797)" "$apdr_out" "/run/systemd/system/xmrig.service"
assert_contains "plan: enable --runtime wording (#797)" "$apdr_out" "enable --runtime --now"
assert_contains "plan: grow-only preview still renders (#797/#328)" "$apdr_out" "grow the pool so 200 2MB HugePages are available"
for mut in apt-get modprobe tee mount sysctl update-grub; do
    assert_absent "appliance dry-run never invokes $mut (#797/#146)" "$(cat "$APDR/calls.log" 2>/dev/null)" "[$mut]"
done
while IFS= read -r step; do
    assert_contains "appliance plan covers main() step '$step' (#797/#146)" "$apdr_out" "$step"
done <<<"$main_steps"

# Full black-box setup with the flag, host-native OS path: proves the flag survives main() wiring
# end to end. Portable asserts here; the Linux-only /etc assertions run on Linux hosts and in the
# Linux CI job (the macOS path skips kernel/limits/service by OS, not by flag).
APW="$(e2e_setup)"
RIGFORGE_APPLIANCE=1 e2e_run "$APW" "$HOST_OS"
rc=$?
assert_rc "appliance full run exits 0 (#797)" "$rc" "0"
assert_absent "appliance full run: no apt-get (#797)" "$(cat "$APW/calls.log")" "[apt-get]"
assert_absent "appliance full run: no brew install (#797)" "$(cat "$APW/calls.log")" "[brew] install"
assert_contains "appliance full run: says deps are baked (#797)" "$E2E_OUT" "dependencies are baked into the image"
if [ "$HOST_OS" = Linux ]; then
    assert_contains "appliance full run: GRUB skip taken (#797)" "$E2E_OUT" "the kernel cmdline is image-owned"
    assert_contains "appliance full run: GRUB file untouched (#797)" "$(cat "$APW/etc/default/grub")" 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash memmap=4G&2M"'
    assert_absent "appliance full run: no fstab hugetlbfs lines (#797)" "$(cat "$APW/etc/fstab")" "hugetlbfs"
    assert_absent "appliance full run: no memlock append (#797)" "$(cat "$APW/etc/security/limits.conf")" "memlock"
    assert_eq "appliance full run: no msr.conf drop-in (#797)" "$([ -e "$APW/etc/modules-load.d/msr.conf" ] && echo present || echo absent)" "absent"
    assert_contains "appliance full run: unit enabled --runtime (#797)" "$(cat "$APW/calls.log")" "[systemctl] enable --runtime xmrig.service"
    # Every enable under the flag must be --runtime — a persisted enable writes the volatile
    # /etc overlay and silently vanishes on reboot. The xmrig assert above pins one site; this
    # guards the other enable sites (timers, api, control) against a future call that forgets
    # its ${ENABLE_RUNTIME:+...} expansion.
    assert_eq "appliance full run: every systemctl enable is --runtime (#797)" \
        "$(grep -F "[systemctl] enable" "$APW/calls.log" | grep -cv -- --runtime)" "0"
    # /etc/logrotate.d is volatile on the appliance and the image runs no logrotate — the drop-in
    # must not be written (log policy is the integration layer's, pithead#797 R2).
    assert_eq "appliance full run: no logrotate drop-in (#797)" "$([ -e "$APW/etc/logrotate.d/xmrig" ] && echo present || echo absent)" "absent"
fi
# check_prerequisites under the flag: a missing jq is a hard, actionable failure — never an install
# (the non-appliance path would apt/brew it; PATH without jq simulates an image that forgot to bake it).
apjq_out="$( (
    source "$SCRIPT"
    RIGFORGE_APPLIANCE=1
    OS_TYPE=Linux
    set +e
    # Sourcing ran jq, so bash hashed its real path — clear the table or `command -v jq`
    # ignores the emptied PATH and the missing-tool branch never fires.
    hash -r
    PATH="/nonexistent" check_prerequisites 2>&1
))"
apjq_rc=$?
assert_rc "appliance + missing jq fails hard (#797)" "$apjq_rc" "1"
assert_contains "appliance + missing jq names the fix (#797)" "$apjq_out" "bake jq into the image"
assert_absent "appliance + missing jq never installs (#797)" "$apjq_out" "Installing prerequisite"

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
assert_contains "unknown tune flag message" "$out" "Unknown option for tune"

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

# #347: an INTERRUPTED autotune sweep must not persist the mid-sweep prefetch candidate. Each trial
# merges a candidate mode into the overrides and restarts the miner on it; the EXIT trap must restore
# the pre-sweep mode — via the same MERGE the sweep uses, so offline-`tune` knobs survive the abort too.
# The fake API serves the baseline read fast, then flags + blocks on the first candidate window; the
# test kills autotune there and asserts prefetch is back at the pre-sweep mode with the merged knobs
# intact and a post-kill restart.
echo "== black-box: aborted autotune restores the pre-sweep prefetch mode (#347) =="
cat >"$OVR" <<'EOF'
{ "randomx": { "scratchpad_prefetch_mode": 1 }, "cpu": { "rx": 4, "yield": false } }
EOF
FLAGAT347="$TN/flagat347"
CLAT347="$TN/callsat347.log"
ACTR347="$TN/actr347"
rm -f "$FLAGAT347" "$ACTR347"
: >"$CLAT347"
(cd "$TN" && RIGFORGE_HOME="$PWD" PATH="$STUBS:$PATH" CALL_LOG="$CLAT347" LOGROTATE_DIR="$TN/logrotate" \
    FLAGAT347="$FLAGAT347" ACTR347="$ACTR347" \
    API_CMD='c=$(cat "$ACTR347" 2>/dev/null||echo 0);c=$((c+1));echo "$c">"$ACTR347";if [ "$c" -ge 2 ]; then touch "$FLAGAT347"; sleep 60; fi; echo 1200' \
    AUTOTUNE_WARMUP=0 AUTOTUNE_SAMPLES=1 AUTOTUNE_INTERVAL=0 \
    exec bash "$SCRIPT" autotune </dev/null >"$TN/abortat347.out" 2>&1) &
PIDAT347=$!
for _ in $(seq 1 100); do
    [ -f "$FLAGAT347" ] && break
    sleep 0.1
done
assert_eq "autotune abort test reached a candidate window (#347)" "$([ -f "$FLAGAT347" ] && echo y || echo n)" "y"
assert_eq "mid-sweep: overrides hold the candidate mode, not the baseline (#347)" \
    "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "0"
RESTARTS_PREAT347="$(grep -c '\[systemctl\] restart' "$CLAT347")"
kill "$PIDAT347" 2>/dev/null
wait "$PIDAT347" 2>/dev/null
assert_contains "aborted autotune announces the restore (#347)" "$(cat "$TN/abortat347.out")" "sweep interrupted — restoring prefetch_mode=1"
assert_eq "aborted autotune: prefetch back at the pre-sweep mode (#347)" "$(J "$OVR" '.randomx.scratchpad_prefetch_mode')" "1"
assert_eq "aborted autotune: merged threads survive the abort restore (#347)" "$(J "$OVR" '.cpu.rx')" "4"
assert_eq "aborted autotune: merged yield survives the abort restore (#347)" "$(J "$OVR" '.cpu.yield')" "false"
RESTARTS_POSTAT347="$(grep -c '\[systemctl\] restart' "$CLAT347")"
assert_eq "aborted autotune: the miner saw a final restart on the restored mode (#347)" \
    "$([ "$RESTARTS_POSTAT347" -gt "$RESTARTS_PREAT347" ] && echo y || echo n)" "y"

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
# (3) a valid tar whose config.json fails parse_config semantically (not just invalid JSON — pools
# isn't an array). Checksum the live config before/after: it must be byte-identical, not merely
# equal on the one field the earlier assertions happen to check.
BADCFG="$(mktemp -d "$SANDBOX/badcfg.XXXXXX")"
printf '{"pools": "not-an-array"}\n' >"$BADCFG/config.json"
tar -czf "$FR/badcfg.tar.gz" -C "$BADCFG" config.json
before_sum="$(cksum "$FR/config.json")"
out="$(cd "$FR" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y "$FR/badcfg.tar.gz" </dev/null 2>&1)"
assert_rc "restore of a semantically invalid config fails" "$?" "1"
assert_contains "restore of a semantically invalid config is reported" "$out" "validation"
assert_eq "invalid config did not clobber the existing config" "$(cksum "$FR/config.json")" "$before_sum"
# backup needs a config to snapshot.
NOC="$(mktemp -d "$SANDBOX/noc.XXXXXX")"
cp "$ROOT/VERSION" "$NOC/"
out="$(cd "$NOC" && PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" backup </dev/null 2>&1)"
assert_rc "backup without a config fails" "$?" "1"
assert_contains "backup no-config message" "$out" "No config.json"

# #353 (3): backup/restore/support-bundle's mktemp -d staging (config.json, tokens) must not survive
# a set -e abort — same EXIT-trap treatment tune() got in #135. Force a real abort (a tar that always
# fails) and confirm the staged tempdir is actually GONE afterward, not just that the command failed.
# mktemp is wrapped, not replaced — it still creates a real dir; the wrapper only logs the path so the
# test can check it from outside the subprocess that owned it.
REAL_MKTEMP="$(command -v mktemp)"
_leak_test_bins() { # <dir> -> writes a logging mktemp wrapper + an always-fails tar into <dir>/bin
    mkdir -p "$1/bin"
    cat >"$1/bin/mktemp" <<EOF
#!/usr/bin/env bash
p="\$("$REAL_MKTEMP" "\$@")"
echo "\$p" >>"$1/mktemp.log"
printf '%s' "\$p"
EOF
    cat >"$1/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$1/bin/mktemp" "$1/bin/tar"
    : >"$1/mktemp.log"
}

echo "== black-box: backup leaks no staging tempdir on a set -e abort (#353) =="
BKT="$(mktemp -d "$SANDBOX/backup-trap.XXXXXX")"
_leak_test_bins "$BKT"
cat >"$BKT/config.json" <<EOF
{ "HOME_DIR": "$BKT/home", "pools": [{"url": "h:3333"}] }
EOF
bkt_rc=0
(cd "$BKT" && PATH="$BKT/bin:$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" backup </dev/null >/dev/null 2>&1) || bkt_rc=$?
bkt_stage="$(tail -1 "$BKT/mktemp.log" 2>/dev/null)"
if [ -z "$bkt_stage" ]; then
    bad "backup leak-test setup (#353)" "mktemp was never logged — the wrapper stub isn't wired correctly"
else
    assert_rc "backup with a failing tar exits nonzero (sanity: the abort really happened)" "$bkt_rc" "1"
    assert_eq "backup's EXIT trap removed the staging tempdir after the abort (#353)" "$([ -d "$bkt_stage" ] && echo leaked || echo clean)" "clean"
fi

echo "== black-box: restore leaks no staging tempdir on a set -e abort (#353) =="
RST="$(mktemp -d "$SANDBOX/restore-trap.XXXXXX")"
_leak_test_bins "$RST"
rst_rc=0
(cd "$RST" && PATH="$RST/bin:$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y "$ARCHIVE" </dev/null >/dev/null 2>&1) || rst_rc=$?
rst_stage="$(tail -1 "$RST/mktemp.log" 2>/dev/null)"
if [ -z "$rst_stage" ]; then
    bad "restore leak-test setup (#353)" "mktemp was never logged — the wrapper stub isn't wired correctly"
else
    assert_rc "restore with a failing tar -xzf exits nonzero (sanity: the abort really happened)" "$rst_rc" "1"
    assert_eq "restore's EXIT trap removed the staging tempdir after the abort (#353)" "$([ -d "$rst_stage" ] && echo leaked || echo clean)" "clean"
fi

echo "== black-box: support-bundle leaks no staging tempdir on a set -e abort (#353) =="
SBT="$(mktemp -d "$SANDBOX/support-bundle-trap.XXXXXX")"
_leak_test_bins "$SBT"
cat >"$SBT/config.json" <<EOF
{ "HOME_DIR": "$SBT/home", "pools": [{"url": "h:3333"}] }
EOF
sbt_rc=0
(cd "$SBT" && PATH="$SBT/bin:$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" support-bundle </dev/null >/dev/null 2>&1) || sbt_rc=$?
sbt_stage="$(tail -1 "$SBT/mktemp.log" 2>/dev/null)"
if [ -z "$sbt_stage" ]; then
    bad "support-bundle leak-test setup (#353)" "mktemp was never logged — the wrapper stub isn't wired correctly"
else
    assert_rc "support-bundle with a failing tar exits nonzero (sanity: the abort really happened)" "$sbt_rc" "1"
    assert_eq "support-bundle's EXIT trap removed the staging tempdir after the abort (#353)" "$([ -d "$sbt_stage" ] && echo leaked || echo clean)" "clean"
fi

echo "== unit: VERSION is SemVer (#3) =="
ver="$(tr -d '[:space:]' <"$ROOT/VERSION" 2>/dev/null)"
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.].*)?$ ]]; then ok "VERSION is SemVer ($ver)"; else bad "VERSION is SemVer" "got [$ver]"; fi

# #23: the advanced example must be valid JSON and must document every config.json key parse_config
# reads — so the reference can't silently drift from the code.
echo "== unit: config.reference.json (#23) =="
ADV="$ROOT/config.reference.json"
if jq -e . "$ADV" >/dev/null 2>&1; then ok "advanced example is valid JSON"; else bad "advanced example is valid JSON" "jq parse failed"; fi
# The advanced example must document the FULL key set both directions — derived from rigforge.sh's own
# "known" list (_warn_unknown_config_keys' typo lint, rigforge.sh:571) rather than hardcoded here twice,
# so either side drifting from the code fails this test. RIG_NAME is documented there as reserved for
# the #1 image seed, not a config.reference.json default — excluded.
known_keys="$(sed -nE 's/^[[:space:]]*local known="([^"]*)".*/\1/p' "$SCRIPT" | head -1)"
[ -n "$known_keys" ] || bad "could not extract the known-keys list from rigforge.sh" "sed found nothing"
known_sorted="$(tr ' ' '\n' <<<"$known_keys" | grep -v '^RIG_NAME$' | sort)"
ref_sorted="$(jq -r 'keys[] | select(. != "_docs")' "$ADV" | sort)"
assert_eq "advanced example documents exactly the keys parse_config knows (#275)" \
    "$(diff <(echo "$known_sorted") <(echo "$ref_sorted") || true)" ""
# The rig label lives in pools[].user and the template is internal, so WORKER_NAME / WORKER_CONFIG_FILE
# / POOL_HOST must NOT appear.
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

# #142/#243: api_allow_from — valid IPv4 OR IPv6 address/CIDR parse (with the right nft family);
# bad octets, prefixes, hostnames, and shell metachars all hard-error (the value reaches an nft
# file, so the per-family charset is the injection guard too).
for good in "192.168.1.10" "10.0.0.0/8"; do
    c="$(mkconf "af_ok_$RANDOM" "{ $POOL, \"api_allow_from\": \"$good\" }")"
    assert_eq "api_allow_from '$good' parses IPv4 (#142)" "$(parse_and_print "$c" "$ROOT" API_ALLOW_FROM)" "$good"
    assert_eq "api_allow_from '$good' -> family ip (#243)" "$(parse_and_print "$c" "$ROOT" API_ALLOW_FAMILY)" "ip"
done
# incl. the all-zeros address (::) and the v6 default route (::/0 — permissive but valid) as edges.
for good6 in "fd00::/64" "2001:db8::5" "fe80::1" "::1" "::" "::/0"; do
    c="$(mkconf "af6_ok_$RANDOM" "{ $POOL, \"api_allow_from\": \"$good6\" }")"
    assert_eq "api_allow_from '$good6' parses IPv6 (#243)" "$(parse_and_print "$c" "$ROOT" API_ALLOW_FROM)" "$good6"
    assert_eq "api_allow_from '$good6' -> family ip6 (#243)" "$(parse_and_print "$c" "$ROOT" API_ALLOW_FAMILY)" "ip6"
done
# The IPv6 guard is charset + prefix-bound only — a charset-valid but STRUCTURALLY-invalid address
# (>8 groups) deliberately passes parse and is caught fail-closed at `nft -f` load (see the
# install_api_firewall rejection test). Pin that boundary so the split of responsibility is a
# conscious contract, not an accident. (#243/scan)
c="$(mkconf af6_toolong "{ $POOL, \"api_allow_from\": \"1:2:3:4:5:6:7:8:9\" }")"
assert_eq "structurally-invalid IPv6 passes parse's charset guard; nft fail-closes it (#243)" "$(parse_and_print "$c" "$ROOT" API_ALLOW_FAMILY)" "ip6"
# scan/#243: an IPv6 allow_from with IPv4 (default) binds is a silent no-op — warn, don't fail.
c="$(mkconf ipv6_nobind "{ $POOL, \"api\": \"enabled\", \"api_allow_from\": \"fd00::/64\" }")"
w6="$( (
    source "$SCRIPT"
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" parse_config 2>&1 >/dev/null
))"
assert_contains "IPv6 allow_from + IPv4 bind warns of the no-op scope (#243)" "$w6" "aren't reachable over IPv6"
c="$(mkconf ipv6_bound "{ $POOL, \"api\": \"enabled\", \"api_allow_from\": \"fd00::/64\", \"api_bind\": \"::\" }")"
w6b="$( (
    source "$SCRIPT"
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" parse_config 2>&1 >/dev/null
))"
assert_absent "IPv6 allow_from + :: bind: no warn (#243)" "$w6b" "aren't reachable over IPv6"
for bad in "256.1.1.1" "1.2.3.4/33" "fd00::/200" "xyz::1" "stack-host.lan" "1.2.3.4; rm -rf /" "fd00::/64 accept; drop"; do
    c="$(mkconf "af_bad_$RANDOM" "{ $POOL, \"api_allow_from\": \"$bad\" }")"
    parse_rc "$c" "$ROOT"
    assert_rc "api_allow_from '$bad' rejected (#142/#243)" "$?" "1"
done

# #140: miner_user — valid name parses; root and malformed names hard-error; absent = empty.
c="$(mkconf mu_ok "{ $POOL, \"miner_user\": \"xmrig\" }")"
assert_eq "miner_user parses (#140)" "$(parse_and_print "$c" "$ROOT" MINER_USER)" "xmrig"
c="$(mkconf mu_root "{ $POOL, \"miner_user\": \"root\" }")"
parse_rc "$c" "$ROOT"
assert_rc "miner_user=root rejected (#140)" "$?" "1"
c="$(mkconf mu_bad "{ $POOL, \"miner_user\": \"Bad!Name\" }")"
parse_rc "$c" "$ROOT"
assert_rc "malformed miner_user rejected (#140)" "$?" "1"
c="$(mkconf mu_none "{ $POOL }")"
assert_eq "miner_user absent -> empty (run as root) (#140)" "$(parse_and_print "$c" "$ROOT" MINER_USER)" ""

echo "== black-box: install_api_firewall renders + tears down the nft table (#142) =="
FW="$(mktemp -d "$SANDBOX/fw.XXXXXX")"
run_fw() { # <allow_from> <api_mode>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        WORKER_ROOT="$FW"
        API_ALLOW_FROM="$1"
        API_MODE="$2"
        API_PORT=8081
        set +e
        PATH="$STUBS:$PATH" CALL_LOG="$FW/calls.log" install_api_firewall 2>&1
    )
}
: >"$FW/calls.log"
out="$(run_fw "192.168.1.10" disabled)"
assert_eq "firewall: nft file written when api_allow_from set (#142)" "$([ -f "$FW/api-firewall.nft" ] && echo y || echo n)" "y"
nft_body="$(cat "$FW/api-firewall.nft")"
assert_contains "firewall: own inet rigforge table (#142)" "$nft_body" "table inet rigforge"
assert_contains "firewall: loopback always accepted (#142)" "$nft_body" 'iifname "lo" accept'
assert_contains "firewall: the configured source is accepted (#142)" "$nft_body" "ip saddr 192.168.1.10 accept"
assert_contains "firewall: :8080 guarded, others dropped (#142)" "$nft_body" "tcp dport { 8080 }"
assert_contains "firewall: applied via nft -f (#142)" "$(cat "$FW/calls.log")" "[nft] -f"
# API enabled -> :8081 joins the guarded set.
run_fw "192.168.1.0/24" enabled >/dev/null
assert_contains "firewall: sister-API port joins the set when enabled (#142)" "$(cat "$FW/api-firewall.nft")" "8080, 8081"
# Cleared -> table destroyed, file removed.
: >"$FW/calls.log"
run_fw "" disabled >/dev/null
assert_eq "firewall: file removed when cleared (#142)" "$([ -f "$FW/api-firewall.nft" ] && echo y || echo n)" "n"
assert_contains "firewall: table destroyed on teardown (#142)" "$(cat "$FW/calls.log")" "[nft] destroy table inet rigforge"
# #243: an IPv6 api_allow_from renders an `ip6 saddr` rule (the inet table carries both families).
run_fw6() {
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        WORKER_ROOT="$FW"
        API_ALLOW_FROM="$1"
        API_ALLOW_FAMILY="$2"
        API_MODE=disabled
        API_PORT=8081
        set +e
        PATH="$STUBS:$PATH" CALL_LOG="$FW/calls.log" install_api_firewall >/dev/null 2>&1
        cat "$FW/api-firewall.nft" 2>/dev/null
    )
}
assert_contains "firewall: IPv6 source renders ip6 saddr (#243)" "$(run_fw6 "fd00::/64" ip6)" "ip6 saddr fd00::/64 accept"
assert_contains "firewall: IPv4 source still renders ip saddr (#243)" "$(run_fw6 "10.0.0.9" ip)" "ip saddr 10.0.0.9 accept"
# nft missing while enabled -> hard error (never silently leave the port open thinking it's guarded).
NONFT="$(mktemp -d "$SANDBOX/nonft.XXXXXX")"
for cmd in sudo tee; do cp "$STUBS/$cmd" "$NONFT/" 2>/dev/null || true; done
out="$( (
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$FW"
    API_ALLOW_FROM=10.0.0.1
    set +e
    PATH="$NONFT" install_api_firewall 2>&1
))"
assert_contains "firewall: missing nft is a hard error, not a silent no-guard (#142)" "$out" "install nftables"
# scan: nft REJECTING the ruleset (not just missing) must also fail closed. A charset-valid but
# structurally-invalid IPv6 can pass parse_config's guard yet make `nft -f` fail; install_api_firewall
# now checks that exit and errors, instead of `apply`'s `|| true` swallowing it + a false success log.
BADNFT="$(mktemp -d "$SANDBOX/badnft.XXXXXX")"
printf '#!/usr/bin/env bash\n[ "$1" = -f ] && exit 1\nexit 0\n' >"$BADNFT/nft"
chmod +x "$BADNFT/nft"
fwrej="$( (
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$FW"
    API_ALLOW_FROM="fd00::/64"
    API_ALLOW_FAMILY=ip6
    API_MODE=disabled
    API_PORT=8081
    set +e
    PATH="$BADNFT:$STUBS:$PATH" install_api_firewall 2>&1
))"
assert_contains "firewall: nft load rejection fails closed (scan)" "$fwrej" "FAILED to load"
assert_absent "firewall: no false 'active' log when nft rejects the ruleset (scan)" "$fwrej" "firewall active"

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
# Security hardening (audit 2026-07-10): the network-facing unit drops root via DynamicUser and
# reads the 0600 config through a systemd credential (root loads it, the sandbox user reads it).
assert_eq "server never runs as root (DynamicUser) (#sec)" "$(grep -c '^DynamicUser=yes$' "$APS/systemd/rigforge-api.service")" "1"
assert_contains "server reads the token via LoadCredential, not the 0600 file (#sec)" "$(cat "$APS/systemd/rigforge-api.service")" "LoadCredential=config:"
assert_contains "server ExecStart points at the credential copy (#sec)" "$(cat "$APS/systemd/rigforge-api.service")" '${CREDENTIALS_DIRECTORY}/config'
assert_eq "credential var survives the envsubst render un-expanded (#sec)" "$(grep -c 'CREDENTIALS_DIRECTORY' "$APS/systemd/rigforge-api.service")" "2"
assert_contains "server caps request-arrival time (slowloris) (#sec)" "$(cat "$ROOT/util/api-server.py")" "Handler.timeout"
assert_contains "token compare is constant-time (#sec)" "$(cat "$ROOT/util/api-server.py")" "hmac.compare_digest"
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
assert_eq "/health wire contract: exact key set" "$(jq -cS 'keys' "$APIQ/data/health.json")" '["clock_pct_of_boost","firmware","governor","hugepages_1g","hugepages_total","msr","ram","service_active","smt","throttling","watchdog","xmp"]'
assert_eq "/tune wire contract: exact key set" "$(jq -cS 'keys' "$APIQ/data/tune.json")" '["applied","autotune","candidates_tried","last_best_hs","target"]'
# #212: watchdog state on the wire. Disabled (no key in config) -> the one-field object.
assert_eq "watchdog disabled -> {mode: disabled} (#212)" "$(jq -cS '.rigforge.watchdog' "$APIQ/data/summary.json")" '{"mode":"disabled"}'
# Enabled with a thermal hold + one strike: the API must explain the stopped miner.
printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "h:3333"}], "watchdog": "enabled", "max_temp_c": 90 }\n' "$APIQ" >"$APIQ/config-wd.json"
touch "$APIQ/home/worker/watchdog.thermal-hold"
printf '1\n' >"$APIQ/home/worker/watchdog.fails"
run_refresh "CONFIG_JSON=$APIQ/config-wd.json TUNE_TEMP_CMD='echo 97.2'"
assert_eq "watchdog hold: thermal_hold true (#212)" "$(jq -r '.rigforge.watchdog.thermal_hold' "$APIQ/data/summary.json")" "true"
assert_eq "watchdog hold: resume threshold on the wire (#212)" "$(jq -r '.rigforge.watchdog.resumes_below_c' "$APIQ/data/summary.json")" "85"
assert_eq "watchdog hold: live temp on the wire (#212)" "$(jq -r '.rigforge.watchdog.temp_c' "$APIQ/data/summary.json")" "97.2"
assert_eq "watchdog hold: strike count (#212)" "$(jq -r '.rigforge.watchdog.strikes' "$APIQ/data/summary.json")" "1"
assert_eq "/health names the thermal hold (#212)" "$(jq -r '.watchdog.thermal_hold' "$APIQ/data/health.json")" "true"
# Garbled state files degrade to defaults, never fail the refresh.
printf 'xx\n' >"$APIQ/home/worker/watchdog.fails"
run_refresh "CONFIG_JSON=$APIQ/config-wd.json"
assert_eq "garbled strike file -> 0, refresh survives (#212)" "$(jq -r '.rigforge.watchdog.strikes' "$APIQ/data/summary.json")" "0"
rm -f "$APIQ/home/worker/watchdog.thermal-hold" "$APIQ/home/worker/watchdog.fails"
run_refresh 'API_CMD="printf %s \"\""'
assert_eq "xmrig down: summary still produced with the marker" "$(jq -r '.rigforge.xmrig_api' "$APIQ/data/summary.json")" "unreachable"
printf '{broken' >"$APIQ/home/worker/tune-overrides.json"
run_refresh
assert_eq "corrupt tune-overrides -> applied null, not a crash" "$(jq -r '.applied' "$APIQ/data/tune.json")" "null"
rm -f "$APIQ/home/worker/tune-overrides.json"
# #346: the last control outcome mirrored into the feed as rigforge.control — pithead's poller catches
# a late terminal outcome on the open read feed instead of a new authenticated dial to the control port.
# A realistic full status.json (the _control_status shape): the mirror picks exactly the three keys.
CTL346="$(mktemp -d "$SANDBOX/ctl346.XXXXXX")"
printf '%s' '{"status":"rolled_back","change_id":"abc0123456789def","source":"control","applied_at":"2026-01-01T00:00:00Z","changed_keys":["DONATION"],"reason":"miner did not return to a live hashrate; rolled back and live","backup":"/b","warnings":[]}' >"$CTL346/status.json"
run_refresh "RIGFORGE_CONTROL_STATE=$CTL346"
assert_eq "control mirror: exactly {change_id, status, reason} on the feed (#346)" "$(jq -cS '.rigforge.control' "$APIQ/data/summary.json")" '{"change_id":"abc0123456789def","reason":"miner did not return to a live hashrate; rolled back and live","status":"rolled_back"}'
# No status.json (a rig that never took a control change, or control disabled) -> null, feed intact.
run_refresh "RIGFORGE_CONTROL_STATE=$CTL346/absent"
assert_eq "control mirror: no status.json -> null (#346)" "$(jq -c '.rigforge.control' "$APIQ/data/summary.json")" "null"
# Malformed status.json -> null, and the refresh still writes the feed.
printf '{broken' >"$CTL346/status.json"
run_refresh "RIGFORGE_CONTROL_STATE=$CTL346"
assert_eq "control mirror: malformed status.json -> null, refresh survives (#346)" "$(jq -c '.rigforge.control' "$APIQ/data/summary.json")" "null"
# #276 (item 5): each `printf | jq ... && mv` (rigforge.sh:4233-4235) is independently atomic — a jq
# failure on ONE file must not corrupt or block the others. Break _api_rigforge_block so specifically
# health.json's own extraction (`.health + {watchdog: .watchdog}`) fails (health is a string, not an
# object -> jq type error), while the rest of the block stays valid JSON.
_rf_broken_health_block() {
    jq -n --arg v "x" --arg xv "x" --arg xc "x" \
        '{version: $v, xmrig_version: $xv, xmrig_commit: $xc, tune: {applied: true}, power: null, health: "BROKEN", watchdog: {mode: "disabled"}, config: {}, config_meta: {}}'
}
oldhealth="$(cat "$APIQ/data/health.json")"
run_refresh '_api_rigforge_block() { _rf_broken_health_block; }'
assert_eq "api-refresh: a broken health block leaves health.json serving the previous content (#276)" "$(cat "$APIQ/data/health.json")" "$oldhealth"
assert_eq "api-refresh: tune.json still updates despite the health failure (#276)" "$(jq -r '.applied' "$APIQ/data/tune.json")" "true"
assert_eq "api-refresh: summary.json still updates despite the health failure (#276)" "$(jq -r '.rigforge.xmrig_version' "$APIQ/data/summary.json")" "x"
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

echo "== black-box: api-server IPv6 dual-stack bind (#243) =="
if command -v python3 >/dev/null 2>&1 && python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1",0)); s.close()' 2>/dev/null; then
    V6="$(mktemp -d "$SANDBOX/v6.XXXXXX")"
    printf '%s' '{"hashrate":{"total":[4242.5]}}' >"$V6/summary.json"
    printf '%s' '{}' >"$V6/health.json"
    printf '%s' '{}' >"$V6/tune.json"
    printf '{ "pools":[{"url":"h:3333"}], "ACCESS_TOKEN":"tok-v6" }\n' >"$V6/config.json"
    V6PORT=$((20000 + RANDOM % 20000))
    python3 "$ROOT/util/api-server.py" "::" "$V6PORT" "$V6" "$V6/config.json" &
    V6PID=$!
    v6up=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -s -g -o /dev/null --max-time 2 -H "Authorization: Bearer tok-v6" "http://[::1]:$V6PORT/health" 2>/dev/null && {
            v6up=1
            break
        }
        sleep 0.3
    done
    assert_eq "api-server binds :: and is reachable over IPv6 (#243)" "$v6up" "1"
    assert_eq "IPv6-reachable api-server serves the summary (#243)" "$(curl -fsS -g --max-time 5 -H 'Authorization: Bearer tok-v6' "http://[::1]:$V6PORT/2/summary" 2>/dev/null | jq -r '.hashrate.total[0]')" "4242.5"
    # IPV6_V6ONLY=0 -> the same :: socket also answers IPv4 loopback (v4-mapped), so v4 clients still reach it.
    assert_eq "dual-stack :: also answers IPv4 loopback (#243)" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -H 'Authorization: Bearer tok-v6' "http://127.0.0.1:$V6PORT/health" 2>/dev/null)" "200"
    kill "$V6PID" 2>/dev/null || true
    wait "$V6PID" 2>/dev/null || true
else
    echo "  SKIP: no IPv6 loopback / python3 absent — api-server IPv6 bind test (#243)"
fi

# ---------------------------------------------------------------------------
# Writable control path (#236): the producer for pithead #185. Separate opt-in endpoint, fail-closed
# dual auth, an allowlist of mutable keys, an unprivileged staged receiver, and a privileged applier
# that snapshots + validates before it commits and rolls back a change that doesn't come back live.
CFG_236='{ "pools": [{"url":"h:3333"}], "DONATION": 1 }'

echo "== unit: parse_config — control keys + fail-closed dual auth (#236) =="
cm236() { parse_and_print "$1" "$ROOT" CONTROL_MODE; }
c="$(mkconf ctl_def "{ $POOL }")"
assert_eq "control absent -> disabled" "$(cm236 "$c")" "disabled"
assert_eq "control_port defaults to 8082" "$(parse_and_print "$c" "$ROOT" CONTROL_PORT)" "8082"
assert_eq "control_bind defaults to 0.0.0.0" "$(parse_and_print "$c" "$ROOT" CONTROL_BIND)" "0.0.0.0"
c="$(mkconf ctl_off "{ $POOL, \"control\": \"disabled\" }")"
assert_eq "control disabled -> disabled" "$(cm236 "$c")" "disabled"
c="$(mkconf ctl_notok "{ $POOL, \"control\": \"enabled\", \"api_allow_from\": \"10.0.0.5\" }")"
assert_contains "control enabled w/o token hard-errors (fail closed)" "$(parse_fails "$c")" "requires ACCESS_TOKEN"
c="$(mkconf ctl_noallow "{ $POOL, \"control\": \"enabled\", \"ACCESS_TOKEN\": \"tok-1\" }")"
assert_contains "control enabled w/o api_allow_from hard-errors (fail closed)" "$(parse_fails "$c")" "requires api_allow_from"
c="$(mkconf ctl_ok "{ $POOL, \"control\": \"enabled\", \"ACCESS_TOKEN\": \"tok-1\", \"api_allow_from\": \"10.0.0.5\" }")"
assert_eq "control enabled w/ token + source -> enabled" "$(cm236 "$c")" "enabled"
c="$(mkconf ctl_true "{ $POOL, \"control\": true, \"ACCESS_TOKEN\": \"tok-1\", \"api_allow_from\": \"10.0.0.5\" }")"
assert_eq "control legacy true -> enabled" "$(cm236 "$c")" "enabled"
c="$(mkconf ctl_badval "{ $POOL, \"control\": \"maybe\" }")"
assert_contains "control typo hard-errors" "$(parse_fails "$c")" 'Invalid "control" value'
c="$(mkconf ctl_p0 "{ $POOL, \"control_port\": 0 }")"
assert_contains "control_port 0 rejected" "$(parse_fails "$c")" "control_port must be"
c="$(mkconf ctl_pbig "{ $POOL, \"control_port\": 99999 }")"
assert_contains "control_port 99999 rejected" "$(parse_fails "$c")" "control_port must be"
c="$(mkconf ctl_p8080 "{ $POOL, \"control_port\": 8080 }")"
assert_contains "control_port 8080 (XMRig) rejected" "$(parse_fails "$c")" "collides with XMRig"
c="$(mkconf ctl_pcol "{ $POOL, \"control\": \"enabled\", \"ACCESS_TOKEN\": \"tok-1\", \"api_allow_from\": \"10.0.0.5\", \"api\": \"enabled\", \"api_port\": 8082, \"control_port\": 8082 }")"
assert_contains "control_port colliding with the sister API rejected" "$(parse_fails "$c")" "collides with the sister API"
c="$(mkconf ctl_bind "{ $POOL, \"control_bind\": \"nope\" }")"
assert_contains "control_bind non-IP rejected" "$(parse_fails "$c")" "control_bind must be"
c="$(mkconf ctl_keys "{ $POOL, \"control\": \"disabled\", \"control_port\": 8082, \"control_bind\": \"0.0.0.0\" }")"
ctl_warns="$( (
    source "$SCRIPT"
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" parse_config 2>&1 >/dev/null
))"
assert_absent "control* keys are known (no unknown-key warning) (#138/#236)" "$ctl_warns" "unknown key"

# #308: control_upgrade — a SECOND opt-in layered on control, default off, only valid when control is on.
cu308() { parse_and_print "$1" "$ROOT" CONTROL_UPGRADE; }
c="$(mkconf cu_def "{ $POOL }")"
assert_eq "control_upgrade absent -> disabled" "$(cu308 "$c")" "disabled"
c="$(mkconf cu_noctl "{ $POOL, \"control_upgrade\": \"enabled\" }")"
assert_contains "control_upgrade without control hard-errors" "$(parse_fails "$c")" "control_upgrade requires control"
c="$(mkconf cu_ok "{ $POOL, \"control\": \"enabled\", \"ACCESS_TOKEN\": \"tok-1\", \"api_allow_from\": \"10.0.0.5\", \"control_upgrade\": \"enabled\" }")"
assert_eq "control_upgrade enabled (atop control) -> enabled" "$(cu308 "$c")" "enabled"
c="$(mkconf cu_default_off "{ $POOL, \"control\": \"enabled\", \"ACCESS_TOKEN\": \"tok-1\", \"api_allow_from\": \"10.0.0.5\" }")"
assert_eq "control on but control_upgrade absent -> disabled (no silent RCE surface)" "$(cu308 "$c")" "disabled"
c="$(mkconf cu_badval "{ $POOL, \"control\": \"enabled\", \"ACCESS_TOKEN\": \"t\", \"api_allow_from\": \"10.0.0.5\", \"control_upgrade\": \"maybe\" }")"
assert_contains "control_upgrade typo hard-errors" "$(parse_fails "$c")" 'Invalid "control_upgrade" value'
c="$(mkconf cu_known "{ $POOL, \"control_upgrade\": \"disabled\" }")"
cu_warns="$( (
    source "$SCRIPT"
    CONFIG_JSON="$c"
    SCRIPT_DIR="$ROOT"
    set +e
    PATH="$STUBS:$PATH" parse_config 2>&1 >/dev/null
))"
assert_absent "control_upgrade is a known key (no unknown-key warning) (#308)" "$cu_warns" "unknown key"

echo "== black-box: install_control units enable/disable (#236) =="
CPS="$(mktemp -d "$SANDBOX/cps.XXXXXX")"
mkdir -p "$CPS/systemd"
cp "$ROOT/systemd/rigforge-control.service.template" "$ROOT/systemd/rigforge-control-apply.service.template" "$ROOT/systemd/rigforge-control-apply.path.template" "$ROOT/systemd/rigforge-control-upgrade.service.template" "$ROOT/systemd/rigforge-control-upgrade.path.template" "$CPS/systemd/"
cp -R "$ROOT/util" "$CPS/" 2>/dev/null || true
run_control_install() { # <disabled|enabled> [port]
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$CPS"
        SYSTEMD_DIR="$CPS/systemd"
        REAL_USER=rfop
        CONTROL_MODE="$1"
        CONTROL_BIND=0.0.0.0
        CONTROL_PORT="${2:-8082}"
        CONTROL_UPGRADE="${CU:-disabled}" # #308: default off so existing #236 assertions are unchanged
        API_ALLOW_FROM=10.0.0.5
        API_PORT=8081
        ACCESS_TOKEN=tok-secret
        set +e
        PATH="$STUBS:$PATH" install_control 2>&1
    )
}
out="$(run_control_install enabled)"
assert_eq "control enable writes the server unit" "$([ -f "$CPS/systemd/rigforge-control.service" ] && echo y || echo n)" "y"
assert_eq "control enable writes the applier unit" "$([ -f "$CPS/systemd/rigforge-control-apply.service" ] && echo y || echo n)" "y"
assert_eq "control enable writes the path watcher" "$([ -f "$CPS/systemd/rigforge-control-apply.path" ] && echo y || echo n)" "y"
assert_contains "server unit runs control-server.py with the configured bind/port" "$(cat "$CPS/systemd/rigforge-control.service")" "control-server.py 0.0.0.0 8082"
assert_eq "server is unprivileged (DynamicUser)" "$(grep -c '^DynamicUser=yes$' "$CPS/systemd/rigforge-control.service")" "1"
assert_eq "server has a writable StateDirectory spool" "$(grep -c '^StateDirectory=rigforge-control$' "$CPS/systemd/rigforge-control.service")" "1"
assert_contains "applier unit baked with the operator (#reown)" "$(cat "$CPS/systemd/rigforge-control-apply.service")" "RIGFORGE_OPERATOR=rfop"
assert_contains "path watcher globs the pending files" "$(cat "$CPS/systemd/rigforge-control-apply.path")" "PathExistsGlob=/var/lib/rigforge-control/spool/pending-*.json"
assert_absent "no token baked into any control unit" "$(cat "$CPS/systemd/rigforge-control.service" "$CPS/systemd/rigforge-control-apply.service" "$CPS/systemd/rigforge-control-apply.path")" "tok-secret"
out="$(run_control_install enabled 9099)"
assert_contains "control server honours the port override" "$(cat "$CPS/systemd/rigforge-control.service")" "control-server.py 0.0.0.0 9099"
out="$(run_control_install disabled)"
assert_eq "control disable removes the server unit" "$([ -f "$CPS/systemd/rigforge-control.service" ] && echo y || echo n)" "n"
assert_eq "control disable removes the applier unit" "$([ -f "$CPS/systemd/rigforge-control-apply.service" ] && echo y || echo n)" "n"
assert_eq "control disable removes the path watcher" "$([ -f "$CPS/systemd/rigforge-control-apply.path" ] && echo y || echo n)" "n"

# #308: the remote-upgrade units ride ON TOP of control — written only when control_upgrade is also on,
# removed when it's off, and torn down with the control path. The upgrade glob must be DISTINCT from
# the apply glob so an upgrade intent never wakes the config-applier.
out="$(CU=enabled run_control_install enabled)"
assert_eq "control_upgrade on writes the upgrade oneshot" "$([ -f "$CPS/systemd/rigforge-control-upgrade.service" ] && echo y || echo n)" "y"
assert_eq "control_upgrade on writes the upgrade path watcher" "$([ -f "$CPS/systemd/rigforge-control-upgrade.path" ] && echo y || echo n)" "y"
assert_contains "upgrade path globs upgrade-*.json" "$(cat "$CPS/systemd/rigforge-control-upgrade.path")" "PathExistsGlob=/var/lib/rigforge-control/spool/upgrade-*.json"
assert_absent "upgrade path does NOT reuse the apply pending-*.json glob (#308)" "$(cat "$CPS/systemd/rigforge-control-upgrade.path")" "pending-*.json"
assert_contains "upgrade oneshot runs control-upgrade" "$(cat "$CPS/systemd/rigforge-control-upgrade.service")" "rigforge.sh control-upgrade"
assert_contains "upgrade oneshot baked with the operator handback" "$(cat "$CPS/systemd/rigforge-control-upgrade.service")" "RIGFORGE_OPERATOR=rfop"
out="$(CU=disabled run_control_install enabled)"
assert_eq "control_upgrade off removes the upgrade oneshot" "$([ -f "$CPS/systemd/rigforge-control-upgrade.service" ] && echo y || echo n)" "n"
assert_eq "control_upgrade off keeps the apply path (control still on)" "$([ -f "$CPS/systemd/rigforge-control-apply.path" ] && echo y || echo n)" "y"
out="$(CU=enabled run_control_install enabled)"
out="$(run_control_install disabled)"
assert_eq "control disable tears down the upgrade path too (#308)" "$([ -f "$CPS/systemd/rigforge-control-upgrade.path" ] && echo y || echo n)" "n"
run_ctl_fw() { # <api_mode> <control_mode> -> the rendered nft rule
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        WORKER_ROOT="$CPS/wr"
        mkdir -p "$CPS/wr"
        API_ALLOW_FROM=10.0.0.5
        API_MODE="$1"
        API_PORT=8081
        CONTROL_MODE="$2"
        CONTROL_PORT=8082
        set +e
        PATH="$STUBS:$PATH" install_api_firewall >/dev/null 2>&1
        cat "$CPS/wr/api-firewall.nft" 2>/dev/null
    )
}
assert_contains "firewall scopes control_port when control enabled (#236)" "$(run_ctl_fw disabled enabled)" "8082"
assert_absent "firewall omits control_port when control disabled" "$(run_ctl_fw disabled disabled)" "8082"

echo "== unit: _control_commit — validate, backup, merge, atomic (#236) =="
commit_case() { # <config-json> <staged-json> -> "<verb>|don=<d>|pool=<host>|bk=<n>|tmp=<n>"
    local d
    d=$(mktemp -d "$SANDBOX/cc.XXXXXX")
    printf '%s\n' "$1" >"$d/config.json"
    printf '%s' "$2" >"$d/staged.json"
    local out verb
    out=$( (
        source "$SCRIPT"
        CONFIG_JSON="$d/config.json"
        SCRIPT_DIR="$d"
        set +e
        PATH="$STUBS:$PATH" _control_commit "$d/staged.json" "$d/backups"
    ) 2>/dev/null)
    verb="${out%% *}"
    printf '%s|don=%s|pool=%s|bk=%s|tmp=%s' "$verb" \
        "$(jq -r '.DONATION // "-"' "$d/config.json")" \
        "$(jq -r '.pools[0].url // "-"' "$d/config.json")" \
        "$(ls "$d/backups"/config-*.json 2>/dev/null | wc -l | tr -d ' ')" \
        "$(ls "$d/config.json".control.* 2>/dev/null | wc -l | tr -d ' ')"
}
assert_eq "commit: valid scalar change lands + one backup" "$(commit_case "$CFG_236" '{"DONATION":5}')" "committed|don=5|pool=h:3333|bk=1|tmp=0"
assert_eq "commit: pools array replaced" "$(commit_case "$CFG_236" '{"pools":[{"url":"newpool:4444"}]}')" "committed|don=1|pool=newpool:4444|bk=1|tmp=0"
assert_eq "commit: non-writable key rejected, nothing written" "$(commit_case "$CFG_236" '{"ACCESS_TOKEN":"x"}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: invalid value rejected (parse gate), nothing written" "$(commit_case "$CFG_236" '{"DONATION":200}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: non-object rejected" "$(commit_case "$CFG_236" '[1,2]')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: empty object rejected" "$(commit_case "$CFG_236" '{}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: writable+non-writable mix rejected atomically" "$(commit_case "$CFG_236" '{"DONATION":3,"HOME_DIR":"/x"}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
# #257: the control path is a TUNING channel — the applier backstop refuses a staged change that strips
# thermal protection (watchdog disable / out-of-band or unset max_temp_c), while tuning within the band
# still commits. Mirrors util/control-server.py's unsafe_reasons() (the receiver rejects these with 400).
assert_eq "commit: watchdog disable refused (safety #257)" "$(commit_case "$CFG_236" '{"watchdog":"disabled"}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: watchdog false refused (safety #257)" "$(commit_case "$CFG_236" '{"watchdog":false}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: max_temp_c out-of-band refused (safety #257)" "$(commit_case "$CFG_236" '{"max_temp_c":999}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: max_temp_c unset refused (safety #257)" "$(commit_case "$CFG_236" '{"max_temp_c":null}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: watchdog enable still commits (tuning #257)" "$(commit_case "$CFG_236" '{"watchdog":"enabled"}')" "committed|don=1|pool=h:3333|bk=1|tmp=0"
assert_eq "commit: max_temp_c within band still commits (tuning #257)" "$(commit_case "$CFG_236" '{"max_temp_c":80}')" "committed|don=1|pool=h:3333|bk=1|tmp=0"
assert_eq "commit: max_temp_c band floor 40 commits (#257)" "$(commit_case "$CFG_236" '{"max_temp_c":40}')" "committed|don=1|pool=h:3333|bk=1|tmp=0"
assert_eq "commit: max_temp_c band ceiling 110 commits (#257)" "$(commit_case "$CFG_236" '{"max_temp_c":110}')" "committed|don=1|pool=h:3333|bk=1|tmp=0"
assert_eq "commit: max_temp_c 111 just-over refused (#257)" "$(commit_case "$CFG_236" '{"max_temp_c":111}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: max_temp_c non-integer 40.5 refused (#257)" "$(commit_case "$CFG_236" '{"max_temp_c":40.5}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
# #412: the same inevaluable-value defect reached this applier-side SAFETY backstop. `[ "$mt_new" -gt
# 110 ]` returned 2 on a 20-digit value, the `if` read it as false, and a staged max_temp_c that the
# Python receiver rejects outright was COMMITTED here — the one path #257 exists to close. Asserted
# both directly and, below, as a receiver/applier lockstep case, because the two must never disagree.
assert_eq "commit: max_temp_c too large for bash to evaluate refused (safety #412)" "$(commit_case "$CFG_236" '{"max_temp_c":99999999999999999999}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
assert_eq "commit: watchdog invalid 0 rejected — not a silent disable (#257)" "$(commit_case "$CFG_236" '{"watchdog":0}')" "rejected|don=1|pool=h:3333|bk=0|tmp=0"
# #257: the receiver (control-server.py unsafe_reasons) and the applier (_control_commit) must reach
# the SAME safety verdict on every input — the "behavioural drift test" the control-server comment cites.
if command -v python3 >/dev/null 2>&1; then
    recv_verdict() { # <json> -> reject|allow, from the Python receiver's unsafe_reasons()
        python3 -c 'import sys,types,json; s=open(sys.argv[2]).read().split("if __name__")[0]; m=types.ModuleType("cs"); exec(s, m.__dict__); print("reject" if m.unsafe_reasons(json.loads(sys.argv[1])) else "allow")' "$1" "$ROOT/util/control-server.py"
    }
    for scase in '{"watchdog":"disabled"}' '{"watchdog":false}' '{"watchdog":"off"}' '{"max_temp_c":999}' '{"max_temp_c":null}' '{"max_temp_c":39}' '{"max_temp_c":40.5}' '{"max_temp_c":99999999999999999999}' '{"watchdog":"enabled"}' '{"max_temp_c":80}' '{"DONATION":2}'; do
        rv="$(recv_verdict "$scase")"
        av="$(commit_case "$CFG_236" "$scase")"
        av="${av%%|*}"
        want=$([ "$rv" = reject ] && echo rejected || echo committed)
        assert_eq "safety lockstep: receiver==applier for $scase (#257)" "$av" "$want"
    done
else
    echo "  SKIP: python3 absent — receiver/applier safety lockstep (#257)"
fi

# #257: /status carries a warnings[] whenever a change touches thermal protection (even an allowed one),
# so the operator/dashboard can require an extra confirm — additive to the /status shape.
wst="$(mktemp -d "$SANDBOX/wst.XXXXXX")"
(
    source "$SCRIPT"
    _control_status "$wst/s.json" applied cidW "watchdog,DONATION" "" ""
) 2>/dev/null
assert_eq "status: warnings[] flags a watchdog change (#257)" "$(jq -r '.warnings[0]' "$wst/s.json")" "thermal protection changed: watchdog"
(
    source "$SCRIPT"
    _control_status "$wst/s2.json" applied cidT "max_temp_c" "" ""
) 2>/dev/null
assert_eq "status: warnings[] flags a max_temp_c change (#257)" "$(jq -r '.warnings[0]' "$wst/s2.json")" "thermal protection changed: max_temp_c"
(
    source "$SCRIPT"
    _control_status "$wst/s3.json" applied cidP "pools,DONATION" "" ""
) 2>/dev/null
assert_eq "status: no warnings for a non-thermal change (#257)" "$(jq -c '.warnings' "$wst/s3.json")" "[]"
# #255: _control_status also indexes each outcome under changes/<cid>.json so a caller can query it.
csidx="$(mktemp -d "$SANDBOX/csidx.XXXXXX")"
(
    source "$SCRIPT"
    _control_status "$csidx/status.json" applied 0123456789abcdef "DONATION" "" ""
) 2>/dev/null
assert_eq "status: most-recent status.json still written (#255 compat)" "$(jq -r .change_id "$csidx/status.json")" "0123456789abcdef"
assert_eq "status: outcome indexed under changes/<cid>.json (#255)" "$(jq -r .status "$csidx/changes/0123456789abcdef.json" 2>/dev/null)" "applied"
# #276 (item 4): changes/ keeps only the last ~20 outcomes (rigforge.sh:3721's `ls -t ... | tail -n +21`).
# Write 22 distinct outcomes; the first two are separated by real time (sleep) so they're unambiguously
# the oldest by mtime regardless of the remaining 20's write order — exactly enough survivors (20) that
# their mutual ordering doesn't matter.
prd="$(mktemp -d "$SANDBOX/prune.XXXXXX")"
(
    source "$SCRIPT"
    _control_status "$prd/status.json" applied 0000000000000001 "DONATION" "" ""
    sleep 1
    _control_status "$prd/status.json" applied 0000000000000002 "DONATION" "" ""
    sleep 1
    for i in $(seq 3 22); do
        cid=$(printf '%016x' "$i")
        _control_status "$prd/status.json" applied "$cid" "DONATION" "" ""
    done
) 2>/dev/null
assert_eq "changes/ index pruned to exactly 20 outcomes (#276)" "$(ls "$prd/changes"/*.json 2>/dev/null | wc -l | tr -d ' ')" "20"
assert_eq "the oldest outcome is pruned (#276)" "$([ -f "$prd/changes/0000000000000001.json" ] && echo present || echo gone)" "gone"
assert_eq "the 2nd-oldest outcome is pruned (#276)" "$([ -f "$prd/changes/0000000000000002.json" ] && echo present || echo gone)" "gone"
assert_eq "the 1st surviving outcome remains (#276)" "$([ -f "$prd/changes/0000000000000003.json" ] && echo present || echo gone)" "present"
assert_eq "the newest outcome remains (#276)" "$([ -f "$prd/changes/0000000000000016.json" ] && echo present || echo gone)" "present"

# #253: the enriched feed exposes the effective WRITABLE config so the dashboard can prefill/round-trip.
echo "== unit: _api_config_json — effective writable config, secrets masked (#253) =="
cfgblk() { # <config-json> -> the rigforge.config JSON
    local d
    d=$(mktemp -d "$SANDBOX/cfgblk.XXXXXX")
    printf '%s\n' "$1" >"$d/config.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$d/config.json"
        SCRIPT_DIR="$d"
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        _api_config_json
    ) 2>/dev/null
}
C253='{ "pools":[{"url":"stack-host:3333","user":"wallet.rig","pass":"SECRET","keepalive":true,"tls":true,"tls-fingerprint":"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"}], "DONATION":2, "autotune":"perf", "watchdog":"on", "watchdog_interval_min":10, "max_temp_c":85 }'
blk="$(cfgblk "$C253")"
# #415: the mask is now the {"__secret__": true} sentinel, not a deletion. The #253 guarantee is
# unchanged and asserted directly below — the VALUE never appears anywhere in the served block —
# but the FACT that a secret is set is now visible, which is what lets a consumer offer
# "leave blank to keep it" instead of wiping the credential on every pools edit.
assert_eq "config: pool pass masked to the sentinel (#415)" "$(printf '%s' "$blk" | jq -c '.pools[0].pass // "ABSENT"')" '{"__secret__":true}'
assert_eq "config: pool tls-fingerprint masked to the sentinel (#415)" "$(printf '%s' "$blk" | jq -c '.pools[0]."tls-fingerprint" // "ABSENT"')" '{"__secret__":true}'
# The needle's CASE is load-bearing: the mask this feed now emits is the lowercase `__secret__`
# sentinel, so a lowercase needle would match the mask and report a leak that is not one.
assert_absent "config: no pool password anywhere in the served block (#253)" "$blk" "SECRET"
assert_absent "config: no fingerprint anywhere in the served block (#253)" "$blk" "a1b2c3d4e5f6"
# An UNSET secret stays absent — "no marker" is how a consumer tells there is nothing to keep, so a
# marker on a pool that has no password would be a lie the consumer cannot detect (#415).
blkns="$(cfgblk '{ "pools":[{"url":"h:3333","user":"w.rig"}] }')"
assert_eq "config: unset pass has no marker — nothing to keep (#415)" "$(printf '%s' "$blkns" | jq -c '.pools[0] | has("pass")')" "false"
assert_eq "config: unset tls-fingerprint has no marker (#415)" "$(printf '%s' "$blkns" | jq -c '.pools[0] | has("tls-fingerprint")')" "false"
assert_eq "config: pool url + user preserved (#253)" "$(printf '%s' "$blk" | jq -r '.pools[0].url + " " + .pools[0].user')" "stack-host:3333 wallet.rig"
assert_eq "config: autotune canonical perf->performance (#253)" "$(printf '%s' "$blk" | jq -r '.autotune')" "performance"
assert_eq "config: watchdog canonical on->enabled (#253)" "$(printf '%s' "$blk" | jq -r '.watchdog')" "enabled"
assert_eq "config: max_temp_c is a plain int (#253)" "$(printf '%s' "$blk" | jq -r '.max_temp_c')" "85"
assert_eq "config: DONATION + interval carried (#253)" "$(printf '%s' "$blk" | jq -r '"\(.DONATION) \(.watchdog_interval_min)"')" "2 10"
blk2="$(cfgblk '{ "pools":[{"url":"h:3333"}] }')"
assert_eq "config: max_temp_c null when unset (#253)" "$(printf '%s' "$blk2" | jq -r '.max_temp_c')" "null"
assert_eq "config: autotune/watchdog default to disabled (#253)" "$(printf '%s' "$blk2" | jq -r '"\(.autotune) \(.watchdog)"')" "disabled disabled"
# round-trip contract: the config block's keys are EXACTLY the control writable allowlist.
assert_eq "config: keys == the control writable allowlist, round-trippable (#253)" "$(printf '%s' "$blk2" | jq -r 'keys_unsorted | sort | join(",")')" "DONATION,autotune,max_temp_c,pools,watchdog,watchdog_interval_min"

# #254: config revision + last-change provenance in the feed (rigforge.config_meta).
echo "== unit: config_meta — revision + last-change provenance (#254) =="
whash() { # <config-json> -> _writable_config_hash
    local d
    d=$(mktemp -d "$SANDBOX/whash.XXXXXX")
    printf '%s\n' "$1" >"$d/config.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$d/config.json"
        SCRIPT_DIR="$d"
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        _writable_config_hash
    ) 2>/dev/null
}
metablk() { # <config-json> [source] [change_id] -> _api_config_meta_json after an optional stamp
    local d
    d=$(mktemp -d "$SANDBOX/cmeta.XXXXXX")
    printf '%s\n' "$1" >"$d/config.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$d/config.json"
        SCRIPT_DIR="$d"
        CONFIG_META_FILE="$d/meta.json"
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        [ -n "${2:-}" ] && _stamp_config_meta "$2" "${3:-}"
        _api_config_meta_json
    ) 2>/dev/null
}
C254A='{ "pools":[{"url":"h:3333"}], "DONATION":1 }'
r1="$(whash "$C254A")"
assert_eq "config_meta: revision is a stable content hash (#254)" "$([ -n "$r1" ] && [ "$r1" = "$(whash "$C254A")" ] && echo stable || echo unstable)" "stable"
assert_eq "config_meta: revision changes iff the writable config changes (#254)" "$([ "$r1" != "$(whash '{ "pools":[{"url":"h:3333"}], "DONATION":2 }')" ] && echo changed || echo same)" "changed"
# canonicalized: perf==performance, on==enabled -> same effective config -> SAME revision (no false bump)
assert_eq "config_meta: aliases hash identically, perf==performance (#254)" "$([ "$(whash '{ "pools":[{"url":"h:3333"}], "autotune":"perf" }')" = "$(whash '{ "pools":[{"url":"h:3333"}], "autotune":"performance" }')" ] && echo same || echo differ)" "same"
# hash is over the UNMASKED config, so a pool-password change bumps revision even though the feed masks pass
assert_eq "config_meta: a pool pass change bumps the revision (#254)" "$([ "$(whash '{ "pools":[{"url":"h:3333","pass":"a"}] }')" != "$(whash '{ "pools":[{"url":"h:3333","pass":"b"}] }')" ] && echo changed || echo same)" "changed"
assert_eq "config_meta: fresh rig -> revision present, source null (#254)" "$(metablk "$C254A" | jq -r '"\(.revision|length>0) \(.source) \(.last_change_id)"')" "true null null"
assert_eq "config_meta: control stamp records source + change_id + changed_at (#254)" "$(metablk "$C254A" control abc0123456789def | jq -r '"\(.source) \(.last_change_id) \(.changed_at!=null)"')" "control abc0123456789def true"
assert_eq "config_meta: local source recorded (#254)" "$(metablk "$C254A" local | jq -r .source)" "local"
assert_eq "config_meta: restore source recorded (#254)" "$(metablk "$C254A" restore | jq -r .source)" "restore"
# a re-stamp of the SAME writable config is a no-op: keeps the prior provenance (a no-op apply/autotune restart never false-bumps).
noopmeta="$(
    d=$(mktemp -d "$SANDBOX/noop.XXXXXX")
    printf '%s\n' "$C254A" >"$d/config.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$d/config.json"
        SCRIPT_DIR="$d"
        CONFIG_META_FILE="$d/meta.json"
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        _stamp_config_meta control cid0000000000abcd
        _stamp_config_meta local
        _api_config_meta_json | jq -r '"\(.source) \(.last_change_id)"'
    ) 2>/dev/null
)"
assert_eq "config_meta: a re-stamp of the same config keeps the prior source/id (no false bump) (#254)" "$noopmeta" "control cid0000000000abcd"

# contract pin (#253/#254 + v1.7.0 backward-compat): the enriched rigforge block emits the full v1.7.0
# key set PLUS the additive config + config_meta. pithead#209 reads these off the LIVE feed, so unit
# tests of the helpers aren't enough — assert the assembled block actually carries them.
rfblk="$(
    rfd=$(mktemp -d "$SANDBOX/rfblk.XXXXXX")
    printf '1.8.0' >"$rfd/VERSION"
    printf '%s\n' '{ "pools":[{"url":"h:3333","pass":"PWNEEDLE415"}] }' >"$rfd/config.json"
    (
        source "$SCRIPT"
        CONFIG_JSON="$rfd/config.json"
        SCRIPT_DIR="$rfd"
        CONFIG_META_FILE="$rfd/meta.json"
        set +e
        PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
        _api_rigforge_block ""
    ) 2>/dev/null
)"
assert_eq "feed: rigforge block carries the v1.7.0 keys + config + config_meta (contract)" "$(printf '%s' "$rfblk" | jq -r '[has("version"), has("xmrig_version"), has("xmrig_commit"), has("tune"), has("power"), has("health"), has("watchdog"), has("config"), has("config_meta")] | all')" "true"
assert_eq "feed: served config still masks pass + config_meta has a revision (contract)" "$(printf '%s' "$rfblk" | jq -r '(.config.pools[0].pass == {"__secret__": true}) and ((.config_meta.revision | length) > 0)')" "true"
# #415 changed the mask from a deletion to a marker, so re-state the guarantee the old shape carried
# for free: whatever the mask looks like, the password must not appear anywhere in the served block.
# The needle is the literal above and deliberately not the word "secret": the sentinel this feed now
# emits is `__secret__`, so a needle of "secret" would match the MASK and report a leak that is not
# one — the assertion has to be able to tell the two apart to mean anything.
assert_absent "feed: no pool password anywhere in the served block (contract)" "$rfblk" "PWNEEDLE415"
# missing staged file -> unreadable branch; broken config -> merge-fail branch
missing_d=$(mktemp -d "$SANDBOX/cm.XXXXXX")
printf '%s\n' "$CFG_236" >"$missing_d/config.json"
assert_contains "commit: unreadable staged file rejected" "$( (
    source "$SCRIPT"
    CONFIG_JSON="$missing_d/config.json"
    SCRIPT_DIR="$missing_d"
    set +e
    PATH="$STUBS:$PATH" _control_commit "$missing_d/nope.json" "$missing_d/bk"
) 2>/dev/null)" "rejected"
broken_d=$(mktemp -d "$SANDBOX/cb.XXXXXX")
printf '%s' '{broken json' >"$broken_d/config.json"
printf '%s' '{"DONATION":2}' >"$broken_d/s.json"
assert_contains "commit: unmergeable base config rejected (not committed)" "$( (
    source "$SCRIPT"
    CONFIG_JSON="$broken_d/config.json"
    SCRIPT_DIR="$broken_d"
    set +e
    PATH="$STUBS:$PATH" _control_commit "$broken_d/s.json" "$broken_d/bk"
) 2>/dev/null)" "rejected"
# recovery: the backup is a faithful copy of the PRE-change config
recov="$(mktemp -d "$SANDBOX/rec.XXXXXX")"
printf '%s\n' "$CFG_236" >"$recov/config.json"
printf '%s' '{"DONATION":9}' >"$recov/s.json"
(
    source "$SCRIPT"
    CONFIG_JSON="$recov/config.json"
    SCRIPT_DIR="$recov"
    set +e
    PATH="$STUBS:$PATH" _control_commit "$recov/s.json" "$recov/backups" >/dev/null 2>&1
)
assert_eq "commit: backup preserves the OLD config for recovery" "$(jq -r '.DONATION' "$recov/backups"/config-*.json)" "1"
assert_eq "commit: new config carries the change" "$(jq -r '.DONATION' "$recov/config.json")" "9"
# CRITICAL regression (2026-07-11 security review): a commit must NOT downgrade config.json off 0600
# (mv inherits the candidate's mode; without a chmod the live ACCESS_TOKEN + pool creds go
# world-readable on every control-apply).
modechk="$(mktemp -d "$SANDBOX/mode.XXXXXX")"
printf '%s\n' "$CFG_236" >"$modechk/config.json"
chmod 600 "$modechk/config.json"
printf '%s' '{"DONATION":6}' >"$modechk/s.json"
(
    source "$SCRIPT"
    CONFIG_JSON="$modechk/config.json"
    SCRIPT_DIR="$modechk"
    set +e
    PATH="$STUBS:$PATH" _control_commit "$modechk/s.json" "$modechk/bk" >/dev/null 2>&1
)
assert_eq "commit: config.json stays 0600 (secrets not world-readable)" "$(stat -c '%a' "$modechk/config.json" 2>/dev/null || stat -f '%Lp' "$modechk/config.json")" "600"
assert_eq "commit: the backup snapshot is owner-only 0600" "$(stat -c '%a' "$modechk/bk"/config-*.json 2>/dev/null || stat -f '%Lp' "$modechk/bk"/config-*.json)" "600"
# MEDIUM regression: a rejected reason must not echo a raw config value (parse_config value-bearing
# errors quote the value; the reason is truncated at the first quote before it reaches 0644 status.json).
redd="$(mktemp -d "$SANDBOX/red.XXXXXX")"
printf '%s\n' "$CFG_236" >"$redd/config.json"
printf '%s' '{"pools":[{"url":"SECRETMARKER host:3333"}]}' >"$redd/s.json"
red_out="$( (
    source "$SCRIPT"
    CONFIG_JSON="$redd/config.json"
    SCRIPT_DIR="$redd"
    set +e
    PATH="$STUBS:$PATH" _control_commit "$redd/s.json" "$redd/bk"
) 2>/dev/null)"
assert_contains "reject: invalid pool change rejected" "$red_out" "rejected"
assert_absent "reject reason does not echo the raw config value" "$red_out" "SECRETMARKER"
# tls-fingerprint is a per-pool field (not a top-level key): it is writable AS PART OF a pools change.
tlsfp="$(printf 'a%.0s' $(seq 1 64))"
assert_eq "commit: pools change carrying tls-fingerprint lands" "$(commit_case "$CFG_236" "{\"pools\":[{\"url\":\"h:3333\",\"tls\":true,\"tls-fingerprint\":\"$tlsfp\"}]}")" "committed|don=1|pool=h:3333|bk=1|tmp=0"

# #415: a pools change must not wipe the pool credential. The feed never serves the password, so the
# only pools array a consumer of it can send back either carries the {"__secret__": true} sentinel or
# omits `pass` — and jq's `*` replaces arrays wholesale, after which parse_config defaults a missing
# `pass` to "x". Both shapes must now preserve the stored secret; an explicit value must still
# replace it; and a sentinel that resolves to nothing must be REJECTED, never quietly dropped.
echo "== unit: _control_commit — masked pool secrets survive a pools edit (#415) =="
FP415="$(printf 'b%.0s' $(seq 1 64))"
CFG_415="{ \"pools\": [{\"url\":\"h:3333\",\"user\":\"w.rig\",\"pass\":\"STOREDPW\",\"tls\":true,\"tls-fingerprint\":\"$FP415\"},{\"url\":\"h2:3333\",\"pass\":\"SECONDPW\"}], \"DONATION\": 1 }"
secret_case() { # <config-json> <staged-json> -> "<verb>|pass=<p>|fp=kept|other|ABSENT|marker=<n>"
    local d
    d=$(mktemp -d "$SANDBOX/sc.XXXXXX")
    printf '%s\n' "$1" >"$d/config.json"
    printf '%s' "$2" >"$d/staged.json"
    local out
    out=$( (
        source "$SCRIPT"
        CONFIG_JSON="$d/config.json"
        SCRIPT_DIR="$d"
        set +e
        PATH="$STUBS:$PATH" _control_commit "$d/staged.json" "$d/backups"
    ) 2>/dev/null)
    printf '%s|pass=%s|fp=%s|marker=%s' "${out%% *}" \
        "$(jq -r '.pools[0].pass // "ABSENT"' "$d/config.json")" \
        "$(jq -r --arg f "$FP415" 'if (.pools[0]."tls-fingerprint" // "") == $f then "kept" elif (.pools[0] | has("tls-fingerprint")) then "other" else "ABSENT" end' "$d/config.json")" \
        "$(jq -r '[.. | objects | select(has("__secret__"))] | length' "$d/config.json")"
}
assert_eq "commit: pass OMITTED keeps the stored password (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h:3333","user":"w.rig","tls":true}]}')" "committed|pass=STOREDPW|fp=kept|marker=0"
assert_eq "commit: pass SENTINEL keeps the stored password (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h:3333","user":"w.rig","tls":true,"pass":{"__secret__":true}}]}')" "committed|pass=STOREDPW|fp=kept|marker=0"
assert_eq "commit: fingerprint SENTINEL keeps the stored pin (#415)" "$(secret_case "$CFG_415" "{\"pools\":[{\"url\":\"h:3333\",\"user\":\"w.rig\",\"tls\":true,\"tls-fingerprint\":{\"__secret__\":true}}]}")" "committed|pass=STOREDPW|fp=kept|marker=0"
assert_eq "commit: an explicit password still REPLACES the stored one (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h:3333","user":"w.rig","tls":true,"pass":"NEWPW"}]}')" "committed|pass=NEWPW|fp=kept|marker=0"
assert_eq "commit: an explicit fingerprint still replaces the stored pin (#415)" "$(secret_case "$CFG_415" "{\"pools\":[{\"url\":\"h:3333\",\"user\":\"w.rig\",\"tls\":true,\"tls-fingerprint\":\"$tlsfp\"}]}")" "committed|pass=STOREDPW|fp=other|marker=0"
# Every preserve case above pins a `user`. The common shape on a real rig has no `user` key at all —
# its identity is (url, ""), which is the half of pkey a resolver that only ever matched a non-empty
# user would still get past. Pin both shapes on the second stored pool: it has a password, no user,
# and no fingerprint.
assert_eq "commit: pass OMITTED keeps the password of a pool with no user (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h2:3333"}]}')" "committed|pass=SECONDPW|fp=ABSENT|marker=0"
assert_eq "commit: pass SENTINEL keeps the password of a pool with no user (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h2:3333","pass":{"__secret__":true}}]}')" "committed|pass=SECONDPW|fp=ABSENT|marker=0"
# The stored secret belongs to an (url, user) pair. A sentinel that matches no stored pool is a
# request to keep something that is not there — reject it loudly rather than commit a rig to "x".
assert_eq "commit: sentinel for an unknown pool rejected, config untouched (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"other:4444","pass":{"__secret__":true}}]}')" "rejected|pass=STOREDPW|fp=kept|marker=0"
assert_eq "commit: sentinel rejected when the user changed (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h:3333","user":"OTHERWALLET","pass":{"__secret__":true}}]}')" "rejected|pass=STOREDPW|fp=kept|marker=0"
assert_eq "commit: fingerprint sentinel on a pool with no stored pin rejected (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h2:3333","tls":true,"tls-fingerprint":{"__secret__":true}}]}')" "rejected|pass=STOREDPW|fp=kept|marker=0"
sc_unres="$( (
    source "$SCRIPT"
    d=$(mktemp -d "$SANDBOX/scu.XXXXXX")
    printf '%s\n' "$CFG_415" >"$d/config.json"
    printf '%s' '{"pools":[{"url":"other:4444","pass":{"__secret__":true}}]}' >"$d/staged.json"
    CONFIG_JSON="$d/config.json"
    SCRIPT_DIR="$d"
    set +e
    PATH="$STUBS:$PATH" _control_commit "$d/staged.json" "$d/backups"
) 2>/dev/null)"
assert_contains "commit: the rejection names the unresolvable key (#415)" "$sc_unres" "unresolvable-secret-marker:pass"
# The check is a post-condition on the merged pools, not a scan of the two keys the resolver knows,
# so a marker in ANY pool key is refused rather than written into config.json under a confusing
# error from some later validator that never heard of markers.
assert_eq "commit: a marker in a pool key the resolver does not handle is refused too (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h:3333","user":{"__secret__":true}}]}')" "rejected|pass=STOREDPW|fp=kept|marker=0"
# A pool that never had a secret keeps working: omitting `pass` on a brand-new pool is not an error,
# it just means there is nothing to carry over.
assert_eq "commit: a brand-new pool with no pass still commits (#415)" "$(secret_case "$CFG_415" '{"pools":[{"url":"other:4444"}]}')" "committed|pass=ABSENT|fp=ABSENT|marker=0"
# #408 is untouched: an EXPLICIT empty string is still not "leave it alone".
assert_eq "commit: an explicit empty pass is still rejected, not treated as keep (#415/#408)" "$(secret_case "$CFG_415" '{"pools":[{"url":"h:3333","user":"w.rig","tls":true,"pass":""}]}')" "rejected|pass=STOREDPW|fp=kept|marker=0"

# The end-to-end shape the issue reports: take the masked block the feed actually serves, send its
# `pools` straight back as a control change (the only thing a consumer of that feed CAN send), and
# require the stored password to come out byte-identical. This is the round-trip that used to leave
# the rig mining as "x" while reporting success.
rt415="$(mktemp -d "$SANDBOX/rt415.XXXXXX")"
printf '%s\n' "$CFG_415" >"$rt415/config.json"
rt_pools="$( (
    source "$SCRIPT"
    CONFIG_JSON="$rt415/config.json"
    SCRIPT_DIR="$rt415"
    set +e
    PATH="$STUBS:$PATH" parse_config >/dev/null 2>&1
    _api_config_json
) 2>/dev/null | jq -c '{pools: .pools}')"
assert_contains "round-trip: the feed's pools carry the sentinel, not the value (#415)" "$rt_pools" '"__secret__":true'
assert_absent "round-trip: the feed's pools carry no password (#415)" "$rt_pools" "STOREDPW"
assert_eq "round-trip: replaying the feed's own pools preserves the password (#415)" "$(secret_case "$CFG_415" "$rt_pools")" "committed|pass=STOREDPW|fp=kept|marker=0"
# The stated tie-break: on a duplicate (url, user) pair the FIRST-declared stored pool wins — the
# same rule Pithead uses restoring its per-worker token sentinels. Asserted rather than assumed,
# since it is the only place the lookup can silently pick the wrong credential.
CFG_415D='{ "pools": [{"url":"d:3333","user":"u","pass":"FIRSTPW"},{"url":"d:3333","user":"u","pass":"SECONDPW"}], "DONATION": 1 }'
assert_eq "commit: first-declared pool wins a duplicate (url,user) (#415)" "$(secret_case "$CFG_415D" '{"pools":[{"url":"d:3333","user":"u"}]}')" "committed|pass=FIRSTPW|fp=ABSENT|marker=0"
# The resolve pass is now the only step that can fail here, and it fails LOUDLY rather than falling
# through to the overlay: an unreadable base config makes --slurpfile fail, so there is no stored
# password to carry over and the pools array would otherwise replace wholesale — the exact shape
# this fix exists to prevent. The pre-existing `merge-failed` case cannot reach this branch: it
# stages no `pools`, so the resolver never runs and the failure lands on the overlay instead. Both
# reasons are asserted here so a future edit cannot silently swap one for the other.
smb="$(mktemp -d "$SANDBOX/smb.XXXXXX")"
printf '%s' '{broken json' >"$smb/config.json"
printf '%s' '{"pools":[{"url":"h:3333","pass":{"__secret__":true}}]}' >"$smb/pools.json"
printf '%s' '{"DONATION":2}' >"$smb/nopools.json"
smb_case() { # <staged-file> -> the reject reason
    (
        source "$SCRIPT"
        CONFIG_JSON="$smb/config.json"
        SCRIPT_DIR="$smb"
        set +e
        PATH="$STUBS:$PATH" _control_commit "$1" "$smb/bk"
    ) 2>/dev/null
}
assert_eq "commit: an unreadable base config rejects a pools edit at the resolve (#415)" "$(smb_case "$smb/pools.json")" "rejected secret-merge-failed"
assert_eq "commit: the same base without a pools edit still rejects at the overlay (#415)" "$(smb_case "$smb/nopools.json")" "rejected merge-failed"
assert_eq "commit: neither reject wrote config.json (#415)" "$(cat "$smb/config.json")" '{broken json'
# A backup is a HARD precondition: if the snapshot can't be written, the change is rejected and
# config.json is left untouched (never commit a change we couldn't back up).
bkfail="$(mktemp -d "$SANDBOX/bkf.XXXXXX")"
printf '%s\n' "$CFG_236" >"$bkfail/config.json"
printf '%s' '{"DONATION":4}' >"$bkfail/s.json"
: >"$bkfail/backups" # a FILE where the backups dir must go -> mkdir -p fails
bkf_out="$( (
    source "$SCRIPT"
    CONFIG_JSON="$bkfail/config.json"
    SCRIPT_DIR="$bkfail"
    set +e
    PATH="$STUBS:$PATH" _control_commit "$bkfail/s.json" "$bkfail/backups"
) 2>/dev/null)"
assert_contains "commit: unwritable backup dir -> rejected" "$bkf_out" "rejected backup-failed"
assert_eq "commit: backup failure leaves config.json untouched (donation 1)" "$(jq -r .DONATION "$bkfail/config.json")" "1"

echo "== unit: _control_fast_path_eligible — closed allowlist classification (#381) =="
fpe() { # <keys-csv> -> eligible|not
    (
        source "$SCRIPT"
        set +e
        if _control_fast_path_eligible "$1"; then echo eligible; else echo not; fi
    )
}
assert_eq "single restart-free key: watchdog_interval_min -> eligible" "$(fpe "watchdog_interval_min")" "eligible"
assert_eq "single restart-free key: max_temp_c -> eligible" "$(fpe "max_temp_c")" "eligible"
assert_eq "both restart-free keys together -> eligible" "$(fpe "max_temp_c,watchdog_interval_min")" "eligible"
assert_eq "pools alone (own xmrig config) -> not eligible" "$(fpe "pools")" "not"
assert_eq "DONATION alone (own xmrig config) -> not eligible" "$(fpe "DONATION")" "not"
assert_eq "autotune alone (unaudited install_* path) -> not eligible" "$(fpe "autotune")" "not"
assert_eq "watchdog alone (unaudited install_* path) -> not eligible" "$(fpe "watchdog")" "not"
# Mutation this catches: the ALL-keys-must-qualify subset check loosened to an ANY-key check — a
# restart-free key riding alongside DONATION would wrongly clear the whole change for the fast path.
assert_eq "mixed restart-free + non-restart-free -> not eligible" "$(fpe "DONATION,max_temp_c")" "not"
# Mutation this catches: the closed-allowlist subset check inverted into a "not on the slow list"
# complement — an unrecognised/future CONTROL_WRITABLE_KEYS addition would then wrongly pass.
assert_eq "unrecognised/future key alone -> not eligible (closed set, not a complement)" "$(fpe "some_future_key")" "not"
assert_eq "empty keys-csv -> not eligible (fail closed)" "$(fpe "")" "not"
assert_eq "control_apply's jq-failure sentinel '?' -> not eligible (fail closed)" "$(fpe "?")" "not"

# Pin the allowlist's exact membership (mirrors the CONTROL_WRITABLE_KEYS drift guard further below).
# Mutation this catches: the allowlist silently growing (or shrinking) without a matching
# evidence-trail/test update.
fp_keys="$(grep -oE 'CONTROL_FAST_PATH_KEYS="[^"]*"' "$SCRIPT" | head -1 | sed 's/.*="//; s/"//' | tr ' ' '\n' | sort | tr '\n' ' ')"
assert_eq "fast-path allowlist is EXACTLY {max_temp_c, watchdog_interval_min} (#381)" "$fp_keys" "max_temp_c watchdog_interval_min "
# Drift guard: the fast-path allowlist must stay a SUBSET of the control-writable allowlist — a
# fast-path key control_apply couldn't even accept as writable in the first place would be dead code.
ck_keys="$(grep -oE 'CONTROL_WRITABLE_KEYS="[^"]*"' "$SCRIPT" | head -1 | sed 's/.*="//; s/"//' | tr ' ' '\n' | sort | tr '\n' ' ')"
fp_subset_ok=y
for k in $fp_keys; do
    case " $ck_keys " in *" $k "*) ;; *) fp_subset_ok=n ;; esac
done
assert_eq "fast-path allowlist is a subset of the control-writable allowlist (#381)" "$fp_subset_ok" "y"

echo "== unit: _control_do_apply_fast — reuses install_watchdog, skips apply()/xmrig restart (#381) =="
FPA="$(mktemp -d "$SANDBOX/fpa.XXXXXX")"
mkdir -p "$FPA/systemd"
cp "$ROOT/systemd/rigforge-watchdog.service.template" "$ROOT/systemd/rigforge-watchdog.timer.template" "$FPA/systemd/"
fpa_run() { # <watchdog_interval_min> -> "rc=<n>"; side effects: $FPA/apply-called, $FPA/meta.json
    rm -f "$FPA/apply-called" "$FPA/meta.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$FPA"
        SYSTEMD_DIR="$FPA/systemd"
        REAL_USER=rfop
        SERVICE_NAME=xmrig
        CONFIG_JSON="$FPA/config.json"
        CONFIG_META_FILE="$FPA/meta.json"
        WATCHDOG_MODE=enabled
        WATCHDOG_INTERVAL_MIN="$1"
        # Isolate: parse_config would normally derive the globals above from CONFIG_JSON; stub it so
        # this test pins _control_do_apply_fast's OWN behaviour, not parse_config's (covered elsewhere).
        parse_config() { :; }
        apply() {
            echo called >"$FPA/apply-called" 2>/dev/null
            return 0
        }
        RIGFORGE_CONFIG_SOURCE=control
        RIGFORGE_CONFIG_CHANGE_ID=fedcba9876543210
        set +e
        PATH="$STUBS:$PATH" _control_do_apply_fast
        echo "rc=$?"
    )
}
printf '{"pools":[{"url":"h:3333"}],"watchdog":"enabled","watchdog_interval_min":9}\n' >"$FPA/config.json"
out="$(fpa_run 9)"
assert_contains "_control_do_apply_fast returns 0 when the miner service is active" "$out" "rc=0"
assert_eq "_control_do_apply_fast NEVER calls apply() — xmrig is not restarted (#381)" "$([ -f "$FPA/apply-called" ] && echo called || echo not-called)" "not-called"
assert_contains "install_watchdog re-renders the timer with the NEW interval (#381)" "$(cat "$FPA/systemd/rigforge-watchdog.timer")" "OnUnitActiveSec=9min"
assert_eq "config_meta stamped source=control, parity with apply()'s own _stamp_config_meta call (#381)" "$(jq -r .source "$FPA/meta.json" 2>/dev/null)" "control"
assert_eq "config_meta records the change_id, same parity (#381)" "$(jq -r .last_change_id "$FPA/meta.json" 2>/dev/null)" "fedcba9876543210"

# #395: install_watchdog IS this path's entire effect — both fast-path keys reach the rig only
# through it — so swallowing its failure recorded a change as applied that never landed. Two things
# must hold when it fails: a non-zero return (so the caller can roll back), and NO provenance stamp
# (a change that did not take effect must not be recorded as the config in force).
# Mutation this catches: restoring `install_watchdog >/dev/null 2>&1 || true` here — the mutant
# returns rc=0 AND stamps meta.json, reddening both assertions.
fpa_run_unwritable() { # -> "rc=<n>"; templates still readable, units unwritable
    rm -f "$FPA/apply-called" "$FPA/meta.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$FPA"
        SYSTEMD_DIR="$FPA/absent/systemd"
        REAL_USER=rfop
        SERVICE_NAME=xmrig
        CONFIG_JSON="$FPA/config.json"
        CONFIG_META_FILE="$FPA/meta.json"
        WATCHDOG_MODE=enabled
        WATCHDOG_INTERVAL_MIN=9
        parse_config() { :; }
        apply() {
            echo called >"$FPA/apply-called" 2>/dev/null
            return 0
        }
        RIGFORGE_CONFIG_SOURCE=control
        RIGFORGE_CONFIG_CHANGE_ID=fedcba9876543210
        set +e
        PATH="$STUBS:$PATH" _control_do_apply_fast
        echo "rc=$?"
    )
}
out="$(fpa_run_unwritable)"
assert_contains "_control_do_apply_fast fails when the watchdog units cannot be written (#395)" "$out" "rc=1"
assert_eq "a fast path that failed does NOT stamp the change as in force (#395)" "$([ -f "$FPA/meta.json" ] && echo stamped || echo not-stamped)" "not-stamped"

echo "== unit: control_apply + REAL _control_do_apply_fast — run-state criterion, not is-active alone (#381 security review) =="
# The generic systemctl stub always exits 0, so the fpa_run tests above only ever exercise the
# active-before/active-after case. A rig can be LEGITIMATELY stopped when a restart-free change
# lands — a watchdog thermal hold, or an operator's manual stop — and the fast path must not read
# that pre-existing stop as its own failure and roll the change back. This exercises control_apply
# end to end with the REAL _control_do_apply_fast (unlike the marker-stubbed one in ca_exec below) and
# a STATEFUL systemctl stub that answers `is-active` differently across the two calls the function
# makes (before the watchdog reconcile, and after), so the run-state comparison is genuinely tested.
CAF="$(mktemp -d "$SANDBOX/caf.XXXXXX")"
caf_systemctl_stub() { # <rc for the 1st is-active call> <rc for the 2nd+> -> writes $CAF/bin/systemctl
    mkdir -p "$CAF/bin"
    cat >"$CAF/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "[systemctl] \$*" >> "\${CALL_LOG:-/dev/null}"
case "\$*" in
*"is-active"*)
    n=\$(( \$(cat "$CAF/systemctl-calls" 2>/dev/null || echo 0) + 1 ))
    echo "\$n" >"$CAF/systemctl-calls"
    if [ "\$n" -eq 1 ]; then exit $1; else exit $2; fi
    ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$CAF/bin/systemctl"
}
caf_exec() {
    (
        source "$SCRIPT"
        parse_config() { :; } # the live config is already valid; don't re-validate it (matches ca_exec)
        # apply()/_wait_miner_live only matter for the ROLLBACK leg here — already covered in depth by
        # the #236/#276 tests below — so they stay simple stubs; the marker proves whether a rollback
        # (i.e. a restart attempt) was ever reached, which is exactly what a wrongly-tripped fast-path
        # failure would cause.
        apply() {
            echo called >"$CAF/full-apply-called" 2>/dev/null || true
            return "${CAF_APPLY_OK:-0}"
        }
        _wait_miner_live() { return 0; }
        OS_TYPE=Linux
        SCRIPT_DIR="$CAF"
        SYSTEMD_DIR="${CAF_SYSTEMD_DIR:-$CAF/systemd}"
        CONFIG_JSON="$CAF/config.json"
        REAL_USER=rfop
        SERVICE_NAME=xmrig
        WATCHDOG_MODE=enabled
        RIGFORGE_CONTROL_STATE="$CAF/state"
        set +e
        PATH="$CAF/bin:$STUBS:$PATH" control_apply >/dev/null 2>&1
    )
}
caf_run() { # <staged-json> <is-active rc BEFORE> <is-active rc AFTER>
    rm -rf "$CAF"
    mkdir -p "$CAF/systemd" "$CAF/state/spool"
    cp "$ROOT/systemd/rigforge-watchdog.service.template" "$ROOT/systemd/rigforge-watchdog.timer.template" "$CAF/systemd/"
    printf '%s\n' "$CFG_236" >"$CAF/config.json"
    printf '%s' "$1" >"$CAF/state/spool/pending-abc123.json"
    caf_systemctl_stub "$2" "$3"
    caf_exec
}
cfst() { jq -r ".$1" "$CAF/state/status.json" 2>/dev/null; }

# (a) inactive-before, inactive-after (rc 1, 1): a rig thermally held or manually stopped before the
# change. Mutation this catches: reverting the run-state comparison to a naive "is it active NOW"
# check — that mutant reports rc=1 here (not active) and would wrongly roll the change back.
caf_run '{"max_temp_c":90}' 1 1
assert_eq "inactive-before/inactive-after -> status applied, not rolled back (#381)" "$(cfst status)" "applied"
assert_eq "inactive-before/inactive-after -> the new value lands in config.json (#381)" "$(jq -r .max_temp_c "$CAF/config.json")" "90"
assert_eq "inactive-before/inactive-after -> no restart/rollback ever attempted (#381)" "$([ -f "$CAF/full-apply-called" ] && echo called || echo not-called)" "not-called"

# (b) active-before, inactive-after (rc 0, 1): the miner really did go down across this change.
# Guards against the run-state criterion being dropped entirely (e.g. _control_do_apply_fast reverted
# to always returning 0) — a real regression here must still trip the existing rollback.
caf_run '{"max_temp_c":90}' 0 1
assert_eq "active-before/inactive-after -> status rolled_back (#381)" "$(cfst status)" "rolled_back"
assert_eq "active-before/inactive-after -> config restored, max_temp_c unset again (#381)" "$(jq -r .max_temp_c "$CAF/config.json")" "null"
assert_eq "active-before/inactive-after -> rollback re-apply invoked (#381)" "$([ -f "$CAF/full-apply-called" ] && echo called || echo not-called)" "called"

# (c) #395, and the reason this issue exists: the miner is up before AND after (rc 0, 0), so every
# liveness-shaped check this path has says success — but the watchdog units could not be written, so
# the cadence the operator just accepted is NOT the cadence the rig is running. The old code recorded
# "applied" here. This is the end-to-end assertion that the status record stopped lying; it runs the
# REAL _control_do_apply_fast and the REAL install_watchdog, with only the rollback leg stubbed.
# Mutation this catches: any single revert in the #395 chain — install_watchdog returning 0 again, or
# the fast path swallowing it — puts status back to "applied" and reddens the first assertion.
caf_run '{"max_temp_c":90}' 0 0
assert_eq "healthy watchdog render, miner up throughout -> applied (#395 control)" "$(cfst status)" "applied"
CAF_SYSTEMD_DIR="$CAF/absent/systemd" caf_run '{"max_temp_c":90}' 0 0
assert_eq "watchdog units unwritable, miner never down -> rolled_back, NOT applied (#395)" "$(cfst status)" "rolled_back"
# The reason string must name the actual cause. Falling back to the liveness wording here would be a
# fresh lie of the same kind: the miner never left the pool.
assert_contains "the recorded reason names the watchdog, not a liveness failure (#395)" "$(cfst reason)" "watchdog"
assert_absent "the recorded reason does NOT blame the hashrate (#395)" "$(cfst reason)" "live hashrate"
assert_eq "watchdog-failed change -> config restored to pre-change (#395)" "$(jq -r .max_temp_c "$CAF/config.json")" "null"
assert_eq "watchdog-failed change -> the full restart-safe rollback ran (#395)" "$([ -f "$CAF/full-apply-called" ] && echo called || echo not-called)" "called"
# And when the ROLLBACK's own re-apply fails for that same reason, the record must not fall back to
# the liveness wording: a failed apply short-circuits before the liveness wait, so nobody checked it.
# Mutation this catches: dropping the `elif [ -n "$fail_reason" ]` arm — the mutant reports "failed
# to restore liveness" about a miner this test never took down.
CAF_SYSTEMD_DIR="$CAF/absent/systemd" CAF_APPLY_OK=1 caf_run '{"max_temp_c":90}' 0 0
assert_eq "watchdog failure + failed rollback re-apply -> still rolled_back (#395)" "$(cfst status)" "rolled_back"
assert_contains "the reason names the watchdog cause (#395)" "$(cfst reason)" "watchdog"
assert_contains "the reason says the re-apply hit the same failure (#395)" "$(cfst reason)" "re-apply hit the same failure"
assert_absent "it does NOT claim a liveness failure nobody checked (#395)" "$(cfst reason)" "restore liveness"

echo "== unit: control_apply FULL path — a deliberately stopped rig is not rolled back (#396) =="
# The worst case named in #396: an operator raises max_temp_c while the rig is in a thermal hold. Bundle
# it with any non-fast-path key (DONATION here) and the change takes the FULL path, where `apply` — since
# #396 — leaves the held rig stopped. _control_do_apply's old success criterion was the liveness wait
# alone, so it would have read the operator's own hold as THIS change's failure and rolled a perfectly
# good change back; the rollback re-apply would have held the rig too, and the record would then have
# blamed a liveness failure nobody could have observed. Success is "the run-state did not DEGRADE", the
# same criterion _control_do_apply_fast already uses.
#
# The REAL _control_do_apply runs here. apply() is stubbed to a recorder — what is under test is the
# criterion applied to its outcome, not apply's own internals (covered by the black-box tests above) —
# and _wait_miner_live defaults to FAILING, so any mutant that still consults it on a held rig reddens
# the status assertion, not just the call-count one.
CDH="$(mktemp -d "$SANDBOX/cdh.XXXXXX")"
cdh_exec() {
    (
        source "$SCRIPT"
        parse_config() { :; } # the live config is already valid; don't re-validate it (matches caf_exec)
        # CDH_APPLY_RCS is the rc for each successive apply — the change's own, then the rollback
        # re-apply's — so a change that fails on a HELD rig can still have a rollback that succeeds.
        apply() {
            echo called >>"$CDH/apply-calls"
            local n rcs
            n=$(wc -l <"$CDH/apply-calls" | tr -d ' ')
            read -ra rcs <<<"${CDH_APPLY_RCS:-0 0}"
            return "${rcs[$((n - 1))]:-0}"
        }
        _wait_miner_live() {
            echo checked >>"$CDH/live-calls"
            return "${CDH_LIVE_RC:-1}"
        }
        OS_TYPE=Linux
        SCRIPT_DIR="$CDH"
        SYSTEMD_DIR="$CDH/systemd"
        CONFIG_JSON="$CDH/config.json"
        REAL_USER=rfop
        SERVICE_NAME=xmrig
        RIGFORGE_CONTROL_STATE="$CDH/state"
        set +e
        PATH="$CDH/bin:$STUBS:$PATH" control_apply >/dev/null 2>&1
    )
}
cdh_run() { # <word `is-active` prints> <unit installed: y|n>
    rm -rf "$CDH"
    mkdir -p "$CDH/systemd" "$CDH/state/spool" "$CDH/bin"
    printf '%s\n' "$CFG_236" >"$CDH/config.json"
    printf '{"DONATION":2}' >"$CDH/state/spool/pending-abc396.json" # not a fast-path key -> full path
    if [ "$2" = y ]; then : >"$CDH/systemd/xmrig.service"; fi
    cat >"$CDH/bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
*"is-active"*)
    echo "$1"
    [ "$1" = active ] && exit 0 || exit 3
    ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$CDH/bin/systemctl"
    cdh_exec
}
cdhst() { jq -r ".$1" "$CDH/state/status.json" 2>/dev/null; }
# BSD `wc -l` right-pads its count ("       1"), GNU's does not, so the raw output is a string that
# compares equal to the expected count on Linux and not on macOS. `tr -d ' '` is the idiom the rest of
# this file uses for exactly that. The `|| echo 0` fallback cannot live on the pipeline — a missing
# file fails the redirect, `tr` still exits 0, and the fallback would never fire — so the default is
# applied to the captured value instead.
cdh_calls() { # <name> -> how many calls were recorded, 0 when the file was never written
    local n
    n=$(wc -l <"$CDH/$1-calls" 2>/dev/null | tr -d ' ')
    printf '%s' "${n:-0}"
}

# (a) the held rig. Mutation this catches: dropping the run-state guard from _control_do_apply — the
# mutant runs the (failing) liveness wait, records rolled_back, and puts DONATION back to 1.
cdh_run inactive y
assert_eq "held rig -> the change is APPLIED, not rolled back (#396)" "$(cdhst status)" "applied"
assert_eq "held rig -> the new value stays in config.json (#396)" "$(jq -r .DONATION "$CDH/config.json")" "2"
assert_eq "held rig -> the liveness wait is never consulted (#396)" "$(cdh_calls live)" "0"
assert_eq "held rig -> exactly one apply, no rollback re-apply (#396)" "$(cdh_calls apply)" "1"

# (b) the rig really did go down across the change: the pre-existing rollback must still fire. Guards
# against the criterion being widened into "always succeed".
cdh_run active y
assert_eq "a rig that was live and did not come back -> rolled_back (#396 control)" "$(cdhst status)" "rolled_back"
assert_eq "and its config is restored to pre-change (#396 control)" "$(jq -r .DONATION "$CDH/config.json")" "1"
assert_eq "and the liveness wait WAS consulted (#396 control)" "$(cdh_calls live)" "2"

# (c) and (d): the two states that look like a stop and are not. Each must still be judged on liveness.
cdh_run failed y
assert_eq "a FAILED unit is not a hold — still judged on liveness (#396)" "$(cdhst status)" "rolled_back"
cdh_run inactive n
assert_eq "no installed unit is not a hold — still judged on liveness (#396)" "$(cdhst status)" "rolled_back"

# (e) the guard must not swallow a genuinely failed apply on a held rig — `apply || return 1` still runs
# first. Mutation this catches: returning 0 on a held rig BEFORE the apply's exit status is read.
CDH_APPLY_RCS="1 1" cdh_run inactive y
assert_eq "held rig + a failed apply -> still rolled_back (#396)" "$(cdhst status)" "rolled_back"

# (f) the change failed for its own reason on a held rig and the rollback re-apply then succeeded. That
# re-apply leaves the rig stopped, on purpose, and _control_do_apply now calls that success — so the
# unconditional "rolled back and live" would assert a hashrate on a rig nobody started, which is the
# same lie #395 removed from the neighbouring arm.
CDH_APPLY_RCS="1 0" cdh_run inactive y
assert_eq "held rig + failed change + successful rollback -> rolled_back (#396)" "$(cdhst status)" "rolled_back"
assert_contains "the record says the rig stays stopped (#396)" "$(cdhst reason)" "stays stopped"
assert_absent "and it does NOT claim a liveness nobody checked (#396)" "$(cdhst reason)" "and live"
# The pre-existing wording is untouched for the case it was written for: a rig that WAS live, went
# down, and came back on the restored config.
CDH_APPLY_RCS="1 0" CDH_LIVE_RC=0 cdh_run active y
assert_contains "a rig that really did come back is still reported live (#396 control)" "$(cdhst reason)" "rolled back and live"

# #395: the two seams between install_watchdog and the status record. apply() swallowed the failure
# outright, and _control_do_apply then DISCARDED apply's exit status — the liveness wait's verdict
# became the whole answer, so an apply that failed for a reason the miner's hashrate cannot show
# still reported success. Both are covered here rather than through control_apply, because the
# control_apply harnesses stub apply() and so cannot see either seam.
echo "== unit: apply() and _control_do_apply propagate a watchdog render failure (#395) =="
AWD="$(mktemp -d "$SANDBOX/awd.XXXXXX")"
mkdir -p "$AWD/systemd"
cp "$ROOT/systemd/rigforge-watchdog.service.template" "$ROOT/systemd/rigforge-watchdog.timer.template" "$AWD/systemd/"
awd_apply() { # <systemd-dir> -> "rc=<n>"; side effect: $AWD/reached-later-steps
    rm -f "$AWD/reached-later-steps"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$AWD"
        SYSTEMD_DIR="$1"
        REAL_USER=rfop
        SERVICE_NAME=xmrig
        WATCHDOG_MODE=enabled
        WATCHDOG_INTERVAL_MIN=7
        # Everything apply() does EXCEPT install_watchdog is out of scope here and covered elsewhere,
        # so it is stubbed away; install_watchdog stays REAL and fails (or not) on the dir passed in.
        parse_config() { :; }
        _apply_runtime() { :; }
        install_autotune() { :; }
        install_api() { echo later >"$AWD/reached-later-steps" 2>/dev/null || true; }
        install_control() { :; }
        install_api_firewall() { :; }
        _autotune_apply_notice() { :; }
        _stamp_config_meta() { :; }
        _apply_pool_check() { :; }
        set +e
        PATH="$STUBS:$PATH" apply >/dev/null 2>&1
        echo "rc=$?"
    )
}
assert_eq "apply() returns 0 when the watchdog renders (#395)" "$(awd_apply "$AWD/systemd")" "rc=0"
assert_eq "apply() returns non-zero when the watchdog could not render (#395)" "$(awd_apply "$AWD/absent/systemd")" "rc=1"
# The reconcile must not be abandoned mid-way: stranding install_api/control/firewall as well would
# leave MORE units stale than the one that failed. This pins that the failure is recorded, not raised.
assert_eq "a failed watchdog render does not abort the rest of the reconcile (#395)" "$([ -f "$AWD/reached-later-steps" ] && echo ran || echo skipped)" "ran"

# Mutation this catches: restoring `apply >/dev/null 2>&1` as its own statement (status discarded).
# That mutant runs the liveness wait anyway, so the marker appears and rc drops to 0.
cda_run() { # <apply rc> -> "rc=<n>"; side effect: $AWD/waited
    rm -f "$AWD/waited"
    (
        source "$SCRIPT"
        # Capture the helper's argument BEFORE defining apply: inside apply's own body, "$1" would be
        # apply's parameter, not this one — and unset under `set -u` it fails for the wrong reason,
        # which made the short-circuit assertion below pass vacuously until this was caught.
        _cda_rc="$1"
        apply() { return "$_cda_rc"; }
        _wait_miner_live() {
            echo waited >"$AWD/waited" 2>/dev/null || true
            return 0
        }
        set +e
        _control_do_apply
        echo "rc=$?"
    )
}
assert_eq "_control_do_apply still waits for liveness when apply succeeds (#395)" "$(cda_run 0)" "rc=0"
assert_eq "apply succeeded -> the liveness wait really ran (#395)" "$([ -f "$AWD/waited" ] && echo waited || echo skipped)" "waited"
assert_eq "_control_do_apply fails when apply fails (#395)" "$(cda_run 1)" "rc=1"
assert_eq "a failed apply short-circuits the liveness wait (#395)" "$([ -f "$AWD/waited" ] && echo waited || echo skipped)" "skipped"

echo "== unit: control_apply orchestration + rollback (#236) =="
CA="$(mktemp -d "$SANDBOX/ca.XXXXXX")"
ca_exec() {
    (
        source "$SCRIPT"
        parse_config() { :; } # the live config is already valid; don't re-validate it
        # Stub apply + liveness (not _control_do_apply itself) so its real body runs: apply is a
        # no-op, CA_APPLY_OK drives whether the miner "comes back" (0 -> the rollback path). The
        # marker file lets an assertion OUTSIDE this subshell prove apply() — the pipeline that
        # regenerates xmrig's config and restarts it — was (or, #381, was deliberately NOT) reached.
        apply() {
            echo called >"$CA/full-apply-called" 2>/dev/null || true
            return 0
        }
        # #381: the fast-path counterpart, stubbed the same way — not _control_fast_path_eligible
        # (its real body runs, since the routing decision IS what these tests exercise).
        # CA_FAST_APPLY_OK drives whether it "succeeds" (default 1); on failure control_apply must
        # fall through to the SAME full-pipeline rollback a failed full apply already takes.
        _control_do_apply_fast() {
            echo called >"$CA/fast-apply-called" 2>/dev/null || true
            [ "${CA_FAST_APPLY_OK:-1}" = 1 ]
        }
        # _wait_miner_live is called once for the initial apply and (on the rollback path) again for the
        # rollback re-apply. CA_APPLY_OK drives the 1st call; CA_ROLLBACK_OK drives the 2nd, defaulting to
        # CA_APPLY_OK so every pre-#276 test (which only ever sets CA_APPLY_OK) is unaffected — #276 pins
        # the double-failure contract by setting them differently (0 then 1, or 0 then 0).
        _ca_calln=0
        _wait_miner_live() {
            _ca_calln=$((_ca_calln + 1))
            if [ "$_ca_calln" -eq 1 ]; then [ "${CA_APPLY_OK:-1}" = 1 ]; else [ "${CA_ROLLBACK_OK:-${CA_APPLY_OK:-1}}" = 1 ]; fi
        }
        # #276: simulate an unreadable rollback backup — hook the one place control_apply already calls
        # between a successful commit and the rollback's `cp "$backup" ...` (rigforge.sh:3759). Swap the
        # backup FILE for a directory of the same name: a plain `cp` (no -r) always refuses to read a
        # directory, unlike chmod 000 which root (e.g. the kcov coverage container) simply ignores.
        if [ "${CA_BACKUP_UNREADABLE:-0}" = 1 ]; then
            _reown_config_backups() {
                local f
                for f in "$1"/config-*.json; do rm -f "$f" && mkdir -p "$f"; done
            }
        fi
        OS_TYPE=Linux
        SCRIPT_DIR="$CA"
        CONFIG_JSON="$CA/config.json"
        REAL_USER=rfop
        RIGFORGE_CONTROL_STATE="$CA/state"
        set +e
        PATH="$STUBS:$PATH" control_apply >/dev/null 2>&1
    )
}
ca_run() { # <config> <staged|""> <apply_ok 1|0>
    rm -rf "$CA"
    mkdir -p "$CA/state/spool"
    printf '%s\n' "$1" >"$CA/config.json"
    [ -n "$2" ] && printf '%s' "$2" >"$CA/state/spool/pending-abc123.json"
    CA_APPLY_OK="$3" ca_exec
}
cst() { jq -r ".$1" "$CA/state/status.json" 2>/dev/null; }
ca_run "$CFG_236" "" 1
assert_eq "apply: nothing staged writes no status" "$([ -f "$CA/state/status.json" ] && echo y || echo n)" "n"
ca_run "$CFG_236" '{"DONATION":7}' 1
assert_eq "apply: valid change -> status applied" "$(cst status)" "applied"
assert_eq "apply: source stamped 'control'" "$(cst source)" "control"
assert_eq "apply: changed_keys recorded" "$(cst 'changed_keys[0]')" "DONATION"
assert_eq "apply: config committed (donation 7)" "$(jq -r .DONATION "$CA/config.json")" "7"
assert_eq "apply: exactly one backup made" "$(ls "$CA"/config-backups/config-*.json 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "apply: spool drained" "$(ls "$CA"/state/spool/pending-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
ca_run "$CFG_236" '{"ACCESS_TOKEN":"x"}' 1
assert_eq "apply: non-writable staged -> status rejected" "$(cst status)" "rejected"
assert_eq "apply: rejected leaves config untouched (donation 1)" "$(jq -r .DONATION "$CA/config.json")" "1"
assert_eq "apply: rejected drains the spool" "$(ls "$CA"/state/spool/pending-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
ca_run "$CFG_236" '{"DONATION":42}' 0
assert_eq "apply: failed liveness -> status rolled_back" "$(cst status)" "rolled_back"
assert_eq "apply: rollback restores the old config (donation 1)" "$(jq -r .DONATION "$CA/config.json")" "1"
# #276 (item 1a): CA_APPLY_OK=0 fails BOTH the initial apply and the rollback's own re-apply (same stub,
# same value) — the double-failure path. Pin a distinguishable reason so the receiver can tell "rolled
# back and live" from "rolled back, rig still down" instead of reading identical text for both.
assert_contains "rollback double-failure gets a distinguishable reason (#276)" "$(cst reason)" "rollback re-apply also failed to restore liveness"
# Contrast: initial apply fails but the rollback's re-apply succeeds -> a DIFFERENT reason string.
CA_APPLY_OK=0 CA_ROLLBACK_OK=1 ca_run "$CFG_236" '{"DONATION":42}' 0
assert_eq "single-failure rollback still reports rolled_back" "$(cst status)" "rolled_back"
assert_contains "single-failure rollback (live again) gets its own reason (#276)" "$(cst reason)" "rolled back and live"
assert_absent "single-failure reason is NOT the double-failure text (#276)" "$(cst reason)" "also failed"
# #276 (item 1b) — the real bug: the backup snapshot itself unreadable at rollback time. Before the fix,
# `cp "$backup" ...` fails under set -Eeuo pipefail and the oneshot exits with NO status written at all,
# so the receiver serves the stale previous outcome forever. The applier must write a terminal status
# (failed + reason) on this exit path.
CA_APPLY_OK=0 CA_BACKUP_UNREADABLE=1 ca_run "$CFG_236" '{"DONATION":42}' 0
assert_eq "unreadable rollback backup still writes a terminal status (#276)" "$([ -f "$CA/state/status.json" ] && echo y || echo n)" "y"
assert_eq "unreadable rollback backup -> status failed (#276)" "$(cst status)" "failed"
assert_contains "unreadable rollback backup reason names the cause (#276)" "$(cst reason)" "rollback backup unreadable"
# supersede: two staged -> only the newest applies, older dropped, no double restart
rm -rf "$CA"
mkdir -p "$CA/state/spool"
printf '%s\n' "$CFG_236" >"$CA/config.json"
printf '%s' '{"DONATION":3}' >"$CA/state/spool/pending-old.json"
sleep 1
printf '%s' '{"DONATION":8}' >"$CA/state/spool/pending-new.json"
CA_APPLY_OK=1 ca_exec
assert_eq "apply: newest staged change wins (donation 8)" "$(jq -r .DONATION "$CA/config.json")" "8"
assert_eq "apply: superseded staged changes all drained" "$(ls "$CA"/state/spool/pending-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
# #344: a terminal write clears the receiver's own pending/<cid>.json (stage_pending() in
# control-server.py) now that the real outcome has landed. Needs a genuine 16-hex cid — every ca_run
# case above uses "abc123", too short to ever hit the change_id index's hex-16 guard at all.
rm -rf "$CA"
mkdir -p "$CA/state/spool" "$CA/state/pending"
printf '%s\n' "$CFG_236" >"$CA/config.json"
CID344="1234567890abcdef"
printf '%s' '{"DONATION":9}' >"$CA/state/spool/pending-$CID344.json"
printf '%s' '{"status":"pending","change_id":"'"$CID344"'","accepted_at":"2020-01-01T00:00:00Z"}' >"$CA/state/pending/$CID344.json"
CA_APPLY_OK=1 ca_exec
assert_eq "control_apply writes the terminal changes/<cid>.json (#344)" "$([ -f "$CA/state/changes/$CID344.json" ] && echo y || echo n)" "y"
assert_eq "control_apply clears the now-superseded pending/<cid>.json (#344)" "$([ -f "$CA/state/pending/$CID344.json" ] && echo y || echo n)" "n"

# #381 (from #344 item 1): control_apply must route a change through _control_do_apply_fast instead
# of the full, xmrig-restarting apply() IFF every changed key is on the closed CONTROL_FAST_PATH_KEYS
# allowlist — proven here via the full-apply-called/fast-apply-called markers ca_exec's stubs write,
# not just by the reported status (which is "applied" either way and so can't tell the paths apart).
ca_run "$CFG_236" '{"watchdog_interval_min":9}' 1
assert_eq "watchdog_interval_min-only change -> status applied (#381)" "$(cst status)" "applied"
assert_eq "watchdog_interval_min-only change -> config committed" "$(jq -r .watchdog_interval_min "$CA/config.json")" "9"
assert_eq "watchdog_interval_min-only change takes the fast path" "$([ -f "$CA/fast-apply-called" ] && echo called || echo not-called)" "called"
assert_eq "watchdog_interval_min-only change NEVER calls apply() (xmrig untouched, #381)" "$([ -f "$CA/full-apply-called" ] && echo called || echo not-called)" "not-called"
ca_run "$CFG_236" '{"max_temp_c":90}' 1
assert_eq "max_temp_c-only change also takes the fast path (#381)" "$([ -f "$CA/fast-apply-called" ] && echo called || echo not-called)" "called"
assert_eq "max_temp_c-only change never calls apply() (#381)" "$([ -f "$CA/full-apply-called" ] && echo called || echo not-called)" "not-called"
ca_run "$CFG_236" '{"watchdog_interval_min":9,"max_temp_c":90}' 1
assert_eq "both restart-free keys together still take the fast path (#381)" "$([ -f "$CA/fast-apply-called" ] && echo called || echo not-called)" "called"
assert_eq "both-keys change reports applied (#381)" "$(cst status)" "applied"

# Mutation this catches: if the ALL-keys-must-qualify subset check were loosened to an ANY-key (or a
# "not explicitly on the slow list") check, this mixed change would wrongly take the fast path and
# skip the restart DONATION needs to actually reach xmrig.
ca_run "$CFG_236" '{"DONATION":5,"max_temp_c":90}' 1
assert_eq "mixed restart-free + full-path key -> takes the FULL path (#381)" "$([ -f "$CA/full-apply-called" ] && echo called || echo not-called)" "called"
assert_eq "mixed change never takes the fast path (#381)" "$([ -f "$CA/fast-apply-called" ] && echo called || echo not-called)" "not-called"
assert_eq "mixed change still reports applied" "$(cst status)" "applied"
# A pure DONATION change (already covered under #236 above) stays on the full path too — restated
# here under #381 naming so the fast/full boundary is asserted with the marker files in one place.
ca_run "$CFG_236" '{"DONATION":6}' 1
assert_eq "DONATION-only change takes the full path, not fast (#381)" "$([ -f "$CA/full-apply-called" ] && echo called || echo not-called)" "called"
assert_eq "DONATION-only change never takes the fast path (#381)" "$([ -f "$CA/fast-apply-called" ] && echo called || echo not-called)" "not-called"

# A failed fast-path apply must fall back to the SAME full, restart-safe rollback a failed full apply
# already takes — never report "applied" on a fast-path failure, and never leave the change stuck.
# Mutation this catches: the fast branch skipping the rollback on failure, or reporting "applied"
# regardless of _control_do_apply_fast's return code.
CA_FAST_APPLY_OK=0 ca_run "$CFG_236" '{"max_temp_c":90}' 1
assert_eq "failed fast-path apply -> status rolled_back, not applied (#381)" "$(cst status)" "rolled_back"
assert_eq "failed fast-path apply -> config restored to pre-change (max_temp_c unset again)" "$(jq -r .max_temp_c "$CA/config.json")" "null"
assert_eq "the rollback re-apply after a fast-path failure uses the FULL path (#381)" "$([ -f "$CA/full-apply-called" ] && echo called || echo not-called)" "called"

# prune: KEEP_CONFIG_BACKUPS caps the history
PB="$(mktemp -d "$SANDBOX/pb.XXXXXX")"
mkdir -p "$PB/bk"
for i in 1 2 3 4 5; do printf '{}' >"$PB/bk/config-2026010$i-000000.json"; done
(
    source "$SCRIPT"
    set +e
    KEEP_CONFIG_BACKUPS=2 _reown_config_backups "$PB/bk"
)
assert_eq "backups pruned to KEEP_CONFIG_BACKUPS" "$(ls "$PB/bk"/config-*.json 2>/dev/null | wc -l | tr -d ' ')" "2"
# black-box dispatch: Linux-only guard + extra-arg rejection
cb_out="$( (STUB_UNAME_S=Darwin RIGFORGE_HOME="$ROOT" bash "$SCRIPT" control-apply </dev/null) 2>&1 || true)"
if [ "$(uname -s)" = Linux ]; then
    assert_contains "control-apply on Linux needs a config (reached the verb)" "$( (RIGFORGE_HOME="$ROOT" bash "$SCRIPT" control-apply </dev/null) 2>&1 || true)" "configuration"
else
    assert_contains "control-apply refuses off-Linux" "$cb_out" "Linux-only"
fi
cb_out="$( (RIGFORGE_HOME="$ROOT" bash "$SCRIPT" control-apply --extra </dev/null) 2>&1 || true)"
assert_contains "control-apply rejects extra args" "$cb_out" "Unexpected argument for control-apply"
cb_out="$( (RIGFORGE_HOME="$ROOT" bash "$SCRIPT" control-upgrade --extra </dev/null) 2>&1 || true)"
assert_contains "control-upgrade rejects extra args (#312)" "$cb_out" "Unexpected argument for control-upgrade"

# #426: the REJECTION branch through the REAL dispatch — errexit and the ERR trap live. Every
# rejection assertion above runs control_apply SOURCED under `set +e` (ca_exec), which is the one
# shape that cannot see this defect, so those rows stayed green while it shipped.
# Separate bash process on purpose, for the #364 reason above: a subshell would inherit this
# suite's errexit context instead of a clean top-level one.
# `invalid-config` is the trigger reachable over HTTP — a WRITABLE key whose value parse_config
# refuses. control-server.py screens non-writable and unsafe keys with a 400 before staging, so
# most of _control_commit's other rejection branches never get here.
CAB="$(mktemp -d "$SANDBOX/cab.XXXXXX")"
CAB_CID=00000000000000ab # 16 hex: _control_status only writes the changes/<cid>.json index for these
mkdir -p "$CAB/state/spool"
printf '%s\n' "$CFG_236" >"$CAB/config.json"
printf '%s' '{"DONATION":500}' >"$CAB/state/spool/pending-$CAB_CID.json"
cab_out="$( (cd "$CAB" && PATH="$STUBS:$PATH" STUB_UNAME_S=Linux RIGFORGE_CONTROL_STATE="$CAB/state" \
    RIGFORGE_HOME="$PWD" bash "$SCRIPT" control-apply </dev/null) 2>&1)"
cab_rc=$?
cabst() { jq -r ".$1" "$CAB/state/status.json" 2>/dev/null; }
assert_rc "a rejected change does not abort control-apply (#426)" "$cab_rc" "0"
assert_absent "a rejected change does not ERR-trap the applier (#426)" "$cab_out" "aborted while"
# The reporting half: without these the change is decided and the decision is never published.
assert_eq "rejected change writes a terminal status (#426)" "$(cabst status)" "rejected"
assert_contains "the rejected status names why (#426)" "$(cabst reason)" "invalid-config"
assert_eq "GET /status?change_id= stops reading pending (#426)" "$(jq -r .status "$CAB/state/changes/$CAB_CID.json" 2>/dev/null)" "rejected"
# The availability half: an undrained spool is what re-triggers the .path unit into the start limit.
assert_eq "a rejected change drains the spool (#426)" "$(ls "$CAB"/state/spool/pending-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
# Unchanged by the fix, asserted so a future rewrite of this branch cannot quietly lose it.
assert_eq "a rejected change leaves config.json untouched (#426)" "$(jq -r .DONATION "$CAB/config.json")" "1"

echo "== unit: control_upgrade orchestration — whitelist, anti-rollback, throttle, rollback (#308) =="
# The git fetch/checkout/reachability/build half (_control_upgrade_do) and the miner liveness check are
# stubbed here — they need a real git remote + compiler + systemd, and are validated on miner-0. This
# exercises the security-critical ORCHESTRATION: strict version whitelist, monotonic anti-rollback,
# spool handoff, throttle, and the applied/rolled_back/failed status the receiver serves back.
cu_run() { # <staged-json|""> <installed-version> <do:ok|fail|down> -> status.json contents
    local d
    d=$(mktemp -d "$SANDBOX/cu.XXXXXX")
    mkdir -p "$d/state/spool"
    printf '%s' "$2" >"$d/VERSION"
    printf '{"pools":[{"url":"h:3333"}]}\n' >"$d/config.json"
    [ -n "$1" ] && printf '%s\n' "$1" >"$d/state/spool/upgrade-abc123def4567890.json"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$d"
        CONFIG_JSON="$d/config.json"
        RIGFORGE_CONTROL_STATE="$d/state"
        CONTROL_UPGRADE_MIN_INTERVAL=0
        DO="$3"
        WML=0
        UDO=0
        # forward checkout+build is call #1, the rollback checkout+build is call #2.
        # 'buildfail' = the forward build fails but the rollback rebuild succeeds (-> rolled_back);
        # 'fail' = both fail (-> terminal failed).
        _control_upgrade_do() {
            UDO=$((UDO + 1))
            case "$DO" in
            buildfail) [ "$UDO" -eq 1 ] && return 1 ;;
            fail) return 1 ;;
            esac
            return 0
        }
        # 'down' = miner dead after the forward build but the rollback restores liveness (-> rolled_back).
        _wait_miner_live() {
            WML=$((WML + 1))
            { [ "$DO" = down ] && [ "$WML" -eq 1 ]; } && return 1
            return 0
        }
        # Match the subcommand anywhere in the args: #308's `-c safe.directory=...` sits between
        # `-C dir` and the subcommand, so positional ($3) matching broke when it landed.
        git() { case "$*" in *describe*) echo v0.0.1 ;; *rev-parse*) echo deadbeefcafe ;; *) return 0 ;; esac }
        set +e
        PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    )
    cat "$d/state/status.json" 2>/dev/null
}
st() { printf '%s' "$1" | jq -r .status 2>/dev/null; }
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" ok)"
assert_eq "upgrade applied on a newer, buildable release" "$(st "$s")" "applied"
# #320: the applied record must say which version landed — no cross-reading the miner API for it.
assert_contains "applied reason echoes the landed version (#320)" "$s" "upgraded to v9.9.9"
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" down)"
assert_eq "built but miner stays down -> rolled_back" "$(st "$s")" "rolled_back"
# #308 security review (HIGH): a build failure AFTER checkout must roll the tree back to the prior
# version, not leave it pinned to the unbuilt target (which would short-circuit all future retries and
# run unverified code). A clean rollback reports rolled_back, never a false "no change applied".
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" buildfail)"
assert_eq "build failure after checkout rolls back cleanly -> rolled_back" "$(st "$s")" "rolled_back"
s="$(cu_run '{"version":"v9.9.9"}' "1.0.0" fail)"
assert_eq "forward AND rollback both fail -> terminal failed" "$(st "$s")" "failed"
assert_contains "hard-failure reason flags manual intervention" "$s" "manual intervention"
s="$(cu_run '{"version":"v1.0.0"}' "2.0.0" ok)"
assert_eq "downgrade refused -> failed (never built)" "$(st "$s")" "failed"
assert_contains "downgrade reason names anti-rollback" "$s" "not newer"
s="$(cu_run '{"version":"v1.0.0"}' "1.0.0" ok)"
# #320: already-on-target is an idempotent no-op, not a failure — a dashboard must not show red
# for a rig sitting exactly where the operator wants it.
assert_eq "same version -> noop, not failed (#320)" "$(st "$s")" "noop"
assert_contains "noop reason still says already on" "$s" "already on v1.0.0"
s="$(cu_run '{"version":"garbage"}' "1.0.0" ok)"
assert_contains "malformed target refused, never run" "$s" "malformed"
s="$(cu_run '{"version":"v9.9.9","evil":"x"}' "1.0.0" ok)"
assert_contains "extra key beyond version refused (strict whitelist)" "$s" "malformed"
s="$(cu_run "" "1.0.0" ok)"
assert_eq "nothing staged -> no status file" "$s" ""
# D8 spool handoff: a staged SYMLINK is refused before it's read.
dsl=$(mktemp -d "$SANDBOX/cusl.XXXXXX")
mkdir -p "$dsl/state/spool"
printf '1.0.0' >"$dsl/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$dsl/config.json"
printf '{"version":"v9.9.9"}\n' >"$dsl/evil.json"
ln -s "$dsl/evil.json" "$dsl/state/spool/upgrade-abc123def4567890.json"
sl="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$dsl"
    CONFIG_JSON="$dsl/config.json"
    RIGFORGE_CONTROL_STATE="$dsl/state"
    CONTROL_UPGRADE_MIN_INTERVAL=0
    _control_upgrade_do() { return 0; }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    cat "$dsl/state/status.json" 2>/dev/null
)"
assert_contains "staged symlink refused (D8 spool handoff)" "$sl" "symlink"

echo "== unit: _control_upgrade_throttle_ok (#308) =="
td=$(mktemp -d "$SANDBOX/thr.XXXXXX")
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_throttle_ok "$td"
)
assert_eq "throttle: first attempt allowed (and stamps)" "$?" "0"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_throttle_ok "$td"
)
assert_eq "throttle: second attempt within the window blocked" "$?" "1"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=0
    _control_upgrade_throttle_ok "$td"
)
assert_eq "throttle: zero interval always allowed" "$?" "0"
# Fail CLOSED when the lock can't be opened (#321): the anti-beacon throttle must not silently
# disable itself on exactly the degraded state dir an attacker might arrange. rc 2, not 1, so the
# caller can report the real cause instead of "throttled — retry later". The dangling symlink into
# a missing dir makes the open fail for ANY uid (root included), unlike a chmod-based setup.
roThr="$SANDBOX/thr-ro"
mkdir -p "$roThr"
ln -s "$roThr/no-such-dir/lock" "$roThr/.upgrade-throttle.lock"
(
    source "$SCRIPT"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_throttle_ok "$roThr"
) >/dev/null 2>&1
assert_eq "throttle: unopenable lock fails CLOSED (rc 2) (#321)" "$?" "2"

# _control_upgrade_do against a STUB git (+ stub rigforge.sh) so the real fetch/reachability/checkout
# lines run under coverage — and, more importantly, the D10 reachability guard is exercised for real.
echo "== unit: _control_upgrade_do fetch + reachability + checkout (#308, stub git) =="
udoDir=$(mktemp -d "$SANDBOX/udo.XXXXXX")
mkdir -p "$udoDir/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$udoDir/rigforge.sh"
chmod +x "$udoDir/rigforge.sh"
_mk_git_stub() { # <merge-base-rc> <fetch-rc>
    cat >"$udoDir/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
*"fetch"*) exit ${2:-0} ;;
*"merge-base --is-ancestor"*) exit ${1:-0} ;;
*"rev-parse"*) echo deadbeefcafe; exit 0 ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$udoDir/bin/git"
}
_run_udo() { (
    source "$SCRIPT"
    set +e # sourcing enables -e; a non-zero _control_upgrade_do must not abort before we echo $?
    SCRIPT_DIR="$udoDir"
    PATH="$udoDir/bin:$PATH" _control_upgrade_do "v9.9.9" >/dev/null 2>&1
    echo $?
); }
_mk_git_stub 0 0
assert_eq "_control_upgrade_do: reachable tag, all steps ok -> 0" "$(_run_udo)" "0"
_mk_git_stub 1 0
assert_eq "_control_upgrade_do: unreachable tag (merge-base fails) -> 1 (D10)" "$(_run_udo)" "1"
_mk_git_stub 0 1
assert_eq "_control_upgrade_do: git fetch failure -> 1" "$(_run_udo)" "1"
# #318: the D10 guard must pin origin/main (the branch releases are cut from), never origin/HEAD —
# a fresh clone resolves HEAD to develop, which doesn't contain the release merge commits on main.
assert_contains "D10 reachability guard pins origin/main (#318)" \
    "$(grep 'merge-base --is-ancestor' "$SCRIPT")" 'origin/main'
assert_eq "D10 guard does not consult origin/HEAD (#318)" \
    "$(grep -c 'symbolic-ref' "$SCRIPT")" "0"

# control_upgrade's throttle-blocked path: a fresh stamp inside the window -> failed(throttled).
cuThr=$(mktemp -d "$SANDBOX/cuthr.XXXXXX")
mkdir -p "$cuThr/state/spool"
printf '1.0.0' >"$cuThr/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$cuThr/config.json"
printf '{"version":"v9.9.9"}\n' >"$cuThr/state/spool/upgrade-abc123def4567890.json"
date +%s >"$cuThr/state/upgrade-last"
sThr="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$cuThr"
    CONFIG_JSON="$cuThr/config.json"
    RIGFORGE_CONTROL_STATE="$cuThr/state"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_do() { return 0; }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    cat "$cuThr/state/status.json" 2>/dev/null
)"
assert_eq "control_upgrade within the throttle window -> status throttled (#308/#320)" "$(st "$sThr")" "throttled"
assert_contains "throttled reason says why" "$sThr" "too soon"

# #321: unusable throttle state (rc 2) is a fail-closed refusal, and must NOT read as "throttled"
# — a consumer would retry-later forever against a rig whose state dir is actually broken.
cuTs=$(mktemp -d "$SANDBOX/cuts.XXXXXX")
mkdir -p "$cuTs/state/spool"
printf '1.0.0' >"$cuTs/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$cuTs/config.json"
printf '{"version":"v9.9.9"}\n' >"$cuTs/state/spool/upgrade-abc123def4567890.json"
ln -s "$cuTs/state/no-such-dir/lock" "$cuTs/state/.upgrade-throttle.lock"
sTs="$(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$cuTs"
    CONFIG_JSON="$cuTs/config.json"
    RIGFORGE_CONTROL_STATE="$cuTs/state"
    CONTROL_UPGRADE_MIN_INTERVAL=3600
    _control_upgrade_do() { return 0; }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
    cat "$cuTs/state/status.json" 2>/dev/null
)"
assert_eq "unusable throttle state -> failed, never built (#321)" "$(st "$sTs")" "failed"
assert_contains "fail-closed reason names the throttle state, not 'throttled'" "$sTs" "throttle state unavailable"

# #320: between the D8 claim and the terminal outcome the verb writes ONE non-terminal `started`
# record, so a poller can tell "mid-run" (and "oneshot died mid-run": started never superseded)
# from "queued, path unit hasn't fired" (previous change's terminal record still served).
cuSt=$(mktemp -d "$SANDBOX/cust.XXXXXX")
mkdir -p "$cuSt/state/spool"
printf '1.0.0' >"$cuSt/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$cuSt/config.json"
printf '{"version":"v9.9.9"}\n' >"$cuSt/state/spool/upgrade-abc123def4567890.json"
(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$cuSt"
    CONFIG_JSON="$cuSt/config.json"
    RIGFORGE_CONTROL_STATE="$cuSt/state"
    CONTROL_UPGRADE_MIN_INTERVAL=0
    # Snapshot the status file at the moment the build half runs — the started record must already
    # be there, and must carry this change's id (not the previous change's terminal record).
    _control_upgrade_do() {
        cp "$cuSt/state/status.json" "$cuSt/mid-status.json" 2>/dev/null
        return 0
    }
    _wait_miner_live() { return 0; }
    git() { echo v0.0.1; }
    set +e
    PATH="$STUBS:$PATH" control_upgrade >/dev/null 2>&1
)
sMid="$(cat "$cuSt/mid-status.json" 2>/dev/null)"
assert_eq "started record served while the build runs (#320)" "$(st "$sMid")" "started"
assert_contains "started record carries this change's id" "$sMid" "abc123def4567890"
assert_eq "started record indexed under changes/<cid> too (#320)" \
    "$([ -f "$cuSt/state/changes/abc123def4567890.json" ] && echo y || echo n)" "y"
assert_eq "terminal record supersedes started" "$(st "$(cat "$cuSt/state/status.json" 2>/dev/null)")" "applied"

# #308: the control-upgrade oneshot runs as root with NO $HOME, so git can't read root's safe.directory
# config and fatals on "dubious ownership" of the operator-owned install — every git op then fails and
# the upgrade silently dies (a real miner-0 finding; the stubbed suite can't reach it since it stubs
# git). Every `git -C "$SCRIPT_DIR"` in the upgrade path MUST pin -c safe.directory. Drift-guard it.
echo "== unit: control-upgrade git calls pin safe.directory (#308) =="
bare_rf_git=$(grep -nE 'git -C "\$SCRIPT_DIR"' "$SCRIPT" | grep -v 'safe.directory' || true)
assert_eq "no control git call omits -c safe.directory (root oneshot has no HOME)" "$bare_rf_git" ""

# Same failure, a second invocation shape, found on the v1.16.0 gate (#401). git exempts a repo from
# its dubious-ownership check when the repo is owned by $SUDO_UID, so a plain
# `sudo bash tests/e2e-real.sh upgrade` works. Nest that inside another sudo — a `nohup setsid`
# detach recipe is one — and the inner sudo rewrites SUDO_UID to 0, the exemption stops matching a
# repo owned by the operator, and every bare `git -C "$HERE"` in the upgrade phase fatals with
# "detected dubious ownership". The releaser then reads a RED on a gate that is fine.
echo "== unit: e2e-real git calls survive a nested sudo (#401) =="
bare_e2e_git=$(grep -nE 'git -C "\$HERE"' "$ROOT/tests/e2e-real.sh" | grep -v 'safe\.directory' || true)
assert_eq "no e2e-real git call omits -c safe.directory (nested sudo breaks git's SUDO_UID exemption)" "$bare_e2e_git" ""
# ...and the row above is not vacuous: it would also pass on a file with no git calls left in it.
hgit_calls=$(grep -cE '(^|[^A-Za-z_])_hgit ' "$ROOT/tests/e2e-real.sh")
if [ "$hgit_calls" -ge 10 ]; then
    ok "e2e-real still routes its git through the helper ($hgit_calls call sites)"
else
    bad "e2e-real routes too few git calls through _hgit" "expected >= 10, got $hgit_calls"
fi

echo "== unit: control writable-keys drift guard — bash vs python (#236) =="
bash_ckeys="$(grep -oE 'CONTROL_WRITABLE_KEYS="[^"]*"' "$SCRIPT" | head -1 | sed 's/.*="//; s/"//' | tr ' ' '\n' | sort | tr '\n' ' ')"
py_ckeys="$(grep -oE 'WRITABLE = \{[^}]*\}' "$ROOT/util/control-server.py" | grep -oE '"[a-zA-Z_]+"' | tr -d '"' | sort | tr '\n' ' ')"
assert_eq "control writable-keys match across rigforge.sh + control-server.py (#236)" "$bash_ckeys" "$py_ckeys"

echo "== black-box: the control server (#236) =="
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not present (kcov container) — the control-server wire suite runs in the other CI jobs"
else
    python3 -m py_compile "$ROOT/util/control-server.py" && ok "control-server.py compiles" || bad "control-server.py does not compile" ""
    CSRV="$(mktemp -d "$SANDBOX/csrv.XXXXXX")"
    mkdir -p "$CSRV/state"
    CTOK="tok-ctl1"
    printf '{ "pools":[{"url":"h:3333"}], "ACCESS_TOKEN":"%s" }\n' "$CTOK" >"$CSRV/config.json"
    CPORT=$((20000 + RANDOM % 20000))
    python3 "$ROOT/util/control-server.py" 127.0.0.1 "$CPORT" "$CSRV/state" "$CSRV/config.json" &
    CSRV_PID=$!
    U="http://127.0.0.1:$CPORT"
    cup=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -s -o /dev/null --max-time 2 -H "Authorization: Bearer $CTOK" "$U/status" 2>/dev/null; then
            cup=1
            break
        fi
        sleep 0.3
    done
    assert_eq "control server comes up" "$cup" "1"
    hc() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
    assert_eq "POST unauthed -> 401" "$(hc -X POST "$U/apply" -H 'Content-Type: application/json' -d '{"DONATION":2}')" "401"
    assert_eq "POST wrong token -> 401" "$(hc -X POST "$U/apply" -H "Authorization: Bearer nope" -H 'Content-Type: application/json' -d '{"DONATION":2}')" "401"
    resp="$(curl -sS --max-time 5 -X POST "$U/apply" -H 'Content-Type: application/json' -d '{"DONATION":2}' 2>/dev/null)"
    assert_absent "401 body never echoes the token" "$resp" "$CTOK"
    body="$(curl -sS --max-time 5 -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"DONATION":2}' 2>/dev/null)"
    assert_contains "POST allowed key -> accepted" "$body" '"status": "accepted"'
    assert_contains "accepted returns a change_id" "$body" '"change_id"'
    assert_eq "one change staged as pending-*.json" "$(ls "$CSRV/state/spool"/pending-*.json 2>/dev/null | wc -l | tr -d ' ')" "1"
    assert_eq "no temp file left in the spool (atomic stage)" "$(ls "$CSRV/state/spool"/.tmp-* 2>/dev/null | wc -l | tr -d ' ')" "0"
    # #344 item 2: the accepted change_id resolves to a pending record IMMEDIATELY — no oneshot has
    # run yet (nothing has touched state/changes) — instead of the unknown-id 404 during the whole
    # window before control-apply's terminal write lands.
    acid="$(printf '%s' "$body" | jq -r .change_id)"
    assert_eq "receiver writes its own pending/<cid>.json at accept time (#344)" "$([ -f "$CSRV/state/pending/$acid.json" ] && echo y || echo n)" "y"
    assert_eq "no temp file left in state/pending (atomic write, #344)" "$(ls "$CSRV/state/pending"/.tmp-* 2>/dev/null | wc -l | tr -d ' ')" "0"
    assert_eq "GET /status?change_id=<in-flight, no terminal record yet> -> 200, not 404 (#344 item 2)" "$(hc "$U/status?change_id=$acid" -H "Authorization: Bearer $CTOK")" "200"
    pbody="$(curl -sS --max-time 5 -H "Authorization: Bearer $CTOK" "$U/status?change_id=$acid" 2>/dev/null)"
    assert_eq "in-flight change_id reads as 'pending', not a fabricated outcome (#344 item 2)" "$(printf '%s' "$pbody" | jq -r .status)" "pending"
    assert_contains "pending record carries an accepted-at stamp (#344 item 2)" "$pbody" '"accepted_at"'
    assert_contains "pending record's age is visible too (#344 items 2+3)" "$pbody" '"age_seconds"'
    # A terminal write (control-apply landing the real outcome) supersedes the pending marker for the
    # SAME change_id — proves changes/ is checked before the pending/ fallback.
    mkdir -p "$CSRV/state/changes"
    printf '{"status":"applied","change_id":"%s","applied_at":"2020-01-01T00:00:00Z"}' "$acid" >"$CSRV/state/changes/$acid.json"
    tbody="$(curl -sS --max-time 5 -H "Authorization: Bearer $CTOK" "$U/status?change_id=$acid" 2>/dev/null)"
    assert_eq "a terminal record wins over a same-id pending leftover (#344)" "$(printf '%s' "$tbody" | jq -r .status)" "applied"
    assert_eq "the terminal record's own age derives from applied_at, not accepted_at (#344 item 3)" "$(printf '%s' "$tbody" | jq -r '(.age_seconds // 0) > 100000000')" "true"
    body="$(curl -sS --max-time 5 -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"ACCESS_TOKEN":"x"}' 2>/dev/null)"
    assert_contains "POST non-writable key -> 400 naming it" "$body" "ACCESS_TOKEN"
    assert_eq "POST non-writable key -> 400" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"HOME_DIR":"/x"}')" "400"
    # #257: the remote path refuses to strip thermal protection — 400 before anything is staged.
    assert_eq "POST watchdog:disabled -> 400 (safety #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"watchdog":"disabled"}')" "400"
    assert_eq "POST watchdog:false -> 400 (safety #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"watchdog":false}')" "400"
    assert_eq "POST max_temp_c:null -> 400 (safety #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"max_temp_c":null}')" "400"
    assert_eq "POST max_temp_c:999 -> 400 (safety #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"max_temp_c":999}')" "400"
    safebody="$(curl -sS --max-time 5 -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"watchdog":"disabled"}' 2>/dev/null)"
    assert_contains "safety 400 explains the refusal + points at local rigforge.sh (#257)" "$safebody" "change it locally on the rig with rigforge.sh"
    assert_eq "POST watchdog:enabled -> 202 (tuning still works #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"watchdog":"enabled"}')" "202"
    assert_eq "POST max_temp_c:80 -> 202 (within band #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"max_temp_c":80}')" "202"
    assert_eq "POST max_temp_c:40 -> 202 (band floor #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"max_temp_c":40}')" "202"
    assert_eq "POST max_temp_c:110 -> 202 (band ceiling #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"max_temp_c":110}')" "202"
    assert_eq "POST max_temp_c:111 -> 400 (just over band #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"max_temp_c":111}')" "400"
    assert_eq "POST max_temp_c:40.5 non-integer -> 400 (receiver matches applier #257)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"max_temp_c":40.5}')" "400"
    assert_eq "POST not JSON -> 400" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d 'nope')" "400"
    assert_eq "POST empty object -> 400" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{}')" "400"
    assert_eq "POST wrong content-type -> 415" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: text/plain' -d '{"DONATION":2}')" "415"
    assert_eq "POST without a Content-Length -> 411" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -H 'Transfer-Encoding: chunked' -d '{"DONATION":2}')" "411"
    assert_eq "POST unknown route -> 404" "$(hc -X POST "$U/nope" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"DONATION":2}')" "404"
    assert_eq "PUT -> 405 (writes only via /apply)" "$(hc -X PUT "$U/apply" -H "Authorization: Bearer $CTOK")" "405"
    assert_eq "GET /status before any apply -> 503" "$(hc "$U/status" -H "Authorization: Bearer $CTOK")" "503"
    printf '{"status":"applied","change_id":"z","applied_at":"2020-01-01T00:00:00Z"}' >"$CSRV/state/status.json"
    assert_eq "GET /status after an apply -> 200" "$(hc "$U/status" -H "Authorization: Bearer $CTOK")" "200"
    # #344 item 3: the walkthrough that reported this — an 11-day-old record with no staleness cue,
    # indistinguishable from a fresh one — reading the no-arg endpoint directly. age_seconds is
    # ADDITIVE (applied_at itself is untouched) and computed at serve time, never persisted to disk.
    nbody="$(curl -sS --max-time 5 -H "Authorization: Bearer $CTOK" "$U/status" 2>/dev/null)"
    assert_contains "no-arg /status keeps its recorded-at stamp (#344 item 3)" "$nbody" '"applied_at": "2020-01-01T00:00:00Z"'
    assert_contains "no-arg /status gains a derived age signal (#344 item 3)" "$nbody" '"age_seconds"'
    assert_eq "the age signal reflects a genuinely stale record (#344 item 3)" "$(printf '%s' "$nbody" | jq -r '(.age_seconds // 0) > 100000000')" "true"
    # #255: query a SPECIFIC change_id, unaffected by a later change (index written by the applier).
    mkdir -p "$CSRV/state/changes"
    printf '{"status":"applied","change_id":"1111222233334444","changed_keys":["DONATION"]}' >"$CSRV/state/changes/1111222233334444.json"
    printf '{"status":"rolled_back","change_id":"aaaabbbbccccdddd","reason":"x"}' >"$CSRV/state/changes/aaaabbbbccccdddd.json"
    assert_eq "GET /status?change_id=<known> -> 200 (#255)" "$(hc "$U/status?change_id=1111222233334444" -H "Authorization: Bearer $CTOK")" "200"
    assert_eq "?change_id returns THAT change, not the most-recent (#255)" "$(curl -s --max-time 5 -H "Authorization: Bearer $CTOK" "$U/status?change_id=aaaabbbbccccdddd" | jq -r .status)" "rolled_back"
    assert_eq "GET /status?change_id=<unknown 16hex> -> 404 (#255)" "$(hc "$U/status?change_id=deadbeefdeadbeef" -H "Authorization: Bearer $CTOK")" "404"
    assert_eq "GET /status?change_id=<non-hex / traversal> -> 400 (#255)" "$(hc "$U/status?change_id=..%2f..%2fetc%2fpasswd" -H "Authorization: Bearer $CTOK")" "400"
    assert_eq "GET /status?change_id=<too short> -> 400 (#255)" "$(hc "$U/status?change_id=abc" -H "Authorization: Bearer $CTOK")" "400"
    assert_eq "no-arg GET /status still returns most-recent (#255 compat)" "$(hc "$U/status" -H "Authorization: Bearer $CTOK")" "200"
    assert_eq "?change_id still requires the bearer (#255)" "$(hc "$U/status?change_id=1111222233334444")" "401"
    bigbody="$(head -c 70000 /dev/zero | tr '\0' 'a')"
    assert_eq "POST oversized body -> 413" "$(hc -X POST "$U/apply" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' --data-binary "$bigbody")" "413"
    # #308: /upgrade is gated by control_upgrade — THIS server has it off, so the endpoint is refused.
    assert_eq "POST /upgrade with control_upgrade off -> 403 (#308)" "$(hc -X POST "$U/upgrade" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"version":"v9.9.9"}')" "403"
    assert_eq "POST /upgrade still requires the bearer (#308)" "$(hc -X POST "$U/upgrade" -H 'Content-Type: application/json' -d '{"version":"v9.9.9"}')" "401"
    kill "$CSRV_PID" 2>/dev/null || true
    wait "$CSRV_PID" 2>/dev/null || true
    # #308: a dedicated server WITH control_upgrade enabled — /upgrade now accepts a well-formed version
    # and stages it as upgrade-*.json (distinct from the apply path's pending-*.json).
    CSRV2="$(mktemp -d "$SANDBOX/csrv2.XXXXXX")"
    mkdir -p "$CSRV2/state"
    printf '{ "pools":[{"url":"h:3333"}], "ACCESS_TOKEN":"%s", "control_upgrade":"enabled" }\n' "$CTOK" >"$CSRV2/config.json"
    CPORT2=$((20000 + RANDOM % 20000))
    python3 "$ROOT/util/control-server.py" 127.0.0.1 "$CPORT2" "$CSRV2/state" "$CSRV2/config.json" &
    CSRV2_PID=$!
    U2="http://127.0.0.1:$CPORT2"
    cup2=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -s -o /dev/null --max-time 2 -H "Authorization: Bearer $CTOK" "$U2/status" 2>/dev/null; then
            cup2=1
            break
        fi
        sleep 0.3
    done
    assert_eq "upgrade-enabled control server comes up" "$cup2" "1"
    ubody="$(curl -sS --max-time 5 -X POST "$U2/upgrade" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"version":"v1.2.3"}' 2>/dev/null)"
    assert_contains "POST /upgrade well-formed -> accepted (#308)" "$ubody" '"status": "accepted"'
    assert_eq "upgrade staged as upgrade-*.json (#308)" "$(ls "$CSRV2/state/spool"/upgrade-*.json 2>/dev/null | wc -l | tr -d ' ')" "1"
    assert_eq "upgrade did NOT stage a pending-*.json (distinct from apply #308)" "$(ls "$CSRV2/state/spool"/pending-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
    assert_eq "POST /upgrade malformed version -> 400 (#308)" "$(hc -X POST "$U2/upgrade" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"version":"garbage"}')" "400"
    assert_eq "POST /upgrade extra key -> 400 (strict whitelist #308)" "$(hc -X POST "$U2/upgrade" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"version":"v1.2.3","x":1}')" "400"
    assert_eq "POST /upgrade missing version -> 400 (#308)" "$(hc -X POST "$U2/upgrade" -H "Authorization: Bearer $CTOK" -H 'Content-Type: application/json' -d '{"DONATION":2}')" "400"
    kill "$CSRV2_PID" 2>/dev/null || true
    wait "$CSRV2_PID" 2>/dev/null || true
    # Fail closed: a config with no ACCESS_TOKEN must make the WRITABLE path refuse everyone.
    printf '{ "pools":[{"url":"h:3333"}] }\n' >"$CSRV/config.json"
    python3 "$ROOT/util/control-server.py" 127.0.0.1 "$CPORT" "$CSRV/state" "$CSRV/config.json" &
    NT_PID=$!
    ntup=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -X POST "$U/apply" -H 'Content-Type: application/json' -d '{}' 2>/dev/null)"
        [ -n "$code" ] && [ "$code" != "000" ] && {
            ntup=1
            break
        }
        sleep 0.3
    done
    assert_eq "no-token control server bound" "$ntup" "1"
    assert_eq "no-token control server: POST -> 403 (fail closed)" "$(hc -X POST "$U/apply" -H "Authorization: Bearer anything" -H 'Content-Type: application/json' -d '{"DONATION":2}')" "403"
    kill "$NT_PID" 2>/dev/null || true
    wait "$NT_PID" 2>/dev/null || true

    # #243: the WRITABLE control server must bind IPv6 dual-stack when its bind addr is v6, same as the
    # sister API — an IPv6-primary stack has to reach the control port too. Mirrors the api-server IPv6
    # test; skip cleanly if the host has no IPv6 loopback.
    if python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1",0)); s.close()' 2>/dev/null; then
        printf '{ "pools":[{"url":"h:3333"}], "ACCESS_TOKEN":"%s" }\n' "$CTOK" >"$CSRV/config.json"
        printf '{"status":"applied","change_id":"z6"}' >"$CSRV/state/status.json"
        C6PORT=$((20000 + RANDOM % 20000))
        python3 "$ROOT/util/control-server.py" "::" "$C6PORT" "$CSRV/state" "$CSRV/config.json" &
        C6_PID=$!
        c6up=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            curl -s -g -o /dev/null --max-time 2 -H "Authorization: Bearer $CTOK" "http://[::1]:$C6PORT/status" 2>/dev/null && {
                c6up=1
                break
            }
            sleep 0.3
        done
        assert_eq "control-server binds :: and answers over IPv6 (#243)" "$c6up" "1"
        assert_eq "IPv6 control-server: authed GET /status -> 200 (#243)" "$(hc -g -H "Authorization: Bearer $CTOK" "http://[::1]:$C6PORT/status")" "200"
        assert_eq "IPv6 control-server: unauthed POST -> 401 (#243)" "$(hc -g -X POST "http://[::1]:$C6PORT/apply" -H 'Content-Type: application/json' -d '{"DONATION":2}')" "401"
        assert_eq "dual-stack :: control-server also answers IPv4 loopback (#243)" "$(hc -H "Authorization: Bearer $CTOK" "http://127.0.0.1:$C6PORT/status")" "200"
        kill "$C6_PID" 2>/dev/null || true
        wait "$C6_PID" 2>/dev/null || true
    else
        echo "  SKIP: no IPv6 loopback — control-server IPv6 bind test (#243)"
    fi
fi

# ---------------------------------------------------------------------------
# #183: rig_lock — the flock both release gates take before touching the shared rig (miner-0).
# The function under test is extracted from the suites themselves (duplicated there on purpose —
# no shared lib), so first pin that contract: the two copies must be identical, verbatim. The
# behaviour tests then drive the real function against sandboxed RIG_LOCK_FILE/RIG_LOCK_HOLDER
# paths — no root, no /var/lock — with background subshells as the competing "suites".
# #214: perf recording judges BEFORE it writes — the recording run is the only perf gate most
# rigs ever get, so a regressed measurement must fail the phase and leave the baseline untouched
# (E2E_PERF_FORCE=1 is the conscious override). #267: the harness must exercise the REAL
# summary/exit plumbing (ok/bad/summary extracted verbatim from e2e-real.sh, same as the rig_lock
# tests do it below) rather than reimplement it — only phase and the bench are stubbed.
echo "== unit: e2e-real perf record gate (#214/#267) =="
PJ="$(mktemp -d "$SANDBOX/pj.XXXXXX")"
sed -n '/^ok() {$/,/^}/p; /^bad() {$/,/^}/p; /^summary() {$/,/^}/p; /^_perf_judge()/,/^}/p; /^perf()/,/^}/p' "$ROOT/tests/e2e-real.sh" >"$PJ/fns.sh"
cat >"$PJ/rigforge-stub" <<'EOF'
#!/usr/bin/env bash
[ "$1" = bench ] && echo "${STUB_BENCH_HS:-10000.0} H/s"
exit 0
EOF
chmod +x "$PJ/rigforge-stub"
run_perf() { # env: STUB_BENCH_HS E2E_PERF_RECORD E2E_PERF_FORCE; prints output; rc = perf()'s real summary/exit
    (
        cd "$PJ" || exit 9
        HERE="$PJ"
        RIGFORGE="$PJ/rigforge-stub"
        PASS=0
        FAIL=0
        phase() { :; }
        source "$PJ/fns.sh"
        perf 2>&1
    )
}
host="$(hostname)"
mkdir -p "$PJ/tests/perf-baselines"
printf '{"bench_1m_hs": 10000.0, "cpu": "x", "recorded": "2026-07-10"}\n' >"$PJ/tests/perf-baselines/$host.json"
printf '{"tag":"v0","recorded":"2026-07-10","bench_1m_hs":10000.0}\n' >"$PJ/tests/perf-baselines/$host.history.jsonl"
out="$(STUB_BENCH_HS=9990.0 E2E_PERF_RECORD=1 run_perf)"
rc=$?
assert_rc "record: healthy measurement passes the judge (#214)" "$rc" "0"
assert_contains "record: healthy measurement is recorded (#214)" "$out" "baseline recorded"
assert_eq "record: baseline updated (#214)" "$(jq -r .bench_1m_hs "$PJ/tests/perf-baselines/$host.json")" "9990.0"
assert_eq "record: history appended (#214)" "$(grep -c . "$PJ/tests/perf-baselines/$host.history.jsonl")" "2"
out="$(STUB_BENCH_HS=9000.0 E2E_PERF_RECORD=1 run_perf)"
rc=$?
[ "$rc" -ge 1 ] && ok "record: regression fails the phase (#214)" || bad "record: regression fails the phase (#214)" "rc=$rc"
assert_contains "record: regression refuses to write (#214)" "$out" "NOT recorded"
assert_eq "record: regressed baseline untouched (#214)" "$(jq -r .bench_1m_hs "$PJ/tests/perf-baselines/$host.json")" "9990.0"
assert_eq "record: regressed history untouched (#214)" "$(grep -c . "$PJ/tests/perf-baselines/$host.history.jsonl")" "2"
out="$(STUB_BENCH_HS=9000.0 E2E_PERF_RECORD=1 E2E_PERF_FORCE=1 run_perf)"
assert_contains "record: FORCE records a regression loudly (#214)" "$out" "REGRESSED measurement"
assert_eq "record: FORCE actually wrote (#214)" "$(jq -r .bench_1m_hs "$PJ/tests/perf-baselines/$host.json")" "9000.0"
out="$(STUB_BENCH_HS=9000.0 run_perf)"
rc=$?
[ "$rc" -ge 1 ] && ok "judge: regression vs best-ever still fails (#214)" || bad "judge: regression vs best-ever still fails (#214)" "rc=$rc"
assert_contains "judge: ratchet names best-ever (#214)" "$out" "RATCHET"
rm "$PJ/tests/perf-baselines/$host.json" "$PJ/tests/perf-baselines/$host.history.jsonl"
out="$(STUB_BENCH_HS=9000.0 E2E_PERF_RECORD=1 run_perf)"
rc=$?
assert_rc "record: first-ever recording needs no judge (#214)" "$rc" "0"
assert_eq "record: first-ever wrote the baseline (#214)" "$(jq -r .bench_1m_hs "$PJ/tests/perf-baselines/$host.json")" "9000.0"

# #362: the DynamicUser services (control/api) can't traverse a checkout under a mode-750 $HOME —
# require_traversable_checkout catches it before any phase runs. Same extraction+eval technique as
# rig_lock below. `stat` is faked (not a real directory tree) so the result never depends on the REAL
# host's tmp/HOME permissions, which this exact suite run already showed vary by OS (#362 dev note:
# mktemp -d is 700 on macOS, and even its TMPDIR parent can be 700) — a real-directory version of this
# test would be hostage to whatever the CI runner or developer's box happens to have.
echo "== unit: require_traversable_checkout — DynamicUser traversal pre-flight (#362) =="
RTC_SRC="$(sed -n '/^require_traversable_checkout()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
if [ -z "$RTC_SRC" ]; then
    bad "could not extract require_traversable_checkout from e2e-real.sh (#362)" "sed extraction was empty"
else
    RTCD="$(mktemp -d "$SANDBOX/travcheck.XXXXXX")"
    mkdir -p "$RTCD/bin"
    # The exact shape #362 found live: the checkout itself (mode 750) blocks; its ancestors don't.
    cat >"$RTCD/bin/stat" <<'EOF'
#!/usr/bin/env bash
case "$3" in
"/home/miner/rigforge") echo 750 ;;
*) echo 755 ;;
esac
EOF
    chmod +x "$RTCD/bin/stat"
    out="$( (
        eval "$RTC_SRC"
        die() {
            echo "DIE: $1"
            exit 2
        }
        set +e
        PATH="$RTCD/bin:$PATH" require_traversable_checkout /home/miner/rigforge/tests
        echo "rc=$?"
    ) 2>&1)"
    assert_contains "a mode-750 ancestor is caught (#362)" "$out" "DIE:"
    assert_contains "names the exact blocking path and mode (#362)" "$out" "'/home/miner/rigforge' is mode 750"
    assert_contains "names the remedy (#362)" "$out" "/opt/rigforge-e2e"
    out2="$( (
        eval "$RTC_SRC"
        die() {
            echo "DIE: $1"
            exit 2
        }
        set +e
        PATH="$RTCD/bin:$PATH" require_traversable_checkout /opt/rigforge-e2e
        echo "rc=$?"
    ) 2>&1)"
    assert_absent "a fully-traversable path never dies (#362)" "$out2" "DIE:"
    assert_contains "a fully-traversable path returns cleanly (#362)" "$out2" "rc=0"
fi

echo "== unit: e2e-pithead dashboard leg — hardened-dashboard curl + no vacuous drop-off (#390) =="
DC_SRC="$(sed -n '/^dash_curl()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
PD_SRC="$(sed -n '/^phase_dashboard()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
DDIR="$(mktemp -d "$SANDBOX/dash390.XXXXXX")"
# dash_curl behavior: a stub curl records its argv; the helper must follow redirects through the
# self-signed cert (-kLfsS; -f keeps an HTTP-error payload empty instead of an error page) and present E2E_DASH_AUTH via -u only when set.
mkdir -p "$DDIR/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$DC_ARGS"\n' >"$DDIR/bin/curl"
chmod +x "$DDIR/bin/curl"
out="$( (
    eval "$DC_SRC"
    export DC_ARGS="$DDIR/args.with"
    E2E_DASH_URL="http://stack-host/api/state" E2E_DASH_AUTH="probe:pw" PATH="$DDIR/bin:$PATH" dash_curl >/dev/null
    export DC_ARGS="$DDIR/args.without"
    E2E_DASH_URL="http://stack-host/api/state" E2E_DASH_AUTH="" PATH="$DDIR/bin:$PATH" dash_curl >/dev/null
) 2>&1)"
assert_contains "dash_curl follows redirects + accepts the stack cert (#390)" "$(cat "$DDIR/args.with")" "-kLfsS"
assert_contains "dash_curl presents basic-auth creds when E2E_DASH_AUTH is set (#390)" "$(cat "$DDIR/args.with")" "probe:pw"
assert_absent "dash_curl sends no -u when E2E_DASH_AUTH is empty (#390)" "$(cat "$DDIR/args.without")" "probe:pw"
# Never-visible worker: the leg must report the failure and SKIP the drop-off check — before #390
# the loop broke on its first probe and reported "dropped off within 0s", a pass that measured
# nothing. Mutation (run during review): restoring the pre-#390 body (no skip/return) makes the
# assert_absent below go red.
pd_run() { # <dash_curl-body> -> phase_dashboard transcript with stubbed collaborators
    (
        eval "$PD_SRC"
        eval "dash_curl() { $1; }"
        phase() { :; }
        skip() { printf 'SKIP %s\n' "$1"; }
        ok() { printf 'OK %s\n' "$1"; }
        bad() { printf 'BAD %s\n' "$1"; }
        RIGFORGE=true E2E_DASH_URL="http://stack-host/api/state" E2E_DROPOFF_TIMEOUT=1 phase_dashboard
    ) 2>&1
}
out="$(pd_run 'printf no-workers-here')"
assert_contains "never-visible worker reads as a failure (#390)" "$out" "BAD worker"
assert_contains "drop-off is skipped when visibility never held (#390)" "$out" "SKIP drop-off check skipped"
assert_absent "no vacuous dropped-off pass on a never-visible worker (#390)" "$out" "dropped off within"
# Visible-then-stopped worker: the drop-off pass must still function (first probe sees the rig,
# later probes do not).
out="$(pd_run 'if [ ! -f "'"$DDIR"'/seen" ]; then touch "'"$DDIR"'/seen"; hostname; fi')"
assert_contains "visible worker passes the visibility check (#390)" "$out" "OK worker"
assert_contains "stopped worker still measured dropping off (#390)" "$out" "OK stopped worker dropped off"

echo "== unit: rig_lock — the shared-rig flock (#183) =="
RL_SRC="$(sed -n '/^rig_lock()/,/^}/p' "$ROOT/tests/e2e-real.sh")"
assert_eq "e2e-real.sh and e2e-pithead.sh carry the identical helper (#183)" \
    "$(sed -n '/^rig_lock()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")" "$RL_SRC"
# #269: the byte-compare above only sees rig_lock() itself, not _cleanup's own fallback drifting
# back to the pre-#244 path. Match the ":-" fallback shape, not bare text — e2e-real.sh/e2e-pithead.sh
# both legitimately mention the old path in an (#244) migration comment. Split so this needle can't self-match.
_stale_holder_pat=':-/run/rig-e2e.hold''er'
assert_eq "no code under tests/ still falls back to the pre-#244 holder path (#269)" \
    "$(grep -rl -- "$_stale_holder_pat" "$ROOT/tests" 2>/dev/null | wc -l | tr -d ' ')" "0"
if ! command -v flock >/dev/null 2>&1; then
    echo "  SKIP: no flock(1) on this host (macOS) — the lock-behaviour tests run in the Linux CI jobs"
else
    RLD="$(mktemp -d "$SANDBOX/riglock.XXXXXX")"
    export RIG_LOCK_FILE="$RLD/lock" RIG_LOCK_HOLDER="$RLD/holder"
    # Acquire in a background subshell, flag readiness, then hold until released (or killed). The
    # caller reads $! for the holder pid: the lock lives exactly as long as that process — which is
    # the property under test.
    rl_hold() { # <project> <suite> <mode-or-empty> <id>
        (
            eval "$RL_SRC"
            rig_lock "$1" "$2" "$3"
            touch "$RLD/up.$4"
            while [ ! -f "$RLD/release.$4" ]; do sleep 0.1; done
        ) &
    }
    rl_wait_up() { # <id> — wait on readiness, not sleep-and-hope
        local i=0
        while [ ! -f "$RLD/up.$1" ] && [ "$i" -lt 100 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        [ -f "$RLD/up.$1" ]
    }

    # (a) exclusive vs exclusive: the second exits 75 (EX_TEMPFAIL) and names the holder
    rl_hold rigforge e2e-real "" a
    RL_PID_A=$!
    rl_wait_up a || bad "exclusive holder never came up (#183)" "no up.a marker"
    out="$( (
        eval "$RL_SRC"
        rig_lock pithead dash-e2e ""
    ) 2>&1)"
    assert_rc "second exclusive acquire exits 75, EX_TEMPFAIL (#183)" "$?" "75"
    assert_contains "busy message names the holder: project suite pid (#183)" "$out" "rigforge e2e-real pid="
    assert_contains "busy message offers the queue knob (#183)" "$out" "RIG_LOCK_WAIT=1"

    # kill -9 the holder: the flock dies with the process, so the next exclusive acquires with no
    # manual cleanup — the stale sidecar (its trap never ran) is display-only debris, not a lock.
    kill -9 "$RL_PID_A" 2>/dev/null
    wait "$RL_PID_A" 2>/dev/null
    sleep 0.3 # a just-forked `sleep 0.1` inherits fd 9 and can pin the flock for its lifetime
    (
        eval "$RL_SRC"
        rig_lock rigforge after-kill ""
    ) 2>/dev/null
    assert_rc "after kill -9 the next exclusive acquires — no stale lock (#183)" "$?" "0"

    # (b) shared + shared coexist
    rl_hold rigforge reader-1 shared b
    RL_PID_B=$!
    rl_wait_up b || bad "shared holder never came up (#183)" "no up.b marker"
    (
        eval "$RL_SRC"
        rig_lock pithead reader-2 shared
    ) 2>/dev/null
    assert_rc "shared + shared coexist (#183)" "$?" "0"

    # (c) shared vs exclusive excludes
    (
        eval "$RL_SRC"
        rig_lock rigforge e2e-real ""
    ) 2>/dev/null
    assert_rc "exclusive against a shared holder exits 75 (#183)" "$?" "75"
    touch "$RLD/release.b"
    wait "$RL_PID_B" 2>/dev/null

    # (d) RIG_LOCK_WAIT=1 queues: blocked while held, acquires once the holder exits
    rl_hold rigforge e2e-real "" d
    RL_PID_D=$!
    rl_wait_up d || bad "wait-test holder never came up (#183)" "no up.d marker"
    (
        eval "$RL_SRC"
        RIG_LOCK_WAIT=1 rig_lock pithead queued ""
        touch "$RLD/got.q"
    ) 2>"$RLD/err.q" &
    RL_PID_Q=$!
    sleep 1
    assert_eq "RIG_LOCK_WAIT=1 blocks while the lock is held (#183)" \
        "$([ -f "$RLD/got.q" ] && echo acquired || echo blocked)" "blocked"
    assert_contains "queued waiter announces whom it waits on (#183)" "$(cat "$RLD/err.q")" "waiting"
    touch "$RLD/release.d"
    wait "$RL_PID_D" 2>/dev/null
    wait "$RL_PID_Q"
    assert_rc "queued waiter exits 0 once the holder exits (#183)" "$?" "0"
    assert_eq "queued waiter actually acquired (#183)" \
        "$([ -f "$RLD/got.q" ] && echo acquired || echo blocked)" "acquired"

    # #242: the lock is opened READ-only, so a pre-existing lock file (a leftover a non-root
    # reserve created earlier) is acquired without needing to O_CREAT-write it — which is what
    # dodges fs.protected_regular's block on root re-opening a non-root-created file in /run/lock.
    RIG_LOCK_FILE="$RLD/pre" RIG_LOCK_HOLDER="$RLD/pre.holder"
    : >"$RIG_LOCK_FILE" # pre-exists before any rig_lock call
    (eval "$RL_SRC" && rig_lock rigforge pre-existing "" && touch "$RLD/pre.ok") 2>/dev/null
    assert_eq "acquires a pre-existing lock file (#242)" "$([ -f "$RLD/pre.ok" ] && echo y || echo n)" "y"
    # A lock file left at a restrictive mode is normalized and still acquired (the root+sticky
    # protected_regular sidestep itself — read-open of a non-root-created file — needs a live root
    # rig and is covered by the e2e gate, not this sandbox).
    RIG_LOCK_FILE="$RLD/ro" RIG_LOCK_HOLDER="$RLD/ro.holder"
    : >"$RIG_LOCK_FILE" && chmod 444 "$RIG_LOCK_FILE"
    (eval "$RL_SRC" && rig_lock rigforge restrictive "" && touch "$RLD/ro.ok") 2>/dev/null
    assert_eq "normalizes + acquires a restrictive-mode lock file (#242)" "$([ -f "$RLD/ro.ok" ] && echo y || echo n)" "y"
    chmod 666 "$RLD/ro" 2>/dev/null || true

    # #244: with RIG_LOCK_HOLDER unset, the breadcrumb defaults BESIDE the lock (not root-owned
    # /run) and its timestamp is the portable Zulu form, not GNU-only `date -Iseconds` (+00:00).
    RIG_LOCK_FILE="$RLD/def.lock"
    (unset RIG_LOCK_HOLDER && eval "$RL_SRC" && rig_lock rigforge deftest "" && touch "$RLD/def.up" && while [ ! -f "$RLD/def.rel" ]; do sleep 0.1; done) &
    DEF_PID=$!
    _i=0
    while [ ! -f "$RLD/def.up" ] && [ "$_i" -lt 50 ]; do
        sleep 0.1
        _i=$((_i + 1))
    done
    assert_eq "holder defaults beside the lock, not /run (#244)" "$([ -f "$RLD/def.lock.holder" ] && echo y || echo n)" "y"
    def_holder="$(cat "$RLD/def.lock.holder" 2>/dev/null)"
    assert_contains "holder uses a portable UTC timestamp (#244)" "$def_holder" "started=$(date -u +%Y-%m-%dT)"
    assert_absent "holder timestamp isn't the GNU -Iseconds offset form (#244)" "$def_holder" "+00:00"
    touch "$RLD/def.rel"
    wait "$DEF_PID" 2>/dev/null
    assert_eq "holder cleaned up on exit (#244)" "$([ -f "$RLD/def.lock.holder" ] && echo present || echo gone)" "gone"

    # scan hardening: refuse a symlinked lock path (a planted symlink in world-writable /run/lock
    # could otherwise redirect the root-side create/chmod/holder-write onto another file).
    ln -s "$RLD/some-target" "$RLD/sym.lock"
    (
        RIG_LOCK_FILE="$RLD/sym.lock"
        eval "$RL_SRC" && rig_lock rigforge symtest "" && touch "$RLD/sym.acquired"
    ) 2>/dev/null
    assert_eq "refuses a symlinked lock path (scan hardening)" "$([ -f "$RLD/sym.acquired" ] && echo acquired || echo refused)" "refused"
    rm -f "$RLD/sym.lock"

    # (#249) the kernel flock is genuinely HELD for the whole run — probe with a RAW `flock -n`
    # (not rig_lock's own busy-check) so we assert the actual advisory lock sits on FD 9. The bug
    # #249 caught was rig_lock returning success while the flock was never held (`exec 9>` failing
    # silently on a root-owned lock under fs.protected_regular), leaving the shared box UNRESERVED.
    # The read-open (#242) sidesteps that; here we prove the hold directly. (Re-confirmed live on
    # the rig during the v1.8.0 gate: a raw `flock -n` failed 91/91 one-second probes over a perf run.)
    RIG_LOCK_FILE="$RLD/held" RIG_LOCK_HOLDER="$RLD/held.holder"
    rl_hold rigforge held-probe "" p
    RL_PID_P=$!
    rl_wait_up p || bad "held-probe holder never came up (#249)" "no up.p marker"
    flock -n -x "$RIG_LOCK_FILE" true 2>/dev/null
    assert_rc "raw flock -n FAILS while rig_lock holds it — flock genuinely held mid-run (#249)" "$?" "1"
    touch "$RLD/release.p"
    wait "$RL_PID_P" 2>/dev/null
    sleep 0.3 # let a just-forked child that inherited fd 9 exit before the free-probe
    flock -n -x "$RIG_LOCK_FILE" true 2>/dev/null
    assert_rc "raw flock -n succeeds after the holder exits — flock released (#249)" "$?" "0"

    # (#249) even if the holder marker CANNOT be written at all — plain write AND `sudo -n tee` both
    # fail (here: an unwritable parent dir) — the run must still ACQUIRE and HOLD the flock. The
    # best-effort `|| true` must never let a failed DISPLAY-ONLY write abort the run and drop the lock.
    RIG_LOCK_FILE="$RLD/hf.lock" RIG_LOCK_HOLDER="$RLD/no-such-dir/holder"
    (eval "$RL_SRC" && rig_lock rigforge hf-fail "" && touch "$RLD/hf.up" && while [ ! -f "$RLD/hf.rel" ]; do sleep 0.1; done) &
    HF_PID=$!
    _i=0
    while [ ! -f "$RLD/hf.up" ] && [ "$_i" -lt 50 ]; do
        sleep 0.1
        _i=$((_i + 1))
    done
    assert_eq "rig_lock acquires despite an unwritable holder path (#249)" "$([ -f "$RLD/hf.up" ] && echo up || echo dead)" "up"
    flock -n -x "$RLD/hf.lock" true 2>/dev/null
    assert_rc "flock stays HELD even when the holder write fails entirely (#249)" "$?" "1"
    assert_eq "the unwritable holder was indeed never created (#249)" "$([ -f "$RLD/no-such-dir/holder" ] && echo y || echo n)" "n"
    touch "$RLD/hf.rel"
    wait "$HF_PID" 2>/dev/null

    unset RIG_LOCK_FILE RIG_LOCK_HOLDER
fi

# ---------------------------------------------------------------------------
echo "== contract guard: wire-shape fixtures (#351) =="
# Cross-repo tripwire: pithead's fakes fetch and byte-compare tests/contract/v1/*.json against a
# live worker. Regenerate the SAME shapes here through the real code (api_refresh / _control_status,
# not hand-written JSON), normalize the couple of fields that legitimately vary release-to-release
# or run-to-run, and diff against the committed fixture — see tests/contract/v1/README.md for the
# normalization list and the change rule. This is what makes a wire-shape drift fail HERE instead of
# only ever surfacing as a manual live run against a real pithead stack.
#
# _control_status (rigforge.sh) is only HALF the wire: util/control-server.py's own do_GET serves a
# 503 no-history body of its own, stage_pending() writes a `pending` record neither rigforge.sh nor
# _control_status ever produces, and _with_age() injects a derived age_seconds into EVERY served body
# — none of that exists on disk for _control_status()-side generation to find. Regenerating only
# through rigforge.sh made the guard structurally blind to anything the Python receiver adds or emits
# itself. The vocabulary check below is unioned across both sources, and the record-shape check below
# that drives the REAL util/control-server.py over HTTP (same harness as the "#236 black-box: the
# control server" section above) for exactly the three things only IT can produce.
CONTRACT_DIR="$ROOT/tests/contract/v1"

# --- vocabulary: every literal status word rigforge.sh hands to _control_status (the call sites, not
# a hand-maintained list) UNIONED with every `"status": "<word>"` literal control-server.py itself
# writes to a file GET /status can serve (stage_pending's `pending`; a same-line `_send(202, ...)` is
# excluded — that's the synchronous POST /apply|/upgrade accept ack, a different value than anything
# a later GET /status call returns, so it does not belong in this vocabulary). A new status word from
# EITHER side can't land without this noticing, fixture update or not.
live_statuses_bash="$(grep -oE '_control_status "\$status" [a-z_]+' "$SCRIPT" | awk '{print $3}')"
live_statuses_py="$(grep -v '_send(202' "$ROOT/util/control-server.py" | grep -oE '"status": "[a-z_]+"' | sed -E 's/.*"([a-z_]+)"$/\1/')"
live_statuses="$(printf '%s\n%s\n' "$live_statuses_bash" "$live_statuses_py" | sort -u | jq -R . | jq -cs .)"
fixture_statuses="$(jq -c '.statuses' "$CONTRACT_DIR/control-status.json")"
assert_eq "control status vocabulary matches the fixture, rigforge.sh + control-server.py union (#351/#320/#344)" "$live_statuses" "$fixture_statuses"

# --- shape: one example record per TERMINAL/started status, produced by the actual _control_status
# writer (the single choke point control_apply and control_upgrade both go through) with fixed
# inputs, so applied_at is the only volatile field (normalized below). age_seconds is additionally
# normalized here though _control_status never writes it — it's serve-time-derived by
# control-server.py's _with_age() on every real GET /status, so it's part of the wire shape a poller
# actually sees; the server-driven leg below proves _with_age genuinely adds it rather than just
# asserting the fixture says so. Full orchestration through control_apply/control_upgrade is already
# exercised elsewhere in this file; this re-derives the exact wire record for each status the same
# way those call sites do.
CTLFX="$(mktemp -d "$SANDBOX/ctlfx.XXXXXX")"
mk_status_record() { # <status> <cid> <keys-csv> <reason> <backup>
    local d f
    d=$(mktemp -d "$CTLFX/s.XXXXXX")
    f="$d/status.json"
    (
        source "$SCRIPT"
        set +e
        _control_status "$f" "$1" "$2" "$3" "$4" "$5"
    ) >/dev/null 2>&1
    jq -S '.applied_at = "NORMALIZED" | .age_seconds = "NORMALIZED"' "$f"
}

# --- server-driven: the `pending` example, the 503 no-history body, and proof that a served terminal
# record really does carry age_seconds — all three exist only in util/control-server.py, so only the
# real server (not _control_status) can produce them. Same spin-up/curl/kill harness as "#236
# black-box: the control server" above, a dedicated instance so this doesn't depend on that section's
# mutated state.
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not present (kcov container) — the server-driven contract legs run in the other CI jobs"
else
    CGSRV="$(mktemp -d "$SANDBOX/cgsrv.XXXXXX")"
    mkdir -p "$CGSRV/state"
    CGTOK="tok-cg1"
    printf '{ "pools":[{"url":"h:3333"}], "ACCESS_TOKEN":"%s" }\n' "$CGTOK" >"$CGSRV/config.json"
    CGPORT=$((20000 + RANDOM % 20000))
    python3 "$ROOT/util/control-server.py" 127.0.0.1 "$CGPORT" "$CGSRV/state" "$CGSRV/config.json" &
    CGSRV_PID=$!
    CGU="http://127.0.0.1:$CGPORT"
    cgup=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -s -o /dev/null --max-time 2 -H "Authorization: Bearer $CGTOK" "$CGU/status" 2>/dev/null && {
            cgup=1
            break
        }
        sleep 0.3
    done
    assert_eq "contract-guard control server comes up (#351)" "$cgup" "1"

    # 503 no-history: do_GET's OWN fallback when state/status.json has never been written — invisible
    # to _control_status()-side generation by construction (that function is never called with "no
    # history yet"; only a fresh do_GET can produce this body).
    live_no_history="$(jq -Sn --argjson code "$(hc "$CGU/status" -H "Authorization: Bearer $CGTOK")" \
        --argjson body "$(curl -sS --max-time 5 -H "Authorization: Bearer $CGTOK" "$CGU/status" 2>/dev/null)" \
        '{body: $body, http_status: $code}')"
    fixture_no_history="$(jq -S '.no_history' "$CONTRACT_DIR/control-status.json")"

    # pending: staged by the REAL /apply accept path (stage_pending()) — the only source for this
    # status word; _control_status never writes it. change_id is server-random
    # (os.urandom(8).hex() in stage_change), unlike the fixed cid's mk_status_record supplies above,
    # so it's normalized here same as accepted_at/age_seconds — see contract/v1/README.md.
    pcid="$(curl -sS --max-time 5 -X POST "$CGU/apply" -H "Authorization: Bearer $CGTOK" -H 'Content-Type: application/json' -d '{"DONATION":2}' 2>/dev/null | jq -r .change_id)"
    live_pending="$(curl -sS --max-time 5 -H "Authorization: Bearer $CGTOK" "$CGU/status?change_id=$pcid" 2>/dev/null |
        jq -S '.accepted_at = "NORMALIZED" | .age_seconds = "NORMALIZED" | .change_id = "NORMALIZED"')"

    # age_seconds on a served TERMINAL record: _with_age derives it from applied_at for status.json
    # too, not just the pending path — assert this against the real serving code, not just the fixture.
    printf '{"status":"applied","change_id":"9999999999999999","applied_at":"2020-01-01T00:00:00Z"}' >"$CGSRV/state/status.json"
    tbody="$(curl -sS --max-time 5 -H "Authorization: Bearer $CGTOK" "$CGU/status" 2>/dev/null)"
    assert_eq "age_seconds present on a served terminal record (#351/#344)" "$(printf '%s' "$tbody" | jq 'has("age_seconds")')" "true"

    kill "$CGSRV_PID" 2>/dev/null || true
    wait "$CGSRV_PID" 2>/dev/null || true

    assert_eq "control server's no-history 503 matches the fixture (#351)" "$live_no_history" "$fixture_no_history"

    live_examples="$(jq -Sn \
        --argjson started "$(mk_status_record started 1111111111111111 version '' '')" \
        --argjson applied "$(mk_status_record applied 2222222222222222 version 'upgraded to v9.9.9' '')" \
        --argjson noop "$(mk_status_record noop 3333333333333333 version 'already on v9.9.9 — nothing to upgrade' '')" \
        --argjson throttled "$(mk_status_record throttled 4444444444444444 version 'throttled — too soon since the last upgrade attempt' '')" \
        --argjson failed "$(mk_status_record failed 5555555555555555 version 'staged upgrade target malformed (want vX.Y.Z)' '')" \
        --argjson rejected "$(mk_status_record rejected 6666666666666666 DONATION 'rejected merge-failed' '')" \
        --argjson rolled_back "$(mk_status_record rolled_back 7777777777777777 watchdog,DONATION 'miner did not return to a live hashrate; rolled back and live' /b)" \
        --argjson pending "$live_pending" \
        '{applied: $applied, failed: $failed, noop: $noop, pending: $pending, rejected: $rejected, rolled_back: $rolled_back, started: $started, throttled: $throttled}')"
    fixture_examples="$(jq -S '.examples' "$CONTRACT_DIR/control-status.json")"
    assert_eq "control status record shape matches the fixture (#351)" "$live_examples" "$fixture_examples"
fi

# --- feed: the rigforge block's shape, produced by the real api_refresh path. This file's own
# HARDWARE INDEPENDENCE exports (top of file: MEMINFO/GOVERNOR_FILE/RAPL_DIR/...) already make
# health/tune/watchdog fully deterministic on any machine; only installed-software provenance
# varies release to release, so that's all that needs normalizing.
FEEDFX="$(mktemp -d "$SANDBOX/feedfx.XXXXXX")"
mkdir -p "$FEEDFX/home" "$FEEDFX/data" "$FEEDFX/control"
printf 'v0.0.0-fixture\n' >"$FEEDFX/VERSION"
printf '{ "HOME_DIR": "%s/home", "pools": [{"url": "h:3333", "pass": "secret"}], "watchdog": "enabled", "max_temp_c": 85 }\n' "$FEEDFX" >"$FEEDFX/config.json"
printf '%s' '{"status":"rolled_back","change_id":"7777777777777777","source":"control","applied_at":"2026-01-01T00:00:00Z","changed_keys":["watchdog","DONATION"],"reason":"miner did not return to a live hashrate; rolled back and live","backup":"/b","warnings":["thermal protection changed: watchdog"]}' >"$FEEDFX/control/status.json"
printf '%s' '{"hashrate":{"total":[1234.5,0,0]},"connection":{"pool":"poolbox.lan:3333","uptime":93700,"failures":0,"accepted":42,"rejected":1},"uptime":93780,"hugepages":[1248,1248]}' >"$FEEDFX/xmrig-body.json"
(
    source "$SCRIPT"
    OS_TYPE=Linux
    SCRIPT_DIR="$FEEDFX"
    CONFIG_JSON="$FEEDFX/config.json"
    # source-time CONFIG_META_FILE was derived from the REAL $SCRIPT_DIR (above), not this sandbox —
    # override it explicitly (same reason the #253/#254 contract-pin test above does) or this reads
    # whatever `apply()` left at the real repo root from an earlier test in this same run.
    CONFIG_META_FILE="$FEEDFX/meta.json"
    RIGFORGE_API_DATA="$FEEDFX/data"
    RIGFORGE_CONTROL_STATE="$FEEDFX/control"
    API_CMD="cat '$FEEDFX/xmrig-body.json'"
    # _health_json shells out to the REAL `systemctl is-active` for service_active — API_CMD only
    # replaces the worker-API curl, not that. On any Linux box genuinely running the xmrig unit (i.e.
    # every fleet rig) the untouched default SERVICE_NAME=xmrig would read "active" there and byte-
    # diff this fixture on rigs while passing everywhere else. Point it at a unit name no rig will
    # ever have instead of putting $STUBS on PATH: the generic systemctl stub there always exits 0
    # (fine for the tests that use it, which never assert exact service_active/autotune values), which
    # would make this read "active" unconditionally instead of fixing anything. Pins service_active:
    # false and, since both are gated on it, clock_pct_of_boost/throttling: null too — see
    # contract/v1/README.md.
    SERVICE_NAME="rigforge-contract-fixture-nonexistent"
    set +e
    api_refresh 2>/dev/null
)
live_feed="$(jq -S '.rigforge.version = "NORMALIZED" | .rigforge.xmrig_version = "NORMALIZED" | .rigforge.xmrig_commit = "NORMALIZED"' "$FEEDFX/data/summary.json")"
fixture_feed="$(jq -S . "$CONTRACT_DIR/feed.json")"
assert_eq "sister-API feed shape matches the fixture (#351)" "$live_feed" "$fixture_feed"

# ---------------------------------------------------------------------------
echo ""
echo "== tree hygiene: the suite writes nothing into the tracked tree (#418) =="
if [ "$PYCACHE_PRE" = present ]; then
    echo "  SKIP: util/__pycache__ predates this run — it cannot be attributed to the suite"
else
    pycache_post=absent
    [ -e "$ROOT/util/__pycache__" ] && pycache_post=present
    assert_eq "no util/__pycache__ left in the tracked tree (#418)" "$pycache_post" "absent"
fi

# ---------------------------------------------------------------------------
echo ""
printf 'rigforge tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
