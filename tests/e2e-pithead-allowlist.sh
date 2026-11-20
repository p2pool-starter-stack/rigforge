#!/usr/bin/env bash

api_allowlist_drop_packets() {
    local port=$1
    nft -j list chain inet rigforge api 2>/dev/null | jq -r --argjson port "$port" '
        [.nftables[].rule
            | select(.family == "inet" and .table == "rigforge" and .chain == "api")
            | select(any(.expr[]?; has("drop")))
            | select(any(.expr[]?; .match?.left?.payload?.protocol == "tcp"
                and .match.left.payload.field == "dport"
                and ((.match.right.set? // [.match.right]) | index($port) != null)))
            | [.expr[]? | .counter?.packets // empty]
            | select(length == 1) | .[0]]
        | if length == 1 then .[0] else error("expected one API drop counter") end
    '
}

api_allowlist_probe() {
    (
        local port=$1 token=$2 allow_hook=${3:-:}
        local ns="rfapi-$$" host_if="rfah-$$" peer_if="rfan-$$" host_cidr ns_cidr allowed_ip subnet
        local ns_created=0 link_created=0 before after code ns_rc hash third base tries probe_rc
        local auth=(-H "Authorization: Bearer $token") hash_wait=${E2E_ALLOWLIST_HASH_WAIT:-90} hash_step=${E2E_ALLOWLIST_HASH_INTERVAL:-3} waited=0
        probe_fail() {
            printf 'api allowlist probe: %s\n' "$2" >&2
            exit "$1"
        }
        for tool in ip nft curl jq awk grep python3; do
            command -v "$tool" >/dev/null 2>&1 || probe_fail 2 "missing required tool: $tool"
        done
        declare -F live_hashrate >/dev/null || probe_fail 2 "live hashrate reader unavailable"
        if [ -n "${E2E_ALLOWLIST_HOST_CIDR:-}" ] || [ -n "${E2E_ALLOWLIST_NS_CIDR:-}" ]; then
            [ -n "${E2E_ALLOWLIST_HOST_CIDR:-}" ] && [ -n "${E2E_ALLOWLIST_NS_CIDR:-}" ] || probe_fail 2 "both CIDR overrides are required"
            host_cidr=$E2E_ALLOWLIST_HOST_CIDR
            ns_cidr=$E2E_ALLOWLIST_NS_CIDR
        else
            for tries in 1 2 3 4 5 6 7 8; do
                third=$(((RANDOM + $$ + tries) % 250 + 1))
                base=$(((RANDOM % 31) * 8))
                printf -v subnet '%d.%d.%d.%d/29' 169 254 "$third" "$base"
                if ip -4 route show table all | python3 -c '
import ipaddress, sys
candidate = ipaddress.ip_network(sys.argv[1])
for line in sys.stdin:
    try:
        if candidate.overlaps(ipaddress.ip_network(line.split()[0], strict=False)):
            raise SystemExit(0)
    except (ValueError, IndexError):
        pass
raise SystemExit(1)
' "$subnet"; then
                    continue
                fi
                printf -v host_cidr '%d.%d.%d.%d/29' 169 254 "$third" "$((base + 1))"
                printf -v ns_cidr '%d.%d.%d.%d/29' 169 254 "$third" "$((base + 2))"
                break
            done
            [ -n "${host_cidr:-}" ] || probe_fail 2 "no unused link network found"
        fi
        allowed_ip=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).ip + 1)' "$ns_cidr") || probe_fail 2 "cannot derive the allowed address from $ns_cidr"
        ip netns list | awk '{print $1}' | grep -Fxq "$ns" && probe_fail 2 "namespace $ns already exists"
        ip link show "$host_if" >/dev/null 2>&1 && probe_fail 2 "link $host_if already exists"
        # shellcheck disable=SC2329
        cleanup_api_probe() {
            local cleanup_rc=0
            [ "$link_created" = 0 ] || ip link del "$host_if" >/dev/null 2>&1 || { printf 'api allowlist probe: cleanup could not delete link %s\n' "$host_if" >&2; cleanup_rc=1; }
            [ "$ns_created" = 0 ] || ip netns del "$ns" >/dev/null 2>&1 || { printf 'api allowlist probe: cleanup could not delete namespace %s\n' "$ns" >&2; cleanup_rc=1; }
            return "$cleanup_rc"
        }
        trap 'probe_rc=$?; trap - EXIT; cleanup_api_probe || [ "$probe_rc" -ne 0 ] || probe_rc=2; exit "$probe_rc"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        ip netns add "$ns" || probe_fail 2 "namespace create failed"
        ns_created=1
        ip link add "$host_if" type veth peer name "$peer_if" || probe_fail 2 "veth create failed"
        link_created=1
        ip link set "$peer_if" netns "$ns" || probe_fail 2 "moving the veth peer into the namespace failed"
        ip address add "$host_cidr" dev "$host_if" || probe_fail 2 "host address assignment failed"
        ip link set "$host_if" up || probe_fail 2 "host link up failed"
        ip -n "$ns" address add "$ns_cidr" dev "$peer_if" || probe_fail 2 "namespace address assignment failed"
        ip -n "$ns" address add "$allowed_ip/${ns_cidr#*/}" dev "$peer_if" || probe_fail 2 "allowed address assignment failed"
        ip -n "$ns" link set lo up || probe_fail 2 "namespace loopback up failed"
        ip -n "$ns" link set "$peer_if" up || probe_fail 2 "namespace link up failed"
        ip -n "$ns" route add default via "${host_cidr%/*}" || probe_fail 2 "namespace default route failed"
        "$allow_hook" "$allowed_ip" || probe_fail 2 "allow hook failed for $allowed_ip"
        while [ "$waited" -lt "$hash_wait" ]; do
            hash=$(live_hashrate)
            [ -z "$hash" ] || ! jq -en --argjson hash "$hash" '$hash | type == "number" and . > 0' >/dev/null 2>&1 || break
            sleep "$hash_step"
            waited=$((waited + hash_step))
        done
        [ "$waited" -lt "$hash_wait" ] || probe_fail 2 "no live hashrate within ${hash_wait}s of the last config apply (last read: '${hash:-empty}')"
        before=$(api_allowlist_drop_packets "$port") || probe_fail 2 "cannot read the API drop counter before the probe"
        code=$(ip netns exec "$ns" curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 --interface "$allowed_ip" "${auth[@]}" "http://${host_cidr%/*}:$port/2/summary") || probe_fail 1 "allowed source request failed"
        [ "$code" = 200 ] || probe_fail 1 "allowed source got HTTP $code, want 200"
        if ip netns exec "$ns" curl --noproxy '*' -sS -o /dev/null --connect-timeout 2 --max-time 5 --interface "${ns_cidr%/*}" "${auth[@]}" "http://${host_cidr%/*}:$port/2/summary" 2>/dev/null; then
            ns_rc=0
        else
            ns_rc=$?
        fi
        case "$ns_rc" in 7 | 28) ;; *) probe_fail 1 "second source was not refused (curl exit $ns_rc)" ;; esac
        after=$(api_allowlist_drop_packets "$port") || probe_fail 2 "cannot read the API drop counter after the probe"
        [ "$after" -gt "$before" ] || probe_fail 1 "drop counter did not move (before $before, after $after)"
        code=$(ip netns exec "$ns" curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 --interface "$allowed_ip" "${auth[@]}" "http://${host_cidr%/*}:$port/2/summary") || probe_fail 1 "allowed source request failed after the refusal"
        [ "$code" = 200 ] || probe_fail 1 "allowed source got HTTP $code after the refusal, want 200"
    )
}

api_allowlist_apply_source() {
    # shellcheck disable=SC2016
    set_cfg '.api_allow_from = $source' soft --arg source "$1/32" || return 1
    sleep 3
}

phase_api_allowlist() {
    local api_port token
    for tool in ip jq; do command -v "$tool" >/dev/null 2>&1 || { printf 'api allowlist probe: missing required tool: %s\n' "$tool" >&2 && return 2; }; done
    api_port=$(jq -r '.http.port // empty' "$GEN_CFG")
    token=$(jq -r '.ACCESS_TOKEN // empty' "$CFG")
    [ -n "$api_port" ] || { printf 'api allowlist probe: no API port in the generated config\n' >&2 && return 2; }
    api_allowlist_probe "$api_port" "$token" api_allowlist_apply_source
}
