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
#   teardown  : sudo ./rigforge.sh uninstall --yes  -> assert a clean revert of every system path + idempotency
#
# Linux-only and root-only (kernel tuning, modprobe, apt). Typical flow on the release rig:
#   sudo bash tests/e2e-real.sh provision
#   sudo reboot                         # then reconnect
#   sudo bash tests/e2e-real.sh verify
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
ok() {
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
    PASS=$((PASS + 1))
}
bad() {
    printf '  \033[1;31m✗\033[0m %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}
phase() { printf '\n\033[1m== e2e-real: %s ==\033[0m\n' "$1"; }
die() {
    printf '\033[31me2e-real: %s\033[0m\n' "$1" >&2
    exit 2
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
    local wr="$HERE/data/worker" op=""
    op=$(systemctl cat rigforge-autotune.service 2>/dev/null | sed -nE 's/^Environment=RIGFORGE_OPERATOR=//p' | head -1)
    if [ -n "$op" ]; then
        ok "autotune unit bakes in RIGFORGE_OPERATOR=$op (#reown)"
        if [ -d "$wr" ]; then
            chown -R root:root "$wr" 2>/dev/null
            env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin RIGFORGE_OPERATOR="$op" RIGFORGE_HOME="$HERE" bash "$RIGFORGE" apply >/dev/null 2>&1 || true
            [ "$(stat -c %U "$wr")" = "$op" ] &&
                ok "a root-context run (no SUDO_USER) re-owned the worker to '$op', not root (#reown)" ||
                bad "a root-context run left the worker owned by '$(stat -c %U "$wr")' (expected '$op')"
        fi
    else
        ok "SKIP autotune re-own check — periodic autotune not enabled ('autotune': true in config.json)"
    fi
    summary "verify"
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

case "${1:-}" in
provision) provision ;;
verify) verify ;;
teardown) teardown ;;
all)
    provision
    if [ "$(hugepages_total)" -gt 0 ]; then
        verify
        teardown
    else
        echo "e2e-real: stopping after provision — reboot, then run 'verify' and 'teardown'." >&2
    fi
    ;;
*)
    die "usage: sudo bash tests/e2e-real.sh {provision|verify|teardown|all}"
    ;;
esac
