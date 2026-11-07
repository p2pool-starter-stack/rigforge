#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/worker/xmrig/build"
GEN_CFG="$D/worker/xmrig/build/config.json"
RIGFORGE="$D/rigforge"
cat >"$RIGFORGE" <<'STUB'
#!/usr/bin/env bash
case "$1" in
bench)
    [ "$BENCH_MODE" = verified ] || exit 1
    printf '{"verdict":"verified"}\n' >"$WORKER/rigforge-bench.json"
    echo 'Benchmark correctness: verified (hash 898B6E0431C28A6B).'
    ;;
stress)
    [ "$1 $2 $3" = "stress --minutes 1" ] || exit 2
    [ "$STRESS_MODE" != fail ] || exit 1
    [ "$STRESS_MODE" != drift ] || : >"$WORKER/drift"
    echo 'Stress PASS: hashed for 1 minute(s); peak temperature 60°C.'
    ;;
esac
STUB
chmod +x "$RIGFORGE"
export WORKER="$D/worker"
systemctl() {
    [ "$1" = is-active ] || return 1
    if [ "$2" = rigforge-watchdog.timer ] && [ -e "$WORKER/drift" ]; then
        echo inactive
        return 3
    fi
    echo active
}
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
    FAIL=$((FAIL + 1))
    printf '%s\n' "$1" >>"$D/bad"
    return 1
}
phase() { :; }
source "$ROOT/tests/e2e-selftest.sh"
status=0
check() {
    local want_rc="$1" want_fail="$2" rc=0
    PASS=0 FAIL=0
    rm -f "$WORKER/rigforge-bench.json" "$WORKER/drift" "$D/bad"
    phase_selftest 2>/dev/null || rc=$?
    if [ "$rc" != "$want_rc" ] || [ "$FAIL" != "$want_fail" ]; then
        printf 'FAIL: bench=%s stress=%s rc=%s fail=%s\n' "$BENCH_MODE" "$STRESS_MODE" "$rc" "$FAIL"
        status=1
    fi
}
export BENCH_MODE=verified STRESS_MODE=pass
check 0 0
BENCH_MODE=mismatch check 1 1
STRESS_MODE=fail check 1 1
STRESS_MODE=drift check 1 1
grep -q "before 'xmrig=active rigforge-autotune.timer=active rigforge-watchdog.timer=active '" "$D/bad" || {
    echo 'FAIL: unit drift was not reported'
    status=1
}
[ "$status" = 0 ] && echo 'e2e selftest phase: PASS'
exit "$status"
