# shellcheck shell=bash
# shellcheck disable=SC2034
# Hardware-free diagnosis of #563; raw response fields must never reach the job log.
source "$ROOT/tests/e2e-summary-diagnostics.sh"
summary_diag_case() { printf '%s\n' "$1" "$2" | summary_contract_diagnostics; }
DIAG_GOOD='{"hashrate":{},"rigforge":{},"generated_at":"2026-10-02T06:00:00Z"}'
diag=$(summary_diag_case '["hashrate"]' "$DIAG_GOOD")
assert_eq "summary diagnostics: valid superset classified" "$diag" 'network-summary: {"json_valid":true,"worker_keys":true,"sister_object":true,"rigforge_object":true,"generated_at_valid":true,"xmrig_unreachable":false,"keys_match":true}'
assert_eq "summary diagnostics: absent record sanitized" "$(summary_diag_case '["hashrate"]' '')" 'network-summary: {"json_valid":false}'
for payload in 'null' '[]' '"secret-marker"' 'true' '42'; do
    diag=$(summary_diag_case '["hashrate"]' "$payload")
    assert_contains "summary diagnostics: missing/non-object sister classified" "$diag" '"sister_object":false'
done
for stamp in '' 'secret-marker' '2026-10-02T06:00:00+00:00'; do
    diag=$(summary_diag_case '["hashrate"]' "$(printf '%s' "$DIAG_GOOD" | jq --arg s "$stamp" '.generated_at=$s')")
    assert_contains "summary diagnostics: invalid timestamp classified" "$diag" '"generated_at_valid":false'
    assert_absent "summary diagnostics: timestamp value omitted" "$diag" 'secret-marker'
done
diag=$(summary_diag_case '["hashrate"]' '{"rigforge":{"xmrig_api":"unreachable","secret":"secret-marker"},"generated_at":"2026-10-02T06:00:00Z"}')
assert_contains "summary diagnostics: unreachable snapshot distinguished" "$diag" '"xmrig_unreachable":true'
assert_contains "summary diagnostics: missing XMRig keys distinguished" "$diag" '"keys_match":false'
assert_absent "summary diagnostics: nested secrets omitted" "$diag" 'secret-marker'
diag=$(summary_diag_case '["secret-marker"]' "$DIAG_GOOD")
assert_absent "summary diagnostics: key names omitted" "$diag" 'secret-marker'
assert_eq "summary diagnostics: malformed JSON sanitized" "$(summary_diag_case '["hashrate"]' '{secret-marker')" 'network-summary: {"json_valid":false}'
assert_eq "summary diagnostics: multiple records refused" "$(summary_diag_case '[]' '{} {}')" 'network-summary: {"json_valid":false}'
# Exercise phase wiring and keep the original failing assertion fatal.
(
    eval "$(sed -n '/^phase_network()/,/^}/p' "$ROOT/tests/e2e-pithead.sh")"
    HERE="$ROOT" PITHEAD_URL=pool.invalid:3333
    phase() { :; }
    set_cfg() { :; }
    sleep() { :; }
    ss() {
        case "$1" in
        -Htnp) printf 'ESTAB 0 0 local pool.invalid:3333 xmrig\n' ;;
        -Htln) printf 'LISTEN 0 0 *:8081 peer\n' ;;
        -Htlnp) printf 'LISTEN 0 0 *:8080 peer xmrig\n' ;;
        esac
    }
    api8080() { printf '{"hashrate":{}}'; }
    api8081() { printf '{"rigforge":{"xmrig_api":"unreachable"}}'; }
    ok() { :; }
    bad() {
        printf 'FAIL:%s\n' "$1"
        return 1
    }
    set -e
    phase_network
) >"$SANDBOX/summary-diag-phase" 2>&1
rc=$?
assert_rc "summary diagnostics: wire failure remains fatal" "$rc" 1
assert_contains "summary diagnostics: phase emits observations before failure" "$(cat "$SANDBOX/summary-diag-phase")" 'network-summary:'
assert_contains "summary diagnostics: original failing row retained" "$(cat "$SANDBOX/summary-diag-phase")" 'FAIL:sister summary lacks valid metadata or its XMRig key superset differs'
