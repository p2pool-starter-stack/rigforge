#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT=${1:-"$ROOT/rigforge.sh"}
PASS=0
FAIL=0
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"
}
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi; }
assert_has() {
    case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3" "missing [$2] in [$1]" ;;
    esac
}

echo "== unit: RIGFORGE_LIB read-only with a writable RIGFORGE_STATE (#781) =="

T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
LIB="$T/tree"
STATE="$T/state"
STUBS="$T/stubs"
mkdir -p "$LIB" "$STATE" "$STUBS"
cp "$ROOT/rigforge.sh" "$ROOT/VERSION" "$LIB/"
cp -R "$ROOT/util" "$ROOT/systemd" "$LIB/"
cat >"$STUBS/curl" <<'EOF'
#!/bin/sh
printf '{"tag_name":"v99.99.99","html_url":"https://example.invalid/release"}'
EOF
chmod +x "$STUBS/curl"

_tree_hash() { (cd "$LIB" && find . -type f | sort | xargs cksum) | cksum; }
_rig() {
    out=$(RIGFORGE_LIB="$LIB" RIGFORGE_STATE="$STATE" PATH="$STUBS:$PATH" bash "$SCRIPT" "$@" 2>&1) || rc=$?
}

V=$(tr -d '[:space:]' <"$ROOT/VERSION")
H1=$(_tree_hash)
chmod -R a-w "$LIB"

rc=0
_rig setup --dry-run
assert_eq "$rc" 0 "setup --dry-run exits 0 against a read-only lib dir"
assert_has "$out" "would create $STATE/config.json" "setup --dry-run places config.json in the state dir"

printf '{"pools":[{"url":"pool.invalid:3333","user":"rig1","password":"-"}]}\n' >"$STATE/config.json"

rc=0
_rig upgrade --check
assert_eq "$rc" 0 "upgrade --check exits 0 against a read-only lib dir"
assert_has "$out" "A newer RigForge is available: 99.99.99" "upgrade --check reads VERSION from the lib dir"

rc=0
_rig doctor
assert_has "$out" "RigForge $V" "doctor prints the version read from the lib dir"

rc=0
_rig support-bundle
assert_eq "$rc" 0 "support-bundle exits 0 against a read-only lib dir"
archives=$(ls "$STATE"/rigforge-support-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$archives" "1" "support-bundle writes its archive into the state dir"

assert_eq "$(_tree_hash)" "$H1" "the lib tree is byte-identical after all four verbs"

echo "lib/state split: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
