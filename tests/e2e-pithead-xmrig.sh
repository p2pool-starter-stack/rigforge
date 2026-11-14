# shellcheck shell=bash
_xmrig_overlay_rows() {
    local feed="" pool_before ts_before
    pool_before=$(jq -c '.cpu."memory-pool"' "$GEN_CFG" 2>/dev/null)
    ts_before=$(systemctl show -p ExecMainStartTimestamp --value xmrig 2>/dev/null || true)
    set_cfg '.xmrig = {"cpu": {"memory-pool": false}} | .api = "enabled"'
    jq -e '.cpu."memory-pool" == false' "$GEN_CFG" >/dev/null 2>&1 && ok "xmrig overlay merged into the generated config" || bad "xmrig overlay did not reach the generated config"
    [ "$(systemctl show -p ExecMainStartTimestamp --value xmrig 2>/dev/null || true)" != "$ts_before" ] && ok "unit restarted by the overlay apply" || bad "unit not restarted by the overlay apply"
    for _ in $(seq 1 15); do
        feed=$(api8081 http://127.0.0.1:8081/2/summary)
        printf '%s' "$feed" | jq -e '.hashrate.total[0] > 0' >/dev/null 2>&1 && break
        sleep 6
    done
    printf '%s' "$feed" | jq -e '.hashrate.total[0] > 0' >/dev/null 2>&1 && ok "worker mining after the overlay restart" || bad "worker not mining after the overlay restart"
    printf '%s' "$feed" | jq -e '.rigforge.config.xmrig.cpu."memory-pool" == false' >/dev/null 2>&1 && ok "feed config carries the xmrig overlay" || bad "feed config lacks the xmrig overlay"
    set_cfg 'del(.xmrig) | .api = "disabled"'
    [ "$(jq -c '.cpu."memory-pool"' "$GEN_CFG" 2>/dev/null)" = "$pool_before" ] && ok "overlay removal restored the generated config" || bad "overlay removal left the generated config changed"
}
