# shellcheck shell=bash disable=SC1090,SC2034,SC2329
# #762: a DONATION/Tor conflict must not stop the watchdog's thermal cutoff.
run_watchdog_conflict() {
    (
        source "$SCRIPT"
        parse_config() {
            [ "${RIGFORGE_TOLERATE_DONATION_TOR:-0}" = 1 ] || {
                echo "parse_config refused the conflict"
                exit 1
            }
            DONATION=5
            DONATION_TOR_CONFLICT=1
        }
        OS_TYPE=Linux
        WORKER_ROOT="$WDR"
        SERVICE_NAME=xmrig
        MAX_TEMP_C=85
        sudo() { "$@"; }
        systemctl() {
            echo "[systemctl] $*" >>"$WDR/calls.log"
            return 0
        }
        set +e
        TUNE_TEMP_CMD='echo 92.5' API_CMD='echo 12345' watchdog 2>&1
        echo "rc=$?"
    )
}
: >"$WDR/calls.log"
rm -f "$WDR/watchdog.thermal-hold"
out="$(run_watchdog_conflict)"
assert_contains "watchdog tolerates a DONATION/Tor conflict (#762)" "$out" "the thermal stop and wedge recovery still run"
assert_absent "watchdog never hits the parse refusal (#762)" "$out" "parse_config refused the conflict"
assert_eq "watchdog thermal stop still fires under the conflict (#762)" "$(wd_calls 'stop xmrig')" "1"
rm -f "$WDR/watchdog.thermal-hold" "$WDR/watchdog.fails"
msr_conflict_out="$( (
    source "$SCRIPT"
    parse_config() {
        [ "${RIGFORGE_TOLERATE_DONATION_TOR:-0}" = 1 ] || {
            echo "parse_config refused the conflict"
            exit 1
        }
        DONATION_TOR_CONFLICT=1
        SHARED_HOST=false
    }
    OS_TYPE=Linux
    id() { echo 0; }
    _msr_detect_preset() { :; }
    set +e
    msr_apply 2>&1
    echo "rc=$?"
) 2>&1)"
assert_contains "msr-apply tolerates a DONATION/Tor conflict so a miner_user unit still starts (#762)" "$msr_conflict_out" "rc=0"
assert_absent "msr-apply never hits the parse refusal (#762)" "$msr_conflict_out" "parse_config refused the conflict"
msr_shared_out="$( (
    source "$SCRIPT"
    parse_config() {
        [ "${RIGFORGE_TOLERATE_DONATION_TOR:-0}" = 1 ] || exit 1
        DONATION_TOR_CONFLICT=1
        SHARED_HOST=true
    }
    OS_TYPE=Linux
    id() { echo 0; }
    set +e
    msr_apply 2>&1
    echo "rc=$?"
) 2>&1)"
assert_contains "msr-apply still refuses shared_host under the conflict (#762)" "$msr_shared_out" "MSR tuning is disabled in shared_host"
cat >"$ST/config.json" <<EOF
{ "HOME_DIR": "$ST/home", "pools": [{"url": "h:3333"}], "tor_socks5": "127.0.0.1:9050", "DONATION": 5 }
EOF
: >"$ST/calls.log"
out="$(run_status ok)"
assert_contains "status: live summary survives a DONATION/Tor conflict (#762)" "$out" "Hashrate:  1234.5 H/s"
cat >"$ST/config.json" <<EOF
{ "HOME_DIR": "$ST/home", "pools": [{"url": "h:3333"}] }
EOF
assert_contains "legacy upgrade gives the control receiver the appliance posture (#762)" "$(cat "$APW/systemd-clean/rigforge-control.service")" "Environment=RIGFORGE_APPLIANCE=1"
