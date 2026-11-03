#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D" RIGFORGE_REVISION_KEY="$D/key"
source "$SCRIPT"
set +e
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
PASS=hunter2
_writable_config_canonical() { jq -Sn --arg p "$PASS" '{pools: [{url: "h:3333", pass: $p}], DONATION: 0}'; }
masked_guess() {
    PASS="$1" _writable_config_canonical | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16
}

echo "== unit: public revision is keyed to a local secret (#629) =="
rev=$(_writable_config_hash)
check "revision is present" y "$([ ${#rev} = 16 ] && echo y || echo n)"
check "an offline guess of the true password does not reproduce the revision" differs "$([ "$rev" = "$(masked_guess hunter2)" ] && echo reproduced || echo differs)"
check "the key file is private to its owner" 600 "$(stat -c %a "$RIGFORGE_REVISION_KEY" 2>/dev/null || stat -f %Lp "$RIGFORGE_REVISION_KEY")"
check "unchanged content keeps its revision across processes" "$rev" "$(bash -c 'source "$1"; _writable_config_canonical() { jq -Sn --arg p hunter2 "{pools: [{url: \"h:3333\", pass: \$p}], DONATION: 0}"; }; _writable_config_hash' _ "$SCRIPT")"
PASS=hunter3
check "credential rotation changes the revision" differs "$([ "$rev" = "$(_writable_config_hash)" ] && echo same || echo differs)"
PASS=hunter2
saved=$(cat "$RIGFORGE_REVISION_KEY")
rm -f "$RIGFORGE_REVISION_KEY"
check "a different local key yields a different revision" differs "$([ "$rev" = "$(_writable_config_hash)" ] && echo same || echo differs)"
printf '%s' "$saved" >"$RIGFORGE_REVISION_KEY"
check "restoring the key restores the revision" "$rev" "$(_writable_config_hash)"
rm -f "$RIGFORGE_REVISION_KEY"
: >"$RIGFORGE_REVISION_KEY"
check "an empty key file is replaced, not fatal" 16 "$(_writable_config_hash | tr -d '\n' | wc -c | tr -d ' ')"
rm -f "$RIGFORGE_REVISION_KEY"
ln -s "$D/elsewhere" "$RIGFORGE_REVISION_KEY"
check "a symlinked key file is refused" "" "$(_writable_config_hash 2>/dev/null)"
check "a symlinked key file is not written through" n "$([ -e "$D/elsewhere" ] && echo y || echo n)"
exit "$fail"
