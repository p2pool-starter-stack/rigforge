#!/usr/bin/env bash

_selftest_stop() { # <direct-child-pid>
    local pid="${1:-}" tries=20
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    kill -TERM "$pid" 2>/dev/null || {
        wait "$pid" 2>/dev/null || true
        return 0
    }
    while [ "$tries" -gt 0 ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
        tries=$((tries - 1))
    done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
}

_bench_safe_config() { # <source-or-empty> <destination>
    local src="${1:-}" dst="$2"
    if [ -n "$src" ]; then
        [ -f "$src" ] || return 1
        jq 'if type != "object" then error("config must be an object") else . end | del(.http, .pools, ."log-file", .benchmark, .bench, ."bench-algo", ."bench-size", .seed, .hash, .submit, .verify, .stress) | .colors = true | .background = false | .autosave = false | .watch = false | ."pause-on-active" = false | ."pause-on-battery" = false' "$src" >"$dst" 2>/dev/null
    else
        printf '{}\n' | jq '.colors = true | .background = false | .autosave = false | .watch = false | ."pause-on-active" = false | ."pause-on-battery" = false' >"$dst" 2>/dev/null
    fi
}

_bench_submission_id() {
    awk '/^rigforge-bench-id: [[:alnum:]]+$/ { line = $2; if (length(line) <= 128) id = line } /benchmark submitted/ { line = $0; sub(/^.*\//, "", line); gsub(/[^[:alnum:]].*$/, "", line); if (line ~ /^[[:alnum:]]+$/ && length(line) <= 128) id = line } END { print id }'
}

_bench_capture_cleanup() {
    if [ -n "${_BENCH_CAPTURE_XPID:-}" ]; then _selftest_stop "$_BENCH_CAPTURE_XPID"; fi
    if [ -n "${_BENCH_CAPTURE_CPID:-}" ]; then _selftest_stop "$_BENCH_CAPTURE_CPID"; fi
    [ -z "${_BENCH_CAPTURE_TMP:-}" ] || rm -rf "$_BENCH_CAPTURE_TMP"
    _BENCH_CAPTURE_XPID=""
    _BENCH_CAPTURE_CPID=""
    _BENCH_CAPTURE_TMP=""
}

_bench_capture_signal() {
    local rc="$1"
    _bench_capture_cleanup
    trap - EXIT HUP INT TERM
    exit "$rc"
}

_bench_capture() { # <bin> <size> <config> <offline|submit|verify> [id]
    local bin="$1" size="$2" cfg="$3" mode="$4" id="${5:-}"
    local tmp fifo out xpid="" cpid="" deadline done=0 rc=0
    local freqs="" f wsamples="" pe0="" pt0="" pmax="" w
    tmp=$(mktemp -d) || return 1
    fifo="$tmp/stdout.fifo"
    out="$tmp/stdout"
    mkfifo "$fifo" || {
        rm -rf "$tmp"
        return 1
    }
    _BENCH_CAPTURE_TMP="$tmp"
    _BENCH_CAPTURE_XPID=""
    _BENCH_CAPTURE_CPID=""
    trap '_bench_capture_cleanup' EXIT
    trap '_bench_capture_signal 129' HUP
    trap '_bench_capture_signal 130' INT
    trap '_bench_capture_signal 143' TERM

    cat "$fifo" >"$out" &
    cpid=$!
    _BENCH_CAPTURE_CPID=$cpid
    case "$mode" in
    offline) "$bin" --bench="$size" --config="$cfg" >"$fifo" 2>&1 & ;;
    submit) "$bin" --bench="$size" --submit --config="$cfg" >"$fifo" 2>&1 & ;;
    verify) "$bin" --verify="$id" --config="$cfg" >"$fifo" 2>&1 & ;;
    esac
    xpid=$!
    _BENCH_CAPTURE_XPID=$xpid

    if [ -n "${BENCH_FREQ_FILE:-}" ]; then
        f=$(_cpu_eff_khz)
        [ -n "$f" ] && freqs="$f"
    fi
    if [ -n "${BENCH_WATTS_FILE:-}" ]; then
        if [ -n "${TUNE_POWER_CMD:-}" ]; then
            w=$(_read_watts_now)
            case "$w" in '') ;; *) wsamples="$w" ;; esac
        else
            pe0=$(_rapl_sum energy_uj || true)
            pt0=$(_now_s)
            pmax=$(_rapl_sum max_energy_range_uj || true)
        fi
    fi

    deadline=$(($(date +%s) + ${BENCH_TIMEOUT:-1800}))
    while kill -0 "$xpid" 2>/dev/null; do
        case "$mode" in
        submit) grep -qs 'benchmark submitted' "$out" && done=1 ;;
        *) grep -qs 'benchmark finished' "$out" && done=1 ;;
        esac
        [ "$done" -eq 1 ] && break
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf '\nrigforge-bench-timeout\n' >>"$out"
            rc=1
            break
        fi
        if [ -n "${BENCH_FREQ_FILE:-}" ]; then
            f=$(_cpu_eff_khz)
            [ -n "$f" ] && freqs="$freqs $f"
        fi
        if [ -n "${BENCH_WATTS_FILE:-}" ] && [ -n "${TUNE_POWER_CMD:-}" ]; then
            w=$(_read_watts_now)
            case "$w" in '') ;; *) wsamples="$wsamples $w" ;; esac
        fi
        sleep 0.2
    done

    if [ -n "${BENCH_WATTS_FILE:-}" ]; then
        local pe1="" pt1="" secs="" wout=""
        if [ -n "${TUNE_POWER_CMD:-}" ]; then
            # shellcheck disable=SC2086
            wout=$(_mean $wsamples)
        elif [ -n "$pe0" ]; then
            pe1=$(_rapl_sum energy_uj || true)
            pt1=$(_now_s)
            secs=$(awk -v a="$pt0" -v b="$pt1" 'BEGIN { if (a == "" || b == "") exit; printf "%.3f", b - a }')
            wout=$(_watts_from_energy "$pe0" "$pe1" "${pmax:-0}" "$secs")
        fi
        printf '%s' "$wout" >"$BENCH_WATTS_FILE"
    fi

    if ! kill -0 "$xpid" 2>/dev/null; then
        wait "$xpid" 2>/dev/null || rc=$?
        _BENCH_CAPTURE_XPID=""
        if [ "$rc" -ne 0 ]; then printf '\nrigforge-bench-process-exit: %s\n' "$rc" >>"$out"; fi
    else
        _selftest_stop "$xpid"
        _BENCH_CAPTURE_XPID=""
    fi
    wait "$cpid" 2>/dev/null || true
    _BENCH_CAPTURE_CPID=""

    # shellcheck disable=SC2086
    if [ -n "${BENCH_FREQ_FILE:-}" ]; then _median $freqs | awk 'NF{printf "%d", $0+0}' >"$BENCH_FREQ_FILE"; fi
    cat "$out"
    rm -rf "$tmp"
    _BENCH_CAPTURE_TMP=""
    trap - EXIT HUP INT TERM
    return "$rc"
}

_bench_result() { # <captured-output>
    local raw="${1:-}" parsed fatal seed final
    BENCH_HASH=""
    BENCH_SEED="0000000000000000000000000000000000000000000000000000000000000000"
    BENCH_VERDICT="unverified"
    BENCH_HR=""
    BENCH_ID=""

    parsed=$(printf '%s\n' "$raw" | LC_ALL=C awk 'BEGIN { esc = sprintf("%c", 27) } /benchmark finished/ { final = $0 } END { rest = final; sub(/^.*hash sum = /, "", rest); while (match(rest, /[[:xdigit:]]+/)) { token = substr(rest, RSTART, RLENGTH); if (length(token) == 16) { hash = token; if (index(final, esc "[1;32m" token esc "[0m")) verdict = "verified"; else if (index(final, esc "[1;31m" token esc "[0m")) verdict = "mismatch" } rest = substr(rest, RSTART + RLENGTH) } print verdict "\t" hash }')
    BENCH_VERDICT=${parsed%%$'\t'*}
    BENCH_HASH=${parsed#*$'\t'}
    if [ -z "$BENCH_VERDICT" ] || [ "$BENCH_VERDICT" = "$parsed" ]; then BENCH_VERDICT="unverified"; fi
    final=$(printf '%s\n' "$raw" | awk '/benchmark finished/{line=$0} END{print line}')
    BENCH_HR=$(printf '%s\n' "$final" | _parse_hashrate || true)
    BENCH_ID=$(_bench_submission_id <<<"$raw")
    seed=$(printf '%s\n' "$raw" | sed -E $'s/\033\\[[0-9;]*m//g' | awk '/bench[[:space:]]+seed/{for(i=1;i<=NF;i++)if($i~/^[[:xdigit:]]+$/)s=$i} END{print s}')
    [ -z "$seed" ] || BENCH_SEED=$seed
    fatal=$(printf '%s\n' "$raw" | grep -iE 'MEMORY ALLOC FAILED|unable to (open|parse) config|error parsing config|rigforge-bench-(timeout|process-exit|config-error|submission-error)' || true)
    if [ -n "$fatal" ]; then
        BENCH_VERDICT="failed"
        return 1
    fi
    [ "$BENCH_VERDICT" = verified ] || return 1
    [ -n "$BENCH_HASH" ] || return 1
    if ! awk -v h="$BENCH_HR" 'BEGIN { exit !(h + 0 > 0) }'; then
        BENCH_VERDICT="failed"
        return 1
    fi
}

_bench_record() { # <captured-output>
    local raw="$1" tmp verdict_rc=0
    [ -n "${WORKER_ROOT:-}" ] || return 0
    _bench_result "$raw" || verdict_rc=$?
    tmp=$(mktemp "$WORKER_ROOT/.rigforge-bench.XXXXXX") || {
        warn "Could not record the latest benchmark result."
        return 0
    }
    jq -n --arg saved "$(date '+%Y-%m-%d %H:%M:%S')" --arg seed "$BENCH_SEED" \
        --arg hash "$BENCH_HASH" --arg verdict "$BENCH_VERDICT" --arg hr "$BENCH_HR" \
        --arg id "$BENCH_ID" --argjson passed "$([ "$verdict_rc" -eq 0 ] && echo true || echo false)" \
        '{saved: $saved, seed: $seed, hash: $hash, verdict: $verdict, hashrate: $hr, id: (if $id == "" then null else $id end), passed: $passed}' >"$tmp" 2>/dev/null || {
        rm -f "$tmp"
        warn "Could not record the latest benchmark result."
        return 0
    }
    if ! chmod 644 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$WORKER_ROOT/rigforge-bench.json" 2>/dev/null; then
        rm -f "$tmp"
        warn "Could not record the latest benchmark result."
    fi
}

_bench_bundle() { # <record>
    jq -e '. as $r | if type != "object" or (($r.seed // "") | test("^[[:xdigit:]]+$") | not) or (($r.hash | type) != "string") or (if $r.hash == "" then (["failed", "unverified"] | index($r.verdict) | not) else ($r.hash | test("^[[:xdigit:]]{16}$") | not) end) or (["verified", "mismatch", "unverified", "failed"] | index($r.verdict) | not) or ($r.id != null and (($r.id | type) != "string" or ($r.id | test("^[[:alnum:]]{1,128}$") | not))) then error("invalid benchmark record") else {seed, hash, verdict, id} end' "$1"
}

_bench_run_cleanup() {
    [ -z "${_BENCH_RUN_TMP:-}" ] || rm -rf "$_BENCH_RUN_TMP"
    _BENCH_RUN_TMP=""
}

_bench_run_signal() {
    local rc="$1"
    _bench_run_cleanup
    trap - EXIT HUP INT TERM
    exit "$rc"
}

_xmrig_bench() { # <bin> <size> <config> [submit|verify] [id]
    (
        umask 077
        local bin="$1" size="$2" source_cfg="${3:-}" mode="${4:-offline}" id="${5:-}"
        local tmp cfg first second submitted out rc=0
        case "$size" in '' | -* | *[![:alnum:]]*)
            printf 'rigforge-bench-config-error\n'
            return 1
            ;;
        esac
        case "$mode" in
        offline | submit) ;;
        verify)
            case "$id" in '' | *[![:alnum:]]*)
                printf 'rigforge-bench-config-error\n'
                return 1
                ;;
            esac
            [ "${#id}" -le 128 ] || {
                printf 'rigforge-bench-config-error\n'
                return 1
            }
            ;;
        *)
            printf 'rigforge-bench-config-error\n'
            return 1
            ;;
        esac
        tmp=$(mktemp -d) || return 1
        _BENCH_RUN_TMP=$tmp
        trap '_bench_run_cleanup' EXIT
        trap '_bench_run_signal 129' HUP
        trap '_bench_run_signal 130' INT
        trap '_bench_run_signal 143' TERM
        cfg="$tmp/config.json"
        if ! _bench_safe_config "$source_cfg" "$cfg"; then
            out="rigforge-bench-config-error"
            printf '%s\n' "$out"
            _bench_record "$out"
            rm -rf "$tmp"
            return 1
        fi
        case "$mode" in
        submit)
            first=$(_bench_capture "$bin" "$size" "$cfg" submit) || rc=$?
            submitted=$(_bench_submission_id <<<"$first")
            if [ "$rc" -ne 0 ] || [ -z "$submitted" ]; then
                out="$first
rigforge-bench-submission-error"
            else
                rc=0
                second=$(_bench_capture "$bin" "$size" "$cfg" verify "$submitted") || rc=$?
                out="$first
$second"
            fi
            ;;
        verify)
            out=$(_bench_capture "$bin" "$size" "$cfg" verify "$id") || rc=$?
            out="rigforge-bench-id: $id
$out"
            ;;
        *) out=$(_bench_capture "$bin" "$size" "$cfg" offline) || rc=$? ;;
        esac
        printf '%s\n' "$out"
        _bench_record "$out"
        rm -rf "$tmp"
        _BENCH_RUN_TMP=""
        trap - EXIT HUP INT TERM
        return "$rc"
    )
}

bench() {
    local bin cfg size="${BENCH:-1M}" mode="offline" id="" out rc=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --submit)
            [ "$mode" = offline ] || error "Use only one bench mode."
            mode=submit
            ;;
        --verify)
            [ "$mode" = offline ] && [ "$#" -ge 2 ] || error "Usage: $0 bench [--submit|--verify ID]."
            mode=verify
            id=$2
            shift
            ;;
        --verify=*)
            [ "$mode" = offline ] || error "Use only one bench mode."
            mode=verify
            id=${1#*=}
            ;;
        *) error "Unknown option for bench: '$1' (use --submit or --verify ID). Run '$0 help'." ;;
        esac
        shift
    done
    case "$id" in *[![:alnum:]]*) error "Benchmark IDs contain only letters and numbers." ;; esac
    [ "${#id}" -le 128 ] || error "Benchmark ID is too long."
    parse_config
    bin="$WORKER_ROOT/xmrig/build/xmrig"
    cfg="$WORKER_ROOT/xmrig/build/config.json"
    [ -x "$bin" ] || error "No built worker at $bin. Run 'setup' first."
    [ -f "$cfg" ] || error "No generated worker config at $cfg. Run 'setup' first."
    log "Running the XMRig benchmark correctness check..."
    out=$(_xmrig_bench "$bin" "$size" "$cfg" "$mode" "$id") || rc=$?
    if [ "$rc" -ne 0 ] || ! _bench_result "$out"; then
        printf '%s\n' "$out" >&2
        error "Benchmark correctness check failed — see the XMRig output above."
    fi
    log "Benchmark hashrate: $BENCH_HR H/s"
    log "Benchmark correctness: verified (hash $BENCH_HASH)."
    if [ -n "$BENCH_ID" ]; then log "Benchmark submission ID: $BENCH_ID"; fi
}
