#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s — %s\n' "$1" "$2" >&2
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in [$2]" ;; esac }
absent() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in [$2]" ;; *) ok "$1" ;; esac }

base_config() {
    local out="$1" extra="${2:-}"
    [ -n "$extra" ] || extra='{}'
    jq --arg home "$TMP/runtime" --argjson extra "$extra" \
        '.pools[0].url |= gsub("[^A-Za-z0-9.:-]"; "") | .HOME_DIR = $home | . * $extra' \
        "$ROOT/config.minimal.json" >"$out"
}
TEST_HOST="$(jq -r '.pools[0].url | gsub("[^A-Za-z0-9.:-]"; "") | sub(":[0-9]+$"; "")' "$ROOT/config.minimal.json")"

parse_case() {
    local overlay="$1" cfg="$TMP/parse.json"
    base_config "$cfg" "$(jq -cn --argjson x "$overlay" '{xmrig:$x}')"
    (
        source "$SCRIPT"
        CONFIG_JSON="$cfg"
        SCRIPT_DIR="$ROOT"
        set +e
        parse_config
    ) 2>&1
}

echo '== xmrig overlay: parse validation =='
for row in \
    'pools|{"pools":[]}' \
    'http|{"http":{"enabled":false}}' \
    'donate-level|{"donate-level":0}' \
    'donate-over-proxy|{"donate-over-proxy":null}' \
    'opencl|{"opencl":false}' \
    'cuda|{"cuda":null}'; do
    key="${row%%|*}"
    out="$(parse_case "${row#*|}")"
    rc=$?
    eq "protected $key is rejected" "$rc" 1
    has "protected $key is named" "$out" "$key"
done
out="$(parse_case '[1]')"
eq 'non-object overlay is rejected' "$?" 1
has 'non-object error names xmrig' "$out" xmrig
out="$(parse_case '{"unlisted_overlay_probe":true}')"
eq 'unknown overlay key remains accepted' "$?" 0
has 'unknown overlay key warns' "$out" unlisted_overlay_probe

generate_case() {
    local name="$1" overlay="$2" tune="$3" cap="$4" script="${5:-$SCRIPT}" d cfg
    d="$TMP/$name"
    cfg="$d/config.json"
    mkdir -p "$d/out" "$TMP/runtime/worker"
    base_config "$cfg" "$overlay"
    rm -f "$TMP/runtime/worker/tune-overrides.json"
    [ -z "$tune" ] || printf '%s\n' "$tune" >"$TMP/runtime/worker/tune-overrides.json"
    (
        source "$script"
        CONFIG_JSON="$cfg"
        SCRIPT_DIR="$ROOT"
        OS_TYPE=Linux
        RIGFORGE_APPLIANCE=1
        lscpu() { printf 'Model name: Fixture CPU\n'; }
        hostname() { printf '%s\n' "$TEST_HOST"; }
        _cpu_missing_isa() { :; }
        sudo() { "$@"; }
        parse_config >/dev/null
        THREADS_CAP="$cap"
        cd "$d/out" || exit 1
        generate_xmrig_config >/dev/null
    )
    printf '%s' "$d/out/config.json"
}

echo '== xmrig overlay: generation order and compatibility =='
plain="$(generate_case plain '{}' '' '')"
empty="$(generate_case empty '{"xmrig":{}}' '' '')"
if cmp -s "$plain" "$empty"; then ok 'missing and empty overlays generate identical bytes'; else bad 'missing and empty overlays generate identical bytes' 'files differ'; fi
if [ -n "${BASELINE_SCRIPT:-}" ]; then
    baseline="$(generate_case baseline '{}' '' '' "$BASELINE_SCRIPT")"
    if cmp -s "$plain" "$baseline"; then ok 'absent overlay is byte-identical to baseline'; else bad 'absent overlay is byte-identical to baseline' 'files differ'; fi
fi
tuned="$(generate_case tuned '{}' '{"cpu":{"priority":3}}' '')"
eq 'tune overrides generated defaults' "$(jq -r '.cpu.priority' "$tuned")" 3
ordered="$(generate_case ordered '{"xmrig":{"cpu":{"priority":4,"rx":8}}}' '{"cpu":{"priority":3,"rx":9}}' 4)"
eq 'overlay overrides tune' "$(jq -r '.cpu.priority' "$ordered")" 4
eq 'thread cap overrides overlay' "$(jq -r '.cpu.rx' "$ordered")" 4

echo '== xmrig overlay: tuning pins =='
pin_out="$(
    source "$SCRIPT"
    XMRIG_OVERLAY='{"randomx":{"scratchpad_prefetch_mode":2,"1gb-pages":false,"cache_qos":null,"wrmsr":1},"cpu":{"yield":true,"rx":[1,2],"priority":null,"huge-pages-jit":true}}'
    TUNE_PREFETCH_MODES='0 1 2 3' TUNE_YIELDS='false true' TUNE_THREADS='-1 4' TUNE_ONEGB='true false'
    TUNE_PRIORITIES='0 1 2' TUNE_HPJIT='false true' TUNE_CACHEQOS='false true' TUNE_WRMSR='true false'
    for knob in prefetch yield threads onegb priority hpjit cacheqos wrmsr; do
        printf '%s=%s\n' "$knob" "$(_knob_values "$knob")"
    done
)"
eq 'every pinned tune knob yields only its overlay value' "$pin_out" $'prefetch=2\nyield=true\nthreads=[1,2]\nonegb=false\npriority=null\nhpjit=true\ncacheqos=null\nwrmsr=1'
pins="$(
    source "$SCRIPT"
    _xmrig_overlay_pins '{"cpu":{"yield":false},"randomx":{"scratchpad_prefetch_mode":2}}'
)"
has 'pin listing includes cpu.yield' "$pins" cpu.yield
has 'pin listing includes prefetch' "$pins" randomx.scratchpad_prefetch_mode
(
    source "$SCRIPT"
    TUNE_BASE="$TMP/tune-base.json"
    printf '{"cpu":{"priority":2,"rx":-1},"randomx":{"scratchpad_prefetch_mode":1}}\n' >"$TUNE_BASE"
    XMRIG_OVERLAY='{"cpu":{"priority":4,"rx":8},"randomx":{"scratchpad_prefetch_mode":3}}'
    THREADS_CAP=4
    _tune_config "$TMP/tune-candidate.json" 2 false 9 true 3 false false true
)
eq 'tune candidates enforce overlay' "$(jq -r '.randomx.scratchpad_prefetch_mode' "$TMP/tune-candidate.json")" 3
eq 'tune candidates enforce thread cap last' "$(jq -r '.cpu.rx' "$TMP/tune-candidate.json")" 4

tune_case() {
    local search="$1" variant="${2:-$1}" overlay="${3:-}" expected="${4:-}" d
    [ -n "$overlay" ] || overlay='{"randomx":{"scratchpad_prefetch_mode":2},"cpu":{"rx":3}}'
    [ -n "$expected" ] || expected=3
    d="$TMP/tune-$variant"
    mkdir -p "$d/xmrig/build"
    : >"$d/1"
    printf '#!/usr/bin/env bash\nexit 99\n' >"$d/xmrig/build/xmrig"
    chmod +x "$d/xmrig/build/xmrig"
    printf '{"cpu":{"yield":false,"priority":2,"rx":-1,"huge-pages-jit":false},"randomx":{"scratchpad_prefetch_mode":1,"1gb-pages":true,"cache_qos":false,"wrmsr":true}}\n' >"$d/xmrig/build/config.json"
    (
        cd "$d" || exit 1
        source "$SCRIPT"
        OS_TYPE=Darwin
        parse_config() {
            WORKER_ROOT="$d"
            XMRIG_OVERLAY="$overlay"
            AUTOTUNE_TARGET=perf
        }
        _l3_thread_center() { echo 2; }
        _measure() {
            jq -cn --argjson argc "$#" --argjson threads "$3" '{argc:$argc,threads:$threads}' >>"$d/candidates"
            echo 100
        }
        _accept_better() { return 1; }
        sudo() { "$@"; }
        TUNE_SEARCH="$search" TUNE_SEEDS=auto TUNE_ITERS=1 TUNE_PREFETCH_MODES='0 1 2 3' \
            TUNE_YIELDS='false true' TUNE_THREADS='-1 2 3 4' TUNE_PRIORITIES=2 \
            TUNE_HPJIT=false TUNE_CACHEQOS=false TUNE_WRMSR=true tune >"$d/output" 2>&1
    )
    jq -se --argjson expected "$expected" 'length > 0 and all(.[]; .argc == 8 and .threads == $expected)' "$d/candidates" >/dev/null
}
if tune_case hill; then ok 'hill-climb candidates respect overlay pins'; else bad 'hill-climb candidates respect overlay pins' 'unpinned candidate measured'; fi
eq 'hill-climb final overrides omit pinned paths' "$(jq -r '(.randomx | has("scratchpad_prefetch_mode")) or (.cpu | has("rx"))' "$TMP/tune-hill/tune-overrides.json")" false
if tune_case grid; then ok 'grid candidates respect overlay pins'; else bad 'grid candidates respect overlay pins' 'unpinned candidate measured'; fi
eq 'grid final overrides omit pinned paths' "$(jq -r '(.randomx | has("scratchpad_prefetch_mode")) or (.cpu | has("rx"))' "$TMP/tune-grid/tune-overrides.json")" false
if tune_case grid grid-array '{"randomx":{"scratchpad_prefetch_mode":2},"cpu":{"rx":[1,2]}}' '[1,2]'; then ok 'grid preserves an array thread profile as one JSON candidate'; else bad 'grid preserves an array thread profile as one JSON candidate' 'profile split or expanded'; fi
if tune_case grid grid-string '{"randomx":{"scratchpad_prefetch_mode":2},"cpu":{"rx":"custom profile"}}' '"custom profile"'; then ok 'grid preserves a spaced thread profile as one JSON candidate'; else bad 'grid preserves a spaced thread profile as one JSON candidate' 'profile split'; fi
eq 'a spaced pinned profile does not activate the threads knob' "$(wc -l <"$TMP/tune-grid-string/candidates" | tr -d ' ')" 2
history="$({
    source "$SCRIPT"
    OS_TYPE=Darwin
    XMRIG_OVERLAY='{"cpu":{"yield":false},"randomx":{"scratchpad_prefetch_mode":2}}'
    _tune_history "$TMP/no-overrides" "$TMP/no-log"
} 2>&1)"
has 'tune history reports pinned cpu.yield' "$history" cpu.yield
has 'tune history reports pinned prefetch' "$history" randomx.scratchpad_prefetch_mode
auto_dir="$TMP/autotune"
mkdir -p "$auto_dir"
auto_out="$({
    source "$SCRIPT"
    OS_TYPE=Linux
    parse_config() {
        WORKER_ROOT="$auto_dir"
        XMRIG_OVERLAY='{"randomx":{"scratchpad_prefetch_mode":2}}'
    }
    _autotune_sample() { printf '100\t0\n'; }
    _apply_runtime() { printf 'restart\n' >>"$auto_dir/calls"; }
    sleep() { :; }
    AUTOTUNE_MODES='0 1 2 3' autotune
} 2>&1)"
if [ ! -e "$auto_dir/calls" ]; then ok 'autotune does not sweep a pinned prefetch mode'; else bad 'autotune does not sweep a pinned prefetch mode' 'candidate was applied'; fi
has 'autotune explains the pinned mode' "$auto_out" pinned

echo '== xmrig overlay: feed and remote boundary =='
feed_case() {
    local extra="$1" cfg="$TMP/feed.json"
    base_config "$cfg" "$extra"
    (
        source "$SCRIPT"
        CONFIG_JSON="$cfg"
        SCRIPT_DIR="$ROOT"
        parse_config >/dev/null
        _api_config_json
    ) 2>/dev/null
}
feed="$(feed_case '{"xmrig":{"cpu":{"yield":true}}}')"
eq 'feed includes a nonempty xmrig overlay' "$(printf '%s' "$feed" | jq -c '.xmrig')" '{"cpu":{"yield":true}}'
feed="$(feed_case '{}')"
eq 'feed without overlay keeps xmrig absent' "$(printf '%s' "$feed" | jq 'has("xmrig")')" false
feed="$(feed_case '{"xmrig":{}}')"
eq 'feed omits an empty overlay' "$(printf '%s' "$feed" | jq 'has("xmrig")')" false
doctor_cfg="$TMP/doctor.json"
base_config "$doctor_cfg" '{"xmrig":{"cpu":{"yield":true},"randomx":{"scratchpad_prefetch_mode":2}}}'
doctor_out="$({
    source "$SCRIPT"
    OS_TYPE=Linux CONFIG_JSON="$doctor_cfg" SCRIPT_DIR="$ROOT"
    systemctl() { return 1; }
    _tcp_probe() { return 0; }
    _cpu_missing_isa() { :; }
    doctor || true
} 2>&1)"
has 'doctor reports pinned overlay paths' "$doctor_out" 'cpu.yield, randomx.scratchpad_prefetch_mode'
if ! command -v python3 >/dev/null 2>&1; then
    echo '  SKIP: remote receiver allowlist check requires python3'
elif python3 - "$ROOT/util/control-server.py" <<'PY'
import runpy, sys
assert "xmrig" not in runpy.run_path(sys.argv[1])["WRITABLE"]
PY
then ok 'remote control cannot write xmrig'; else bad 'remote control cannot write xmrig' 'xmrig is writable'; fi

echo '== xmrig overlay: apply validation =='
APPLY="$TMP/apply"
mkdir -p "$APPLY/runtime/worker/xmrig/build" "$APPLY/bin"
base_config "$APPLY/config.json" '{"miner_user":"fixture_user","xmrig":{"print-time":17,"dry-run":false}}'
jq --arg home "$APPLY/runtime" '.HOME_DIR=$home' "$APPLY/config.json" >"$APPLY/config.next"
mv "$APPLY/config.next" "$APPLY/config.json"
cat >"$APPLY/runtime/worker/xmrig/build/xmrig" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$XMRIG_CALLS"
[ "$1" = --config ] && [ -f "$2" ] && [ "$3" = --dry-run ] || exit 19
[ "$(jq -r '."dry-run"' "$2")" = true ] || exit 18
[ "$(jq -r '.cpu."memory-pool"' "$2")" = false ] || exit 17
printf '%s\n' 'overlay parser rejected candidate' >&2
exit "${XMRIG_RC:-0}"
STUB
chmod +x "$APPLY/runtime/worker/xmrig/build/xmrig"
mkdir -p "$APPLY/systemd"
printf 'original unit\n' >"$APPLY/systemd/xmrig.service"

apply_case() {
    local rc="$1"
    shift
    (
        source "$SCRIPT"
        CONFIG_JSON="$APPLY/config.json"
        SCRIPT_DIR="$ROOT"
        SYSTEMD_DIR="$APPLY/systemd"
        OS_TYPE=Linux
        RIGFORGE_APPLIANCE=1
        XMRIG_CALLS="$APPLY/xmrig.calls"
        XMRIG_RC="$rc"
        export XMRIG_CALLS XMRIG_RC
        lscpu() { printf 'Model name: Fixture CPU\n'; }
        _cpu_missing_isa() { :; }
        systemctl() {
            printf '%s\n' "$*" >>"$APPLY/systemctl.calls"
            case "$*" in *restart*) printf 'restart\n' >>"$APPLY/events" ;; esac
            return 0
        }
        sudo() {
            case "$1" in chown)
                printf 'chown\n' >>"$APPLY/events"
                return "${CHOWN_RC:-0}"
                ;;
            esac
            "$@"
        }
        mv() {
            if [ "${PUBLISH_FAIL:-0}" = 1 ] && [ "${2:-}" = "$live" ]; then return 1; fi
            command mv "$@"
        }
        envsubst() { cat; }
        _ensure_miner_user() { :; }
        _reown_worker() { :; }
        install_autotune() { :; }
        install_watchdog() { :; }
        install_api() { :; }
        install_control() { :; }
        install_api_firewall() { :; }
        _autotune_apply_notice() { :; }
        _stamp_config_meta() { :; }
        _apply_pool_check() { :; }
        _miner_deliberately_stopped() { return 1; }
        set +e
        apply "$@"
    ) 2>&1
}

live="$APPLY/runtime/worker/xmrig/build/config.json"
printf '{"sentinel":"live"}\n' >"$live"
: >"$APPLY/xmrig.calls"
out="$(apply_case 0 --dry-run)"
eq 'apply dry-run succeeds after validation' "$?" 0
has 'apply dry-run invokes validator with config before dry-run' "$(cat "$APPLY/xmrig.calls")" '--config '
has 'apply dry-run keeps dry-run last' "$(cat "$APPLY/xmrig.calls")" ' --dry-run'
eq 'apply dry-run preserves live config' "$(jq -r '.sentinel' "$live")" live
printf '{"sentinel":"live"}\n' >"$live"
: >"$APPLY/xmrig.calls"
out="$(apply_case 7 --dry-run)"
eq 'validator failure aborts apply dry-run' "$?" 1
has 'dry-run validation failure reaches the operator' "$out" 'overlay parser rejected candidate'
eq 'failed apply dry-run preserves live config' "$(jq -r '.sentinel' "$live")" live
: >"$APPLY/xmrig.calls"
: >"$APPLY/systemctl.calls"
: >"$APPLY/events"
out="$(apply_case 0)"
eq 'apply succeeds after validation' "$?" 0
has 'apply invokes validator with config before dry-run' "$(cat "$APPLY/xmrig.calls")" '--config '
has 'successful apply reaches restart' "$(cat "$APPLY/systemctl.calls")" restart
eq 'candidate ownership is set before restart' "$(tr '\n' ' ' <"$APPLY/events")" 'chown restart '
printf '{"sentinel":"live"}\n' >"$live"
: >"$APPLY/xmrig.calls"
: >"$APPLY/systemctl.calls"
out="$(apply_case 7)"
eq 'validator failure aborts apply' "$?" 1
has 'validator failure reaches the operator' "$out" 'overlay parser rejected candidate'
absent 'validator failure aborts before restart' "$(cat "$APPLY/systemctl.calls")" restart
absent 'validator failure aborts before unit render' "$(cat "$APPLY/systemctl.calls")" daemon-reload
eq 'validator failure preserves live config' "$(jq -r '.sentinel' "$live")" live

printf '%s\n' '{"sentinel":"live"}' >"$live"
: >"$APPLY/systemctl.calls"
chmod -x "$APPLY/runtime/worker/xmrig/build/xmrig"
out="$(apply_case 0)"
eq 'missing executable aborts apply' "$?" 1
has 'missing executable failure reaches the operator' "$out" 'No built XMRig'
eq 'missing executable preserves live config' "$(jq -r '.sentinel' "$live")" live
absent 'missing executable aborts before restart' "$(cat "$APPLY/systemctl.calls")" restart
chmod +x "$APPLY/runtime/worker/xmrig/build/xmrig"

printf '%s\n' '{"sentinel":"live"}' >"$live"
: >"$APPLY/systemctl.calls"
out="$(CHOWN_RC=1 apply_case 0)"
eq 'ownership failure aborts apply' "$?" 1
eq 'ownership failure preserves live config' "$(jq -r '.sentinel' "$live")" live
absent 'ownership failure aborts before restart' "$(cat "$APPLY/systemctl.calls")" restart

printf '%s\n' '{"sentinel":"live"}' >"$live"
: >"$APPLY/systemctl.calls"
out="$(PUBLISH_FAIL=1 apply_case 0)"
eq 'publish failure aborts apply' "$?" 1
eq 'publish failure preserves live config' "$(jq -r '.sentinel' "$live")" live
absent 'publish failure aborts before restart' "$(cat "$APPLY/systemctl.calls")" restart

disabled_cfg="$TMP/all-disabled.json"
jq '.pools |= map(.enabled=false)' "$plain" >"$disabled_cfg"
disabled_out="$({
    source "$SCRIPT"
    _validate_xmrig_config "$TMP/no-executor" "$disabled_cfg" "$TMP/disabled-preview.json"
} 2>&1)"
eq 'all-disabled pools are rejected without an executor' "$?" 1
has 'all-disabled rejection names the enabled-pool requirement' "$disabled_out" 'enabled pool'
absent 'all-disabled rejection is independent of the executor' "$disabled_out" 'No built XMRig'

missing_validation="$TMP/missing-executor-preview.json"
missing_validator_out="$({
    source "$SCRIPT"
    _validate_xmrig_config "$TMP/no-executor" "$plain" "$missing_validation"
} 2>&1)"
eq 'validator rejects a missing executable' "$?" 1
has 'missing validator executable reaches the operator' "$missing_validator_out" 'No built XMRig'
if [ ! -e "$missing_validation" ]; then ok 'missing executable creates no validation config'; else bad 'missing executable creates no validation config' 'validation file exists'; fi

printf 'xmrig overlay regressions: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
