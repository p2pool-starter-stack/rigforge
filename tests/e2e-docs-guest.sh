#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "usage: $0 <baseline|dry-run-check|installed|allowlist-refuse|allowlist-accept|control-apply|control-revert|upgrade-leg|upgraded|restored|appliance|removed> <clone-root> <state-dir>" >&2
    exit 2
}

fail() {
    echo "e2e-docs-guest: $*" >&2
    exit 1
}

[ "$#" -eq 3 ] || usage
PHASE="$1"
CLONE_ROOT="$(cd "$2" && pwd -P)"
mkdir -p "$3"
STATE_DIR="$(cd "$3" && pwd -P)"
BASELINE="$STATE_DIR/baseline"
BOOT_ID_FILE="${E2E_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
CMDLINE_FILE="${E2E_CMDLINE_FILE:-/proc/cmdline}"
GRUB_DEFAULT_FILE="${E2E_GRUB_DEFAULT_FILE:-/etc/default/grub}"
GRUB_CONFIG_FILE="${E2E_GRUB_CONFIG_FILE:-}"
GRUB_DROPIN_DIR="${E2E_GRUB_DROPIN_DIR:-/etc/default/grub.d}"
FSTAB_FILE="${E2E_FSTAB_FILE:-/etc/fstab}"
LIMITS_FILE="${E2E_LIMITS_FILE:-/etc/security/limits.conf}"
MODULES_FILE="${E2E_MODULES_FILE:-/etc/modules}"
MSR_LOAD_FILE="${E2E_MSR_LOAD_FILE:-/etc/modules-load.d/msr.conf}"
HUGEPAGES_2M_FILE="${E2E_HUGEPAGES_2M_FILE:-/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages}"
OS_RELEASE_FILE="${E2E_OS_RELEASE_FILE:-/etc/os-release}"
SHARE_TIMEOUT="${E2E_SHARE_TIMEOUT:-180}"
SHARE_INTERVAL="${E2E_SHARE_INTERVAL:-5}"
ACTIVE_TIMEOUT="${E2E_ACTIVE_TIMEOUT:-60}"
CONTROL_PORT="${E2E_CONTROL_PORT:-8082}"
CONTROL_TIMEOUT="${E2E_CONTROL_TIMEOUT:-300}"
CONTROL_INTERVAL="${E2E_CONTROL_INTERVAL:-5}"
CONTROL_TOKEN="${E2E_CONTROL_TOKEN:-}"
CONTROL_STATE_DIR="${E2E_CONTROL_STATE_DIR:-/var/lib/rigforge-control-upgrade}"
CONTROL_PROBE_TAG="${E2E_CONTROL_PROBE_TAG:-v99.99.99}"
UPGRADE_LEG="${E2E_UPGRADE_LEG:-}"
EXPECTED_HEAD="${E2E_EXPECTED_HEAD:-}"
RESTORED_SHA256="${E2E_RESTORED_CONFIG_SHA256:-}"
ALLOW_NS="${E2E_ALLOWLIST_NS:-rfg-docs-allow}"
ALLOW_HOST_IF="${E2E_ALLOWLIST_HOST_IF:-rfgdocs-h}"
ALLOW_PEER_IF="${E2E_ALLOWLIST_PEER_IF:-rfgdocs-p}"
ALLOW_TARGET="${E2E_ALLOWLIST_TARGET:-169.254.241.1}"
ALLOW_REFUSED_SOURCE="${E2E_ALLOWLIST_REFUSED_SOURCE:-169.254.241.2}"
ALLOW_ALLOWED_SOURCE="${E2E_ALLOWLIST_ALLOWED_SOURCE:-169.254.241.3}"
ALLOW_NET="${E2E_ALLOWLIST_NET:-169.254.241.0/29}"

read_file() {
    [ -f "$1" ] && cat "$1" || printf '<absent>\n'
}

grub_config() {
    if [ -n "$GRUB_CONFIG_FILE" ]; then
        printf '%s\n' "$GRUB_CONFIG_FILE"
    elif [ -f /boot/grub/grub.cfg ]; then
        printf '%s\n' /boot/grub/grub.cfg
    else
        printf '%s\n' /boot/grub2/grub.cfg
    fi
}

product_units() {
    local files loaded
    files="$(systemctl list-unit-files --no-legend --no-pager --plain)" || fail "unit-file inventory failed"
    loaded="$(systemctl list-units --all --no-legend --no-pager --plain)" || fail "loaded-unit inventory failed"
    printf '%s\n%s\n' "$files" "$loaded" |
        awk '$1 ~ /^(xmrig|rigforge-).*(\.service|\.socket|\.timer|\.path)$/ {print}' | sort -u
}

product_processes() {
    local output rc
    if output="$(pgrep -af '(^|/)(xmrig|rigforge\.sh|api-server\.py|control-server\.py)( |$)' 2>/dev/null)"; then
        [ -z "$output" ] || printf '%s\n' "$output"
    else
        rc=$?
        [ "$rc" -eq 1 ] || fail "process inventory failed"
    fi
}

product_listeners() {
    listening_sockets | awk '/xmrig|rigforge-(api|control)/ {print}' | sort
}

nft_table() {
    local tables
    tables="$(nft -j list tables)" || fail "nft inventory failed"
    jq -ce '[.nftables[]? | .table? | select(.family == "inet" and .name == "rigforge")]' <<<"$tables" || fail "nft inventory was invalid"
}

hugepages_total() {
    read_file "$HUGEPAGES_2M_FILE"
}

directory_state() {
    local dir="$1"
    if [ -d "$dir" ]; then
        find "$dir" -type f -exec sha256sum {} + | sort
    else
        printf '<absent>\n'
    fi
}

snapshot() {
    local out="$1" grub
    mkdir -p "$out"
    grub="$(grub_config)"
    read_file "$BOOT_ID_FILE" >"$out/boot-id"
    read_file "$CMDLINE_FILE" >"$out/cmdline"
    read_file "$GRUB_DEFAULT_FILE" >"$out/grub-default"
    read_file "$grub" >"$out/grub-config"
    directory_state "$GRUB_DROPIN_DIR" >"$out/grub-dropins"
    read_file "$FSTAB_FILE" >"$out/fstab"
    read_file "$LIMITS_FILE" >"$out/limits"
    read_file "$MODULES_FILE" >"$out/modules"
    read_file "$MSR_LOAD_FILE" >"$out/msr-load"
    product_units >"$out/units"
    product_processes >"$out/processes"
    product_listeners >"$out/listeners"
    nft_table >"$out/nft"
    hugepages_total >"$out/hugepages-total"
}

assert_empty() {
    [ ! -s "$1" ] || fail "$2"
}

assert_fresh() {
    assert_empty "$BASELINE/units" "baseline has RigForge systemd units"
    assert_empty "$BASELINE/processes" "baseline has RigForge processes"
    assert_empty "$BASELINE/listeners" "baseline has RigForge listeners"
    [ "$(cat "$BASELINE/nft")" = '[]' ] || fail "baseline has the inet rigforge nft table"
    [ "$(cat "$BASELINE/hugepages-total")" = 0 ] || fail "baseline has 2 MiB HugePages"
    ! grep -Eq '(^| )(default_)?hugepagesz=|(^| )hugepages=|(^| )msr\.allow_writes=' "$BASELINE/cmdline" ||
        fail "baseline kernel command line already has RigForge flags"
}

config_paths() {
    CONFIG_FILE="$CLONE_ROOT/config.json"
    [ -f "$CONFIG_FILE" ] || fail "prepared config is missing"
    local configured_root
    configured_root="$(jq -er '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_FILE")" || fail "prepared config is invalid"
    case "$configured_root" in
    DYNAMIC_HOME | "") WORKER_ROOT="$CLONE_ROOT/data/worker" ;;
    /*) WORKER_ROOT="${configured_root%/}/worker" ;;
    *) fail "HOME_DIR is not absolute or DYNAMIC_HOME" ;;
    esac
    GENERATED_CONFIG="$WORKER_ROOT/xmrig/build/config.json"
}

read_live_config() {
    config_paths
    [ -f "$GENERATED_CONFIG" ] || fail "generated XMRig config is missing"
    [ "$(jq '[.pools[] | select(.enabled != false)] | length' "$CONFIG_FILE")" = 1 ] || fail "prepared config does not have exactly one enabled pool"
    [ "$(jq '[.pools[] | select(.enabled != false)] | length' "$GENERATED_CONFIG")" = 1 ] || fail "generated config does not have exactly one enabled pool"
    PREPARED_POOL_URL="$(jq -er '.pools | map(select(.enabled != false))[0].url' "$CONFIG_FILE")" || fail "prepared pool is missing"
    POOL_URL="$(jq -er '.pools | map(select(.enabled != false))[0].url' "$GENERATED_CONFIG")" || fail "enabled pool is missing"
    [ "$POOL_URL" = "$PREPARED_POOL_URL" ] || fail "generated pool differs from prepared config"
    POOL_PORT="${POOL_URL##*:}"
    POOL_HOST="${POOL_URL%:*}"
    POOL_HOST="${POOL_HOST#[}"
    POOL_HOST="${POOL_HOST%]}"
    API_PORT="$(jq -er '.http.port' "$GENERATED_CONFIG")" || fail "base API port is missing"
    jq -e '.http.host | type == "string" and length > 0' "$GENERATED_CONFIG" >/dev/null || fail "base API host is missing"
    API_HOST="$(loopback_host)"
    [ -n "$API_HOST" ] || fail "loopback address discovery failed"
    case "$API_HOST" in *:*) API_URL="http://[$API_HOST]:$API_PORT" ;; *) API_URL="http://$API_HOST:$API_PORT" ;; esac
    ACCESS_TOKEN="$(jq -r '.http."access-token" // empty' "$GENERATED_CONFIG")"
}

resolve_pool() {
    getent ahosts "$POOL_HOST" 2>/dev/null | awk '{print $1}' | sort -u
}

xmrig_peers() {
    established_sockets | awk '/xmrig/ {print $5}' | sort -u
}

established_sockets() {
    local sockets
    sockets="$(ss -Htnp)" || fail "established-socket inventory failed"
    awk '$1 == "ESTAB"' <<<"$sockets"
}

listening_sockets() {
    local sockets
    sockets="$(ss -Htlpn)" || fail "listening-socket inventory failed"
    printf '%s\n' "$sockets"
}

peer_is_pool() {
    local peer="$1" address port
    port="${peer##*:}"
    address="${peer%:*}"
    address="${address#[}"
    address="${address%]}"
    [ "$port" = "$POOL_PORT" ] && grep -Fxq "$address" "$STATE_DIR/pool-addresses"
}

api_summary() {
    local args=(-fsS --noproxy '*' --max-time 5)
    [ -z "$ACCESS_TOKEN" ] || args+=(-H "Authorization: Bearer $ACCESS_TOKEN")
    curl "${args[@]}" "$API_URL/2/summary"
}

loopback_host() {
    ip -o addr show dev lo | awk '$3 == "inet" || $3 == "inet6" {sub(/\/.*/, "", $4); print $4; exit}'
}

phase_baseline() {
    local tool
    [ "$(uname -s)" = Linux ] || fail "guest is not Linux"
    [ "$(uname -m)" = x86_64 ] || fail "guest is not x86_64"
    grep -Eq '^ID="?ubuntu"?$' "$OS_RELEASE_FILE" || fail "guest is not stock Ubuntu"
    grep -qw avx2 "${E2E_CPUINFO_FILE:-/proc/cpuinfo}" || fail "guest CPU does not expose AVX2"
    [ "$(ps -p 1 -o comm= | tr -d ' ')" = systemd ] || fail "systemd is not PID 1"
    systemctl is-system-running --wait >/dev/null 2>&1 || fail "systemd is not running"
    for tool in curl getent git ip jq nft pgrep sha256sum ss systemctl; do
        command -v "$tool" >/dev/null 2>&1 || fail "required guest tool is missing: $tool"
    done
    snapshot "$BASELINE"
    assert_fresh
}

phase_dry_run_check() {
    local after="$STATE_DIR/after-dry-run" file
    [ -d "$BASELINE" ] || fail "baseline is missing"
    snapshot "$after"
    for file in boot-id cmdline grub-default grub-config grub-dropins fstab limits modules msr-load units processes listeners nft hugepages-total; do
        cmp -s "$BASELINE/$file" "$after/$file" || fail "dry run changed $file"
    done
}

_assert_enabled_active() {
    local waited=0 active=0
    systemctl is-enabled --quiet xmrig.service || fail "xmrig is not enabled"
    while [ "$waited" -lt "$ACTIVE_TIMEOUT" ]; do
        if systemctl is-active --quiet xmrig.service; then
            active=1
            break
        fi
        sleep "$SHARE_INTERVAL"
        waited=$((waited + SHARE_INTERVAL))
    done
    [ "$active" = 1 ] || fail "xmrig did not autostart within ${ACTIVE_TIMEOUT}s"
}

_assert_donation_zero_config() {
    [ "$(jq -r '."donate-level"' "$GENERATED_CONFIG")" = 0 ] || fail "donate-level is not zero"
    [ "$(jq -r '."donate-over-proxy"' "$GENERATED_CONFIG")" = 0 ] || fail "donate-over-proxy is not zero"
    [ "$(jq -r '.http.restricted' "$GENERATED_CONFIG")" = true ] || fail "base API is not restricted"
}

_assert_expected_peers() {
    local peer waited=0
    resolve_pool >"$STATE_DIR/pool-addresses"
    [ -s "$STATE_DIR/pool-addresses" ] || fail "pool host did not resolve"
    printf '%s\n' "$POOL_PORT" >"$STATE_DIR/pool-port"
    printf '%s\n' "$API_PORT" >"$STATE_DIR/api-port"
    while [ "$waited" -lt "$ACTIVE_TIMEOUT" ]; do
        peer="$(xmrig_peers)"
        [ -n "$peer" ] && break
        sleep "$SHARE_INTERVAL"
        waited=$((waited + SHARE_INTERVAL))
    done
    [ -n "$peer" ] || fail "xmrig has no established pool peer within ${ACTIVE_TIMEOUT}s"
    while IFS= read -r peer; do peer_is_pool "$peer" || fail "xmrig has an unexpected peer"; done <<<"$peer"
}

_assert_nft_table_present() {
    local nft_state
    nft_state="$(nft_table)" || fail "nft inventory failed during installed verification"
    [ "$nft_state" != '[]' ] || fail "API allowlist nft table is missing"
}

_assert_accepted_shares() {
    local summary accepted rejected waited=0
    while [ "$waited" -lt "$ACTIVE_TIMEOUT" ]; do
        summary="$(api_summary 2>/dev/null)" || summary=""
        if jq -e '.donate_level == 0 and ((.hashrate.total[0] // 0) > 0)' >/dev/null 2>&1 <<<"$summary"; then break; fi
        sleep "$SHARE_INTERVAL"
        waited=$((waited + SHARE_INTERVAL))
    done
    jq -e '.donate_level == 0' >/dev/null 2>&1 <<<"$summary" || fail "runtime donation level is not zero"
    jq -e '((.hashrate.total[0] // 0) > 0)' >/dev/null 2>&1 <<<"$summary" || fail "xmrig did not report a nonzero hashrate within ${ACTIVE_TIMEOUT}s"
    accepted="$(jq -er '.connection.accepted // 0' <<<"$summary")" || fail "base API omitted accepted shares"
    rejected="$(jq -er '.connection.rejected // 0' <<<"$summary")" || fail "base API omitted rejected shares"
    [ "$rejected" = 0 ] || fail "base API reports rejected shares"
    while [ "$waited" -lt "$SHARE_TIMEOUT" ]; do
        sleep "$SHARE_INTERVAL"
        summary="$(api_summary)" || fail "base API summary transport failed"
        rejected="$(jq -r '.connection.rejected // -1' <<<"$summary" 2>/dev/null || echo -1)"
        [ "$rejected" = 0 ] || fail "rejected shares rose while waiting"
        [ "$(jq -r '.connection.accepted // 0' <<<"$summary" 2>/dev/null || echo 0)" -gt "$accepted" ] && break
        waited=$((waited + SHARE_INTERVAL))
    done
    [ "$(jq -r '.connection.accepted // 0' <<<"$summary")" -gt "$accepted" ] || fail "accepted shares did not rise within ${SHARE_TIMEOUT}s"
}

_assert_read_only_api() {
    local code
    code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 -H 'Content-Type: application/json' -X PUT --data '{}' "$API_URL/1/config")" || fail "base API write probe transport failed"
    [ "$code" = 403 ] || fail "base API write probe did not return HTTP 403"
}

phase_installed() {
    [ -d "$BASELINE" ] || fail "baseline is missing"
    [ "$(cat "$BOOT_ID_FILE")" != "$(cat "$BASELINE/boot-id")" ] || fail "guest did not reboot after setup"
    _assert_enabled_active
    read_live_config
    _assert_donation_zero_config
    _assert_expected_peers
    printf '%s\n' "$(cat "$BOOT_ID_FILE")" >"$STATE_DIR/installed-boot-id"
    _assert_nft_table_present
    _assert_accepted_shares
    _assert_read_only_api
}

phase_upgraded() {
    [ -d "$BASELINE" ] || fail "baseline is missing"
    [[ "$EXPECTED_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "expected candidate commit is missing"
    [ "$(git -C "$CLONE_ROOT" rev-parse HEAD)" = "$EXPECTED_HEAD" ] || fail "checkout is not at the candidate commit"
    [ -s "$CLONE_ROOT/VERSION" ] || fail "candidate VERSION is missing"
    _assert_enabled_active
    read_live_config
    _assert_donation_zero_config
    _assert_expected_peers
    _assert_nft_table_present
    _assert_accepted_shares
    _assert_read_only_api
}

_control_curl() {
    local method="$1" url="$2" payload="${3:-}" file="" rc=0
    if [ -n "$payload" ]; then
        file="$(mktemp "$STATE_DIR/.control-payload.XXXXXX")"
        printf '%s' "$payload" >"$file"
    fi
    {
        printf 'silent\nshow-error\nnoproxy = "*"\nconnect-timeout = 2\nmax-time = 8\nrequest = "%s"\nurl = "%s"\n' "$method" "$url"
        [ -z "$CONTROL_TOKEN" ] || printf 'header = "Authorization: Bearer %s"\n' "$CONTROL_TOKEN"
        [ -z "$payload" ] || printf 'header = "Content-Type: application/json"\ndata = "@%s"\n' "$file"
    } | curl --config - 2>/dev/null || rc=$?
    [ -z "$file" ] || rm -f "$file"
    return "$rc"
}

_control_post_and_poll() {
    local endpoint="$1" payload="$2" want="$3" resp cid waited=0 status=""
    [ -n "$CONTROL_TOKEN" ] || fail "control token is missing"
    systemctl is-active --quiet rigforge-control.service || fail "control receiver is not active"
    resp="$(_control_curl POST "http://127.0.0.1:$CONTROL_PORT/$endpoint" "$payload")" || fail "control $endpoint request failed"
    cid="$(jq -er 'select(.status == "accepted") | .change_id' <<<"$resp" 2>/dev/null)" || fail "control $endpoint request was not accepted"
    [[ "$cid" =~ ^[0-9a-f]{16}$ ]] || fail "control change id was malformed"
    while [ "$waited" -lt "$CONTROL_TIMEOUT" ]; do
        status="$(_control_curl GET "http://127.0.0.1:$CONTROL_PORT/status?change_id=$cid" | jq -r '.status // empty' 2>/dev/null || true)"
        case "$status" in
        applied | rejected | rolled_back | failed | noop | busy | throttled) break ;;
        esac
        sleep "$CONTROL_INTERVAL"
        waited=$((waited + CONTROL_INTERVAL))
    done
    [ "$status" = "$want" ] || fail "control $endpoint ended '$status' (expected $want)"
}

_assert_runtime_donation() {
    local want="$1" waited=0 summary=""
    read_live_config
    [ "$(jq -r '."donate-level"' "$GENERATED_CONFIG")" = "$want" ] || fail "generated config did not follow the control change"
    while [ "$waited" -lt "$ACTIVE_TIMEOUT" ]; do
        summary="$(api_summary 2>/dev/null)" || summary=""
        [ "$(jq -r '.donate_level // empty' <<<"$summary" 2>/dev/null)" = "$want" ] && break
        sleep "$SHARE_INTERVAL"
        waited=$((waited + SHARE_INTERVAL))
    done
    [ "$(jq -r '.donate_level // empty' <<<"$summary" 2>/dev/null)" = "$want" ] || fail "runtime donation level did not follow the control change"
    systemctl is-active --quiet xmrig.service || fail "xmrig is not active after the control change"
}

phase_control_apply() {
    _control_post_and_poll apply '{"DONATION":1}' applied
    _assert_runtime_donation 1
}

phase_control_revert() {
    _control_post_and_poll apply '{"DONATION":0}' applied
    _assert_runtime_donation 0
}

phase_upgrade_leg() {
    local before_head before_version payload
    case "$UPGRADE_LEG" in
    noop | refused) ;;
    *) fail "upgrade leg is not selected" ;;
    esac
    systemctl is-active --quiet rigforge-control.service || fail "control receiver is not active"
    before_head="$(git -C "$CLONE_ROOT" rev-parse HEAD)" || fail "checkout inventory failed"
    before_version="$(cat "$CLONE_ROOT/VERSION")"
    if [ "$UPGRADE_LEG" = noop ]; then
        payload="{\"version\":\"v$(tr -d '[:space:]' <"$CLONE_ROOT/VERSION")\"}"
        _control_post_and_poll upgrade "$payload" noop
    else
        payload="{\"version\":\"$CONTROL_PROBE_TAG\"}"
        _control_post_and_poll upgrade "$payload" rolled_back
        [ -n "$(ls -A "$CONTROL_STATE_DIR" 2>/dev/null)" ] || fail "no throttle stamp after the refused leg"
    fi
    [ "$(git -C "$CLONE_ROOT" rev-parse HEAD)" = "$before_head" ] || fail "checkout moved during the $UPGRADE_LEG leg"
    [ "$(cat "$CLONE_ROOT/VERSION")" = "$before_version" ] || fail "VERSION changed during the $UPGRADE_LEG leg"
    systemctl is-active --quiet xmrig.service || fail "xmrig is not active after the $UPGRADE_LEG leg"
}

_drop_counter() {
    nft -j list chain inet rigforge api 2>/dev/null | jq -r --argjson port "$1" '
        [.nftables[].rule
            | select(.family == "inet" and .table == "rigforge" and .chain == "api")
            | select(any(.expr[]?; has("drop")))
            | [.expr[]? | .counter?.packets // empty]
            | select(length == 1) | .[0]]
        | if length == 1 then .[0] else error("expected one API drop counter") end'
}

_allow_netns_setup() {
    ip netns list 2>/dev/null | awk '{print $1}' | grep -Fxq "$ALLOW_NS" ||
        ip netns add "$ALLOW_NS" || fail "allowlist namespace could not be created"
    if ! ip link show "$ALLOW_HOST_IF" >/dev/null 2>&1; then
        ip link add "$ALLOW_HOST_IF" type veth peer name "$ALLOW_PEER_IF" || fail "allowlist veth pair could not be created"
        ip link set "$ALLOW_PEER_IF" netns "$ALLOW_NS" || fail "allowlist veth peer could not move into the namespace"
    fi
    ip address show dev "$ALLOW_HOST_IF" | grep -q "${ALLOW_TARGET}/" ||
        ip address add "${ALLOW_TARGET}/${ALLOW_NET##*/}" dev "$ALLOW_HOST_IF" || fail "allowlist target address could not be added"
    ip link set "$ALLOW_HOST_IF" up || fail "allowlist host link could not be raised"
    ip -n "$ALLOW_NS" address show dev "$ALLOW_PEER_IF" | grep -q "${ALLOW_REFUSED_SOURCE}/" ||
        ip -n "$ALLOW_NS" address add "${ALLOW_REFUSED_SOURCE}/${ALLOW_NET##*/}" dev "$ALLOW_PEER_IF" ||
        fail "refused source address could not be added"
    ip -n "$ALLOW_NS" address show dev "$ALLOW_PEER_IF" | grep -q "${ALLOW_ALLOWED_SOURCE}/" ||
        ip -n "$ALLOW_NS" address add "${ALLOW_ALLOWED_SOURCE}/${ALLOW_NET##*/}" dev "$ALLOW_PEER_IF" ||
        fail "allowed source address could not be added"
    ip -n "$ALLOW_NS" link set lo up || fail "namespace loopback could not be raised"
    ip -n "$ALLOW_NS" link set "$ALLOW_PEER_IF" up || fail "namespace veth peer could not be raised"
    ip -n "$ALLOW_NS" route show default | grep -q "$ALLOW_TARGET" ||
        ip -n "$ALLOW_NS" route add default via "$ALLOW_TARGET" || fail "namespace default route could not be added"
}

_allow_probe() {
    ip netns exec "$ALLOW_NS" curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' \
        --connect-timeout 2 --max-time 5 --interface "$1" "http://$ALLOW_TARGET:$API_PORT/2/summary"
}

phase_allowlist_refuse() {
    local before after rc=0
    read_live_config
    _allow_netns_setup
    before="$(_drop_counter "$API_PORT")" || fail "API drop counter is unreadable before the probe"
    _allow_probe "$ALLOW_REFUSED_SOURCE" >/dev/null 2>&1 || rc=$?
    case "$rc" in
    7 | 28) ;;
    *) fail "second source was not refused (curl exit $rc)" ;;
    esac
    after="$(_drop_counter "$API_PORT")" || fail "API drop counter is unreadable after the probe"
    [ "$after" -gt "$before" ] || fail "API drop counter did not rise for the refused source"
    printf '%s\n' "$ALLOW_REFUSED_SOURCE" >"$STATE_DIR/allowlist-refused"
}

phase_allowlist_accept() {
    local code
    read_live_config
    [ -f "$STATE_DIR/allowlist-refused" ] || fail "the refused-source leg has not run"
    _allow_netns_setup
    code="$(_allow_probe "$ALLOW_ALLOWED_SOURCE")" || fail "allowed second source probe transport failed"
    [ "$code" = 200 ] || fail "allowed second source did not receive HTTP 200 (got $code)"
    api_summary >/dev/null || fail "loopback API probe failed after the allowlist widened"
    ip netns del "$ALLOW_NS" 2>/dev/null || true
    ip link del "$ALLOW_HOST_IF" 2>/dev/null || true
    rm -f "$STATE_DIR/allowlist-refused"
}

phase_restored() {
    local digest
    [ -n "$RESTORED_SHA256" ] || fail "expected config digest is missing"
    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "$CLONE_ROOT/config.json" 2>/dev/null | awk '{print $1}')"
    else
        digest="$(shasum -a 256 "$CLONE_ROOT/config.json" 2>/dev/null | awk '{print $1}')"
    fi
    [ -n "$digest" ] || fail "config digest is unreadable"
    [ "$digest" = "$RESTORED_SHA256" ] || fail "restored config differs from the backup"
    ls "$CLONE_ROOT"/backups/rigforge-backup-*.tar.gz >/dev/null 2>&1 || fail "backup archive is missing"
}

phase_appliance() {
    local fragment persistent
    [ -d "$BASELINE" ] || fail "baseline is missing"
    fragment="$(systemctl show -p FragmentPath --value xmrig.service | tr -d '[:space:]')"
    case "$fragment" in
    /run/systemd/system/*) ;;
    *) fail "xmrig is not a runtime unit" ;;
    esac
    persistent="$(find /etc/systemd/system -maxdepth 1 \( -name 'xmrig-*' -o -name 'rigforge-*' \) -print -quit 2>/dev/null || true)"
    [ -z "$persistent" ] || fail "appliance mode wrote persistent units"
    cmp -s "$BASELINE/fstab" <(read_file "$FSTAB_FILE") || fail "appliance mode changed fstab"
    cmp -s "$BASELINE/limits" <(read_file "$LIMITS_FILE") || fail "appliance mode changed limits"
    cmp -s "$BASELINE/modules" <(read_file "$MODULES_FILE") || fail "appliance mode changed modules"
    cmp -s "$BASELINE/msr-load" <(read_file "$MSR_LOAD_FILE") || fail "appliance mode changed the MSR module config"
    cmp -s "$BASELINE/grub-default" <(read_file "$GRUB_DEFAULT_FILE") || fail "appliance mode changed GRUB defaults"
    cmp -s "$BASELINE/grub-config" <(read_file "$(grub_config)") || fail "appliance mode changed the generated GRUB config"
    cmp -s "$BASELINE/grub-dropins" <(directory_state "$GRUB_DROPIN_DIR") || fail "appliance mode changed GRUB drop-ins"
    cmp -s "$BASELINE/cmdline" <(read_file "$CMDLINE_FILE") || fail "appliance mode changed the kernel command line"
    mount 2>/dev/null | grep -q hugetlbfs || fail "hugetlbfs is not mounted at runtime"
    systemctl is-enabled --quiet --runtime xmrig.service || fail "xmrig is not enabled at runtime"
    systemctl is-active --quiet xmrig.service || fail "xmrig is not active under appliance mode"
    read_live_config
    [ "$(jq -r '."donate-level"' "$GENERATED_CONFIG")" = 0 ] || fail "donate-level is not zero"
}

phase_removed() {
    local peer port address remaining
    [ -f "$STATE_DIR/installed-boot-id" ] || fail "installed state is missing"
    [ "$(cat "$BOOT_ID_FILE")" != "$(cat "$STATE_DIR/installed-boot-id")" ] || fail "guest did not reboot after uninstall"
    remaining="$(product_units)"
    [ -z "$remaining" ] || fail "RigForge systemd units remain"
    remaining="$(product_processes)"
    [ -z "$remaining" ] || fail "RigForge processes remain"
    [ "$(nft_table)" = '[]' ] || fail "inet rigforge nft table remains"
    port="$(cat "$STATE_DIR/pool-port")"
    remaining="$(established_sockets)"
    while IFS= read -r peer; do
        [ -n "$peer" ] || continue
        address="${peer%:*}"
        address="${address#[}"
        address="${address%]}"
        if [ "${peer##*:}" = "$port" ] && grep -Fxq "$address" "$STATE_DIR/pool-addresses"; then
            fail "pool connection remains after uninstall"
        fi
    done < <(awk '{print $5}' <<<"$remaining" | sort -u)
    remaining="$(listening_sockets | awk -v p="$(cat "$STATE_DIR/api-port")" '$4 ~ (":" p "$") {print}')"
    [ -z "$remaining" ] || fail "base API listener remains after uninstall"
    [ "$(hugepages_total)" = 0 ] || fail "2 MiB HugePages remain after uninstall reboot"
    cmp -s "$BASELINE/grub-default" <(read_file "$GRUB_DEFAULT_FILE") || fail "GRUB defaults were not restored"
    cmp -s "$BASELINE/grub-config" <(read_file "$(grub_config)") || fail "generated GRUB config was not restored"
    cmp -s "$BASELINE/grub-dropins" <(directory_state "$GRUB_DROPIN_DIR") || fail "GRUB drop-ins were not restored"
    cmp -s "$BASELINE/fstab" <(read_file "$FSTAB_FILE") || fail "fstab was not restored"
    cmp -s "$BASELINE/limits" <(read_file "$LIMITS_FILE") || fail "limits were not restored"
    cmp -s "$BASELINE/modules" <(read_file "$MODULES_FILE") || fail "modules were not restored"
    cmp -s "$BASELINE/msr-load" <(read_file "$MSR_LOAD_FILE") || fail "MSR module config was not restored"
    ! grep -Eq '(^| )(default_)?hugepagesz=|(^| )hugepages=|(^| )msr\.allow_writes=' "$CMDLINE_FILE" ||
        fail "managed kernel flags remain after uninstall reboot"
}

case "$PHASE" in
baseline) phase_baseline ;;
dry-run-check) phase_dry_run_check ;;
installed) phase_installed ;;
allowlist-refuse) phase_allowlist_refuse ;;
allowlist-accept) phase_allowlist_accept ;;
control-apply) phase_control_apply ;;
control-revert) phase_control_revert ;;
upgrade-leg) phase_upgrade_leg ;;
upgraded) phase_upgraded ;;
restored) phase_restored ;;
appliance) phase_appliance ;;
removed) phase_removed ;;
*) usage ;;
esac
