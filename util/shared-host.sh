#!/usr/bin/env bash
# shellcheck disable=SC2034

_shared_host_parse() {
    SHARED_HOST=false SHARED_CPU_QUOTA=0 SHARED_MEMORY_MAX_MB=0
    local profile
    profile=$(jq -c 'if has("shared_host") then .shared_host else false end' "$CONFIG_JSON") || error "Cannot read shared_host."
    [ "$profile" != false ] || return 0
    jq -e 'type == "object" and (keys - ["cpu_quota_percent", "memory_max_mb", "existing_host_tuning"] | length == 0)
        and (.cpu_quota_percent | type == "number" and floor == . and . >= 1 and . <= 10000)
        and (.memory_max_mb | type == "number" and floor == . and . >= 3072 and . <= 1048576)
        and ((has("existing_host_tuning") | not) or .existing_host_tuning == "preserve")' <<<"$profile" >/dev/null ||
        error "shared_host requires cpu_quota_percent (integer 1-10000) and memory_max_mb (integer 3072-1048576); existing_host_tuning may only be preserve."
    SHARED_HOST=true
    SHARED_CPU_QUOTA=$(jq -r .cpu_quota_percent <<<"$profile")
    SHARED_MEMORY_MAX_MB=$(jq -r .memory_max_mb <<<"$profile")
}

_shared_host_config() {
    [ "${SHARED_HOST:-false}" = true ] || return 0
    local content
    content=$(jq --argjson cap "${THREADS_CAP:-null}" '
        .autosave = false | .cpu.priority = 1 | .cpu.yield = true |
        .cpu."huge-pages" = false | .cpu."huge-pages-jit" = false | .cpu."memory-pool" = false |
        .randomx."1gb-pages" = false | .randomx.rdmsr = false | .randomx.wrmsr = false |
        .randomx.cache_qos = false | .randomx.numa = false | .randomx.init = ($cap // 1) |
        .opencl = false | .cuda = false |
        if $cap != null then
            .cpu.rx as $rx |
            .cpu |= with_entries(select((.value | type) != "array" and (.value | type) != "object")) |
            .cpu.rx = (if ($rx | type) == "array" and ($rx | length) > 0 and all($rx[]; type == "number" and floor == . and . >= -1)
                then $rx[:$cap]
                else [range(0; if ($rx | type) == "number" and $rx >= 1 and $rx == ($rx | floor) then ([$rx, $cap] | min) else $cap end) | -1] end) |
            .cpu["*"] = .cpu.rx
        else . end
    ' "$1") || error "Could not apply shared-host XMRig safeguards."
    printf '%s\n' "$content" >"$1"
}

_shared_host_merge() {
    if [ "${SHARED_HOST:-false}" = true ]; then
        jq -s '.[0] * (.[1] | {cpu: (.cpu // {}), randomx: (.randomx // {})})' "$@"
    else
        jq -s '.[0] * .[1]' "$@"
    fi
}

_shared_host_supported() {
    local controllers total huge
    [ "$OS_TYPE" = Linux ] || {
        echo "shared_host requires Linux with systemd and cgroup v2"
        return 1
    }
    controllers=$(cat "${RIGFORGE_CGROUP_ROOT:-/sys/fs/cgroup}/cgroup.controllers" 2>/dev/null) || {
        echo "shared_host requires a unified cgroup v2 hierarchy"
        return 1
    }
    case " $controllers " in *" cpu "*) ;; *)
        echo "shared_host CPU controller is unavailable"
        return 1
        ;;
    esac
    case " $controllers " in *" memory "*) ;; *)
        echo "shared_host memory controller is unavailable"
        return 1
        ;;
    esac
    command -v systemctl >/dev/null && command -v systemd-run >/dev/null || {
        echo "shared_host requires systemctl and systemd-run"
        return 1
    }
    total=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO" 2>/dev/null)
    huge=$(awk '/^Hugetlb:/ {print $2}' "$MEMINFO" 2>/dev/null)
    _uint_in_range "$total" 1 1099511627776 && _uint_in_range "$huge" 0 1099511627776 || {
        echo "shared_host cannot account for RAM and existing HugeTLB reservations"
        return 1
    }
    [ "$((total - huge))" -ge "$(((SHARED_MEMORY_MAX_MB + 1024) * 1024))" ] || {
        echo "shared_host must leave at least 1024 MiB outside its ceiling and existing HugeTLB pools"
        return 1
    }
}

_shared_host_verify_budget() {
    local cg="${RIGFORGE_CGROUP_ROOT:-/sys/fs/cgroup}/rigforge.slice" quota period memory swap weight
    read -r quota period <"$cg/cpu.max" 2>/dev/null || {
        echo "shared_host CPU quota is unavailable"
        return 1
    }
    memory=$(cat "$cg/memory.max" 2>/dev/null) swap=$(cat "$cg/memory.swap.max" 2>/dev/null) weight=$(cat "$cg/cpu.weight" 2>/dev/null)
    _uint_in_range "$quota" 1 1000000000 && _uint_in_range "$period" 1 1000000 &&
        [ "$((quota * 100))" -le "$((SHARED_CPU_QUOTA * period))" ] || {
        echo "shared_host CPU quota is missing or exceeds the configured ceiling"
        return 1
    }
    _uint_in_range "$memory" 1 1099511627776 && [ "$memory" -le "$((SHARED_MEMORY_MAX_MB * 1048576))" ] && [ "$swap" = 0 ] || {
        echo "shared_host memory ceiling or zero-swap control is unavailable"
        return 1
    }
    [ "$weight" = 10 ] || {
        echo "shared_host CPU weight is not effective"
        return 1
    }
    printf 'effective CPU quota %s/%s us; memory %s bytes; swap 0; CPU weight 10\n' "$quota" "$period" "$memory"
}

_shared_host_in_slice() {
    local cg
    cg=$(awk -F: '$1 == "0" {print $3}' "${RIGFORGE_PROC_CGROUP:-/proc/self/cgroup}" 2>/dev/null) || return 1
    case "$cg" in /rigforge.slice/*) return 0 ;; *) return 1 ;; esac
}

_shared_host_prepare() {
    [ "${SHARED_HOST:-false}" = true ] || return 0
    local reason fragment loaded state transient dropins group consumers unit="$SYSTEMD_DIR/$SERVICE_NAME.service" slice="$SYSTEMD_DIR/rigforge.slice"
    reason=$(_shared_host_supported) || error "$reason; miner activation refused."
    if [ -e "$unit" ] && ! grep -qFx '# RigForge shared-host profile' "$unit"; then
        [ "$(jq -r '.shared_host.existing_host_tuning // empty' "$CONFIG_JSON")" = preserve ] ||
            error "Dedicated-to-shared transition requires existing_host_tuning: preserve; see docs/shared-host.md."
        if systemctl is-active --quiet "$SERVICE_NAME"; then error "Stop the dedicated miner before applying shared_host; existing host tuning will be preserved."; fi
    fi
    if [ -e "$slice" ] && ! grep -qFx 'Description=RigForge shared-host resource budget' "$slice"; then
        error "rigforge.slice already exists without RigForge ownership; refusing to replace it."
    fi
    fragment=$(systemctl show rigforge.slice -p FragmentPath --value) || error "Cannot inspect the existing resource slice."
    loaded=$(systemctl show rigforge.slice -p LoadState --value) || error "Cannot inspect the existing resource slice."
    if [ -z "$fragment" ] && [ "$loaded" != not-found ]; then
        state=$(systemctl show rigforge.slice -p ActiveState --value) || error "Cannot inspect the resource slice state."
        transient=$(systemctl show rigforge.slice -p Transient --value) || error "Cannot inspect resource slice ownership."
        dropins=$(systemctl show rigforge.slice -p DropInPaths --value) || error "Cannot inspect resource slice overrides."
        group=$(systemctl show rigforge.slice -p ControlGroup --value) || error "Cannot inspect the resource slice cgroup."
        consumers=$(systemctl show rigforge.slice -p RequiredBy -p WantedBy --value) || error "Cannot inspect resource slice consumers."
        if [ "$loaded" != loaded ] || [ "$state" != inactive ] || [ "$transient" != no ] || [ -n "$dropins$group$consumers" ]; then
            error "An implicit or transient rigforge.slice already exists; refusing to change its budget."
        fi
    fi
    if [ -n "$fragment" ] && ! grep -qFx 'Description=RigForge shared-host resource budget' "$fragment"; then
        error "The effective rigforge.slice is not owned by RigForge; refusing to shadow it."
    fi
    mkdir -p "$WORKER_ROOT/.rigforge-shared-host" || error "Could not record preserved host tuning."
    sudo tee "$slice" >/dev/null <<EOF
[Unit]
Description=RigForge shared-host resource budget
[Slice]
CPUAccounting=true
CPUQuota=${SHARED_CPU_QUOTA}%
CPUWeight=10
MemoryAccounting=true
MemoryMax=$((SHARED_MEMORY_MAX_MB * 1048576))
MemorySwapMax=0
EOF
    sudo systemctl daemon-reload && sudo systemctl start rigforge.slice || error "Could not activate the shared-host resource slice."
    if ! reason=$(_shared_host_verify_budget); then
        sudo systemctl stop "$SERVICE_NAME" || true
        error "$reason; miner remains stopped."
    fi
    log "Shared host: $reason"
}

_shared_host_unit() {
    if [ "${SHARED_HOST:-false}" != true ]; then
        cat
        return
    fi
    sed '/^ExecStartPre=.* frequency-set -g performance$/d'
    cat <<EOF

# RigForge shared-host profile
[Service]
Slice=rigforge.slice
Nice=19
LimitNICE=0
LimitMEMLOCK=0
CapabilityBoundingSet=
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictRealtime=true
OOMPolicy=stop
Restart=no
ExecStartPre=+$SCRIPT_DIR/rigforge.sh shared-host-check
EOF
}

_shared_host_check() {
    _shared_host_parse
    [ "$SHARED_HOST" = true ] || error "Shared-host unit and selected profile differ; run apply."
    local reason cfg
    reason=$(_shared_host_supported) || error "$reason"
    _shared_host_in_slice || error "Shared-host process is outside rigforge.slice; refusing to run."
    reason=$(_shared_host_verify_budget) || error "$reason"
    if [ "${1:-miner}" = miner ]; then
        cfg="$(_worker_root_from_config)/xmrig/build/config.json"
        local cap
        cap=$(jq -r '.threads // empty' "$CONFIG_JSON")
        [ -z "$cap" ] || _uint_in_range "$cap" 1 1024 || error "Invalid shared-host thread ceiling; run apply."
        jq -e --argjson cap "${cap:-null}" '.autosave == false and .cpu.priority == 1 and .cpu.yield == true and
            .cpu."huge-pages" == false and .cpu."huge-pages-jit" == false and .cpu."memory-pool" == false and
            .randomx."1gb-pages" == false and .randomx.rdmsr == false and .randomx.wrmsr == false and
            .randomx.cache_qos == false and .randomx.numa == false and .opencl == false and .cuda == false and
            (.randomx.init | type == "number" and floor == . and . >= 1 and . <= ($cap // 1)) and
            ($cap == null or ((.cpu.rx | type == "array" and length >= 1 and length <= $cap and all(.[]; type == "number" and floor == . and . >= -1)) and
                .cpu["*"] == .cpu.rx and all(.cpu | to_entries[]; .key == "rx" or .key == "*" or (.value | type != "array" and type != "object"))))' "$cfg" >/dev/null ||
            error "Shared-host miner configuration is unsafe or stale; run apply."
    fi
    log "Shared host: $reason"
}

_shared_host_run() {
    if [ "${SHARED_HOST:-false}" != true ]; then
        "$@"
        return
    fi
    printf '%s\0' "${TUNE_POWER_CMD:-}" | sudo systemd-run --quiet --wait --pipe --collect --service-type=exec --slice=rigforge.slice \
        --property=Nice=19 --property=MemoryAccounting=true --working-directory="$PWD" \
        --setenv="RIGFORGE_OPERATOR=$REAL_USER" --setenv="RIGFORGE_APPLIANCE=$RIGFORGE_APPLIANCE" \
        --setenv="AUTOTUNE_TARGET=${AUTOTUNE_TARGET:-}" \
        --setenv="AUTOTUNE_SAMPLES=${AUTOTUNE_SAMPLES:-}" --setenv="AUTOTUNE_INTERVAL=${AUTOTUNE_INTERVAL:-}" \
        --setenv="AUTOTUNE_WARMUP=${AUTOTUNE_WARMUP:-}" --setenv="AUTOTUNE_MARGIN=${AUTOTUNE_MARGIN:-}" --setenv="AUTOTUNE_MODES=${AUTOTUNE_MODES:-}" \
        "$SCRIPT_DIR/rigforge.sh" shared-host-run "$@"
}

_shared_host_exec() {
    IFS= read -r -d '' TUNE_POWER_CMD || error "Missing shared-host helper context; refusing to run."
    export TUNE_POWER_CMD
    _shared_host_check helper
    exec "$@"
}

_shared_host_start_guard() {
    [ -f "$CONFIG_JSON" ] || return 0
    _shared_host_parse
    [ "$SHARED_HOST" = true ] || return 0
    [ "$OS_TYPE" = Linux ] || error "shared_host requires Linux with systemd and cgroup v2."
    if ! grep -qFx '# RigForge shared-host profile' "$SYSTEMD_DIR/$SERVICE_NAME.service"; then
        error "shared_host is selected but the service is not bounded; stop it and run apply first."
    fi
    local slice pre
    slice=$(systemctl show "$SERVICE_NAME" -p Slice --value) || error "Cannot inspect the loaded miner service; run apply."
    pre=$(systemctl show "$SERVICE_NAME" -p ExecStartPre --value) || error "Cannot inspect the loaded miner startup checks; run apply."
    [ "$slice" = rigforge.slice ] || error "The loaded miner service is outside the shared-host budget; run apply."
    case "$pre" in *'rigforge.sh shared-host-check'*) ;; *) error "The loaded miner service lacks the shared-host startup check; run apply." ;; esac
}

_shared_host_remove() {
    local slice="$SYSTEMD_DIR/rigforge.slice" cg="${RIGFORGE_CGROUP_ROOT:-/sys/fs/cgroup}/rigforge.slice" procs=""
    grep -qFx 'Description=RigForge shared-host resource budget' "$slice" 2>/dev/null || return 0
    if [ -d "$cg" ]; then procs=$(find "$cg" -name cgroup.procs -exec cat {} + 2>/dev/null) || return 0; fi
    [ -z "$procs" ] || return 0
    sudo systemctl stop rigforge.slice 2>/dev/null || return 0
    sudo rm -f "$slice"
    sudo systemctl daemon-reload
}

_shared_host_reload() {
    if ! sudo systemctl daemon-reload; then
        if [ "${SHARED_HOST:-false}" = true ]; then
            sudo systemctl stop "$SERVICE_NAME" || true
            error "Could not reload the shared-host unit; miner remains stopped."
        fi
    fi
}

_shared_host_preserves_tuning() {
    [ -d "$1/.rigforge-shared-host" ] || jq -e '.shared_host | type == "object"' "$CONFIG_JSON" >/dev/null 2>&1
}

_shared_host_report() {
    _shared_host_parse
    if [ "$SHARED_HOST" != true ]; then
        echo 'Resource profile: dedicated'
        return 0
    fi
    printf 'Resource profile: shared host; requested CPU %s%% of one CPU, memory %s MiB\n' "$SHARED_CPU_QUOTA" "$SHARED_MEMORY_MAX_MB"
    local reason group
    reason=$(_shared_host_supported) || {
        echo "Unsupported: $reason"
        return 1
    }
    reason=$(_shared_host_verify_budget) || {
        echo "Not enforced: $reason; run apply"
        return 1
    }
    echo "$reason"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        group=$(systemctl show "$SERVICE_NAME" -p ControlGroup --value)
        case "$group" in /rigforge.slice/*) ;; *)
            echo 'Miner is outside the shared-host budget; stop it and run apply'
            return 1
            ;;
        esac
    else
        echo 'Miner is stopped; startup rechecks the controls before initialization'
    fi
    echo 'HugePages, MSR/cache tuning and governor changes are disabled; host settings are preserved'
}
