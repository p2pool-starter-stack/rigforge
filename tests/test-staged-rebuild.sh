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
chmod +x "$STUBS"/*

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
[ "$fail" = 0 ] || exit 1
echo "failed rebuilds keep the live miner; a good rebuild swaps in: PASS"
