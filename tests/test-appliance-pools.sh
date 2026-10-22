#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
SCRIPT="$1"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D" RIGFORGE_APPLIANCE=1
source "$SCRIPT"
_fsync_paths() { :; }
printf '{"pools":[{"url":"pool.example:3333"}],"DONATION":1}' >"$CONFIG_JSON"
cp "$CONFIG_JSON" "$D/before.json"
for change in '{"pools":[{"url":"other.example:3333"}]}' '{"pools":null}' '{"pools":[{"url":"pool.example:3333"}],"DONATION":2}'; do
    printf '%s' "$change" >"$D/staged.json"
    rc=0
    result=$(_control_commit "$D/staged.json" "$D/backups") || rc=$?
    [ "$rc" = 1 ]
    [[ "$result" == 'rejected appliance-pools-read-only:'* ]]
    [[ "$result" == *rig.json* ]]
    cmp -s "$CONFIG_JSON" "$D/before.json"
    [ ! -e "$D/backups" ]
done
printf '{"DONATION":2}' >"$D/staged.json"
_control_commit "$D/staged.json" "$D/backups" >/dev/null
[ "$(jq -r .DONATION "$CONFIG_JSON")" = 2 ]
RIGFORGE_APPLIANCE=0
printf '{"pools":[{"url":"other.example:3333"}]}' >"$D/staged.json"
_control_commit "$D/staged.json" "$D/backups" >/dev/null
[ "$(jq -r '.pools[0].url' "$CONFIG_JSON")" = other.example:3333 ]
bash "$(dirname "${BASH_SOURCE[0]}")/test-appliance-pool-control.sh"
printf 'appliance pool policy: PASS\n'
