#!/usr/bin/env bash

THREAD_PROFILE_SAVED="" THREAD_PROFILE_OVERRIDES="" THREAD_PROFILE_EXISTED=0

thread_profile_restore() {
    [ -n "$THREAD_PROFILE_SAVED" ] || return 0
    if [ "$THREAD_PROFILE_EXISTED" = 1 ]; then
        cp -p "$THREAD_PROFILE_SAVED/overrides.json" "$THREAD_PROFILE_OVERRIDES" || return 1
    else
        rm -f "$THREAD_PROFILE_OVERRIDES" || return 1
    fi
    rm -r "$THREAD_PROFILE_SAVED" || return 1
    THREAD_PROFILE_SAVED=""
}

thread_profile_count() {
    local data count token auth=() waited=0
    token=$(jq -r '.ACCESS_TOKEN // empty' "$CFG") || return 1
    [ -z "$token" ] || auth=(-H "Authorization: Bearer $token")
    while [ "$waited" -lt 120 ]; do
        if data=$(curl -fsS --max-time 5 "${auth[@]}" http://127.0.0.1:8080/2/backends 2>/dev/null) &&
            count=$(printf '%s' "$data" | jq -er '[.[] | select(.type == "cpu" and .algo == "rx/0") | .threads | select(type == "array") | length] | select(length == 1) | .[0] | select(. > 0)'); then
            printf '%s\n' "$count"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

thread_profile_check() {
    local label="$1" want="$2" got
    "$RIGFORGE" start >/dev/null 2>&1 || return 1
    got=$(thread_profile_count) || {
        bad "$label: no running RandomX CPU profile within 120s"
        return 1
    }
    if [ "$got" = "$want" ]; then
        ok "$label: XMRig runs $want thread(s)"
    else
        bad "$label: XMRig runs $got thread(s), expected $want"
    fi
}

phase_thread_profile() {
    phase "thread-profile — XMRig enforces auto-selection and the configured ceiling"
    local root auto high tmp
    root=$(
        # shellcheck disable=SC1090
        source "$RIGFORGE"
        export CONFIG_JSON="$CFG"
        parse_config >/dev/null
        printf '%s' "$WORKER_ROOT"
    ) || die "cannot resolve configured worker root"
    THREAD_PROFILE_OVERRIDES="$root/tune-overrides.json"
    [ ! -L "$THREAD_PROFILE_OVERRIDES" ] || die "thread-profile refuses symlinked tuning overrides"
    THREAD_PROFILE_SAVED=$(mktemp -d)
    if [ -e "$THREAD_PROFILE_OVERRIDES" ]; then
        cp -p "$THREAD_PROFILE_OVERRIDES" "$THREAD_PROFILE_SAVED/overrides.json" || die "cannot snapshot tuning overrides"
        THREAD_PROFILE_EXISTED=1
        jq 'del(.cpu.rx)' "$THREAD_PROFILE_OVERRIDES" >"$THREAD_PROFILE_SAVED/base.json" || die "invalid tuning overrides"
    else
        printf '{}\n' >"$THREAD_PROFILE_SAVED/base.json"
    fi
    cp "$THREAD_PROFILE_SAVED/base.json" "$THREAD_PROFILE_OVERRIDES"
    chmod 600 "$THREAD_PROFILE_OVERRIDES"
    set_cfg '.threads = ""'
    "$RIGFORGE" start >/dev/null 2>&1
    auto=$(thread_profile_count) || die "cannot observe XMRig auto-selection"
    [ "$auto" -gt 1 ] || die "thread-profile requires XMRig auto-selection above one thread"
    ok "uncapped XMRig auto-selection observed"
    high=$((auto + 2))
    set_cfg '.threads = 1'
    thread_profile_check "cap below auto-selection" 1
    set_cfg ".threads = $high"
    thread_profile_check "cap above auto-selection" "$auto"
    tmp="$THREAD_PROFILE_SAVED/tuned.json"
    jq --argjson count "$((auto + 1))" '.cpu.rx = $count' "$THREAD_PROFILE_SAVED/base.json" >"$tmp"
    cp "$tmp" "$THREAD_PROFILE_OVERRIDES"
    chmod 600 "$THREAD_PROFILE_OVERRIDES"
    set_cfg ".threads = $high"
    thread_profile_check "tuned count cannot raise auto-selection" "$auto"
    jq '.cpu.rx = 1' "$THREAD_PROFILE_SAVED/base.json" >"$tmp"
    cp "$tmp" "$THREAD_PROFILE_OVERRIDES"
    chmod 600 "$THREAD_PROFILE_OVERRIDES"
    set_cfg ".threads = $high"
    thread_profile_check "tuned count below auto-selection" 1
}
