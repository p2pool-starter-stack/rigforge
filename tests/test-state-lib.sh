#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2329
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
D="$(mktemp -d)"
D="$(cd -P "$D" && pwd -P)"
trap 'chmod -R u+w "$D" 2>/dev/null; rm -rf "$D"' EXIT
FAIL=0
pass() { printf '  ok: %s\n' "$1"; }
fail() {
    printf '  FAIL: %s%s\n' "$1" "${2:+ — $2}" >&2
    FAIL=$((FAIL + 1))
}
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3], got [$2]"; fi; }

BIN="$D/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexec "$@"\n' >"$BIN/sudo"
for c in systemctl nft ufw; do printf '#!/bin/sh\nexit 0\n' >"$BIN/$c"; done
chmod +x "$BIN"/*

bundle() {
    mkdir -p "$1"
    cp -R "$ROOT/rigforge.sh" "$ROOT/VERSION" "$ROOT/systemd" "$ROOT/util" "$1/"
}

normalize() {
    local f n
    for f in "$1"/*.*; do
        n=$(basename "$f")
        sed -e "s#$2#@LIB@#g" -e "s#$3#@OUT@#g" -e "s#$BIN#@BIN@#g" "$f" >"$1/$n.norm"
    done
}

echo "== units: default render is byte-identical to the golden render =="
bundle "$D/code"
env -u RIGFORGE_STATE -u RIGFORGE_LIB -u RIGFORGE_HOME bash "$ROOT/tests/state-lib-harness.sh" "$D/code" "$D/out" "$BIN"
normalize "$D/out" "$D/code" "$D/out"
golden_count=0
for g in "$ROOT"/tests/golden/units/*; do
    golden_count=$((golden_count + 1))
    n=$(basename "$g")
    if cmp -s "$g" "$D/out/$n.norm"; then pass "golden $n"; else fail "golden $n" "render differs from tests/golden/units/$n"; fi
done
for t in "$ROOT"/systemd/*.template; do
    n=$(basename "$t" .template)
    [ -f "$ROOT/tests/golden/units/$n" ] && pass "golden exists for $n" || fail "golden exists for $n"
done
eq "no golden without a template" "$(ls "$ROOT/tests/golden/units" | wc -l | tr -d ' ')" "$(ls "$ROOT"/systemd/*.template | wc -l | tr -d ' ')"
eq "unset variables add no Environment line" "$(grep -Ec '^Environment=RIGFORGE_(STATE|LIB)=' "$D"/out/*.service | grep -vc ':0$')" "0"

echo "== units: split lib and state dirs =="
bundle "$D/lib"
mkdir -p "$D/state"
env -u RIGFORGE_HOME RIGFORGE_LIB="$D/lib" RIGFORGE_STATE="$D/state" bash "$ROOT/tests/state-lib-harness.sh" "$D/code" "$D/split" "$BIN"
for u in api control; do
    eq "$u unit loads config from the state dir" "$(grep -c "^LoadCredential=config:$D/state/config.json$" "$D/split/rigforge-$u.service")" "1"
    eq "$u unit loads its server from the lib dir" "$(grep -c "^LoadCredential=server:$D/lib/util/$u-server.py$" "$D/split/rigforge-$u.service")" "1"
done
eq "watchdog ExecStart is under the lib dir" "$(grep -c "^ExecStart=$D/lib/rigforge.sh watchdog$" "$D/split/rigforge-watchdog.service")" "1"
for u in rigforge-autotune rigforge-watchdog rigforge-api-refresh rigforge-control-apply rigforge-control-upgrade xmrig; do
    eq "$u unit gets the state dir in its environment" "$(grep -c "^Environment=RIGFORGE_STATE=$D/state$" "$D/split/$u.service")" "1"
    eq "$u unit gets the lib dir in its environment" "$(grep -c "^Environment=RIGFORGE_LIB=$D/lib$" "$D/split/$u.service")" "1"
done
eq "no unit references the unsplit code dir" "$(grep -l "$D/code" "$D"/split/*.service "$D"/split/*.path "$D"/split/*.timer 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== validation =="
for bad in 'rel/path' '/with space' "/new
line" '/pct%s'; do
    RIGFORGE_STATE="$bad" bash "$ROOT/rigforge.sh" version >/dev/null 2>&1
    eq "RIGFORGE_STATE=[$bad] is refused" "$?" "1"
    RIGFORGE_LIB="$bad" bash "$ROOT/rigforge.sh" version >/dev/null 2>&1
    eq "RIGFORGE_LIB=[$bad] is refused" "$?" "1"
done

echo "== state paths: default equals SCRIPT_DIR, override moves them =="
paths() {
    (
        unset RIGFORGE_STATE RIGFORGE_LIB
        [ -z "$2" ] || export RIGFORGE_STATE="$2"
        [ -z "$3" ] || export RIGFORGE_LIB="$3"
        source "$ROOT/rigforge.sh"
        SCRIPT_DIR="$1"
        printf '%s ' "$(_state_dir)" "$(_lib_dir)" "$(_worker_root_for_home DYNAMIC_HOME)"
    )
}
eq "default state, lib and worker root follow SCRIPT_DIR" "$(paths /x '' '')" "/x /x /x/data/worker "
eq "RIGFORGE_STATE moves state and the worker root only" "$(paths /x /s '')" "/s /x /s/data/worker "
eq "RIGFORGE_LIB moves lib only" "$(paths /x '' "$ROOT")" "/x $ROOT /x/data/worker "

echo "== RIGFORGE_STATE elsewhere: every state file lands only there =="
mkdir -p "$D/sx/lib" "$D/sx/st"
bundle "$D/sx/lib"
printf '{"pools":[{"url":"h:3333"}]}' >"$D/sx/st/config.json"
state_probe() {
    (
        export RIGFORGE_STATE="$D/sx/st"
        export RIGFORGE_LIB="$D/sx/lib"
        unset RIGFORGE_HOME
        source "$D/sx/lib/rigforge.sh"
        SCRIPT_DIR="$D/sx/lib"
        printf '%s\n' "$CONFIG_JSON" "$CONFIG_META_FILE" "$APPLIANCE_MARKER" "$(_worker_root_for_home DYNAMIC_HOME)"
        _writable_config_canonical() { printf '{}'; }
        REAL_USER=$(id -un)
        _writable_config_hash >/dev/null
        ls -A "$D/sx/st"
    )
}
probe=$(state_probe 2>&1)
has_line() { printf '%s\n' "$probe" | grep -Fxq "$1"; }
has_line "$D/sx/st/config.json" && pass "config.json is in the state dir" || fail "config.json is in the state dir" "$probe"
has_line "$D/sx/st/.rigforge-config-meta.json" && pass "provenance sidecar is in the state dir" || fail "provenance sidecar is in the state dir" "$probe"
has_line "$D/sx/st/.rigforge-appliance" && pass "appliance marker is in the state dir" || fail "appliance marker is in the state dir" "$probe"
has_line "$D/sx/st/data/worker" && pass "default worker root is in the state dir" || fail "default worker root is in the state dir" "$probe"
has_line ".rigforge-revision-key" && pass "revision key is written in the state dir" || fail "revision key is written in the state dir" "$probe"
eq "lib dir gained no revision key" "$(find "$D/sx/lib" -maxdepth 1 -name '.rigforge*' | wc -l | tr -d ' ')" "0"
if command -v flock >/dev/null; then
    mkdir -p "$D/sx/cs/spool" "$D/sx/cs/processing"
    chmod 700 "$D/sx/cs/processing"
    printf '{"DONATION":2}' >"$D/sx/cs/spool/pending-fedcba9876543210.json"
    committed=$(
        export RIGFORGE_STATE="$D/sx/st" RIGFORGE_LIB="$D/sx/lib"
        source "$D/sx/lib/rigforge.sh"
        OS_TYPE=Linux SCRIPT_DIR="$D/sx/lib" CONFIG_JSON="$D/sx/st/config.json" RIGFORGE_CONTROL_STATE="$D/sx/cs" RIGFORGE_CONTROL_PROCESSING="$D/sx/cs/processing"
        stat() { printf '0:0:700\n'; }
        _control_commit() { printf '%s' "$2" >"$D/sx/backups-arg"; }
        _control_fast_path_eligible() { return 1; }
        _control_do_apply() { return 0; }
        _sweep_config_backups() { :; }
        control_apply >"$D/sx/ca.log" 2>&1 </dev/null
        cat "$D/sx/backups-arg" 2>/dev/null
    )
    eq "control-apply hands config-backups under the state dir" "$committed" "$D/sx/st/config-backups"
else
    echo "  skip: control-apply backups dir needs flock (Linux CI carries it)"
fi
echo "== black-box: read-only lib, writable state =="
bundle "$D/ro"
chmod -R a-w "$D/ro"
mkdir -p "$D/rostate"
cp "$ROOT/config.minimal.json" "$D/rostate/config.json"
tree_hash() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1); }
before=$(tree_hash "$D/ro")
{ printf 'x\n' >"$D/ro/probe"; } 2>/dev/null && fail "lib dir is read-only" "wrote into it"
bb=$(env -u RIGFORGE_HOME PATH="$BIN:$PATH" RIGFORGE_LIB="$D/ro" RIGFORGE_STATE="$D/rostate" RIGFORGE_APPLIANCE=0 bash "$D/ro/rigforge.sh" backup 2>&1)
rc=$?
eq "backup exits 0 with a read-only lib dir" "$rc" "0"
[ "$rc" = 0 ] || printf '%s\n' "$bb" >&2
eq "backup archive lands under the state dir" "$(find "$D/rostate/backups" -name 'rigforge-backup-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')" "1"
bb=$(env -u RIGFORGE_HOME PATH="$BIN:$PATH" RIGFORGE_LIB="$D/ro" RIGFORGE_STATE="$D/rostate" RIGFORGE_APPLIANCE=0 bash "$D/ro/rigforge.sh" support-bundle 2>&1)
rc=$?
eq "support-bundle exits 0 with a read-only lib dir" "$rc" "0"
[ "$rc" = 0 ] || printf '%s\n' "$bb" >&2
eq "support tarball lands under the state dir" "$(find "$D/rostate" -maxdepth 1 -name 'rigforge-support-*.tar.gz' | wc -l | tr -d ' ')" "1"
eq "lib dir tree is unchanged" "$(tree_hash "$D/ro")" "$before"
eq "state dir holds only state" "$(ls -A "$D/rostate" | sort | tr '\n' ' ')" "backups config.json $(cd "$D/rostate" && ls rigforge-support-*.tar.gz | tr '\n' ' ')"

if [ "$FAIL" -ne 0 ]; then
    printf 'state-lib: %s failure(s)\n' "$FAIL" >&2
    exit 1
fi
echo "state-lib: all passed"
