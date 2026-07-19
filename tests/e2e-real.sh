#!/usr/bin/env bash
#
# Release-gated full e2e — the real-hardware pre-tag gate (generalizes #61's bench-only smoke check).
#
# Our testing split: CI does everything it can on a GitHub runner (lint, the dependency-free suite, the
# Docker /etc e2e, the kcov coverage gate). What CI CANNOT do — compile XMRig, reserve HugePages, write
# the prefetcher MSRs, set the governor, and actually HASH — this does, for real, on a real Linux rig.
# Run it before tagging a release; it is deliberately NOT a CI job (real build + HugePages + mining are
# flaky-by-nature and against Actions' ToS).
#
# It drives the genuine commands end to end and asserts each step:
#   provision : sudo ./rigforge.sh setup   -> deps + real XMRig build + tuning + kernel tuning + service
#   (reboot)  : HugePages (1G + the GRUB cmdline) only take effect on boot
#   verify    : doctor (HugePages/MSR/governor/service) + bench (real H/s) + tune (perf/efficiency/confirm)
#               + autotune (the LIVE re-tune engine the monthly timer drives) + tune --history + the
#               systemd re-own + EVERY verb & alias (version/-v/--version, help/-h/--help, status, logs,
#               start|up, stop|down, restart, enable, disable, upgrade, backup, restore, apply, autotune
#               + non-root doctor)
#   control   : the writable control path (#236), for real, for the first time — enable it, prove the
#               receiver is up, POST a benign change through it, poll the real path-unit -> control-apply
#               round trip to "applied", assert it landed (config + revision + live miner), then revert.
#               Config is snapshotted and control is force-disabled again on ANY exit (see _control_cleanup) —
#               the fleet runs this disabled on purpose and this phase must never leave it on.
#   upgrade   : the remote-upgrade chain (#308/#322) against the real units and REAL git — a noop leg
#               (POST the installed version -> terminal `noop`), a rollback leg (a forged tag the D10
#               ancestry guard must refuse -> `rolled_back`, tree + VERSION untouched, throttle
#               stamped), and an opt-in forward leg (E2E_UPGRADE_TARGET). Same snapshot/revert
#               guarantees as control.
#   teardown  : sudo ./rigforge.sh uninstall --yes  -> assert a clean revert of every system path + idempotency
#
# Env knobs:
#   E2E_ALLOW_OFFLINE_POOL       1 = don't fail the connect check when the pool is unreachable
#   E2E_SHARE_TIMEOUT            seconds to wait for an accepted share (default 180)
#   E2E_AUTOTUNE_MODES           autotune modes exercised by the live-tune check
#   E2E_AUTOTUNE_WARMUP          seconds the live autotune lets each candidate warm up
#   E2E_AB_WARMUP                seconds the A/B tune check warms up per side
#   E2E_PERF_TOLERANCE_PCT       allowed drop vs the committed baseline/best-ever (default 5)
#   E2E_PERF_RECORD              1 = record the baseline + append history instead of judging
#   E2E_PERF_TAG                 release tag stamped into the history entry (with E2E_PERF_RECORD)
#   E2E_UPGRADE_TARGET           vX.Y.Z = the upgrade phase also drives a REAL forward upgrade to this
#                                release and asserts it lands (PERMANENT: upgrades the checkout)
#
# Linux-only and root-only (kernel tuning, modprobe, apt). Typical flow on the release rig:
#   sudo bash tests/e2e-real.sh provision
#   sudo reboot                         # then reconnect
#   sudo bash tests/e2e-real.sh verify
#   sudo bash tests/e2e-real.sh control
#   sudo bash tests/e2e-real.sh upgrade
#   sudo bash tests/e2e-real.sh teardown
# Or, when HugePages are already active (no reboot needed), one shot:
#   sudo bash tests/e2e-real.sh all
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIGFORGE="$HERE/rigforge.sh"
GOVERNOR_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"

PASS=0
FAIL=0
# control phase state (script-global, not `local` — must survive past control()'s own return so a
# late trap fire, e.g. during a later phase in `all` mode, is still a safe idempotent no-op; see
# _control_cleanup).
CTL_SAVED_CFG=""
CTL_CLEANUP_DONE=0
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n' "$1" >&2
}
phase() { printf '\n\033[1m== e2e-real: %s ==\033[0m\n' "$1"; }
die() {
    printf '\033[31me2e-real: %s\033[0m\n' "$1" >&2
    exit 2
}

# #183: the shared-rig lock. miner-0 hosts BOTH RigForge's release gates (rig-mutating) and
# Pithead's e2e (API-reading, assumes a steadily-hashing miner) — a kernel flock serializes them.
# Exclusive for mutators, `shared` for future read-only modes; the lock dies with the holding
# process, so a killed run never needs cleanup. Pithead's harness carries the same helper against
# the same path — the path IS the contract. Duplicated verbatim in tests/e2e-pithead.sh on purpose
# (15 lines beat a lib two repos must share; tests/run.sh guards the copies against drift). The
# env-overridable paths exist only so tests/run.sh can sandbox it without root. FD 9 is inherited
# by children — that is what keeps the lock held for the whole run; do not close it.
rig_lock() { # rig_lock <project> <suite> [shared]
    local mode=-x
    [ "${3:-}" = shared ] && mode=-s
    local lf="${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}"
    # Holder breadcrumb defaults BESIDE the lock, not under root-owned /run (a non-root box can't
    # write /run/rig-e2e.holder — the lock still holds, but the write errors with stderr noise). (#244)
    local hf="${RIG_LOCK_HOLDER:-$lf.holder}"
    # /run/lock is world-writable + sticky; refuse a symlinked lock/holder path so a planted symlink
    # can't redirect our root-side create/chmod/holder-write onto another file (defence for a
    # multi-tenant box; single-tenant rigs aren't exposed, but the guard is free).
    { [ -L "$lf" ] || [ -L "$hf" ]; } && {
        echo "rig_lock: lock/holder path is a symlink — refusing" >&2
        exit 1
    }
    # Open the lock READ-only (9<). A lock file first created by a NON-root flock (a manual reserve
    # after a reboot clears the /run/lock tmpfs) is owned by that user, and fs.protected_regular then
    # blocks even root's O_CREAT-*write* of it (a 9> open) with EACCES. A read-open is never guarded,
    # and flock -x/-s works fine on a read fd, so this sidesteps it without rm-ing a possibly-held
    # lock. Create it first if absent; keep it 0666 so a shared reader can still join. (#242)
    [ -e "$lf" ] || : >"$lf" 2>/dev/null || true
    chmod 666 "$lf" 2>/dev/null || true # best-effort world-writable; a read-open (9<) only needs o+r
    exec 9<"$lf"
    if ! flock -n $mode 9; then
        if [ "${RIG_LOCK_WAIT:-0}" = 1 ]; then
            echo "rig busy ($(cat "$hf" 2>/dev/null || echo unknown)) — waiting..." >&2
            flock $mode 9
        else
            echo "miner-0 busy: $(cat "$hf" 2>/dev/null || echo unknown). Retry with RIG_LOCK_WAIT=1 to queue." >&2
            exit 75 # EX_TEMPFAIL — callers can tell "busy, retry later" from a real failure
        fi
    fi
    # DISPLAY-ONLY and strictly best-effort. The flock is already HELD on FD 9 above; a holder
    # marker we can't write (a root-owned RIG_LOCK_HOLDER + a non-root runner) must NEVER abort
    # under set -e and drop the lock — that would leave the box UNRESERVED, the exact bug (#249).
    # Plain write, then passwordless sudo, then swallow. Portable UTC stamp — the GNU-only
    # `date -Iseconds` errors on BSD/macOS. (#244)
    local _line
    _line="$(printf '%s %s pid=%s started=%s' "$1" "$2" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    { printf '%s\n' "$_line" >"$hf" || printf '%s\n' "$_line" | sudo -n tee "$hf" >/dev/null; } 2>/dev/null || true
    # The trap fires at EXIT when the $hf local is out of scope, so re-derive the path from the
    # durable env/default; best-effort removal, may need sudo for a root-written marker. (#244/#249)
    trap 'rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || sudo -n rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || true' EXIT
}

# Drive `rigforge enable|disable` to a settled systemd boot-state. The gate hammers the service
# with many stop/start/restart/tune cycles, and systemctl/D-Bus can transiently drop a single
# enable/disable under that load — so poll is-enabled for the target state and re-issue the verb
# once before giving up. This absorbs flakes without masking a real break: a genuinely broken
# verb still never reaches the target state and fails. Returns 0 once the state is reached.
_set_boot() { # <enable|disable> <enabled|disabled>
    local verb=$1 want=$2 i
    "$RIGFORGE" "$verb" >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        case "$(systemctl is-enabled xmrig 2>/dev/null || true)" in
        *"$want"*) return 0 ;;
        esac
        [ "$i" = 6 ] && { "$RIGFORGE" "$verb" >/dev/null 2>&1 || true; } # one retry mid-way
        sleep 0.5
    done
    return 1
}

require_linux_root() {
    [ "$(uname -s)" = "Linux" ] || die "Linux-only (this host is $(uname -s)) — run on the release rig."
    [ "$(id -u)" -eq 0 ] || die "must run as root (kernel tuning / modprobe / apt): sudo bash tests/e2e-real.sh $*"
    [ -x "$RIGFORGE" ] || die "$RIGFORGE not found or not executable."
}

hugepages_total() { awk '/^HugePages_Total:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0; }
find_worker_bin() { find "$HERE" -type f -path '*xmrig/build/xmrig' 2>/dev/null | head -1; }

ensure_config() {
    # setup needs a valid config.json. Benching is OFFLINE so any valid pool entry suffices for the build +
    # bench + tune phases; default to an unroutable TEST-NET-3 (RFC 5737) host so the installed service
    # never mines to a real destination. NOTE: verify's live-pool round-trip is mandatory and FAILS on this
    # placeholder — set a real pool, or E2E_ALLOW_OFFLINE_POOL=1 for a deliberate offline run.
    if [ ! -f "$HERE/config.json" ]; then
        printf '{ "pools": [{ "url": "203.0.113.1:3333" }], "DONATION": 1, "add_to_path": true, "autotune": "performance" }\n' >"$HERE/config.json"
        ok "wrote a placeholder config.json (offline bench; the service won't mine; add_to_path + autotune on to exercise the CLI and the periodic-tune timer)"
    else
        ok "using the existing config.json"
    fi
}

# --- phases ------------------------------------------------------------------
provision() {
    require_linux_root provision
    ensure_config
    phase "provision — ./rigforge.sh setup (real deps + build + tuning + service)"
    "$RIGFORGE" setup 2>&1 | tee /tmp/e2e-provision.log

    # #cpu: as root, lscpu also prints a "BIOS Model name:" DMI line; setup's detected-CPU line must show
    # the clean model, not concatenate that line's "… Unknown CPU @ …" garbage.
    if grep -q 'Detected CPU:' /tmp/e2e-provision.log && ! grep -q 'Unknown CPU @' /tmp/e2e-provision.log; then
        ok "setup logged a clean CPU model ($(grep -oE 'Detected CPU: [^—]+' /tmp/e2e-provision.log | head -1 | sed 's/Detected CPU: //'))"
    else
        bad "setup's 'Detected CPU:' line looks garbled (lscpu BIOS-Model-name concatenation?)"
    fi

    local bin
    bin="$(find_worker_bin)"
    [ -n "$bin" ] && [ -x "$bin" ] && ok "XMRig binary was built ($bin)" || bad "no built XMRig binary found"
    systemctl cat xmrig >/dev/null 2>&1 && ok "systemd unit 'xmrig' installed" || bad "xmrig.service not installed"
    # #autotune: when config.json enables periodic autotune, setup must install the timer that drives the
    # monthly live re-tune (teardown later asserts it's removed). Mirror parse_config's enabled set; skip
    # cleanly when the operator's config didn't opt in.
    case "$(jq -r '.autotune // "disabled"' "$HERE/config.json" 2>/dev/null)" in
    performance | perf | efficiency | eff | true | on)
        systemctl cat rigforge-autotune.timer >/dev/null 2>&1 &&
            ok "periodic-autotune timer installed (config opted in)" ||
            bad "autotune is enabled in config.json but setup didn't install rigforge-autotune.timer"
        ;;
    *) ok "SKIP autotune-timer check — periodic autotune not enabled in config.json" ;;
    esac
    # #cli: opt-in. With "add_to_path": true, setup put a `rigforge` command on PATH; prove invoking it
    # THROUGH the symlink resolves the repo. Skip when the operator's config.json hasn't opted in.
    if [ "$(jq -r '.add_to_path // false' "$HERE/config.json" 2>/dev/null)" != "true" ]; then
        ok "SKIP rigforge-on-PATH check — add_to_path not enabled in config.json"
    elif [ -L /usr/local/bin/rigforge ]; then
        ok "the 'rigforge' command is on PATH (-> $(readlink /usr/local/bin/rigforge))"
        [ "$(rigforge version 2>&1)" = "$("$RIGFORGE" version 2>&1)" ] &&
            ok "'rigforge' (via PATH) matches ./rigforge.sh — symlink resolves the repo" ||
            bad "'rigforge' on PATH didn't resolve the repo (version mismatch vs ./rigforge.sh)"
    else
        bad "add_to_path is enabled but setup didn't install /usr/local/bin/rigforge"
    fi

    if [ "$(hugepages_total)" -gt 0 ]; then
        ok "HugePages already reserved — no reboot needed; you can run 'verify' now"
    else
        phase "REBOOT REQUIRED"
        echo "  HugePages need a reboot to take effect. Reboot the rig, then run:"
        echo "      sudo bash tests/e2e-real.sh verify"
    fi
    summary "provision"
}

verify() {
    require_linux_root verify
    # On a freshly rebooted rig the service has only just auto-started, so give it a moment to come fully
    # up — allocate the per-NUMA datasets, apply the MSR mod, and LOG it — before the doctor #66 check
    # below greps that log line. Without this, running `verify` immediately after the reboot races the
    # miner's startup logging and spuriously fails the MSR assertions (the mod is applied a beat later).
    # Best-effort: wait up to ~90s for a live API hashrate, then proceed regardless so a genuinely dead
    # miner still surfaces as a doctor failure rather than hanging.
    # The worker API is open (read-only) with no token by default now, so only send a Bearer when the
    # operator actually set ACCESS_TOKEN — XMRig 401s a token it never asked for, which under set -e +
    # pipefail (curl -f → exit 22) would abort verify here before it prints a thing.
    local _w _hr _tok _auth=()
    _tok=$(jq -r '.ACCESS_TOKEN // empty' "$HERE/config.json" 2>/dev/null || true)
    [ -n "$_tok" ] && _auth=(-H "Authorization: Bearer $_tok")
    for _w in $(seq 1 30); do
        _hr=$(curl -fsS --max-time 4 "${_auth[@]}" http://127.0.0.1:8080/2/summary 2>/dev/null | jq -r '.hashrate.total[0] // 0' 2>/dev/null)
        { [ -n "$_hr" ] && awk "BEGIN{exit !($_hr > 0)}" 2>/dev/null; } && break
        sleep 3
    done
    phase "verify — doctor (tuning actually applied)"
    local doc
    doc="$("$RIGFORGE" doctor 2>&1 || true)" # doctor is advisory; we assert the specifics ourselves below
    printf '%s\n' "$doc"

    [ "$(hugepages_total)" -gt 0 ] && ok "HugePages reserved (HugePages_Total=$(hugepages_total))" ||
        bad "HugePages NOT reserved — did you reboot after provision?"
    # msr can be a loadable module OR built into the kernel; either way it shows under /sys/module
    # (lsmod only lists loadable modules, so a built-in msr would be a false negative) — match doctor.
    [ -d /sys/module/msr ] && ok "msr available (/sys/module/msr)" || bad "msr not available"
    # #66: doctor must confirm the MSR mod actually APPLIED (from XMRig's log) and — since setup installs
    # msr-tools — verify the prefetcher registers hold the preset's values via rdmsr. Hardware-agnostic:
    # it asserts on doctor's output (whatever per-family preset this CPU uses — e.g. ryzen_19h_zen4 on
    # Zen4, intel on Intel), not a fixed model; the verified value tables live in rigforge.sh.
    printf '%s' "$doc" | grep -q "MSR mod applied" &&
        ok "doctor confirms the MSR mod applied (#66)" || bad "doctor didn't confirm the MSR mod applied (#66)"
    if command -v rdmsr >/dev/null 2>&1; then
        printf '%s' "$doc" | grep -q "verified via rdmsr" &&
            ok "doctor verified the MSR registers via rdmsr (#66)" ||
            bad "doctor's rdmsr register verification did not pass (#66) — see the doctor output above"
    else
        bad "rdmsr (msr-tools) missing after setup — the #66 register-level check can't run"
    fi
    [ "$(cat "$GOVERNOR_FILE" 2>/dev/null)" = "performance" ] && ok "CPU governor = performance" ||
        bad "governor is '$(cat "$GOVERNOR_FILE" 2>/dev/null || echo unknown)' (expected performance)"
    systemctl is-active --quiet xmrig && ok "service 'xmrig' is active" || bad "service 'xmrig' not active"
    # #78: the BIOS/firmware advisory reads the board/BIOS identity from /sys/class/dmi/id on real hardware.
    printf '%s' "$doc" | grep -q "Firmware:" &&
        ok "doctor prints the BIOS/firmware context (#78: $(printf '%s' "$doc" | grep -oE 'BIOS [^ ]+' | head -1))" ||
        bad "doctor printed no firmware context line (#78) — is /sys/class/dmi/id readable?"

    phase "verify — live pool (the worker actually connects and submits a share)"
    # Proving the rig REALLY mines is the whole point of the gate, so this round-trip is MANDATORY by
    # default. It needs a REACHABLE pool: ensure_config writes an unroutable TEST-NET-3 placeholder
    # (203.0.113.x) when no config.json exists, so the installed service never mines to a real destination.
    # If that placeholder is still in place the releaser simply forgot to point at a real pool — so FAIL
    # loudly rather than silently skipping the one check that proves end-to-end mining. Point pools[0].url
    # at a real reachable pool before tagging (see RELEASING.md). For a deliberate offline smoke run (no
    # pool on hand), set E2E_ALLOW_OFFLINE_POOL=1 to turn this into an explicit, on-purpose skip.
    if grep -q '203\.0\.113\.' "$HERE/config.json" 2>/dev/null; then
        if [ "${E2E_ALLOW_OFFLINE_POOL:-0}" = 1 ]; then
            ok "SKIP live-pool round-trip — offline placeholder pool, E2E_ALLOW_OFFLINE_POOL=1 set (deliberate offline run)"
        else
            bad "live-pool round-trip can't run: config.json still has the offline placeholder pool (203.0.113.x) — point pools[0].url at a real reachable pool to prove end-to-end mining, or set E2E_ALLOW_OFFLINE_POOL=1 for a deliberate offline run."
        fi
    else
        systemctl is-active --quiet xmrig || "$RIGFORGE" start >/dev/null 2>&1 || true
        local wlog share_to="${E2E_SHARE_TIMEOUT:-180}" waited=0
        wlog="$(find "$HERE" -path '*worker*' -name xmrig.log 2>/dev/null | head -1)"
        if [ -z "$wlog" ]; then
            bad "could not find the worker's xmrig.log to check pool connectivity"
        else
            # Connection: a stratum job from the pool proves the worker reached and authed with it.
            while [ "$waited" -lt 60 ] && ! grep -q 'new job from' "$wlog" 2>/dev/null; do
                sleep 3
                waited=$((waited + 3))
            done
            grep -q 'new job from' "$wlog" 2>/dev/null &&
                ok "connected to the pool ($(grep -oE 'new job from [^ ]+' "$wlog" | tail -1 | awk '{print $NF}'))" ||
                bad "no pool job in the log within 60s — is the pool reachable?"
            # Share submission: an accepted share proves the full mining round-trip. Assumes a reachable
            # pool with sane difficulty; raise E2E_SHARE_TIMEOUT for a high-difficulty pool.
            waited=0
            while [ "$waited" -lt "$share_to" ] && ! grep -q 'accepted (' "$wlog" 2>/dev/null; do
                sleep 5
                waited=$((waited + 5))
            done
            grep -q 'accepted (' "$wlog" 2>/dev/null &&
                ok "submitted an accepted share ($(grep -c 'accepted (' "$wlog") accepted so far)" ||
                bad "no accepted share within ${share_to}s — check pool reachability / difficulty"
        fi
    fi

    phase "verify — live auto-tune engine (the 'autotune' verb / 'tune --now'; the unattended monthly re-tune)"
    # autotune() is a SEPARATE engine from the offline `tune --bench` search below: it samples the RUNNING
    # miner over the HTTP API and live-sweeps prefetch modes against it (no service stop). It's exactly what
    # the monthly systemd timer and `tune --now`/`--short`/`--long` drive, so the gate must prove it on real
    # silicon — the stubbed suites can't read a live API hashrate. It needs a live rate to sample, so (like
    # the round-trip above) it only runs with a real pool; the offline placeholder is an explicit skip.
    # Runs right after the round-trip, while the miner is confirmed warm and mining.
    if grep -q '203\.0\.113\.' "$HERE/config.json" 2>/dev/null; then
        ok "SKIP live auto-tune — offline placeholder pool (the engine needs a live hashrate to sample)"
    else
        systemctl is-active --quiet xmrig || "$RIGFORGE" start >/dev/null 2>&1 || true
        # Keep it quick: sweep two short modes with a brief warmup/sampling — enough to prove the live sweep
        # applies a mode, re-samples the running miner, and reaches a keep/switch verdict. A real re-tune is
        # longer; the knobs below just bound the gate's runtime.
        if AUTOTUNE_MODES="${E2E_AUTOTUNE_MODES:-0 1}" AUTOTUNE_WARMUP="${E2E_AUTOTUNE_WARMUP:-20}" \
            AUTOTUNE_SAMPLES=2 AUTOTUNE_INTERVAL=5 "$RIGFORGE" autotune >/tmp/e2e-autotune.log 2>&1; then
            if grep -q 'autotune: optimizing for' /tmp/e2e-autotune.log &&
                grep -qE 'applying it|keeping prefetch_mode' /tmp/e2e-autotune.log; then
                ok "live auto-tune swept prefetch modes against the running miner ($(grep -oE 'applying it|keeping prefetch_mode=[0-9]+' /tmp/e2e-autotune.log | tail -1))"
            elif grep -q 'could not read a live hashrate' /tmp/e2e-autotune.log; then
                bad "autotune couldn't read a live hashrate — the miner wasn't warm/mining (see /tmp/e2e-autotune.log)"
            else
                bad "autotune ran but produced no live-sweep verdict (see /tmp/e2e-autotune.log)"
            fi
        else
            bad "autotune (live engine) exited non-zero (see /tmp/e2e-autotune.log)"
        fi
        "$RIGFORGE" tune --clear >/dev/null 2>&1 || true # back to baseline for the offline tune phases below
        "$RIGFORGE" apply >/dev/null 2>&1 || true
    fi

    phase "verify — bench (real hashing, off the running service)"
    "$RIGFORGE" stop >/dev/null 2>&1 || true # take the whole machine for a clean reading
    local out hr=""
    if out="$(BENCH=1M "$RIGFORGE" bench 2>&1)"; then
        hr="$(printf '%s' "$out" | grep -oiE '[0-9.]+ H/s' | tail -1)"
        ok "bench produced a hashrate: ${hr:-?}"
    else
        bad "bench failed:"
        printf '%s\n' "$out" | tail -5 >&2
    fi
    "$RIGFORGE" start >/dev/null 2>&1 || true

    phase "verify — a short real tune (pipeline + sustained-clock sampling #62)"
    # Constrain the search to just the candidates the assertions below actually need, so this stays fast (a
    # real tune is a separate, hours-long operation). Every speed knob here was validated against the checks:
    #   - TUNE_BENCH=500K: a ~40-50s loaded window — still ample for the #62 effective-clock median and the
    #     #81 RAPL energy delta, which both integrate over the window and read stable, non-trivial values
    #     long before a full 1M run finishes. Halving the hash count roughly halves each candidate.
    #   - TUNE_ITERS=1: no assertion here ranks on the median hashrate, so one bench per candidate suffices.
    #   - sweep ONLY wrmsr (prefetch + 1gb-pages pinned): wrmsr is the knob #66 needs both presets of; the
    #     prefetch path is already exercised by the efficiency tune below, and 1gb-pages isn't asserted — so
    #     pinning them leaves exactly two candidates (wrmsr true/false), each still recording the
    #     min_freq/watts/hugepages_capped fields the #62/#81/#65 checks read.
    local tj
    if TUNE_BENCH=500K TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 \
        TUNE_ONEGB=true TUNE_WRMSR="true false" TUNE_MAX_ROUNDS=1 "$RIGFORGE" tune >/tmp/e2e-tune.log 2>&1; then
        tj="$(find "$HERE" -path '*worker*' -name 'rigforge-tune.json' 2>/dev/null | head -1)"
        if [ -n "$tj" ]; then
            ok "tune completed and wrote results ($(basename "$tj"))"
            [ "$(jq -r '[.results[]|select(.min_freq_mhz!=null)]|length>0' "$tj" 2>/dev/null)" = true ] &&
                ok "tune sampled the effective clock under load (#62: $(jq -r '[.results[].min_freq_mhz]|min' "$tj") MHz min)" ||
                bad "tune recorded no effective-clock samples (#62)"
            # #66: the wrmsr knob was swept (TUNE_WRMSR="true false"), so the results must carry BOTH
            # values — proving each MSR variant was actually applied and benchmarked on real silicon, not
            # just that a wrmsr field exists.
            [ "$(jq -r '[.results[].wrmsr]|unique|length>=2' "$tj" 2>/dev/null)" = true ] &&
                ok "tune swept the wrmsr knob across both presets (#66: $(jq -c '[.results[].wrmsr]|unique' "$tj"))" ||
                bad "tune didn't sweep wrmsr to 2 distinct values (#66)"
            # #65: the reservation-aware check ran on real hardware — candidates carry hugepages_capped
            # (false here, since setup sized the reservation to fit; the field's presence proves the wiring).
            [ "$(jq -r '[.results[]|select(has("hugepages_capped"))]|length>0' "$tj" 2>/dev/null)" = true ] &&
                ok "tune records the reservation-cap status (#65)" || bad "tune didn't record hugepages_capped (#65)"
            # #81: with NO TUNE_POWER_CMD, the built-in RAPL reader measured CPU-package power UNDER LOAD —
            # a real mining draw (tens of watts), not the old ~idle reading or a null. Proves the energy
            # delta path works on real hardware. (Skipped if RAPL isn't readable, e.g. a locked-down host.)
            if [ -r /sys/class/powercap/intel-rapl:0/energy_uj ]; then
                [ "$(jq -r '[.results[]|select(.watts!=null and .watts>20)]|length>0' "$tj" 2>/dev/null)" = true ] &&
                    ok "tune measured under-load power via built-in RAPL (#81: $(jq -r '[.results[].watts]|max' "$tj") W peak)" ||
                    bad "tune recorded no plausible under-load watts via RAPL (#81)"
            else
                ok "RAPL not readable here — skipping the #81 built-in-power check"
            fi
        else
            bad "tune left no result file"
        fi
    else
        bad "tune failed (see /tmp/e2e-tune.log):"
        tail -5 /tmp/e2e-tune.log >&2
    fi

    phase "verify — efficiency-target tune (#79)"
    # With the built-in RAPL source available, 'tune --efficiency' optimizes hashrate-per-watt and records
    # the target. Proves the efficiency path runs on real hardware (no fall-back to perf). Same 500K/ITERS=1
    # speed-up as above; prefetch is left swept ("1 2") so the hs/watt ranking has two candidates to compare.
    if TUNE_BENCH=500K TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES="1 2" TUNE_YIELDS=false TUNE_THREADS=-1 \
        TUNE_ONEGB=true TUNE_MAX_ROUNDS=1 "$RIGFORGE" tune --efficiency >/tmp/e2e-eff.log 2>&1; then
        tj="$(find "$HERE" -path '*worker*' -name 'rigforge-tune.json' 2>/dev/null | head -1)"
        [ "$(jq -r '.target' "$tj" 2>/dev/null)" = efficiency ] &&
            ok "tune --efficiency optimized hashrate-per-watt on real hardware (#79)" ||
            bad "tune --efficiency didn't record target=efficiency (#79: fell back to perf? — see /tmp/e2e-eff.log)"
    else
        bad "tune --efficiency failed (see /tmp/e2e-eff.log):"
        tail -5 /tmp/e2e-eff.log >&2
    fi

    phase "verify — live A/B confirm (#64)"
    # A real --confirm round against the live miner: it measures the tuned config, restores the previous
    # one and measures that, then keeps or reverts. The #64 path under test is the LIVE A/B, so the offline
    # search is pinned to a single candidate (prefetch + 1gb-pages fixed) just to pick a winner to confirm —
    # a 500K bench plus the short live windows keep this quick.
    if TUNE_LIVE_WARMUP="${E2E_AB_WARMUP:-20}" TUNE_LIVE_SAMPLES=2 TUNE_LIVE_INTERVAL=5 TUNE_BENCH=500K \
        TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_ONEGB=true \
        TUNE_MAX_ROUNDS=1 "$RIGFORGE" tune --confirm >/tmp/e2e-ab.log 2>&1; then
        grep -qE 'Confirmed:|Reverted:' /tmp/e2e-ab.log &&
            ok "live A/B confirm ran ($(grep -oE '(Confirmed|Reverted):.*' /tmp/e2e-ab.log | tail -1))" ||
            bad "live A/B confirm produced no verdict (see /tmp/e2e-ab.log)"
    else
        bad "tune --confirm failed (see /tmp/e2e-ab.log):"
        tail -5 /tmp/e2e-ab.log >&2
    fi
    "$RIGFORGE" tune --clear >/dev/null 2>&1 || true # leave the rig on its baseline config
    "$RIGFORGE" apply >/dev/null 2>&1 || true

    phase "verify — full command surface (every verb)"
    local op="${SUDO_USER:-root}"
    "$RIGFORGE" version 2>&1 | grep -q RigForge && ok "version prints the version" || bad "version failed"
    "$RIGFORGE" help 2>&1 | grep -qi usage && ok "help prints usage" || bad "help failed"
    # aliases must resolve to the same verbs (dispatch synonyms): -v/--version=version, -h/--help=help
    if [ "$("$RIGFORGE" -v 2>&1)" = "$("$RIGFORGE" version 2>&1)" ] &&
        [ "$("$RIGFORGE" --version 2>&1)" = "$("$RIGFORGE" version 2>&1)" ]; then
        ok "-v / --version alias the version verb"
    else
        bad "-v / --version didn't match the version verb"
    fi
    "$RIGFORGE" --help 2>&1 | grep -qi usage && ok "-h / --help alias the help verb" || bad "--help didn't print usage"
    # doctor as the OPERATOR (non-root) must run clean — no abort (#89: non-root dmidecode)
    local nrdoc nrrc
    nrdoc=$(sudo -u "$op" "$RIGFORGE" doctor 2>&1) && nrrc=0 || nrrc=$?
    if [ "$nrrc" = 0 ] && ! printf '%s' "$nrdoc" | grep -qi aborted; then
        ok "doctor runs clean as the operator '$op' (non-root, #89)"
    else
        bad "doctor as the operator (non-root) aborted or exited non-zero (#89)"
    fi
    # status / logs are read-only
    "$RIGFORGE" status >/dev/null 2>&1 && ok "status reports the service" || bad "status failed"
    journalctl -u xmrig -n 1 --no-pager >/dev/null 2>&1 && ok "service journal is readable (logs)" || bad "journal not readable"
    # service control: stop -> inactive, start/restart -> active
    "$RIGFORGE" stop >/dev/null 2>&1 || true
    systemctl is-active --quiet xmrig && bad "stop left the service active" || ok "stop -> service inactive"
    "$RIGFORGE" start >/dev/null 2>&1 || true
    sleep 2
    systemctl is-active --quiet xmrig && ok "start -> service active" || bad "start didn't start the service"
    "$RIGFORGE" restart >/dev/null 2>&1 || true
    sleep 2
    systemctl is-active --quiet xmrig && ok "restart -> service active" || bad "restart left it inactive"
    # up/down are dispatch aliases of start/stop — exercise those arms too
    "$RIGFORGE" down >/dev/null 2>&1 || true
    systemctl is-active --quiet xmrig && bad "down (alias of stop) left the service active" || ok "down -> service inactive (alias of stop)"
    "$RIGFORGE" up >/dev/null 2>&1 || true
    sleep 2
    systemctl is-active --quiet xmrig && ok "up -> service active (alias of start)" || bad "up (alias of start) didn't start the service"
    # enable / disable on boot (settle-tolerant: systemctl can lag/flake under the gate's load)
    _set_boot disable disabled && ok "disable -> not started on boot" ||
        bad "disable didn't take (is-enabled=$(systemctl is-enabled xmrig 2>/dev/null || true))"
    _set_boot enable enabled && ok "enable -> started on boot" ||
        bad "enable didn't take (is-enabled=$(systemctl is-enabled xmrig 2>/dev/null || true))"
    # upgrade is a no-op on the already-pinned XMRig (no rebuild)
    if "$RIGFORGE" upgrade >/tmp/e2e-upgrade.log 2>&1; then
        grep -qiE 'already built|recompile will be skipped|no rebuild|skipp' /tmp/e2e-upgrade.log &&
            ok "upgrade is a no-op on the pinned XMRig (no rebuild)" ||
            ok "upgrade ran cleanly (no-op expected on pinned)"
    else
        bad "upgrade exited non-zero (see /tmp/e2e-upgrade.log)"
    fi
    # backup + restore round-trip
    if "$RIGFORGE" backup >/tmp/e2e-backup.log 2>&1; then
        local ar
        ar=$(find "$HERE/backups" -name 'rigforge-backup-*.tar.gz' 2>/dev/null | sort | tail -1)
        if [ -n "$ar" ] && [ -f "$ar" ]; then
            ok "backup wrote an archive ($(basename "$ar"))"
            "$RIGFORGE" restore -y "$ar" >/tmp/e2e-restore.log 2>&1 &&
                ok "restore round-trips config + tuning" || bad "restore failed (see /tmp/e2e-restore.log)"
        else
            bad "backup reported success but wrote no archive"
        fi
    else
        bad "backup failed (see /tmp/e2e-backup.log)"
    fi
    # apply (regenerate the live config + restart, no recompile)
    if "$RIGFORGE" apply >/tmp/e2e-apply.log 2>&1; then
        sleep 2
        systemctl is-active --quiet xmrig && ok "apply regenerated the config + restarted (no recompile)" ||
            bad "apply ran but the service isn't active"
    else
        bad "apply failed (see /tmp/e2e-apply.log)"
    fi

    phase "verify — tune --history (status) + #92 systemd re-own"
    # tune --history is a read-only status command — it must work after a real tune.
    if "$RIGFORGE" tune --history >/tmp/e2e-history.log 2>&1; then
        grep -qE 'Winning tune options|Periodic auto-tune' /tmp/e2e-history.log &&
            ok "tune --history shows the tuning status" || bad "tune --history produced no status output"
    else
        bad "tune --history failed (see /tmp/e2e-history.log)"
    fi
    # #reown: the nightly autotune runs as root via systemd (no SUDO_USER), so its unit must bake in
    # RIGFORGE_OPERATOR for the re-own to hand files back to the operator (not root). Assert the unit
    # carries it, then exercise the re-own exactly the way the root timer does (no SUDO_USER + that operator).
    local wr op="" raw_home
    # Derive the worker root from the EFFECTIVE config (the "existing config.json" arm above, ~line
    # 149, may set its own HOME_DIR) via rigforge.sh's own resolver, not a hardcoded default path.
    raw_home="$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$HERE/config.json" 2>/dev/null)"
    wr="$(RIGFORGE_HOME="$HERE" bash -c 'source "$1"; _worker_root_for_home "$2"' _ "$RIGFORGE" "$raw_home" 2>/dev/null || true)"
    # SKIP only when the unit itself is absent (autotune genuinely disabled). A unit that EXISTS but
    # bakes in no RIGFORGE_OPERATOR is exactly the #reown regression this phase guards — it must fail,
    # not skip (previously the two states were indistinguishable and the regression slid through).
    if ! systemctl cat rigforge-autotune.service >/dev/null 2>&1; then
        ok "SKIP autotune re-own check — periodic autotune not enabled ('autotune': true in config.json)"
        summary "verify"
        return
    fi
    # `|| true`: sed/head under `set -Eeuo pipefail`.
    op=$(systemctl cat rigforge-autotune.service 2>/dev/null | sed -nE 's/^Environment=RIGFORGE_OPERATOR=//p' | head -1 || true)
    if [ -n "$op" ]; then
        ok "autotune unit bakes in RIGFORGE_OPERATOR=$op (#reown)"
        if [ -n "$wr" ] && [ -d "$wr" ]; then
            chown -R root:root "$wr" 2>/dev/null
            env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin RIGFORGE_OPERATOR="$op" RIGFORGE_HOME="$HERE" bash "$RIGFORGE" apply >/dev/null 2>&1 || true
            [ "$(stat -c %U "$wr")" = "$op" ] &&
                ok "a root-context run (no SUDO_USER) re-owned the worker to '$op', not root (#reown)" ||
                bad "a root-context run left the worker owned by '$(stat -c %U "$wr")' (expected '$op')"
        else
            ok "SKIP reown worker-ownership check (worker root not found at '${wr:-<unresolved>}')"
        fi
    else
        bad "autotune unit exists but bakes in no RIGFORGE_OPERATOR — the #reown regression (nightly tune would hand files to root)"
    fi
    summary "verify"
}

# --- control (#272): the writable control path (#236), for real, for the first time ------------
#
# Everything below has only ever run against stubs: tests/run.sh stubs apply()/_wait_miner_live for
# control_apply(), and the wire test (tests/run.sh's control-server checks) stops at the receiver
# staging a change — it never lets the real rigforge-control-apply.path unit fire the real root
# oneshot against a real systemd. This phase is the first time the whole chain runs for real:
#   POST /apply (receiver, DynamicUser) -> spool -> rigforge-control-apply.path (PathExistsGlob)
#   -> rigforge-control-apply.service (root oneshot: rigforge.sh control-apply) -> _control_commit
#   -> apply() -> _wait_miner_live -> GET /status?change_id=... "applied"
#
# Runs between verify and perf: it restarts services repeatedly (config toggled on, a change
# applied, config toggled back off — each an `apply`), which is exactly the kind of churn perf's
# "clean, idle-machine" bench should NOT be measured through. Sitting it before perf means perf's
# offline bench (which stops the service outright anyway) still runs last against a fully-settled,
# already-reverted config — the same rig state teardown then tears down. Deliberately not "verify"
# itself: verify covers rigforge.sh directly, this exercises the separate control-server.py process
# + two more systemd units, so a broken chain reads as `E2E-REAL (control): FAIL` on its own.
#
# Rollback leg (#272's stretch goal): SKIPPED. control_apply()'s rollback only fires when
# _wait_miner_live times out post-apply, and the only way to force that from outside rigforge.sh
# without editing a live systemd unit (which this gate must not do to a production-adjacent rig) is
# to make the miner fail to come up on purpose — e.g. divert the built xmrig binary out from under a
# running install. That is exactly the kind of "leaves a window where the rig can't mine if cleanup
# doesn't run" risk the task brief calls out as the thing to avoid on miner-0. No clean hook for it
# turned up while reading control_apply()/rigforge-control-apply.path — see #276 for the rollback
# failure-path tests (those exercise it against a stubbed apply, which is the safe place to do it).
control() {
    require_linux_root control
    [ -f "$HERE/config.json" ] || die "no $HERE/config.json — run 'provision' first (this phase needs an already-provisioned worker)."
    phase "control — enable the writable control path + apply"

    # Snapshot BEFORE any mutation and install the EXIT trap immediately: every step below can fail
    # under `set -Eeuo pipefail`, and the rig must come back with control OFF regardless. Same shape
    # as e2e-pithead.sh's snapshot_config/_cleanup (see there for why: traps replace, not stack, so
    # this REPLACES rig_lock's holder-only EXIT trap set at the bottom of this file — the trap below
    # re-does that holder-file removal at process exit. The holder rm lives HERE, not inside
    # _control_cleanup: the explicit mid-phase cleanup call must not delete the breadcrumb while
    # perf/teardown still run holding the flock (a blocked arrival would then read "busy: unknown").
    CTL_SAVED_CFG="$(mktemp)"
    cp "$HERE/config.json" "$CTL_SAVED_CFG"
    trap '_control_cleanup; rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || true' EXIT

    # Ephemeral bearer token for this run only: generated, used over loopback, and discarded. Never
    # echoed, never written anywhere but config.json itself (which the snapshot above restores).
    local tok cur_donation new_donation control_port rev_before rev_after cid st tmp
    tok=$(head -c 32 /dev/urandom | xxd -p -c 256)
    cur_donation=$(jq -r '.DONATION // 1' "$HERE/config.json" 2>/dev/null || echo 1)
    new_donation=$(((cur_donation + 1) % 101)) # DONATION is 0-100 (rigforge.sh); always differs from cur_donation

    # api_allow_from is pinned to loopback: every request this phase makes is FROM this box (root, on
    # miner-0 itself), and the nft firewall install_api_firewall renders always accepts iifname "lo"
    # regardless of the configured scope — so 127.0.0.1/32 both satisfies the hard-required check
    # (rigforge.sh:540-541) and is the literal, correct scope for how this phase actually talks to it.
    tmp="$(mktemp)"
    if jq --arg tok "$tok" '.control = "enabled" | .ACCESS_TOKEN = $tok | .api_allow_from = "127.0.0.1/32"' \
        "$HERE/config.json" >"$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$HERE/config.json"
    else
        rm -f "$tmp"
        bad "could not stage a control-enabled config.json"
    fi
    "$RIGFORGE" apply >/tmp/e2e-control-enable.log 2>&1 &&
        ok "apply enabled the control path" ||
        bad "apply failed while enabling control (see /tmp/e2e-control-enable.log)"
    sleep 3 # let rigforge-control.service (restarted by install_control) and xmrig settle

    control_port=$(jq -r '.control_port // 8082' "$HERE/config.json" 2>/dev/null || echo 8082)
    # Captured AFTER enabling control (not before): control/ACCESS_TOKEN/api_allow_from aren't part
    # of the writable-config hash _stamp_config_meta tracks (only pools/DONATION/autotune/watchdog/
    # watchdog_interval_min/max_temp_c are — the same set control-apply is allowed to touch), so
    # enabling control alone never bumps the revision. This is the true "before" for the #254 check.
    # `|| true`: the meta file may not exist yet on a rig where 'control' runs standalone before any
    # apply() has ever stamped it — jq erroring on a missing file must not abort the phase (set -e).
    rev_before=$(jq -r '.revision // ""' "$HERE/.rigforge-config-meta.json" 2>/dev/null || true)

    phase "control — receiver up"
    systemctl is-active --quiet rigforge-control &&
        ok "rigforge-control.service is active" ||
        bad "rigforge-control.service is not active after enabling control"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $tok" \
        "http://127.0.0.1:$control_port/status" 2>/dev/null || true)
    case "$code" in
    200 | 503) ok "authed GET /status reachable (HTTP $code)" ;;
    *) bad "authed GET /status returned HTTP '$code' (expected 200, or 503 'no change applied yet')" ;;
    esac

    phase "control — POST a benign change (DONATION $cur_donation -> $new_donation) and poll to applied"
    local resp_file resp_code
    resp_file="$(mktemp)"
    resp_code=$(curl -s -o "$resp_file" -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" -d "{\"DONATION\": $new_donation}" \
        "http://127.0.0.1:$control_port/apply" 2>/dev/null || true)
    if [ "$resp_code" = 202 ]; then
        cid=$(jq -r '.change_id // empty' "$resp_file" 2>/dev/null || true)
        [ -n "$cid" ] && ok "POST /apply accepted (change_id=$cid)" || bad "POST /apply returned 202 with no change_id"
    else
        bad "POST /apply returned HTTP '$resp_code' (expected 202): $(head -c 300 "$resp_file" 2>/dev/null)"
    fi
    rm -f "$resp_file"

    st=""
    if [ -n "${cid:-}" ]; then
        # Bounded by control_apply()'s own CONTROL_LIVE_TRIES*sleep (default 20*3s=60s) plus the
        # path-unit trigger (near-instant, inotify) and commit/backup overhead — 150s leaves margin.
        local waited=0 poll_to=150 body
        while [ "$waited" -lt "$poll_to" ]; do
            body=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
                "http://127.0.0.1:$control_port/status?change_id=$cid" 2>/dev/null || true)
            # `|| true`: an empty/unreachable body makes jq exit non-zero on some builds — under
            # pipefail that would abort the whole phase (set -e) on a single transient miss instead
            # of letting the poll loop retry.
            st=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)
            case "$st" in applied | rejected | rolled_back | failed) break ;; esac
            sleep 5
            waited=$((waited + 5))
        done
        [ "$st" = applied ] &&
            ok "change $cid reached 'applied' within ${waited}s (path-unit -> control-apply -> real systemd)" ||
            bad "change $cid did not reach 'applied' within ${poll_to}s (last status: ${st:-unreachable})"
    else
        bad "no change_id to poll — the POST above didn't succeed"
    fi

    phase "control — assert the change actually landed"
    local landed
    landed=$(jq -r '.DONATION' "$HERE/config.json" 2>/dev/null || true)
    [ "$landed" = "$new_donation" ] &&
        ok "config.json carries DONATION=$new_donation (control-apply persisted it)" ||
        bad "config.json DONATION is '$landed', expected $new_donation"
    systemctl is-active --quiet xmrig &&
        ok "miner service is active after the control-path apply" ||
        bad "miner service is not active after the control-path apply"
    rev_after=$(jq -r '.revision // ""' "$HERE/.rigforge-config-meta.json" 2>/dev/null || true)
    if [ -n "$rev_after" ] && [ "$rev_after" != "$rev_before" ]; then
        ok "feed config revision moved ($rev_before -> $rev_after, #254)"
    else
        bad "feed config revision did not move (before='$rev_before' after='$rev_after')"
    fi

    # Revert now (not just on exit): in `all` mode later phases (perf, teardown) run in this SAME
    # process, and the EXIT trap only fires once the whole script exits — an explicit call here is
    # what actually gets the rig back to control-disabled before perf/teardown see it. The trap stays
    # armed as a backstop for a hard abort mid-phase; _control_cleanup is idempotent so the (harmless)
    # second run at real process exit is a no-op.
    _control_cleanup
    summary "control"
}

# Idempotent: restores the snapshotted config.json, then INDEPENDENTLY forces control back to
# disabled (belt-and-suspenders — even if the snapshot copy itself failed, this still lands), re-runs
# apply, and logs (never gates the exit code — this runs from a trap, possibly after summary() has
# already decided pass/fail) whether the receiver is gone and the miner is back live. Guarded by
# CTL_CLEANUP_DONE so a trap fire after control() already ran its own explicit cleanup is a no-op.
_control_cleanup() {
    [ "$CTL_CLEANUP_DONE" = 1 ] && return 0
    CTL_CLEANUP_DONE=1
    echo ""
    echo "control: reverting — restoring the snapshotted config.json and disabling control..."
    if [ -n "$CTL_SAVED_CFG" ] && [ -f "$CTL_SAVED_CFG" ]; then
        cp "$CTL_SAVED_CFG" "$HERE/config.json" 2>/dev/null &&
            echo "  restored config.json from the pre-phase snapshot" ||
            echo "  WARNING: could not restore config.json from $CTL_SAVED_CFG — check it by hand" >&2
        rm -f "$CTL_SAVED_CFG"
    else
        echo "  WARNING: no config.json snapshot on hand to restore — leaving config.json as-is" >&2
    fi
    if [ -f "$HERE/config.json" ]; then
        # This whole block is best-effort belt-and-suspenders on top of the restore above — a failure
        # here (mktemp, jq, mv) must WARN and fall through, never abort mid-cleanup (a partial run
        # here would skip the apply/holder-file steps below).
        local dtmp
        dtmp="$(mktemp 2>/dev/null || true)"
        if [ -n "$dtmp" ] && jq '.control = "disabled" | .control_upgrade = "disabled"' "$HERE/config.json" >"$dtmp" 2>/dev/null && [ -s "$dtmp" ]; then
            mv "$dtmp" "$HERE/config.json" 2>/dev/null ||
                echo "  WARNING: could not move the disabled-control config into place — check $HERE/config.json by hand" >&2
        else
            rm -f "$dtmp" 2>/dev/null || true
            echo "  WARNING: could not force control=disabled via jq — check $HERE/config.json by hand" >&2
        fi
    fi
    "$RIGFORGE" apply >/tmp/e2e-control-cleanup-apply.log 2>&1 ||
        echo "  WARNING: the revert 'apply' exited non-zero (see /tmp/e2e-control-cleanup-apply.log)" >&2
    if systemctl is-active --quiet rigforge-control 2>/dev/null; then
        echo "  WARNING: rigforge-control.service is STILL ACTIVE after revert — check the rig by hand" >&2
    else
        echo "  rigforge-control.service is inactive/absent (control path off)"
    fi
    local _tok _auth=() i hr=""
    _tok=$(jq -r '.ACCESS_TOKEN // empty' "$HERE/config.json" 2>/dev/null || true)
    [ -n "$_tok" ] && _auth=(-H "Authorization: Bearer $_tok")
    for i in 1 2 3 4 5 6 7 8 9 10; do
        # `|| true`: a connection-refused curl (miner not up yet) makes the pipeline non-zero under
        # pipefail even when jq itself succeeds on empty input — must not abort cleanup mid-poll.
        hr=$(curl -fsS --max-time 4 "${_auth[@]}" http://127.0.0.1:8080/2/summary 2>/dev/null | jq -r '.hashrate.total[0] // 0' 2>/dev/null || true)
        { [ -n "$hr" ] && awk "BEGIN{exit !($hr > 0)}" 2>/dev/null; } && break
        sleep 3
    done
    if [ -n "$hr" ] && awk "BEGIN{exit !($hr > 0)}" 2>/dev/null; then
        echo "  miner is live post-revert ($hr H/s)"
    else
        echo "  WARNING: miner did not report a live hashrate post-revert within 30s — check the rig by hand" >&2
    fi
}

# --- upgrade (#322): the remote-upgrade chain (#308, ADR 0002), for real -----------------------
#
# Both real bugs in this chain — #308's missing-$HOME "dubious ownership" silent git death (v1.11.1)
# and #318's origin/HEAD-resolves-to-develop refusal (v1.11.2) — were caught only by a real-hardware
# miner-0 control-upgrade run: the unit suite stubs git BY DESIGN, so this chain regresses in exactly
# the ways only a real rig catches. This codifies that run as a repeatable phase:
#   POST /upgrade (receiver, DynamicUser) -> spool upgrade-*.json -> rigforge-control-upgrade.path
#   -> rigforge-control-upgrade.service (root oneshot: rigforge.sh control-upgrade)
#   -> _control_upgrade_do (REAL git fetch/ancestry/checkout + rebuild) -> health gate -> /status
#
# Legs:
#   noop     : POST the installed version -> terminal `noop` (#320). Proves the wire, path unit,
#              oneshot, and status round trip without touching the tree (never dials GitHub).
#   rollback : POST v99.99.99 from a locally-forged tag on a commit NOT reachable from origin/main
#              -> the D10 ancestry guard refuses the forward leg, the verb rolls back to the running
#              ref -> terminal `rolled_back`, checkout + VERSION unchanged, throttle stamp written.
#              This runs the real git calls (fetch, rev-parse, merge-base, checkout) as the root
#              oneshot with no $HOME — the #308 dubious-ownership class dies here, not in the
#              stubbed suite. Cheap: the forward refusal happens before any checkout or build.
#   forward  : opt-in via E2E_UPGRADE_TARGET=vX.Y.Z (a real release newer than the installed one)
#              -> poll to `applied`, assert VERSION landed. PERMANENTLY upgrades this checkout, so
#              it is not part of the repeatable default — it's the release-flow leg that would have
#              caught #318 (a legit upgrade being refused).
#
# Sits after control (same restart churn perf must not measure through) and reuses control's
# snapshot/cleanup machinery (CTL_ globals + _control_cleanup) — config is snapshotted and BOTH
# control flags are forced off again on ANY exit, plus the upgrade-phase leftovers (probe tag,
# throttle stamp) are removed. Also the producer half of pithead#597's cross-repo tier-4 gate.

# POST /upgrade {"version":<target>} and poll /status?change_id= to a terminal status (echoed).
# `started` (#320) is non-terminal — keep polling through it. Echoes "post-failed:<http-code>" when
# the POST itself is refused, "timeout" when no terminal status lands inside <timeout-s>.
_upg_post_and_poll() { # <token> <port> <vX.Y.Z> <timeout-s> -> terminal status on stdout
    local tok=$1 port=$2 target=$3 to=$4 resp code cid st="" waited=0 body
    resp="$(mktemp)"
    code=$(curl -s -o "$resp" -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" -d "{\"version\": \"$target\"}" \
        "http://127.0.0.1:$port/upgrade" 2>/dev/null || true)
    cid=$(jq -r '.change_id // empty' "$resp" 2>/dev/null || true)
    rm -f "$resp"
    if [ "$code" != 202 ] || [ -z "$cid" ]; then
        printf 'post-failed:%s' "$code"
        return 0
    fi
    while [ "$waited" -lt "$to" ]; do
        # `|| true` on both: transient unreachability mid-oneshot (units restarting) must not abort
        # the poll under set -e/pipefail — same shape as control()'s poll loop.
        body=$(curl -fsS --max-time 5 -H "Authorization: Bearer $tok" \
            "http://127.0.0.1:$port/status?change_id=$cid" 2>/dev/null || true)
        st=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)
        case "$st" in applied | rolled_back | failed | noop | throttled) break ;; esac
        sleep 5
        waited=$((waited + 5))
    done
    case "$st" in applied | rolled_back | failed | noop | throttled) printf '%s' "$st" ;; *) printf 'timeout' ;; esac
}

# The upgrade-phase leftovers on top of _control_cleanup (which restores the snapshot, forces both
# control flags off, re-applies, and checks the miner comes back). Idempotent like its parts.
_upgrade_cleanup() {
    git -C "$HERE" tag -d v99.99.99 >/dev/null 2>&1 || true
    rm -f /var/lib/rigforge-control/upgrade-last 2>/dev/null || true
    _control_cleanup
}

upgrade() {
    require_linux_root upgrade
    [ -f "$HERE/config.json" ] || die "no $HERE/config.json — run 'provision' first (this phase needs an already-provisioned worker)."
    phase "upgrade — enable control + control_upgrade"

    # Same snapshot-first/trap-immediately shape as control(); see there. The trap REPLACES any
    # earlier phase's (control() has already run its explicit, guard-protected cleanup by the time
    # `all` reaches this phase, so replacing its backstop is safe).
    CTL_SAVED_CFG="$(mktemp)"
    cp "$HERE/config.json" "$CTL_SAVED_CFG"
    CTL_CLEANUP_DONE=0
    trap '_upgrade_cleanup; rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || true' EXIT

    local tok control_port tmp installed st
    local stamp="/var/lib/rigforge-control/upgrade-last"
    tok=$(head -c 32 /dev/urandom | xxd -p -c 256)
    tmp="$(mktemp)"
    if jq --arg tok "$tok" '.control = "enabled" | .control_upgrade = "enabled" | .ACCESS_TOKEN = $tok | .api_allow_from = "127.0.0.1/32"' \
        "$HERE/config.json" >"$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$HERE/config.json"
    else
        rm -f "$tmp"
        bad "could not stage a control_upgrade-enabled config.json"
    fi
    "$RIGFORGE" apply >/tmp/e2e-upgrade-enable.log 2>&1 &&
        ok "apply enabled control + control_upgrade" ||
        bad "apply failed while enabling control_upgrade (see /tmp/e2e-upgrade-enable.log)"
    sleep 3 # let rigforge-control.service and xmrig settle
    control_port=$(jq -r '.control_port // 8082' "$HERE/config.json" 2>/dev/null || echo 8082)
    systemctl is-active --quiet rigforge-control &&
        ok "rigforge-control.service is active" ||
        bad "rigforge-control.service is not active after enabling control_upgrade"
    systemctl cat rigforge-control-upgrade.path >/dev/null 2>&1 &&
        ok "rigforge-control-upgrade.path is installed (the upgrade watcher rides on control)" ||
        bad "rigforge-control-upgrade.path is not installed"
    # A stale stamp (a previous run, or a real recent upgrade) would throttle the rollback leg into
    # `throttled` — this run holds the rig_lock, so clearing our own guard here keeps the phase
    # repeatable inside the 6h window without touching CONTROL_UPGRADE_MIN_INTERVAL in the baked unit.
    rm -f "$stamp" 2>/dev/null || true

    installed=$(tr -d '[:space:]' <"$HERE/VERSION" 2>/dev/null || true)
    [ -n "$installed" ] && ok "installed version reads v$installed" || bad "could not read $HERE/VERSION"

    phase "upgrade — noop leg: POST the installed v$installed, poll to terminal"
    st=$(_upg_post_and_poll "$tok" "$control_port" "v$installed" 120)
    [ "$st" = noop ] &&
        ok "already-on-target reached terminal 'noop' (path unit -> root oneshot -> /status, #320)" ||
        bad "noop leg ended '$st' (expected noop)"

    phase "upgrade — rollback leg: POST a tag the D10 ancestry guard must refuse"
    # A commit provably NOT reachable from origin/main, without moving HEAD or dirtying the tree:
    # commit-tree forges a throwaway child of HEAD and a local tag names it (fetch --tags never
    # prunes local-only tags). -f survives a leftover tag from a crashed run; cleanup deletes it.
    local probe rev_before
    probe=$(git -C "$HERE" -c user.name=e2e -c user.email=e2e@localhost \
        commit-tree "HEAD^{tree}" -p HEAD -m "e2e-real upgrade probe (unreachable from origin/main)" 2>/dev/null || true)
    if [ -n "$probe" ] && git -C "$HERE" tag -f v99.99.99 "$probe" >/dev/null 2>&1; then
        ok "forged probe tag v99.99.99 -> ${probe:0:12} (not on origin/main)"
    else
        bad "could not forge the probe tag"
    fi
    rev_before=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || true)
    st=$(_upg_post_and_poll "$tok" "$control_port" "v99.99.99" 420)
    [ "$st" = rolled_back ] &&
        ok "unreachable tag refused and rolled back to the running ref (D10, REAL git as the root oneshot)" ||
        bad "rollback leg ended '$st' (expected rolled_back)"
    [ "$(git -C "$HERE" rev-parse HEAD 2>/dev/null)" = "$rev_before" ] &&
        ok "checkout still on ${rev_before:0:12} (tree untouched by the refused forward leg)" ||
        bad "checkout moved off ${rev_before:0:12}"
    [ "$(tr -d '[:space:]' <"$HERE/VERSION" 2>/dev/null)" = "$installed" ] &&
        ok "VERSION still reads $installed" ||
        bad "VERSION changed across a refused upgrade"
    [ -f "$stamp" ] &&
        ok "throttle stamp written by the attempt ($stamp)" ||
        bad "no throttle stamp after the rollback leg (D6)"
    systemctl is-active --quiet xmrig &&
        ok "miner service is active after the rollback" ||
        bad "miner service is not active after the rollback"

    if [ -n "${E2E_UPGRADE_TARGET:-}" ]; then
        phase "upgrade — forward leg: POST $E2E_UPGRADE_TARGET (PERMANENT — upgrades this checkout)"
        rm -f "$stamp" 2>/dev/null || true # the rollback leg stamped; this leg is operator-requested
        st=$(_upg_post_and_poll "$tok" "$control_port" "$E2E_UPGRADE_TARGET" 600)
        [ "$st" = applied ] &&
            ok "upgrade to $E2E_UPGRADE_TARGET reached 'applied' (fetch + build + health gate, for real)" ||
            bad "forward leg ended '$st' (expected applied)"
        [ "v$(tr -d '[:space:]' <"$HERE/VERSION" 2>/dev/null)" = "$E2E_UPGRADE_TARGET" ] &&
            ok "VERSION reads ${E2E_UPGRADE_TARGET#v} — the target landed" ||
            bad "VERSION did not land at $E2E_UPGRADE_TARGET"
    fi

    # Explicit cleanup now (not just on exit) for the same reason control() does it — later phases
    # in `all` mode must see the rig back to control-disabled; the trap stays as a backstop.
    _upgrade_cleanup
    summary "upgrade"
}

teardown() {
    require_linux_root teardown
    phase "teardown — ./rigforge.sh uninstall --yes (a COMPLETE revert)"
    "$RIGFORGE" uninstall --yes

    # The stubbed suites check most of these against fake /etc, but ONLY this real-hardware gate proves the
    # real privileged `sudo cp`/`rm`/`umount`/`remove_line` against the real system actually leaves the box
    # clean — a leftover fstab line (next `mount -a` fails) or un-removed worker dir would otherwise ship.
    systemctl cat xmrig >/dev/null 2>&1 && bad "xmrig.service still present after uninstall" ||
        ok "systemd unit removed"
    systemctl cat rigforge-autotune.timer >/dev/null 2>&1 && bad "autotune timer still present" ||
        ok "autotune timer removed (or was never installed)"
    if [ -f /etc/default/grub ]; then
        grep -qE 'hugepages|hugepagesz' /etc/default/grub &&
            bad "GRUB still carries HugePage params (revert incomplete)" || ok "GRUB kernel params reverted"
    fi
    [ -f /etc/logrotate.d/xmrig ] && bad "/etc/logrotate.d/xmrig still present" || ok "logrotate policy removed"
    grep -qiE 'hugetlbfs' /etc/fstab 2>/dev/null && bad "fstab still has HugePage mounts" || ok "fstab HugePage mounts removed"
    grep -qiE 'memlock unlimited' /etc/security/limits.conf 2>/dev/null &&
        bad "limits.conf still has memlock entries" || ok "memlock limits removed"
    [ -f /etc/modules-load.d/msr.conf ] && bad "/etc/modules-load.d/msr.conf still present" || ok "msr autoload conf removed"
    grep -qxF 'msr' /etc/modules 2>/dev/null && bad "/etc/modules still autoloads msr" || ok "msr line removed from /etc/modules"
    grep -q 'hugepages1G' /proc/mounts 2>/dev/null && bad "/dev/hugepages1G still mounted" || ok "1G HugePage mount unmounted"
    [ -d "$HERE/data/worker/xmrig" ] && bad "worker build dir still present at $HERE/data/worker/xmrig" || ok "worker build/logs removed"
    [ -f "$HERE/config.json" ] && ok "config.json preserved (uninstall keeps it)" || bad "config.json was removed — uninstall must keep it"
    [ -L /usr/local/bin/rigforge ] && bad "/usr/local/bin/rigforge symlink still present" || ok "the 'rigforge' command was removed from PATH"

    phase "teardown — uninstall is idempotent (a second run is a clean no-op)"
    "$RIGFORGE" uninstall --yes >/tmp/e2e-uninstall2.log 2>&1 &&
        ok "second uninstall exits 0 (idempotent)" || {
        bad "second uninstall failed (not idempotent)"
        tail -5 /tmp/e2e-uninstall2.log >&2
    }
    summary "teardown"
}

summary() {
    echo ""
    if [ "$FAIL" -eq 0 ]; then
        echo "E2E-REAL ($1): PASS — $PASS check(s) passed."
    else
        echo "E2E-REAL ($1): FAIL — $FAIL failed, $PASS passed." >&2
        exit 1
    fi
}

# Standardized performance gate (#114 follow-through): the same offline 1M bench as verify, judged
# against a COMMITTED per-host baseline (tests/perf-baselines/<hostname>.json) so a release can't
# silently regress hashrate. No baseline yet -> reports the measurement and how to record one.
# Knobs: E2E_PERF_RECORD=1 writes/updates the baseline (commit the file); E2E_PERF_TAG=vX.Y.Z tags
# the history entry with the release being cut; E2E_PERF_TOLERANCE_PCT (default 5) is the allowed
# drop — real rigs vary run-to-run with thermals, so keep it honest but not twitchy. The relative
# live-hashrate guard (API load must not shave H/s) lives in tests/e2e-pithead.sh's api-impact
# phase; this one owns the absolute number.
#
# History + anti-ratchet: every E2E_PERF_RECORD appends {tag, recorded, bench_1m_hs} to
# tests/perf-baselines/<hostname>.history.jsonl (commit it with the baseline) so per-release
# benchmarks are never lost to an overwrite. The gate then checks the measurement against BOTH the
# current baseline AND the best history entry — refreshing the baseline every release can never
# ratchet hashrate downward tolerance-by-tolerance without a visible failure.
# Judge a measurement against the committed baseline AND the best-ever history entry (#186).
# Prints the ok/bad verdict lines and returns 1 on any regression — shared by judge mode and
# record mode (#214), so the two can never disagree about what "regressed" means.
_perf_judge() { # <hr> <baseline.json> <history.jsonl> <tolerance_pct>
    local hr="$1" bl="$2" hist="$3" tol="$4" base best rcj=0
    base=$(jq -r '.bench_1m_hs // empty' "$bl" 2>/dev/null || true)
    if [ -z "$base" ]; then
        bad "perf: baseline $bl is unreadable"
        return 1
    fi
    if awk -v h="$hr" -v b="$base" -v t="$tol" 'BEGIN{exit !(h >= b * (1 - t / 100))}'; then
        ok "perf: $hr H/s within ${tol}% of baseline $base ($(jq -r '.recorded' "$bl" 2>/dev/null))"
    else
        bad "perf REGRESSION: $hr H/s vs baseline $base H/s (tolerance ${tol}%) — investigate before releasing"
        rcj=1
    fi
    if [ -f "$hist" ]; then
        best=$(jq -s 'map(.bench_1m_hs) | max // empty' "$hist" 2>/dev/null || true)
        if [ -n "$best" ]; then
            if awk -v h="$hr" -v b="$best" -v t="$tol" 'BEGIN{exit !(h >= b * (1 - t / 100))}'; then
                ok "perf: $hr H/s within ${tol}% of this host's best-ever $best"
            else
                bad "perf RATCHET: $hr H/s vs best-ever $best H/s (tolerance ${tol}%) — slow drift across releases; investigate before releasing"
                rcj=1
            fi
        fi
    fi
    return "$rcj"
}

perf() {
    phase "perf — offline bench vs the committed $(hostname) baseline"
    local bl hist out hr base best tol="${E2E_PERF_TOLERANCE_PCT:-5}"
    bl="$HERE/tests/perf-baselines/$(hostname).json"
    hist="$HERE/tests/perf-baselines/$(hostname).history.jsonl"
    "$RIGFORGE" stop >/dev/null 2>&1 || true # take the whole machine for a clean reading
    if ! out="$(BENCH=1M "$RIGFORGE" bench 2>&1)"; then
        bad "perf: bench failed"
        printf '%s\n' "$out" | tail -3 >&2
        "$RIGFORGE" start >/dev/null 2>&1 || true
        summary "perf"
        return
    fi
    "$RIGFORGE" start >/dev/null 2>&1 || true
    hr="$(printf '%s' "$out" | grep -oiE '[0-9.]+ H/s' | tail -1 | grep -oE '[0-9.]+')"
    if [ -z "$hr" ]; then
        bad "perf: no hashrate parsed from bench output"
        summary "perf"
        return
    fi
    if [ -n "${E2E_PERF_RECORD:-}" ]; then
        # #214: judge BEFORE writing — recording is the only perf run most rigs ever get, and a
        # regressed number must never become the new baseline by default. E2E_PERF_FORCE=1 is the
        # conscious "re-record anyway" override from RELEASING.md's investigate-or-re-record flow.
        if [ -f "$bl" ] && ! _perf_judge "$hr" "$bl" "$hist" "$tol"; then
            if [ -z "${E2E_PERF_FORCE:-}" ]; then
                bad "perf: NOT recorded — the measurement regressed (see above). Fix the regression, or consciously re-record with E2E_PERF_FORCE=1."
                summary "perf"
                return
            fi
            printf '  \033[1;33m∙\033[0m E2E_PERF_FORCE=1 — recording a REGRESSED measurement as the new baseline\n'
        fi
        mkdir -p "$(dirname "$bl")"
        jq -n --arg hs "$hr" --arg cpu "$(lscpu 2>/dev/null | sed -nE 's/^Model name:[ \t]+//p' | head -1)" --arg when "$(date '+%Y-%m-%d')" '{bench_1m_hs: ($hs | tonumber), cpu: $cpu, recorded: $when}' >"$bl"
        jq -cn --arg hs "$hr" --arg tag "${E2E_PERF_TAG:-}" --arg when "$(date '+%Y-%m-%d')" '{tag: $tag, recorded: $when, bench_1m_hs: ($hs | tonumber)}' >>"$hist"
        ok "perf: baseline recorded — $hr H/s -> $bl + history (commit both files)"
        # #206: the recording dirties this checkout, and a later `git checkout <tag>` ABORTS on
        # dirty tracked files — say so now, not at the next deploy.
        printf '  \033[1;33m∙\033[0m collect: %s and %s\n' "$bl" "$hist"
        printf '  \033[1;33m∙\033[0m after they are committed upstream, reset this rig or the next tag deploy aborts: git checkout -- tests/perf-baselines/\n'
        summary "perf"
        return
    fi
    if [ ! -f "$bl" ]; then
        printf '  \033[1;33m∙\033[0m no baseline for %s — measured %s H/s; record with E2E_PERF_RECORD=1 and commit tests/perf-baselines/\n' "$(hostname)" "$hr"
        summary "perf"
        return
    fi
    # The bad lines inside the judge already counted any failure; nothing more to decide here.
    _perf_judge "$hr" "$bl" "$hist" "$tol" || true
    summary "perf"
}

case "${1:-}" in
provision | verify | control | upgrade | perf | teardown | all) ;;
*) die "usage: sudo bash tests/e2e-real.sh {provision|verify|control|upgrade|perf|teardown|all}" ;;
esac
# #183: serialize the shared rig — taken after arg parsing, before the first systemctl/API touch.
rig_lock rigforge e2e-real

case "$1" in
provision) provision ;;
verify) verify ;;
control) control ;;
upgrade) upgrade ;;
perf) perf ;;
teardown) teardown ;;
all)
    provision
    if [ "$(hugepages_total)" -gt 0 ]; then
        verify
        control
        upgrade
        perf
        teardown
    else
        echo "e2e-real: stopping after provision — reboot, then run 'verify' and 'teardown'." >&2
    fi
    ;;
*)
    die "usage: sudo bash tests/e2e-real.sh {provision|verify|control|upgrade|perf|teardown|all}"
    ;;
esac
