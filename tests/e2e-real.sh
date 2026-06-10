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
#   verify    : doctor (HugePages/MSR/governor/service) + bench (real H/s, clean) + a short real tune
#   teardown  : sudo ./rigforge.sh uninstall --yes  -> assert a clean revert
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
    printf '  \033[32m✓\033[0m %s\n' "$1"
    PASS=$((PASS + 1))
}
bad() {
    printf '  \033[31m✗\033[0m %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}
phase() { printf '\n\033[1m== e2e-real: %s ==\033[0m\n' "$1"; }
die() {
    printf '\033[31me2e-real: %s\033[0m\n' "$1" >&2
    exit 2
}

require_linux_root() {
    [ "$(uname -s)" = "Linux" ] || die "Linux-only (this host is $(uname -s)) — run on the release rig."
    [ "$(id -u)" -eq 0 ] || die "must run as root (kernel tuning / modprobe / apt): sudo bash tests/e2e-real.sh $*"
    [ -x "$RIGFORGE" ] || die "$RIGFORGE not found or not executable."
}

hugepages_total() { awk '/^HugePages_Total:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0; }
find_worker_bin() { find "$HERE" -type f -path '*xmrig/build/xmrig' 2>/dev/null | head -1; }

ensure_config() {
    # setup needs a valid config.json. A release e2e benches OFFLINE, so any valid pool entry works;
    # default to an unroutable TEST-NET-3 (RFC 5737) host so the installed service never actually mines.
    if [ ! -f "$HERE/config.json" ]; then
        printf '{ "pools": [{ "url": "203.0.113.1:3333" }], "DONATION": 1 }\n' >"$HERE/config.json"
        ok "wrote a placeholder config.json (offline bench; the service won't mine)"
    else
        ok "using the existing config.json"
    fi
}

# --- phases ------------------------------------------------------------------
provision() {
    require_linux_root provision
    ensure_config
    phase "provision — ./rigforge.sh setup (real deps + build + tuning + service)"
    "$RIGFORGE" setup

    local bin
    bin="$(find_worker_bin)"
    [ -n "$bin" ] && [ -x "$bin" ] && ok "XMRig binary was built ($bin)" || bad "no built XMRig binary found"
    systemctl cat xmrig >/dev/null 2>&1 && ok "systemd unit 'xmrig' installed" || bad "xmrig.service not installed"

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
    # msr-tools — verify the prefetcher registers hold the preset's values via rdmsr. On the 7800X3D rig
    # the preset is ryzen_19h_zen4; the verified value table lives in rigforge.sh (_msr_preset_regs).
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

    phase "verify — live pool (the worker actually connects and submits a share)"
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
        # Share submission: an accepted share proves the full mining round-trip. Assumes a reachable pool
        # with sane difficulty (e.g. the stack's pool); raise E2E_SHARE_TIMEOUT for a high-difficulty pool.
        waited=0
        while [ "$waited" -lt "$share_to" ] && ! grep -q 'accepted (' "$wlog" 2>/dev/null; do
            sleep 5
            waited=$((waited + 5))
        done
        grep -q 'accepted (' "$wlog" 2>/dev/null &&
            ok "submitted an accepted share ($(grep -c 'accepted (' "$wlog") accepted so far)" ||
            bad "no accepted share within ${share_to}s — check pool reachability / difficulty"
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
    # Constrain the search to a couple of quick candidates so this stays fast (a real tune is a separate,
    # hours-long operation). We assert the pipeline runs, writes its result files, and — proving the #62
    # effective-clock sampling works on real hardware under load — records a min_freq_mhz per candidate.
    local tj
    if TUNE_BENCH=1M TUNE_ITERS=2 TUNE_SEEDS=auto TUNE_PREFETCH_MODES="1 2" TUNE_YIELDS=false TUNE_THREADS=-1 \
        TUNE_WRMSR="true false" TUNE_MAX_ROUNDS=1 "$RIGFORGE" tune >/tmp/e2e-tune.log 2>&1; then
        tj="$(find "$HERE" -path '*worker*' -name 'rigforge-tune.json' 2>/dev/null | head -1)"
        if [ -n "$tj" ]; then
            ok "tune completed and wrote results ($(basename "$tj"))"
            [ "$(jq -r '[.results[]|select(.min_freq_mhz!=null)]|length>0' "$tj" 2>/dev/null)" = true ] &&
                ok "tune sampled the effective clock under load (#62: $(jq -r '[.results[].min_freq_mhz]|min' "$tj") MHz min)" ||
                bad "tune recorded no effective-clock samples (#62)"
            # #66: the wrmsr knob was swept (TUNE_WRMSR), so every candidate records its wrmsr value, and
            # the live MSR write/read of each variant exercises the real msr path under load.
            [ "$(jq -r '[.results[]|select(has("wrmsr"))]|length>0' "$tj" 2>/dev/null)" = true ] &&
                ok "tune swept and recorded the wrmsr knob (#66)" || bad "tune didn't record the wrmsr knob (#66)"
            # #65: the reservation-aware check ran on real hardware — candidates carry hugepages_capped
            # (false here, since setup sized the reservation to fit; the field's presence proves the wiring).
            [ "$(jq -r '[.results[]|select(has("hugepages_capped"))]|length>0' "$tj" 2>/dev/null)" = true ] &&
                ok "tune records the reservation-cap status (#65)" || bad "tune didn't record hugepages_capped (#65)"
        else
            bad "tune left no result file"
        fi
    else
        bad "tune failed (see /tmp/e2e-tune.log):"
        tail -5 /tmp/e2e-tune.log >&2
    fi

    phase "verify — live A/B confirm (#64)"
    # A real --confirm round against the live miner: it measures the tuned config, restores the previous
    # one and measures that, then keeps or reverts. Short windows keep the e2e quick.
    if TUNE_LIVE_WARMUP="${E2E_AB_WARMUP:-20}" TUNE_LIVE_SAMPLES=2 TUNE_LIVE_INTERVAL=5 TUNE_BENCH=1M \
        TUNE_ITERS=1 TUNE_SEEDS=auto TUNE_PREFETCH_MODES=1 TUNE_YIELDS=false TUNE_THREADS=-1 TUNE_MAX_ROUNDS=1 \
        "$RIGFORGE" tune --confirm >/tmp/e2e-ab.log 2>&1; then
        grep -qE 'Confirmed:|Reverted:' /tmp/e2e-ab.log &&
            ok "live A/B confirm ran ($(grep -oE '(Confirmed|Reverted):.*' /tmp/e2e-ab.log | tail -1))" ||
            bad "live A/B confirm produced no verdict (see /tmp/e2e-ab.log)"
    else
        bad "tune --confirm failed (see /tmp/e2e-ab.log):"
        tail -5 /tmp/e2e-ab.log >&2
    fi
    "$RIGFORGE" tune --clear >/dev/null 2>&1 || true # leave the rig on its baseline config
    "$RIGFORGE" apply >/dev/null 2>&1 || true
    summary "verify"
}

teardown() {
    require_linux_root teardown
    phase "teardown — ./rigforge.sh uninstall --yes (clean revert)"
    "$RIGFORGE" uninstall --yes

    systemctl cat xmrig >/dev/null 2>&1 && bad "xmrig.service still present after uninstall" ||
        ok "systemd unit removed"
    if [ -f /etc/default/grub ]; then
        grep -qE 'hugepages|hugepagesz' /etc/default/grub &&
            bad "GRUB still carries HugePage params (revert incomplete)" || ok "GRUB kernel params reverted"
    fi
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
