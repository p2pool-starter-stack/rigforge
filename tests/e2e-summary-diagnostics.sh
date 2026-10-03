# shellcheck shell=bash
# Fixed-schema observations only: never echo bodies, key names, timestamps or parser errors.
summary_contract_diagnostics() {
    local result
    result=$(jq -cs '
        if length != 2 then error("record count") else . end |
        .[0] as $keys | .[1] as $body |
        (if ($body | type) == "object" then $body else {} end) as $s |
        {json_valid: true,
         worker_keys: (($keys | type) == "array"),
         sister_object: (($body | type) == "object"),
         rigforge_object: (($s.rigforge | type) == "object"),
         generated_at_valid: (try ($s.generated_at as $g |
             ($g | type) == "string" and
             [($g | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ"))] == [$g]) catch false),
         xmrig_unreachable: (try ($s.rigforge.xmrig_api == "unreachable") catch false),
         keys_match: ($keys == ($s | del(.rigforge, .generated_at) | keys))}
    ' 2>/dev/null) || result='{"json_valid":false}'
    printf 'network-summary: %s\n' "$result"
}
# Preserve the nightly prefix in one snapshot, without running unrelated later phases.
phase_network_sequence() {
    local run_phase
    for run_phase in phase_connect phase_worker_api phase_api_impact phase_network; do
        "$run_phase"
        [ "$FAIL" -eq 0 ] || return 1
    done
}
