#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D"
STUBS="$D/stubs"
mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\ncase "$*" in *rev-parse*) echo "$XMRIG_COMMIT" ;; *clone*) mkdir -p xmrig.new/src; printf "constexpr const int kDefaultDonateLevel = 1;\\nconstexpr const int kMinimumDonateLevel = 1;\\n" >xmrig.new/src/donate.h ;; esac\n' >"$STUBS/git"
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/sudo"
for c in cmake nproc sysctl; do printf '#!/usr/bin/env bash\necho 1\n' >"$STUBS/$c"; done
printf '#!/usr/bin/env bash\nmkdir -p build\n' >"$STUBS/make"
printf '#!/usr/bin/env bash\necho "Model name: stub"\n' >"$STUBS/lscpu"
chmod +x "$STUBS"/*
GEN='RIGFORGE_APPLIANCE=0 POOLS_JSON=[] ACCESS_TOKEN= CPUINFO=/dev/null LOGROTATE_DIR='"$D"'/lr REAL_USER=x'

fail=0
for stage in git make; do
    W="$D/$stage"
    mkdir -p "$W/xmrig/build" "$D/fail-$stage"
    printf 'good\n' >"$W/xmrig/build/xmrig"
    printf '{}\n' >"$W/xmrig/build/config.json"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$D/fail-$stage/$stage"
    chmod +x "$D/fail-$stage/$stage"
    for attempt in 1 2 3 4; do
        set +e
        (
            cd "$W"
            source "$SCRIPT"
            OS_TYPE=Linux
            WORKER_ROOT="$W"
            DONATION=1
            eval "$GEN"
            XMRIG_REBUILD=true
            export XMRIG_COMMIT=ABC
            PATH="$D/fail-$stage:$STUBS:$PATH"
            prepare_workspace >/dev/null 2>&1
            compile_xmrig >/dev/null 2>&1
        )
        rc=$?
        set -e
        [ "$rc" != 0 ] || {
            echo "FAIL: $stage failure attempt $attempt exited 0"
            fail=1
        }
    done
    [ "$(cat "$W/xmrig/build/xmrig")" = good ] || {
        echo "FAIL: $stage failures lost the live binary"
        fail=1
    }
    [ "$(cat "$W/xmrig/build/config.json")" = '{}' ] || {
        echo "FAIL: $stage failures lost the live config"
        fail=1
    }
    [ -z "$(find "$W" -maxdepth 1 -name 'xmrig-*')" ] || {
        echo "FAIL: $stage failures archived the live tree"
        fail=1
    }
done

W="$D/ok"
mkdir -p "$W/xmrig/build"
printf 'good\n' >"$W/xmrig/build/xmrig"
(
    cd "$W"
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$W"
    DONATION=1
    eval "$GEN"
    XMRIG_REBUILD=true
    export XMRIG_COMMIT=ABC
    PATH="$STUBS:$PATH"
    prepare_workspace >/dev/null 2>&1
    compile_xmrig >/dev/null 2>&1
) || {
    echo "FAIL: successful rebuild exited non-zero"
    fail=1
}
[ "$(cat "$W/xmrig/.rigforge-donate-min")" = 0 ] || {
    echo "FAIL: successful rebuild wrote no donation marker"
    fail=1
}
[ -n "$(find "$W" -maxdepth 1 -name 'xmrig-*')" ] || {
    echo "FAIL: successful rebuild did not archive the old tree"
    fail=1
}
[ ! -e "$W/xmrig.new" ] || {
    echo "FAIL: staging dir left behind"
    fail=1
}
jq -e . "$W/xmrig/build/config.json" >/dev/null || {
    echo "FAIL: activated build has no valid configuration"
    fail=1
}
[ "$(stat -c %a "$W/xmrig/build/config.json" 2>/dev/null || stat -f %Lp "$W/xmrig/build/config.json")" = 600 ] || {
    echo "FAIL: activated configuration is not owner-only"
    fail=1
}

W="$D/badcfg"
mkdir -p "$W/xmrig/build"
printf 'good\n' >"$W/xmrig/build/xmrig"
printf '{"live":true}\n' >"$W/xmrig/build/config.json"
set +e
(
    cd "$W"
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$W"
    DONATION=1
    eval "$GEN"
    POOLS_JSON='not json'
    XMRIG_REBUILD=true
    export XMRIG_COMMIT=ABC
    PATH="$STUBS:$PATH"
    prepare_workspace >/dev/null 2>&1
    compile_xmrig >/dev/null 2>&1
)
rc=$?
set -e
[ "$rc" != 0 ] || {
    echo "FAIL: configuration failure exited 0"
    fail=1
}
[ "$(cat "$W/xmrig/build/xmrig")" = good ] && [ "$(cat "$W/xmrig/build/config.json")" = '{"live":true}' ] || {
    echo "FAIL: configuration failure lost the live pair"
    fail=1
}
[ -z "$(find "$W" -maxdepth 1 -name 'xmrig-*')" ] || {
    echo "FAIL: configuration failure archived the live tree"
    fail=1
}

W="$D/killed"
mkdir -p "$W/xmrig/build" "$D/kill-mv"
printf 'good\n' >"$W/xmrig/build/xmrig"
printf '{"live":true}\n' >"$W/xmrig/build/config.json"
printf '#!/usr/bin/env bash\n[ "$*" = "xmrig.new xmrig" ] && kill -9 $PPID\nexec /bin/mv "$@"\n' >"$D/kill-mv/mv"
chmod +x "$D/kill-mv/mv"
set +e
(
    cd "$W"
    source "$SCRIPT"
    OS_TYPE=Linux
    WORKER_ROOT="$W"
    DONATION=1
    eval "$GEN"
    XMRIG_REBUILD=true
    export XMRIG_COMMIT=ABC
    PATH="$D/kill-mv:$STUBS:$PATH"
    prepare_workspace >/dev/null 2>&1
    compile_xmrig >/dev/null 2>&1
)
rc=$?
set -e
[ "$rc" != 0 ] && [ ! -d "$W/xmrig" ] && [ -f "$W/xmrig.swap" ] || {
    echo "FAIL: could not interrupt the swap between its renames"
    fail=1
}
(
    cd "$W"
    source "$SCRIPT"
    WORKER_ROOT="$W"
    decide_rebuild() { :; }
    _recover_xmrig_swap >/dev/null 2>&1
)
jq -e . "$W/xmrig/build/config.json" >/dev/null 2>&1 && [ ! -e "$W/xmrig.swap" ] && [ ! -e "$W/xmrig.new" ] || {
    echo "FAIL: interrupted swap did not recover a valid live pair"
    fail=1
}

W="$D/killed-no-new"
mkdir -p "$W/xmrig-old/build"
printf 'good\n' >"$W/xmrig-old/build/xmrig"
printf 'xmrig-old\n' >"$W/xmrig.swap"
(
    cd "$W"
    source "$SCRIPT"
    WORKER_ROOT="$W"
    decide_rebuild() { :; }
    _recover_xmrig_swap >/dev/null 2>&1
)
[ "$(cat "$W/xmrig/build/xmrig")" = good ] && [ ! -e "$W/xmrig.swap" ] || {
    echo "FAIL: interrupted swap without a staged build did not restore the archive"
    fail=1
}

[ "$fail" = 0 ] || exit 1
echo "failed rebuilds keep the live miner; a good rebuild swaps in with a valid config; an interrupted swap recovers: PASS"
