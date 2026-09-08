#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
SCRIPT="$1"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
source "$SCRIPT"

RIGFORGE_CONTROL_LOCK="$D/control.lock"
_with_control_lock bash -c 'touch "$1/first"; while [ ! -e "$1/release" ]; do sleep .02; done' _ "$D" &
P1=$!
while [ ! -e "$D/first" ]; do sleep .02; done
_with_control_lock touch "$D/second" &
P2=$!
sleep .1
[ ! -e "$D/second" ]
touch "$D/release"
wait "$P1" "$P2"
[ -e "$D/second" ]

mkdir -p "$D/state/spool" "$D/target"
printf '1.0.0' >"$D/VERSION"
printf '{"pools":[{"url":"h:3333"}]}' >"$D/config.json"
printf '{"version":"v9.9.9"}' >"$D/state/spool/upgrade-abc123def4567890.json"
before=$(ls -ld "$D/target")
ln -s "$D/target" "$D/processing"
OS_TYPE=Linux SCRIPT_DIR="$D" CONFIG_JSON="$D/config.json" RIGFORGE_CONTROL_STATE="$D/state" RIGFORGE_CONTROL_PROCESSING="$D/processing" control_upgrade >/dev/null 2>&1
[ "$(jq -r .status "$D/state/status.json")" = failed ]
[ "$before" = "$(ls -ld "$D/target")" ]
