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
