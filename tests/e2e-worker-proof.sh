# shellcheck shell=bash
# shellcheck disable=SC2034

proof_git() { git -C "$HERE" -c safe.directory="$HERE" "$@"; }

proof_identity() {
    local head ref platform untracked
    head=$(printf '%s' "$E2E_PROOF_CONTEXT" | jq -r .head) || return 1
    ref=$(printf '%s' "$E2E_PROOF_CONTEXT" | jq -r .ref) || return 1
    platform=$(printf '%s' "$E2E_PROOF_CONTEXT" | jq -r .platform) || return 1
    untracked=$(proof_git ls-files --others --exclude-standard -- rigforge.sh util systemd tests) || return 1
    [ "$(proof_git rev-parse --verify HEAD 2>/dev/null)" = "$head" ] &&
        [ "$(proof_git rev-parse --verify "$ref^{commit}" 2>/dev/null)" = "$head" ] &&
        [ "$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" = "$platform" ] &&
        proof_git diff --quiet HEAD -- &&
        [ -z "$untracked" ]
}

proof_preflight() {
    E2E_PROOF_ACTIVE=0
    [ -n "${E2E_PROOF_CONTEXT:-}" ] || {
        printf 'worker-proof: {"schema":1,"bound":false}\n'
        return 0
    }
    [ "$1" != shared-host ] || die "shared-host is not a worker-proof group: its host-state and cgroup assertions have no retained pass count (docs/dev/worker-proof.md)"
    E2E_PROOF_CONTEXT=$(printf '%s' "$E2E_PROOF_CONTEXT" | python3 "$HERE/tests/worker-proof.py" context "$1") || die "invalid worker proof context"
    proof_identity || die "worker proof requires the requested clean head and ref"
}

proof_begin() {
    [ -n "${E2E_PROOF_CONTEXT:-}" ] || return 0
    E2E_PROOF_ACTIVE=1 E2E_PROOF_CLEANUP=unknown
    E2E_PROOF_DIR=$(mktemp -d) || return 1
    printf '%s\n' "$E2E_PROOF_CONTEXT" >"$E2E_PROOF_DIR/context" || return 1
    : >"$E2E_PROOF_DIR/events" || return 1
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

proof_phase() {
    [ "${E2E_PROOF_ACTIVE:-0}" = 1 ] || return 0
    local id="${1#phase_}" group
    id=${id//_/-}
    group=$(printf '%s' "$E2E_PROOF_CONTEXT" | jq -r .group) || return 1
    case "$group:$id" in
    control-replay-*:connect) return 0 ;;
    control-replay-*:control-replay) id=$group ;;
    esac
    printf '{"event":"phase","id":"%s"}\n' "$id" >>"$E2E_PROOF_DIR/events"
}

proof_assert() {
    printf '{"event":"%s"}\n' "$1" >>"$E2E_PROOF_DIR/events"
}

proof_skip() {
    [ "${E2E_PROOF_ACTIVE:-0}" = 1 ] || return 0
    local reason=unexplained
    case "$1" in
    'E2E_STRATUM_PASS not set (stack auth off, or secret not provided) — phases skipped') reason=stratum-fixture-absent ;;
    'E2E_DASH_URL not set — dashboard phases skipped (agree fixtures with pithead#209)') reason=dashboard-fixture-absent ;;
    esac
    printf '{"event":"skip","reason":"%s"}\n' "$reason" >>"$E2E_PROOF_DIR/events"
}

proof_cleanup() {
    [ "$1" = 1 ] || E2E_PROOF_CLEANUP=fail
    [ "${E2E_PROOF_CLEANUP:-unknown}" != unknown ] || E2E_PROOF_CLEANUP=pass
}

proof_finish() {
    local rc="$1" result status=0
    proof_identity || rc=1
    if [ -n "${E2E_PROOF_DIR:-}" ]; then
        result=$(python3 "$HERE/tests/worker-proof.py" receipt "$E2E_PROOF_DIR/context" "$E2E_PROOF_DIR/events" "${E2E_PROOF_CLEANUP:-fail}" "$rc") || status=1
        if ! rm -rf "$E2E_PROOF_DIR"; then
            result='' status=1
        fi
        [ -z "$result" ] || printf 'worker-proof: %s\n' "$result"
    else
        status=1
    fi
    E2E_PROOF_ACTIVE=0
    return "$status"
}
