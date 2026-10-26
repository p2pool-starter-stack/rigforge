#!/usr/bin/env bash
set -Eeuo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_OS:-}" = Linux ] || {
    echo 'Run only in the disposable hosted Ubuntu CI job.' >&2
    exit 2
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision="${1:-HEAD}"
expect="${2:-working}"
TEST_DIR=$(mktemp -d "${RUNNER_TEMP:?}/rigforge-home.XXXXXX")
test_user=rigforge-home-test
home_dir="$TEST_DIR/home"
checkout="$home_dir/rigforge"
stage=fixture
apply_rc=not-run
http_code=not-probed
report_failure() {
    printf 'stock-home failure: stage=%s line=%s apply_rc=%s http_code=%s\n' "$stage" "$1" "$apply_rc" "$http_code" >&2
    for diagnostic_log in apply.log failed-apply.log recovered-apply.log journal.log; do
        for marker in 'No built worker' 'Permission denied' 'command not found' 'rigforge aborted' 'Failed to' 'not allowed to execute' 'does not exist'; do
            if grep -Fq "$marker" "$TEST_DIR/$diagnostic_log" 2>/dev/null; then printf '%s diagnostic: %s\n' "$diagnostic_log" "$marker" >&2; fi
        done
    done
    systemctl show rigforge-api.service -p ActiveState -p SubState -p Result -p ExecMainStatus >&2 || true
}
trap 'report_failure "$LINENO"' ERR
cleanup() {
    sudo systemctl disable --now rigforge-api.service rigforge-api-refresh.timer >/dev/null 2>&1 || true
    sudo systemctl stop rigforge-api-refresh.service >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/rigforge-api.service /etc/systemd/system/rigforge-api-refresh.service \
        /etc/systemd/system/rigforge-api-refresh.timer /etc/systemd/system/xmrig.service \
        /etc/sudoers.d/rigforge-home-test
    sudo systemctl daemon-reload
    sudo userdel "$test_user"
}
[ ! -e /etc/systemd/system/xmrig.service ]
sudo useradd -M -d "$home_dir" -s /bin/bash "$test_user"
trap cleanup EXIT
chmod 755 "$TEST_DIR"
sudo mkdir -p "$checkout/data/worker/xmrig/build"
git -C "$ROOT" archive "$revision" | sudo tar -x -C "$checkout"
printf '%s ALL=(root) NOPASSWD: ALL\n' "$test_user" | sudo tee /etc/sudoers.d/rigforge-home-test >/dev/null
sudo chmod 440 /etc/sudoers.d/rigforge-home-test
printf '%s\n' '{"pools":[{"url":"pool.invalid:3333","user":"fixture"}],"DONATION":0,"api":"enabled","api_bind":"127.0.0.1","ACCESS_TOKEN":"fixture-only-token","control":"disabled","control_upgrade":"disabled"}' | sudo tee "$checkout/config.json" >/dev/null
sudo chown -R "$test_user:$test_user" "$home_dir"
sudo chmod 750 "$home_dir"
printf '%s\n' '[Unit]' 'Description=Deliberately stopped miner fixture; never executed' '[Service]' 'ExecStart=/usr/bin/false' | sudo tee /etc/systemd/system/xmrig.service >/dev/null
sudo systemctl daemon-reload
run_apply() {
    sudo -u "$test_user" -H bash -c 'cd "$1" && sudo -n ./rigforge.sh apply' bash "$checkout"
}
stage=initial-apply
if run_apply >"$TEST_DIR/apply.log" 2>&1; then apply_rc=0; else apply_rc=$?; fi
stage=listener
http_code=000
for _ in $(seq 1 30); do
    http_code=$(curl -q --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:8081/health) || http_code=000
    [ "$http_code" = 401 ] && break
    sleep 1
done
stage=fixture-invariants
[ "$(stat -c %a "$home_dir")" = 750 ]
! systemctl is-active --quiet xmrig.service
[ ! -e /etc/systemd/system/rigforge-control.service ]
if [ "$expect" = broken ]; then
    stage=historical-failure
    [ "$apply_rc" = 0 ]
    [ "$http_code" = 000 ]
    ! systemctl is-active --quiet rigforge-api.service
    sudo journalctl -u rigforge-api.service --no-pager | tee "$TEST_DIR/journal.log" >/dev/null
    grep -q 'Permission denied' "$TEST_DIR/journal.log"
    printf 'stock-home historical RED: apply returned success while the sister API could not open its entrypoint\n'
    exit 0
fi
stage=current-listener
[ "$apply_rc" = 0 ]
[ "$http_code" = 401 ]
systemctl is-active --quiet rigforge-api.service
stage=authenticated-health
code=$(printf '%s\n' 'header = "Authorization: Bearer fixture-only-token"' | curl -q --noproxy '*' --config - -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8081/health)
[ "$code" = 200 ]
stage=missing-entrypoint
sudo mv "$checkout/util/api-server.py" "$checkout/util/api-server.saved"
if run_apply >"$TEST_DIR/failed-apply.log" 2>&1; then
    printf 'missing entrypoint incorrectly reconciled successfully\n' >&2
    report_failure "$LINENO"
    exit 1
fi
grep -q 'configured sister API could NOT be reconciled' "$TEST_DIR/failed-apply.log"
sudo mv "$checkout/util/api-server.saved" "$checkout/util/api-server.py"
stage=recovery
run_apply >"$TEST_DIR/recovered-apply.log" 2>&1
systemctl is-active --quiet rigforge-api.service
[ "$(stat -c %a "$home_dir")" = 750 ]
printf 'stock-home GREEN: real DynamicUser service active, port 8081 authenticated, failed reconcile rejected and recovery successful\n'
