#!/usr/bin/env bash
set -Eeuo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_OS:-}" = Linux ] || {
    echo 'Run only in the disposable hosted Ubuntu CI job.' >&2
    exit 2
}
[ "$(id -u)" -ne 0 ]
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision="${1:-HEAD}"
expect="${2:-working}"
TEST_DIR=$(mktemp -d "${RUNNER_TEMP:?}/rigforge-home.XXXXXX")
home_dir="$TEST_DIR/home"
checkout="$home_dir/rigforge"
build="$checkout/data/worker/xmrig/build"
stage=fixture
setup_rc=not-run
apply_rc=not-run
http_code=not-probed
setup_attempted=0
run_cli() {
    env HOME="$home_dir" bash -c 'cd "$1" && shift && sudo -n ./rigforge.sh "$@"' bash "$checkout" "$@"
}
report_failure() {
    printf 'stock-home failure: stage=%s line=%s setup_rc=%s apply_rc=%s http_code=%s\n' "$stage" "$1" "$setup_rc" "$apply_rc" "$http_code" >&2
    for diagnostic_log in setup.log apply.log failed-apply.log recovered-apply.log journal.log cleanup.log; do
        for marker in 'Permission denied' 'command not found' 'rigforge aborted' 'Failed to' 'does not exist' 'Could not resolve' 'Unable to locate package' 'CMake Error' 'fatal:'; do
            if grep -Fq "$marker" "$TEST_DIR/$diagnostic_log" 2>/dev/null; then printf '%s diagnostic: %s\n' "$diagnostic_log" "$marker" >&2; fi
        done
    done
    systemctl show rigforge-api.service -p ActiveState -p SubState -p Result -p ExecMainStatus >&2 || true
}
trap 'report_failure "$LINENO"' ERR
cleanup() {
    local result=$?
    trap - EXIT
    if [ "$setup_attempted" = 1 ]; then
        if ! run_cli uninstall --yes >"$TEST_DIR/cleanup.log" 2>&1; then
            stage=cleanup
            report_failure "$LINENO"
            result=1
        fi
    fi
    exit "$result"
}
[ ! -e /etc/systemd/system/xmrig.service ]
[ ! -e /etc/systemd/system/rigforge-api.service ]
trap cleanup EXIT
chmod 755 "$TEST_DIR"
mkdir -p "$checkout"
git -C "$ROOT" archive "$revision" | tar -x -C "$checkout"
printf '%s\n' '{"pools":[{"url":"127.0.0.1:1","user":"fixture"}],"DONATION":0,"threads":1,"api":"enabled","api_bind":"127.0.0.1","ACCESS_TOKEN":"fixture-only-token","control":"disabled","control_upgrade":"disabled"}' >"$checkout/config.json"
chmod 600 "$checkout/config.json"
chmod 750 "$home_dir"
stage=operator-access
[ -x "$checkout/rigforge.sh" ]
[ ! -e "$build" ]
stage=setup
setup_attempted=1
if run_cli setup >"$TEST_DIR/setup.log" 2>&1; then setup_rc=0; else setup_rc=$?; fi
[ "$setup_rc" = 0 ]
stage=real-worker-installation
[ -x "$build/xmrig" ]
"$build/xmrig" --version >"$TEST_DIR/xmrig-version.log"
grep -q XMRig "$TEST_DIR/xmrig-version.log"
[ -f /etc/systemd/system/xmrig.service ]
grep -Fq "ExecStart=$build/xmrig --config=$build/config.json" /etc/systemd/system/xmrig.service
jq -e '."donate-level" == 0 and (.pools | length == 1) and .pools[0].url == "127.0.0.1:1"' "$build/config.json" >/dev/null
sudo systemctl stop xmrig.service
! systemctl is-active --quiet xmrig.service
stage=setup-listener
for _ in $(seq 1 30); do
    http_code=$(curl -q --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:8081/health) || http_code=000
    [ "$http_code" = 401 ] && break
    sleep 1
done
[ "$(stat -c %a "$home_dir")" = 750 ]
[ ! -e /etc/systemd/system/rigforge-control.service ]
if [ "$expect" = broken ]; then
    stage=historical-setup-failure
    [ "$http_code" = 000 ]
    ! systemctl is-active --quiet rigforge-api.service
    sudo journalctl -u rigforge-api.service --no-pager | tee "$TEST_DIR/journal.log" >/dev/null
    grep -q 'Permission denied' "$TEST_DIR/journal.log"
    grep -q 'api-server.py' "$TEST_DIR/journal.log"
    printf 'stock-home setup historical RED: real setup completed but the sister entrypoint was denied and port 8081 unavailable\n'
    exit 0
fi
stage=current-setup-listener
[ "$http_code" = 401 ]
systemctl is-active --quiet rigforge-api.service
stage=authenticated-setup-health
code=$(printf '%s\n' 'header = "Authorization: Bearer fixture-only-token"' | curl -q --noproxy '*' --config - -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8081/health)
[ "$code" = 200 ]
printf 'stock-home setup GREEN: real setup built XMRig, installed its unit, and served authenticated port 8081 beneath a 0750 HOME\n'
stage=apply
if run_cli apply >"$TEST_DIR/apply.log" 2>&1; then apply_rc=0; else apply_rc=$?; fi
[ "$apply_rc" = 0 ]
systemctl is-active --quiet rigforge-api.service
stage=missing-entrypoint
sudo mv "$checkout/util/api-server.py" "$checkout/util/api-server.saved"
if run_cli apply >"$TEST_DIR/failed-apply.log" 2>&1; then
    printf 'missing entrypoint incorrectly reconciled successfully\n' >&2
    report_failure "$LINENO"
    exit 1
fi
grep -q 'configured sister API could NOT be reconciled' "$TEST_DIR/failed-apply.log"
sudo mv "$checkout/util/api-server.saved" "$checkout/util/api-server.py"
stage=recovery
run_cli apply >"$TEST_DIR/recovered-apply.log" 2>&1
systemctl is-active --quiet rigforge-api.service
[ "$(stat -c %a "$home_dir")" = 750 ]
printf 'stock-home apply GREEN: failed reconcile rejected, service recovered, HOME remains 0750\n'
