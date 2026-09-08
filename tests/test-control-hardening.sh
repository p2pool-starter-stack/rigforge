#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
SCRIPT="$1"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
source "$SCRIPT"

export RIGFORGE_CONTROL_LOCK="$D/control.lock"
flock -x "$RIGFORGE_CONTROL_LOCK" sh -c 'touch "$1"; while [ ! -e "$2" ]; do sleep .02; done' _ "$D/locked" "$D/release" &
HOLDER=$!
while [ ! -e "$D/locked" ]; do sleep .02; done
RIGFORGE_HOME="$D" bash "$SCRIPT" control-apply >/dev/null 2>&1 &
P1=$!
RIGFORGE_HOME="$D" bash "$SCRIPT" control-upgrade >/dev/null 2>&1 &
P2=$!
sleep .1
kill -0 "$P1" "$P2"
touch "$D/release"
wait "$HOLDER"
set +e
wait "$P1"
R1=$?
wait "$P2"
R2=$?
set -e
[ "$R1" -ne 0 ] && [ "$R2" -ne 0 ]

mkdir -p "$D/state/spool" "$D/target"
printf '1.0.0' >"$D/VERSION"
printf '{"pools":[{"url":"h:3333"}]}' >"$D/config.json"
printf '{"version":"v9.9.9"}' >"$D/state/spool/upgrade-abc123def4567890.json"
before=$(ls -ld "$D/target")
ln -s "$D/target" "$D/processing"
OS_TYPE=Linux SCRIPT_DIR="$D" CONFIG_JSON="$D/config.json" RIGFORGE_CONTROL_STATE="$D/state" RIGFORGE_CONTROL_PROCESSING="$D/processing" control_upgrade >/dev/null 2>&1
[ "$(jq -r .status "$D/state/status.json")" = failed ]
[ "$before" = "$(ls -ld "$D/target")" ]

rm "$D/processing"
mkdir -m 700 "$D/processing"
for stat_result in 0:0:755 1:0:700; do
    printf '{"version":"v9.9.9"}' >"$D/state/spool/upgrade-abc123def4567890.json"
    stat() { printf '%s\n' "$stat_result"; }
    OS_TYPE=Linux SCRIPT_DIR="$D" CONFIG_JSON="$D/config.json" RIGFORGE_CONTROL_STATE="$D/state" RIGFORGE_CONTROL_PROCESSING="$D/processing" control_upgrade >/dev/null 2>&1
    [ "$(jq -r .status "$D/state/status.json")" = failed ]
done
