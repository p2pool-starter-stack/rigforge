#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2317
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
D=$(cd -P "$D" && pwd -P)
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
has() { case "$2" in *"$3"*) check "$1" y y ;; *) check "$1" "[$3] present" "$2" ;; esac }
lacks() { case "$2" in *"$3"*) check "$1" "[$3] absent" "$2" ;; *) check "$1" y y ;; esac }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
kind() { if [ -L "$1" ]; then echo link; elif [ -f "$1" ]; then echo file; elif [ -e "$1" ]; then echo other; else echo none; fi; }

harness() {
    source "$SCRIPT"
    set +eu
    OS_TYPE=Linux
    REAL_USER=rfop
    SCRIPT_DIR="$D/tree"
    LOG="$D/calls.log"
    : >"$LOG"
    TREE_UNSAFE=0
    UNSAFE_CHAIN=""
    ID_U=0
    CHOWN_RC=0
    _rg_tree_unsafe() { [ "$TREE_UNSAFE" = 1 ] && echo "tree"; }
    _rg_chain_unsafe() {
        case " $UNSAFE_CHAIN " in *" $1 "*)
            echo "$1"
            return 0
            ;;
        esac
        return 1
    }
    id() { if [ "${1:-}" = -u ]; then echo "$ID_U"; else command id "$@"; fi; }
    sudo() {
        case "$1" in
        chown)
            echo "chown ${*:2}" >>"$LOG"
            [ "$2" != -R ] || return "$CHOWN_RC"
            ;;
        *) "$@" ;;
        esac
    }
}

worker() {
    rm -rf "$D/data" "$D/victims"
    mkdir -p "$D/data/worker/xmrig/build" "$D/data/worker/xmrig/src/a" "$D/victims"
    printf 'v1' >"$D/victims/one"
    printf 'v2' >"$D/victims/two"
    printf 'v3' >"$D/victims/three"
    printf '{}' >"$D/data/worker/tune-overrides.json"
    chmod 666 "$D/data/worker/tune-overrides.json"
    ln -s "$D/victims/one" "$D/data/worker/watchdog.thermal-hold"
    ln -s "$D/victims/two" "$D/data/worker/xmrig/build/config.json"
    ln -s "$D/victims/three" "$D/data/worker/xmrig/src/a/deep"
}

echo "== unit: the worker folder stays root-owned only on a root-owned tree =="
out=$(
    harness
    r() { if _rg_keeps_root "$@"; then echo keep; else echo hand; fi; }
    echo "linux=$(r "$D/data")"
    TREE_UNSAFE=1
    echo "tree=$(r "$D/data")"
    TREE_UNSAFE=0 UNSAFE_CHAIN="$D/other"
    echo "chain=$(r "$D/data" "$D/other")"
    echo "nochain=$(r)"
    OS_TYPE=Darwin UNSAFE_CHAIN=""
    echo "darwin=$(r "$D/data")"
)
has "a root-owned tree and folder chain keep the folder" "$out" "linux=keep"
has "a tree a non-root user can write hands it over" "$out" "tree=hand"
has "any listed folder chain a non-root user can change hands it over" "$out" "chain=hand"
has "no folder to check still needs the tree" "$out" "nochain=keep"
has "macOS keeps handing it over" "$out" "darwin=hand"

echo "== unit: root takes the worker folder back and removes every link inside it =="
worker
out=$(
    harness
    XMRIG_REBUILD=false
    WORKER_ROOT="$D/data/worker"
    _rg_claim_worker 2>&1
    echo "rc=$?"
    echo "rebuild=$XMRIG_REBUILD"
    cat "$LOG"
)
has "the claim succeeds" "$out" "rc=0"
has "the folder is chowned to root recursively" "$out" "chown -R 0:0 $D/data/worker"
lacks "nothing is handed to the operator" "$out" "rfop"
check "a link at the top of the folder is removed" none "$(kind "$D/data/worker/watchdog.thermal-hold")"
check "a link three levels down is removed" none "$(kind "$D/data/worker/xmrig/build/config.json")"
check "a link four levels down is removed" none "$(kind "$D/data/worker/xmrig/src/a/deep")"
has "the removed links are named" "$out" "removed symbolic links inside $D/data/worker: "
has "including the deepest one" "$out" "$D/data/worker/xmrig/src/a/deep"
has "with no miner binary no rebuild is asked for" "$out" "rebuild=false"
check "files the links named are untouched" "v1 v2 v3" "$(cat "$D/victims/one") $(cat "$D/victims/two") $(cat "$D/victims/three")"
check "group and world write bits are removed" 644 "$(mode "$D/data/worker/tune-overrides.json")"
check "the folder itself is kept" y "$([ -d "$D/data/worker" ] && echo y)"

worker
printf 'bin' >"$D/data/worker/xmrig/build/xmrig"
printf 'pin' >"$D/data/worker/xmrig/.rigforge-commit"
[ "$(id -u)" -ne 0 ] || chown 65534 "$D/data/worker/xmrig/build/xmrig"
out=$(
    harness
    XMRIG_REBUILD=false
    WORKER_ROOT="$D/data/worker"
    _rg_claim_worker 2>&1
    echo "rebuild=$XMRIG_REBUILD"
)
has "a miner binary another user owns asks for a rebuild" "$out" "rebuild=true"
has "and says so" "$out" "was not root-owned, so the next setup or upgrade rebuilds it"
check "and drops the build marker so a later setup rebuilds too" none "$(kind "$D/data/worker/xmrig/.rigforge-commit")"
if [ "$(id -u)" -eq 0 ]; then
    worker
    printf 'bin' >"$D/data/worker/xmrig/build/xmrig"
    printf 'pin' >"$D/data/worker/xmrig/.rigforge-commit"
    out=$(
        harness
        XMRIG_REBUILD=false
        WORKER_ROOT="$D/data/worker"
        _rg_claim_worker 2>&1
        echo "rebuild=$XMRIG_REBUILD"
    )
    has "a root-owned miner binary asks for no rebuild" "$out" "rebuild=false"
    check "and keeps the build marker" file "$(kind "$D/data/worker/xmrig/.rigforge-commit")"
fi

worker
ln -s "$D/data/worker" "$D/data/current"
out=$(
    harness
    WORKER_ROOT="$D/data/current"
    _rg_claim_worker
    echo "rc=$?"
    cat "$LOG"
)
has "a worker root reached through a link is claimed at its target" "$out" "chown -R 0:0 $D/data/worker"
check "the link that names the worker root is kept" link "$(kind "$D/data/current")"
check "links inside the target are removed" none "$(kind "$D/data/worker/watchdog.thermal-hold")"

worker
mkdir -p "$D/opdir"
ln -s "$D/data/worker" "$D/opdir/worker"
out=$(
    harness
    UNSAFE_CHAIN="$D/opdir"
    WORKER_ROOT="$D/opdir/worker"
    _rg_claim_worker
    echo "rc=$?"
    cat "$LOG"
)
has "a link to the worker root in a folder another user can change is not claimed" "$out" "rc=1"
lacks "and nothing is chowned through it" "$out" "chown"
check "and the target's links stay" link "$(kind "$D/data/worker/watchdog.thermal-hold")"
rm -f "$D/opdir/worker"
rmdir "$D/opdir"

worker
mkdir -p "$D/elsewhere"
mv "$D/data/worker" "$D/elsewhere/worker"
ln -s "$D/elsewhere/worker" "$D/data/worker"
out=$(
    harness
    UNSAFE_CHAIN="$D/elsewhere"
    WORKER_ROOT="$D/data/worker"
    _rg_claim_worker
    echo "rc=$?"
    cat "$LOG"
)
has "a link target in a folder a non-root user can change is not claimed" "$out" "rc=1"
lacks "and nothing is chowned there" "$out" "chown"
check "and its links stay" link "$(kind "$D/elsewhere/worker/watchdog.thermal-hold")"
rm -rf "$D/elsewhere"

worker
out=$(
    harness
    UNSAFE_CHAIN="$D/data"
    WORKER_ROOT="$D/data/worker"
    _rg_claim_worker
    echo "rc=$?"
    cat "$LOG"
)
has "a worker root in a folder a non-root user can change is not claimed" "$out" "rc=1"
lacks "nothing is chowned" "$out" "chown"
check "its links stay" link "$(kind "$D/data/worker/watchdog.thermal-hold")"

out=$(
    harness
    cd() {
        if [ "$#" -eq 2 ] && [ -z "$2" ]; then return 0; fi
        builtin cd "$@" || return
    }
    builtin cd "$D/data" || exit 1
    WORKER_ROOT=""
    _rg_claim_worker
    echo "empty=$?"
    WORKER_ROOT="$D/missing"
    _rg_claim_worker
    echo "missing=$?"
    cat "$LOG"
)
has "an empty worker root is never claimed, even where cd accepts an empty name" "$out" "empty=1"
has "a missing worker root is never claimed" "$out" "missing=1"
lacks "neither chowns the current folder" "$out" "chown"

worker
out=$(
    harness
    CHOWN_RC=1
    WORKER_ROOT="$D/data/worker"
    CONFIG_JSON="$D/none.json"
    _rg_claim_worker 2>/dev/null
    echo "rc=$?"
    _reown_worker 2>&1
    cat "$LOG"
)
has "a failed claim returns a failure" "$out" "rc=1"
has "a failed claim is reported" "$out" "could not keep $D/data/worker root-owned"
lacks "a failed claim does not hand the folder to the operator" "$out" "-R rfop"

echo "== unit: _reown_worker on a root-owned tree =="
worker
printf '{}' >"$D/config.json"
out=$(
    harness
    WORKER_ROOT="$D/data/worker"
    CONFIG_JSON="$D/config.json"
    MINER_USER=rf-miner
    _reown_worker 2>/dev/null
    cat "$LOG"
)
has "as root it keeps the worker folder root-owned" "$out" "chown -R 0:0 $D/data/worker"
lacks "as root it does not hand the worker folder to the operator" "$out" "-R rfop"
has "config.json still goes to the operator" "$out" "chown rfop:rfop $D/config.json"
has "the miner user still gets its config and log" "$out" "chown rf-miner:rf-miner $D/data/worker/xmrig/build/config.json $D/data/worker/xmrig.log"
worker
out=$(
    harness
    ID_U=1000
    WORKER_ROOT="$D/data/worker"
    CONFIG_JSON="$D/config.json"
    _reown_worker
    cat "$LOG"
)
check "without root nothing is chowned" "" "$out"
worker
out=$(
    harness
    TREE_UNSAFE=1
    WORKER_ROOT="$D/data/worker"
    CONFIG_JSON="$D/config.json"
    _reown_worker
    cat "$LOG"
)
has "on a tree a non-root user can write the folder goes to the operator" "$out" "chown -R rfop:rfop $D/data/worker"
check "and without root nothing is chowned there" "" "$(
    harness
    TREE_UNSAFE=1 ID_U=1000
    WORKER_ROOT="$D/data/worker"
    CONFIG_JSON="$D/config.json"
    _reown_worker
    cat "$LOG"
)"
lacks "and is not chowned to root" "$out" "0:0"
check "and its links are left alone" link "$(kind "$D/data/worker/watchdog.thermal-hold")"

echo "== unit: prepare_workspace before a root build =="
worker
out=$(
    harness
    WORKER_ROOT="$D/data/worker"
    prepare_workspace 2>/dev/null
    echo "pwd=$(pwd -P)"
    cat "$LOG"
)
has "as root on a root-owned tree it says the folder stays root-owned" "$out" "stays root-owned"
has "it takes the folder back before the build" "$out" "chown -R 0:0 $D/data/worker"
lacks "it does not hand the folder to the operator" "$out" "rfop"
has "it enters the worker root" "$out" "pwd=$D/data/worker"
worker
out=$(
    harness
    TREE_UNSAFE=1
    WORKER_ROOT="$D/data/worker"
    prepare_workspace
    OS_TYPE=Darwin
    prepare_workspace
    cat "$LOG"
)
has "as root on another tree it hands the folder to the operator" "$out" "chown -R rfop:rfop $D/data/worker"
has "on macOS it hands it over without a group" "$out" "chown -R rfop $D/data/worker"
lacks "and never to root" "$out" "0:0"
worker
out=$(
    harness
    ID_U=1000
    WORKER_ROOT="$D/data/worker"
    prepare_workspace >/dev/null
    cat "$LOG"
)
check "without root, a folder the operator can still write is left as it is" "" "$out"
if [ "$(id -u)" -ne 0 ]; then
    chmod 555 "$D/data/worker"
    out=$(
        harness
        ID_U=1000
        WORKER_ROOT="$D/data/worker"
        (prepare_workspace) 2>&1
        echo "rc=$?"
        cat "$LOG"
    )
    chmod 755 "$D/data/worker"
    has "without root, a folder the operator cannot write stops the run" "$out" "must be root-owned before the build; run this with sudo"
    has "with a failure" "$out" "rc=1"
    lacks "before anything is chowned" "$out" "chown"
fi
worker
out=$(
    harness
    CHOWN_RC=1
    WORKER_ROOT="$D/data/worker"
    (prepare_workspace) 2>&1
    echo "rc=$?"
    cat "$LOG"
)
has "as root, a claim that fails stops the run" "$out" "must be root-owned before the build"
has "with a failure too" "$out" "rc=1"
lacks "and the folder is not handed to the operator" "$out" "rfop"
if [ "$(id -u)" -ne 0 ]; then
    out=$(
        harness
        ID_U=1000 TREE_UNSAFE=1
        WORKER_ROOT="$D/data/worker"
        chmod 555 "$WORKER_ROOT"
        prepare_workspace >/dev/null 2>&1
        chmod 755 "$WORKER_ROOT"
        cat "$LOG"
    )
    has "without root on another tree an unwritable folder is handed to the operator" "$out" "chown -R rfop:rfop $D/data/worker"
fi
out=$(
    harness
    WORKER_ROOT="$D/data/fresh"
    prepare_workspace
    cat "$LOG"
)
check "a missing worker root is created" y "$([ -d "$D/data/fresh" ] && echo y)"
has "and kept root-owned" "$out" "chown -R 0:0 $D/data/fresh"

echo "== unit: config snapshots on a root-owned tree =="
mkdir -p "$D/state/config-backups"
chmod 700 "$D/state/config-backups"
printf '{"pools":[]}' >"$D/state/config.json"
printf 'victim' >"$D/victims/snap"
ln -s "$D/victims/snap" "$D/state/config-backups/config-1.json"
out=$(
    harness
    CONFIG_JSON="$D/state/config.json"
    _rg_config_snapshot "$D/state/config-backups/config-1.json"
    echo "rc=$?"
    cat "$LOG"
)
has "the snapshot is written" "$out" "rc=0"
has "the folder is taken back by root first" "$out" "chown 0:0 $D/state/config-backups"
check "a link at the snapshot name is replaced, not followed" victim "$(cat "$D/victims/snap")"
check "the snapshot is a regular file" file "$(kind "$D/state/config-backups/config-1.json")"
check "it holds the config" '{"pools":[]}' "$(cat "$D/state/config-backups/config-1.json")"
check "it is readable by its owner only" 600 "$(mode "$D/state/config-backups/config-1.json")"
check "the folder is made readable by the operator" 755 "$(mode "$D/state/config-backups")"
check "no temporary file is left" "config-1.json" "$(ls -A "$D/state/config-backups")"

out=$(
    harness
    CONFIG_JSON="$D/state/missing.json"
    _rg_config_snapshot "$D/state/config-backups/config-2.json" 2>/dev/null
    echo "rc=$?"
)
has "a snapshot that cannot be read fails" "$out" "rc=1"
check "and leaves nothing behind" "config-1.json" "$(ls -A "$D/state/config-backups")"

mkdir -p "$D/state2" "$D/victims/dir"
ln -s "$D/victims/dir" "$D/state2/config-backups"
out=$(
    harness
    CONFIG_JSON="$D/state/config.json"
    _rg_config_snapshot "$D/state2/config-backups/config-3.json"
    echo "rc=$?"
    cat "$LOG"
)
has "a snapshot folder that is a link is followed" "$out" "rc=0"
has "and its target is taken back by root" "$out" "chown 0:0 $D/victims/dir"
check "and the snapshot lands in the target" "config-3.json" "$(ls -A "$D/victims/dir")"
rm -f "$D/victims/dir/config-3.json"
out=$(
    harness
    UNSAFE_CHAIN="$D/victims"
    CONFIG_JSON="$D/state/config.json"
    _rg_config_snapshot "$D/state2/config-backups/config-6.json"
    echo "rc=$?"
    cat "$LOG"
)
has "a link to a folder another user can change is still written" "$out" "rc=0"
lacks "but not taken back by root" "$out" "chown"
rm -f "$D/victims/dir/config-6.json"

mkdir -p "$D/victims/sub"
ln -s "$D/victims/sub" "$D/state/config-backups/config-5.json"
out=$(
    harness
    CONFIG_JSON="$D/state/config.json"
    _rg_config_snapshot "$D/state/config-backups/config-5.json"
    echo "rc=$?"
)
has "a link to a folder at the snapshot name is replaced" "$out" "rc=0"
check "and nothing is moved into that folder" "" "$(ls -A "$D/victims/sub")"
check "the name is now the snapshot" file "$(kind "$D/state/config-backups/config-5.json")"
rm -f "$D/state/config-backups/config-5.json"

out=$(
    harness
    TREE_UNSAFE=1
    CONFIG_JSON="$D/state/config.json"
    _rg_config_snapshot "$D/state/config-backups/config-4.json"
    echo "rc=$?"
    cat "$LOG"
)
has "on another tree the snapshot is still written" "$out" "rc=0"
lacks "without taking the folder" "$out" "chown"
out=$(
    harness
    ID_U=1000
    CONFIG_JSON="$D/state/config.json"
    _rg_config_snapshot "$D/state/config-backups/config-7.json"
    echo "rc=$?"
    cat "$LOG"
)
has "without root the snapshot is written" "$out" "rc=0"
lacks "without taking the folder either" "$out" "chown"
rm -f "$D/state/config-backups/config-7.json"

echo "== unit: a control change snapshots through the same path =="
mkdir -p "$D/cc/backups"
printf '{ "HOME_DIR": "%s", "pools": [{"url": "h:3333"}], "DONATION": 1 }\n' "$D/home" >"$D/cc/config.json"
printf '{"DONATION": 0}' >"$D/cc/staged.json"
printf 'victim' >"$D/victims/cc"
ln -s "$D/victims/cc" "$D/cc/backups/config-20260101-000000.json"
out=$(
    harness
    RIGFORGE_APPLIANCE=0
    CONFIG_JSON="$D/cc/config.json"
    _fsync_paths() { :; }
    date() { if [ "$*" = "-u +%Y%m%d-%H%M%S" ]; then echo 20260101-000000; else command date "$@"; fi; }
    _control_commit "$D/cc/staged.json" "$D/cc/backups" 2>&1
    echo "rc=$?"
    cat "$LOG"
)
has "the change is committed" "$out" "committed $D/cc/backups/config-20260101-000000.json"
has "the backups folder is taken back first" "$out" "chown 0:0 $D/cc/backups"
check "a planted link at the snapshot name is not written through" victim "$(cat "$D/victims/cc")"
check "the snapshot holds the previous config" 1 "$(jq -r .DONATION "$D/cc/backups/config-20260101-000000.json" 2>/dev/null)"
check "the new config is installed" 0 "$(jq -r .DONATION "$D/cc/config.json")"

echo "== unit: the backup sweep hands snapshots, not the folder =="
out=$(
    harness
    _sweep_config_backups "$D/state/config-backups"
    TREE_UNSAFE=1
    _sweep_config_backups "$D/state/config-backups"
    ID_U=1000
    echo "-- non-root" >>"$LOG"
    _sweep_config_backups "$D/state/config-backups"
    cat "$LOG"
)
has "on a root-owned tree each snapshot goes to the operator" "$out" "chown -h rfop $D/state/config-backups/config-1.json $D/state/config-backups/config-4.json"
has "on another tree the folder goes to the operator" "$out" "chown -R rfop $D/state/config-backups"
check "only those two calls are made, none without root" 2 "$(sed '/^-- non-root/q' <<<"$out" | grep -c '^chown')"
check "nothing is chowned without root" "-- non-root" "$(sed -n '/^-- non-root/,$p' <<<"$out")"

echo "== unit: restore takes the worker folder back before copying tune files =="
worker
mkdir -p "$D/rs/stage" "$D/rs/state" "$D/home/worker"
printf 'victim' >"$D/victims/tune"
ln -s "$D/victims/tune" "$D/home/worker/tune-overrides.json"
printf '{ "HOME_DIR": "%s", "pools": [{"url": "h:3333"}] }\n' "$D/home" >"$D/rs/stage/config.json"
printf '{"cpu":{"yield":false}}' >"$D/rs/stage/tune-overrides.json"
tar -czf "$D/rs/backup.tar.gz" -C "$D/rs/stage" config.json tune-overrides.json
cp "$D/rs/stage/config.json" "$D/rs/state/config.json"
mkdir -p "$D/rs/state/config-backups"
printf 'victim' >"$D/victims/rs"
ln -s "$D/victims/rs" "$D/rs/state/config-backups/config-20260101-000000-restore-$$.json"
out=$(
    harness
    date() { if [ "$*" = "-u +%Y%m%d-%H%M%S" ]; then echo 20260101-000000; else command date "$@"; fi; }
    RIGFORGE_STATE="$D/rs/state"
    CONFIG_JSON="$D/rs/state/config.json"
    CONFIG_META_FILE="$D/rs/state/.meta.json"
    _stamp_config_meta() { :; }
    restore -y "$D/rs/backup.tar.gz" >/dev/null 2>&1
    echo "rc=$?"
    cat "$LOG"
)
has "restore finishes" "$out" "rc=0"
has "the worker folder is taken back" "$out" "chown -R 0:0 $D/home/worker"
check "a planted link at a tune file name is not written through" victim "$(cat "$D/victims/tune")"
check "the tune file is restored in place" '{"cpu":{"yield":false}}' "$(cat "$D/home/worker/tune-overrides.json")"
check "the previous config was snapshotted over a planted link" file "$(kind "$D/rs/state/config-backups/config-20260101-000000-restore-$$.json")"
check "and the link's file is untouched" victim "$(cat "$D/victims/rs")"
printf 'victim' >"$D/victims/tune"
rm -f "$D/home/worker/tune-overrides.json"
ln -s "$D/victims/tune" "$D/home/worker/tune-overrides.json"
out=$(
    harness
    CHOWN_RC=1
    RIGFORGE_STATE="$D/rs/state"
    CONFIG_JSON="$D/rs/state/config.json"
    _stamp_config_meta() { :; }
    (restore -y "$D/rs/backup.tar.gz") 2>&1
    echo "rc=$?"
)
has "a worker folder root cannot take back stops the restore" "$out" "the tuning was not restored"
has "with a failure" "$out" "rc=1"
check "before a tune file is written through a link" victim "$(cat "$D/victims/tune")"
out=$(
    harness
    ID_U=1000
    RIGFORGE_STATE="$D/rs/state"
    CONFIG_JSON="$D/rs/state/config.json"
    _stamp_config_meta() { :; }
    (restore -y "$D/rs/backup.tar.gz") >/dev/null 2>&1
    echo "rc=$?"
    cat "$LOG"
)
lacks "without root, restore takes nothing back" "$out" "chown -R 0:0"

echo "== black box: the msr-apply pre-start step still runs to the end as root =="
mkdir -p "$D/msr/bin" "$D/msr/state" "$D/msr/home/worker" "$D/msr/cpu/cpu0"
printf '{ "HOME_DIR": "%s", "miner_user": "rf-miner", "pools": [{"url": "h:3333"}] }\n' "$D/msr/home" >"$D/msr/state/config.json"
printf '#!/usr/bin/env bash\ncase "$*" in *-un*) echo root ;; *-u*) echo 0 ;; *) command id "$@" ;; esac\n' >"$D/msr/bin/id"
printf '#!/usr/bin/env bash\necho Linux\n' >"$D/msr/bin/uname"
printf '#!/usr/bin/env bash\nprintf "Vendor ID: AuthenticAMD\\nCPU family: 25\\nModel: 97\\n"\n' >"$D/msr/bin/lscpu"
printf '#!/usr/bin/env bash\necho "wrmsr $*" >>"%s/msr/calls"\n' "$D" >"$D/msr/bin/wrmsr"
printf '#!/usr/bin/env bash\necho 001c000200000065\n' >"$D/msr/bin/rdmsr"
printf '#!/usr/bin/env bash\nexit 0\n' >"$D/msr/bin/modprobe"
chmod +x "$D/msr/bin"/*
out=$(cd "$D/msr" && PATH="$D/msr/bin:$PATH" RIGFORGE_STATE="$D/msr/state" RIGFORGE_APPLIANCE=0 CPU_SYSFS="$D/msr/cpu" RDMSR_BIN="$D/msr/bin/rdmsr" bash "$SCRIPT" msr-apply </dev/null 2>&1)
check "the msr-apply verb exits 0" 0 "$?"
has "it applies the preset" "$out" "MSR preset 'ryzen_19h_zen4' applied"
check "it records the preset in the worker folder" ryzen_19h_zen4 "$(cat "$D/msr/home/worker/.rigforge-msr-preset" 2>/dev/null)"
has "it writes the registers" "$(cat "$D/msr/calls" 2>/dev/null)" "wrmsr -a 0xc0011020"

exit "$fail"
