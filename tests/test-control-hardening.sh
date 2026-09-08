#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
command -v flock >/dev/null || exit 0 # Linux-only consumer; Linux CI carries the coverage.
SCRIPT="$1"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
source "$SCRIPT"

export RIGFORGE_CONTROL_LOCK="$D/control.lock"
flock -x "$RIGFORGE_CONTROL_LOCK" sh -c 'touch "$1"; while [ ! -e "$2" ]; do sleep .02; done' _ "$D/locked" "$D/release" &
HOLDER=$!
while [ ! -e "$D/locked" ]; do
    kill -0 "$HOLDER" 2>/dev/null || {
        wait "$HOLDER"
        exit 1
    }
    sleep .02
done
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

rm -rf "$D/processing"
mkdir -m 700 "$D/processing"
printf '{"DONATION":2}' >"$D/state/spool/pending-fedcba9876543210.json"
stat() { printf '0:0:700\n'; }
_control_commit() { [ "$1" = "$D/processing/fedcba9876543210.json" ] && [ ! -e "$D/state/spool/pending-fedcba9876543210.json" ] && printf 'committed backup'; }
_control_fast_path_eligible() { return 1; }
_control_do_apply() { return 0; }
_sweep_config_backups() { :; }
OS_TYPE=Linux SCRIPT_DIR="$D" CONFIG_JSON="$D/config.json" RIGFORGE_CONTROL_STATE="$D/state" RIGFORGE_CONTROL_PROCESSING="$D/processing" control_apply >/dev/null 2>&1
[ "$(jq -r .status "$D/state/status.json")" = applied ]
[ ! -e "$D/processing/fedcba9876543210.json" ]

export RIGFORGE_CONTROL_PROCESSING="$D/processing"
for kind in directory fifo; do
    src="$D/state/spool/pending-$kind.json"
    [ "$kind" = directory ] && mkdir "$src" || mkfifo "$src"
    ! _control_claim_staged "$src" "$kind" >/dev/null
done
printf '{"DONATION":2}' >"$D/state/spool/pending-frozen.json"
exec 7<>"$D/state/spool/pending-frozen.json"
frozen=$(_control_claim_staged "$D/state/spool/pending-frozen.json" frozen)
printf '{"DONATION":99}' >&7
exec 7>&-
[ "$(jq -r .DONATION "$frozen")" = 2 ]
