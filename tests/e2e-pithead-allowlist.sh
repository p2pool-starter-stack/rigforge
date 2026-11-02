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

api_allowlist_probe() { # <allowed-source> <api-target> <api-port> <token>
    (
        local allowed_source=$1 target=$2 port=$3 token=$4
        local ns="rfapi-$$" host_if="rfah-$$" peer_if="rfan-$$" host_cidr ns_cidr subnet
        local ns_created=0 link_created=0 before after code ns_rc hash third base tries probe_rc
        local auth=(-H "Authorization: Bearer $token")
        for tool in ip nft curl jq awk grep python3; do
            command -v "$tool" >/dev/null 2>&1 || {
                printf 'api allowlist probe: missing required tool: %s\n' "$tool" >&2
                exit 1
            }
        done
        declare -F live_hashrate >/dev/null || {
            printf 'api allowlist probe: live hashrate reader unavailable\n' >&2
            exit 1
        }
        if [ -n "${E2E_ALLOWLIST_HOST_CIDR:-}" ] || [ -n "${E2E_ALLOWLIST_NS_CIDR:-}" ]; then
            [ -n "${E2E_ALLOWLIST_HOST_CIDR:-}" ] && [ -n "${E2E_ALLOWLIST_NS_CIDR:-}" ] || {
                printf 'api allowlist probe: both CIDR overrides are required\n' >&2
                exit 1
            }
            host_cidr=$E2E_ALLOWLIST_HOST_CIDR
            ns_cidr=$E2E_ALLOWLIST_NS_CIDR
        else
            for tries in 1 2 3 4 5 6 7 8; do
                third=$(((RANDOM + $$ + tries) % 250 + 1))
                base=$(((RANDOM % 63) * 4))
                printf -v subnet '%d.%d.%d.%d/30' 169 254 "$third" "$base"
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
                printf -v host_cidr '%d.%d.%d.%d/30' 169 254 "$third" "$((base + 1))"
                printf -v ns_cidr '%d.%d.%d.%d/30' 169 254 "$third" "$((base + 2))"
                break
            done
            [ -n "${host_cidr:-}" ] || {
                printf 'api allowlist probe: no unused link network found\n' >&2
                exit 1
            }
        fi
        ip netns list | awk '{print $1}' | grep -Fxq "$ns" && exit 1
        ip link show "$host_if" >/dev/null 2>&1 && exit 1
        # shellcheck disable=SC2329
        cleanup_api_probe() {
            local cleanup_rc=0
            [ "$link_created" = 0 ] || ip link del "$host_if" >/dev/null 2>&1 || cleanup_rc=1
            [ "$ns_created" = 0 ] || ip netns del "$ns" >/dev/null 2>&1 || cleanup_rc=1
            return "$cleanup_rc"
        }
        trap 'probe_rc=$?; trap - EXIT; cleanup_api_probe || [ "$probe_rc" -ne 0 ] || probe_rc=1; exit "$probe_rc"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        ip netns add "$ns" || exit 1
        ns_created=1
        ip link add "$host_if" type veth peer name "$peer_if" || exit 1
        link_created=1
        ip link set "$peer_if" netns "$ns" || exit 1
        ip address add "$host_cidr" dev "$host_if" || exit 1
        ip link set "$host_if" up || exit 1
        ip -n "$ns" address add "$ns_cidr" dev "$peer_if" || exit 1
        ip -n "$ns" link set lo up || exit 1
        ip -n "$ns" link set "$peer_if" up || exit 1
        ip -n "$ns" route add default via "${host_cidr%/*}" || exit 1
        before=$(api_allowlist_drop_packets "$port") || exit 1
        code=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 5 --interface "$allowed_source" "${auth[@]}" "http://$target:$port/2/summary") || exit 1
        [ "$code" = 200 ] || exit 1
        if ip netns exec "$ns" curl --noproxy '*' -sS -o /dev/null --connect-timeout 2 --max-time 5 "${auth[@]}" "http://${host_cidr%/*}:$port/2/summary" 2>/dev/null; then
            ns_rc=0
        else
            ns_rc=$?
        fi
        case "$ns_rc" in 7 | 28) ;; *) exit 1 ;; esac
        after=$(api_allowlist_drop_packets "$port") || exit 1
        [ "$after" -gt "$before" ] || exit 1
        code=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 5 --interface "$allowed_source" "${auth[@]}" "http://$target:$port/2/summary") || exit 1
        [ "$code" = 200 ] || exit 1
        hash=$(live_hashrate)
        jq -en --argjson hash "$hash" '$hash | type == "number" and . > 0' >/dev/null 2>&1 || exit 1
    )
}

phase_api_allowlist() {
    local pool_host pool_ip allowed_source api_port token
    for tool in getent ip awk jq; do command -v "$tool" >/dev/null 2>&1 || return 1; done
    pool_host=${PITHEAD_URL%:*}
    pool_ip=$(getent ahostsv4 "$pool_host" | awk 'NR == 1 { print $1 }')
    [ -n "$pool_ip" ] || return 1
    allowed_source=$(ip -4 route get "$pool_ip" | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    api_port=$(jq -r '.http.port // empty' "$GEN_CFG")
    token=$(jq -r '.ACCESS_TOKEN // empty' "$CFG")
    [ -n "$allowed_source" ] && [ -n "$api_port" ] || return 1
    # shellcheck disable=SC2016
    set_cfg '.api_allow_from = $source' soft --arg source "$allowed_source/32" || return 1
    sleep 3
    api_allowlist_probe "$allowed_source" "$allowed_source" "$api_port" "$token"
}
