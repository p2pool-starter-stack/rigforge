#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
STUBS="$D/stubs"
BAD="$D/bad"
mkdir -p "$STUBS" "$BAD"
printf '#!/usr/bin/env bash\necho "Model name: Test CPU"\n' >"$STUBS/lscpu"
printf '#!/usr/bin/env bash\necho 8\n' >"$STUBS/nproc"
printf '#!/usr/bin/env bash\necho rigbox\n' >"$STUBS/hostname"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$STUBS/sudo"
printf '#!/usr/bin/env bash\nprintf %%s "{\\"pools\\":[{\\"ur"\nexit 5\n' >"$BAD/jq"
printf '#!/usr/bin/env bash\ncase " $* " in *" $JQ_FAIL "*) exit 5 ;; esac\nexec "%s" "$@"\n' "$(command -v jq)" >"$D/jqfail"
mkdir "$D/pf"
cp "$D/jqfail" "$D/pf/jq"
chmod +x "$STUBS"/* "$BAD/jq" "$D/pf/jq"
REAL_JQ=$(command -v jq)

render() {
    (
        cd "$1"
        source "$SCRIPT"
        OS_TYPE=Linux WORKER_ROOT="$1" LOGROTATE_DIR="$1" ACCESS_TOKEN=t DONATION=1 THREADS_CAP="${3:-}"
        POOLS_JSON='[{"url":"h:3333"}]'
        set +e
        if PATH="$2:$STUBS:$PATH" generate_xmrig_config >/dev/null 2>&1; then echo 0; else echo 1; fi
    )
}

fail=0
check() {
    [ "$2" = "$3" ] || {
        echo "FAIL: $1 (expected [$3], got [$2])"
        fail=1
    }
}

W="$D/partial"
mkdir "$W"
printf '{"_orig":true}\n' >"$W/config.json"
check "partial-writing jq under a guarded caller returns failure" "$(render "$W" "$BAD")" 1
check "last good config.json survives a partial write" "$("$REAL_JQ" -r '._orig' "$W/config.json")" true
check "failed render leaves no temp file" "$(find "$W" -name 'config.json.*' | wc -l | tr -d ' ')" 0

W="$D/overlay"
mkdir "$W"
printf '{"_orig":true}\n' >"$W/config.json"
printf '{not json\n' >"$W/tune-overrides.json"
check "unreadable tune overlay returns failure" "$(render "$W" "$D")" 1
check "last good config.json survives a bad overlay" "$("$REAL_JQ" -r '._orig' "$W/config.json")" true

for mode in "--argjson cap:clamp" "-e:validation"; do
    W="$D/${mode#*:}"
    mkdir "$W"
    printf '{"_orig":true}\n' >"$W/config.json"
    export JQ_FAIL="${mode%%:*}"
    check "failed ${mode#*:} returns failure" "$(render "$W" "$D/pf" 4)" 1
    check "last good config.json survives a failed ${mode#*:}" "$("$REAL_JQ" -r '._orig' "$W/config.json")" true
    unset JQ_FAIL
done

mkdir "$D/pc"
printf '#!/usr/bin/env bash\ncase "$1" in config.json) [ -z "${CAT_SRC_FAIL:-}" ] || exit 5 ;; *.bak) [ -z "${CAT_BAK_FAIL:-}" ] || exit 5 ;; config.json.*) head -c 20 "$1"; exit "$CAT_RC" ;; esac\nexec "%s" "$@"\n' "$(command -v cat)" >"$D/pc/cat"
chmod +x "$D/pc/cat"
for CAT_RC in 28 0; do
    export CAT_RC
    W="$D/short$CAT_RC"
    mkdir "$W"
    printf '{"_orig":true}\n' >"$W/config.json"
    chmod 644 "$W/config.json"
    inode_before="$(ls -i "$W/config.json" | awk '{print $1}')"
    check "short final write (exit $CAT_RC) returns failure" "$(render "$W" "$D/pc")" 1
    check "last good config.json is restored after a short final write (exit $CAT_RC)" "$("$REAL_JQ" -r '._orig' "$W/config.json")" true
    check "restore keeps the live inode (exit $CAT_RC)" "$(ls -i "$W/config.json" | awk '{print $1}')" "$inode_before"
    check "short final write leaves no temp or backup file (exit $CAT_RC)" "$(find "$W" -name 'config.json.*' | wc -l | tr -d ' ')" 0
done

W="$D/empty"
mkdir "$W"
: >"$W/config.json"
check "short final write over an empty config returns failure" "$(CAT_RC=28 render "$W" "$D/pc")" 1
check "an empty prior config.json is restored, not deleted" "$([ -f "$W/config.json" ] && wc -c <"$W/config.json" | tr -d ' ')" 0

W="$D/absent"
mkdir "$W"
check "short final write with no prior config returns failure" "$(CAT_RC=28 render "$W" "$D/pc")" 1
check "no partial config.json is left when there was none before" "$(find "$W" -name 'config.json*' | wc -l | tr -d ' ')" 0

W="$D/nobackup"
mkdir "$W"
printf '{"_orig":true}\n' >"$W/config.json"
check "failed backup returns failure" "$(CAT_RC=28 CAT_SRC_FAIL=1 render "$W" "$D/pc")" 1
check "failed backup leaves the live config untouched" "$("$REAL_JQ" -r '._orig' "$W/config.json") $(find "$W" -name 'config.json.*' | wc -l | tr -d ' ')" "true 0"

W="$D/norestore"
mkdir "$W"
printf '{"_orig":true}\n' >"$W/config.json"
out="$(cd "$W" && umask 022 && source "$SCRIPT" && OS_TYPE=Linux WORKER_ROOT="$W" LOGROTATE_DIR="$W" ACCESS_TOKEN=t DONATION=1 POOLS_JSON='[{"url":"h:3333"}]' && PATH="$D/pc:$STUBS:$PATH" CAT_RC=28 CAT_BAK_FAIL=1 generate_xmrig_config 2>&1)" && rc=0 || rc=1
check "failed restore returns failure" "$rc" 1
check "failed restore does not claim the config is unchanged" "$(printf '%s' "$out" | grep -c 'previous config.json is unchanged')" 0
bak="$(find "$W" -name 'config.json.*.bak')"
check "failed restore keeps the last good copy it names" "$("$REAL_JQ" -r '._orig' "$bak") $(printf '%s' "$out" | grep -c "previous copy is $bak")" "true 1"
check "the kept backup is owner-only under a permissive umask" "$(stat -c '%a' "$bak" 2>/dev/null || stat -f '%Lp' "$bak")" 600

W="$D/shared-safeguard"
mkdir "$W"
printf '{"_orig":true}\n' >"$W/config.json"
printf '{"cpu":4}\n' >"$W/tune-overrides.json"
check "failed shared-host safeguard render returns failure" "$(SHARED_HOST=true render "$W" "$D")" 1
check "last good config.json survives a failed shared-host safeguard render" "$("$REAL_JQ" -r '._orig' "$W/config.json")" true
check "failed shared-host safeguard render leaves no secret-bearing temp file" "$(find "$W" -name 'config.json.*' | wc -l | tr -d ' ')" 0
check "failed shared-host safeguard render writes no apply stamp" "$(find "$W" -name '.rigforge-apply.json*' | wc -l | tr -d ' ')" 0

W="$D/ok"
mkdir "$W"
printf '{"_orig":true}\n' >"$W/config.json"
inode_before="$(ls -i "$W/config.json" | awk '{print $1}')"
check "successful render returns success" "$(render "$W" "$D" 4)" 0
check "successful render replaces the config" "$("$REAL_JQ" -r '.cpu.rx' "$W/config.json")" 4
check "successful render is owner-only" "$(stat -c '%a' "$W/config.json" 2>/dev/null || stat -f '%Lp' "$W/config.json")" 600

check "successful render keeps the live file's inode" "$(ls -i "$W/config.json" | awk '{print $1}')" "$inode_before"

[ "$fail" = 0 ] && echo "config-atomic: all passed"
exit "$fail"
