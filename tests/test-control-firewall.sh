#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -uo pipefail
SCRIPT="$1" CPS="$2" BADNFT="$3" STUBS="$4"
FAILS=0
assert_contains() { case "$2" in *"$3"*) echo "ok: $1" ;; *)
    echo "FAIL: $1 [$2]"
    FAILS=1
    ;;
esac }
assert_absent() { case "$2" in *"$3"*)
    echo "FAIL: $1"
    FAILS=1
    ;;
*) echo "ok: $1" ;; esac }
run_control_fw() { # <nft dir> <calls.log>
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        SCRIPT_DIR="$CPS"
        SYSTEMD_DIR="$CPS/systemd"
        WORKER_ROOT="$CPS/wr"
        mkdir -p "$WORKER_ROOT"
        REAL_USER=rfop
        CONTROL_MODE=enabled
        CONTROL_BIND=0.0.0.0
        CONTROL_PORT=8082
        CONTROL_UPGRADE=disabled
        API_ALLOW_FROM=10.0.0.5
        API_MODE=enabled
        API_PORT=8081
        ACCESS_TOKEN=tok-secret
        set +e
        PATH="$1:$STUBS:$PATH" CALL_LOG="$2" install_control 2>&1
        echo "rc=$?"
    )
}
: >"$CPS/ok.log"
out="$(run_control_fw "$STUBS" "$CPS/ok.log")"
assert_contains "control enable loads the firewall before restarting the receiver (#628)" "$(grep -n 'nft\]\|systemctl\] restart rigforge-control' "$CPS/ok.log" | cut -d: -f2- | tr '\n' ' ')" "[nft] -f $CPS/wr/api-firewall.nft [systemctl] restart rigforge-control.service"
assert_contains "control unit reloads the firewall on every start and fails closed (#628)" "$(cat "$CPS/systemd/rigforge-control.service")" "ExecStartPre=+"
assert_contains "control unit loads the rendered nft file (#628)" "$(cat "$CPS/systemd/rigforge-control.service")" "-f $CPS/wr/api-firewall.nft"
: >"$CPS/bad.log"
out="$(run_control_fw "$BADNFT" "$CPS/bad.log")"
assert_contains "rejected firewall load fails the control install (#628)" "$out" "FAILED to load"
assert_contains "rejected firewall load stops the receiver first (#628)" "$(cat "$CPS/bad.log")" "[systemctl] stop rigforge-control.service"
assert_absent "rejected firewall load never starts the receiver (#628)" "$(cat "$CPS/bad.log")" "restart rigforge-control"
assert_contains "rejected firewall load still leaves the re-rendered unit with the fail-closed start check (#628)" "$(cat "$CPS/systemd/rigforge-control.service")" "ExecStartPre=+"
assert_absent "rejected firewall load never reloads systemd into a running receiver (#628)" "$(cat "$CPS/bad.log")" "systemctl] enable"
exit "$FAILS"
