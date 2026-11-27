#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
refresh() {
    (
        export RIGFORGE_HOME="$D"
        source "$SCRIPT"
        set +e
        OS_TYPE=Linux RIGFORGE_API_DATA="$1" _identity="$2"
        parse_config() { :; }
        _read_api_summary() { echo '{"hashrate":{"total":[100]}}'; }
        _api_rigforge_block() { echo '{"health":{"service_active":true},"watchdog":{},"tune":{"applied":true}}'; }
        _active_daemon_pool() { return 1; }
        _api_identity_json() { printf '%s' "$_identity"; }
        api_refresh >/dev/null 2>&1
        echo "$?"
    )
}

echo "== unit: api-refresh reports a failed write and leaves no temp files (#820) =="
mkdir -p "$D/bad"
check "a failed summary write exits nonzero" 1 "$(refresh "$D/bad" '{')"
check "the failed write leaves no temp files" "" "$(compgen -G "$D/bad/*.tmp.*" || true)"
check "health.json still publishes past the failed summary write" true "$(jq -r '.service_active' "$D/bad/health.json" 2>/dev/null)"
mkdir -p "$D/good"
check "a clean refresh exits zero" 0 "$(refresh "$D/good" '{}')"
check "a clean refresh publishes the authed summary" 100 "$(jq -r '.hashrate.total[0]' "$D/good/summary-authed.json" 2>/dev/null)"

echo "== black-box: restore snapshots the live config into config-backups/ first (#820) =="
H="$D/home"
mkdir -p "$H" "$D/arc"
printf '{ "DONATION": 3, "pools": [{"url": "h:3333"}] }\n' >"$H/config.json"
chmod 644 "$H/config.json"
printf '{ "DONATION": 7, "pools": [{"url": "h:3333"}] }\n' >"$D/arc/config.json"
tar -czf "$D/arc.tar.gz" -C "$D/arc" config.json
ino=$(inode "$H/config.json")
out=$(cd "$H" && RIGFORGE_HOME="$H" bash "$SCRIPT" restore -y "$D/arc.tar.gz" </dev/null 2>&1) && rc=0 || rc=$?
check "restore exits 0" 0 "$rc"
snap=$(ls "$H"/config-backups/config-*-restore-*.json 2>/dev/null || true)
check "restore wrote one snapshot" 1 "$(printf '%s' "$snap" | grep -c . || true)"
check "the snapshot holds the replaced config" 3 "$(jq -r '.DONATION' "$snap" 2>/dev/null)"
check "the snapshot is private to its owner" 600 "$(mode "$snap" 2>/dev/null)"
check "restore names the snapshot" y "$(case "$out" in *"Previous config saved to $snap"*) echo y ;; *) echo n ;; esac)"
check "the restored config is live" 7 "$(jq -r '.DONATION' "$H/config.json")"
check "the restored config is private to its owner" 600 "$(mode "$H/config.json")"
check "restore leaves no temp config behind" "" "$(compgen -G "$H/*.new.*" || true)"
check "restore renames a new file over config.json" y "$([ "$ino" != "$(inode "$H/config.json")" ] && echo y || echo n)"

echo "== unit: a config install writes a private temp file and renames it into place (#820) =="
printf '{ "DONATION": 9 }\n' >"$D/next.json"
ino=$(inode "$H/config.json")
rc=$(
    export RIGFORGE_HOME="$H"
    source "$SCRIPT"
    set +e
    umask 022
    chmod() {
        mode "$2" >"$D/chmod-seen"
        command chmod "$@"
    }
    _config_replace "$D/next.json"
    echo "$?"
)
check "a config install succeeds" 0 "$rc"
check "the installed config is live" 9 "$(jq -r '.DONATION' "$H/config.json")"
check "the temp file is private before chmod runs" 600 "$(cat "$D/chmod-seen" 2>/dev/null)"
check "a config install replaces the inode" y "$([ "$ino" != "$(inode "$H/config.json")" ] && echo y || echo n)"

echo "== black-box: restore refuses to overwrite when it cannot snapshot (#820) =="
H2="$D/home2"
mkdir -p "$H2"
printf '{ "DONATION": 3, "pools": [{"url": "h:3333"}] }\n' >"$H2/config.json"
: >"$H2/config-backups"
before=$(cksum <"$H2/config.json")
(cd "$H2" && RIGFORGE_HOME="$H2" bash "$SCRIPT" restore -y "$D/arc.tar.gz" </dev/null >/dev/null 2>&1) && rc=0 || rc=$?
check "an unwritable snapshot directory fails the restore" 1 "$rc"
check "the live config is untouched" "$before" "$(cksum <"$H2/config.json")"

echo "== unit: a failed config install keeps the live file and cleans its temp (#820) =="
rc=$(
    export RIGFORGE_HOME="$H2"
    source "$SCRIPT"
    set +e
    _config_replace "$D/missing.json" 2>/dev/null
    echo "$?"
)
check "an unreadable source fails the install" 1 "$rc"
check "the live config survives a failed install" "$before" "$(cksum <"$H2/config.json")"
check "a failed install leaves no temp config" "" "$(compgen -G "$H2/*.new.*" || true)"
exit "$fail"
