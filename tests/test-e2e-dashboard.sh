#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2329
echo "== unit: e2e-pithead dashboard leg — hardened curl + no vacuous offline pass, bounded online wait (#390/#466/#760) =="
DASH_SRC="$ROOT/tests/e2e-pithead-dashboard.sh"
DDIR="$(mktemp -d "$SANDBOX/dash390.XXXXXX")"
mkdir -p "$DDIR/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$DC_ARGS"\n' >"$DDIR/bin/curl"
chmod +x "$DDIR/bin/curl"
out="$( (
    source "$DASH_SRC"
    export DC_ARGS="$DDIR/args.with"
    E2E_DASH_URL="http://stack-host/api/state" E2E_DASH_AUTH="probe:pw" PATH="$DDIR/bin:$PATH" dash_curl >/dev/null
    export DC_ARGS="$DDIR/args.without"
    E2E_DASH_URL="http://stack-host/api/state" E2E_DASH_AUTH="" PATH="$DDIR/bin:$PATH" dash_curl >/dev/null
) 2>&1)"
assert_contains "dash_curl follows redirects + accepts the stack cert (#390)" "$(cat "$DDIR/args.with")" "-kLfsS"
assert_contains "dash_curl presents basic-auth creds when E2E_DASH_AUTH is set (#390)" "$(cat "$DDIR/args.with")" "probe:pw"
assert_absent "dash_curl sends no -u when E2E_DASH_AUTH is empty (#390)" "$(cat "$DDIR/args.without")" "probe:pw"
pd_run() { # <dash_curl-body> -> phase_dashboard transcript with stubbed collaborators
    (
        source "$DASH_SRC"
        eval "dash_curl() { $1; }"
        phase() { :; }
        set_cfg() { printf 'SETCFG %s\n' "$1"; }
        CLOCK=0
        skip() { printf 'SKIP %s\n' "$1"; }
        ok() { printf 'OK %s\n' "$1"; }
        bad() { printf 'BAD %s\n' "$1"; }
        sleep() { CLOCK=$((CLOCK + $1)); }
        RIGFORGE=true PITHEAD_URL=stack-host:3333 E2E_DASH_URL="http://stack-host/api/state" E2E_DROPOFF_TIMEOUT="${DROP-1}" phase_dashboard
    ) 2>&1
}
out="$(pd_run 'printf '\''{"workers":[],"energy":{"per_worker":[{"name":"%s"}]}}'\'' "$(hostname)"')"
assert_contains "never-visible worker reads as a failure (#390)" "$out" "BAD worker"
assert_contains "offline check is skipped when visibility never held (#390)" "$out" "SKIP offline check skipped"
assert_absent "no vacuous offline pass on a never-visible worker (#390)" "$out" "became offline within"
out="$(pd_run 'if [ ! -f "'"$DDIR"'/seen" ]; then touch "'"$DDIR"'/seen"; printf '\''{"workers":[{"name":"%s","status":"online"}]}'\'' "$(hostname)"; else printf '\''{"workers":[{"name":"%s","status":"offline"}],"energy":{"per_worker":[{"name":"%s"}]}}'\'' "$(hostname)" "$(hostname)"; fi')"
assert_contains "visible worker passes the visibility check (#390)" "$out" "OK worker"
assert_contains "stopped worker measured offline before expiry (#466)" "$out" "OK stopped worker became offline"
for invalid in '' '{' '{}' '{"workers":"bad"}' '{"workers":[null]}' '{"workers":[42]}' '{"workers":[{}]}' '{"workers":[{"name":"x"}]}' '{"workers":[{"name":42,"status":"online"}]}' '{"workers":[{"name":"x","status":42}]}' '{"workers":[{"name":"x","status":"paused"}]}'; do
    out="$(pd_run "printf '%s' '$invalid'")"
    assert_contains "invalid dashboard payload fails closed (#464)" "$out" "BAD dashboard returned no valid workers array"
    assert_absent "invalid dashboard payload never proves offline (#466)" "$out" "OK stopped worker became offline"
done
out="$(pd_run 'if [ ! -f "'"$DDIR"'/valid-then-absent" ]; then touch "'"$DDIR"'/valid-then-absent"; printf '\''{"workers":[{"name":"%s","status":"online"}]}'\'' "$(hostname)"; else printf '\''{"workers":[],"energy":{"per_worker":[{"name":"%s"}]}}'\'' "$(hostname)"; fi')"
assert_contains "historical-only worker cannot impersonate offline (#466)" "$out" "BAD worker did not become offline"
assert_absent "historical-only worker never proves offline (#466)" "$out" "OK stopped worker became offline"
out="$(pd_run 'if [ ! -f "'"$DDIR"'/valid-then-malformed" ]; then touch "'"$DDIR"'/valid-then-malformed"; printf '\''{"workers":[{"name":"%s","status":"online"}]}'\'' "$(hostname)"; else printf '\''{"workers":[null,{"name":"%s","status":"offline"}]}'\'' "$(hostname)"; fi')"
assert_contains "malformed member blocks exact-target offline (#466)" "$out" "BAD worker did not become offline"
assert_absent "malformed transition never proves offline (#466)" "$out" "OK stopped worker became offline"
out="$(pd_run 'printf "{\"workers\":[]}"')"
assert_contains "miner is pointed at PITHEAD_URL before the dashboard is read (#760)" "$out" 'SETCFG .pools[0].url = "stack-host:3333"'
assert_contains "an absent worker fails after the bounded online wait (#760)" "$out" "BAD worker"
assert_contains "the online wait is bounded at 120 s by default (#760)" "$out" "within 120s"
DASH_BODY='if [ "$CLOCK" -lt 30 ]; then printf "{\"workers\":[]}"; elif [ "$CLOCK" -lt 320 ]; then printf "{\"workers\":[{\"name\":\"%s\",\"status\":\"online\"}]}" "$(hostname)"; else printf "{\"workers\":[{\"name\":\"%s\",\"status\":\"offline\"}]}" "$(hostname)"; fi'
out="$(DROP=600 pd_run "$DASH_BODY")"
assert_contains "worker that appears after a delay passes the online wait (#760)" "$out" "OK worker"
assert_contains "worker offline 290 s after the stop passes the 600 s window (#760)" "$out" "OK stopped worker became offline"
out="$(DROP=300 pd_run "$DASH_BODY")"
assert_contains "a 300 s window misses an offline flip at 290 s plus polling (#760)" "$out" "BAD worker did not become offline"
out="$(pd_run 'if [ "$CLOCK" -lt 30 ]; then printf ""; else printf "{\"workers\":[{\"name\":\"%s\",\"status\":\"online\"}]}" "$(hostname)"; fi')"
assert_contains "an empty dashboard read while it warms up does not end the online wait (#760)" "$out" "OK worker"
