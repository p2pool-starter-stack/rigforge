#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/rigforge.sh}"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export RIGFORGE_HOME="$TEST_DIR/rigforge"
export RIGFORGE_APPLIANCE=0
export NO_COLOR=1
mkdir -p "$RIGFORGE_HOME"

FAIL=0
bad() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL=1
}

swap_case() {
    local ws="$TEST_DIR/swap-$1" out
    mkdir -p "$ws/worker" "$ws/outside"
    printf 'payload\n' >"$ws/outside/file"
    printf '%s' "$2" >"$ws/worker/xmrig.swap"
    mkdir -p "$ws/worker/xmrig-ok"
    printf 'archived\n' >"$ws/worker/xmrig-ok/marker"
    out=$(
        (
            source "$SCRIPT"
            WORKER_ROOT="$ws/worker"
            decide_rebuild() { :; }
            _recover_xmrig_swap
        ) 2>&1
    ) || true
    [ ! -e "$ws/worker/xmrig.swap" ] || bad "$1: marker was not removed"
    case "$3" in
    moved)
        [ "$(cat "$ws/worker/xmrig/marker" 2>/dev/null)" = archived ] || bad "$1: valid marker was not rolled back"
        ;;
    kept)
        [ ! -e "$ws/worker/xmrig" ] || bad "$1: invalid marker moved something into place"
        [ -f "$ws/outside/file" ] || bad "$1: a directory outside the worker tree was moved"
        [ -d "$ws/worker/xmrig-ok" ] || bad "$1: an unrelated archive was moved"
        [ "$(grep -c 'invalid XMRig swap marker' <<<"$out")" = 1 ] || bad "$1: expected exactly one warning"
        ;;
    esac
}

swap_case valid xmrig-ok moved
swap_case valid-newline $'xmrig-ok\n' moved
swap_case parent '../outside' kept
swap_case parent-prefixed 'xmrig-ok/../../outside' kept
swap_case slash 'xmrig-ok/sub' kept
swap_case absolute "$TEST_DIR/swap-absolute/outside" kept
swap_case dot '.' kept
swap_case dotdot '..' kept
swap_case other-prefix 'other-ok' kept
swap_case empty '' kept
swap_case space 'xmrig-ok x' kept
swap_case newline $'xmrig-ok\n../outside' kept
swap_case glob 'xmrig-*' kept

(
    ws="$TEST_DIR/swap-link"
    mkdir -p "$ws/worker" "$ws/outside"
    ln -s "$ws/outside" "$ws/worker/xmrig-link"
    printf 'xmrig-link' >"$ws/worker/xmrig.swap"
    source "$SCRIPT"
    WORKER_ROOT="$ws/worker"
    decide_rebuild() { :; }
    _recover_xmrig_swap
    [ ! -e "$ws/worker/xmrig" ] && [ ! -L "$ws/worker/xmrig" ]
) >/dev/null 2>&1 || bad "a symlink named by the marker was installed as the xmrig directory"

(
    ws="$TEST_DIR/swap-newlink"
    mkdir -p "$ws/worker" "$ws/outside"
    ln -s "$ws/outside" "$ws/worker/xmrig.new"
    printf 'xmrig-ok' >"$ws/worker/xmrig.swap"
    source "$SCRIPT"
    WORKER_ROOT="$ws/worker"
    decide_rebuild() { :; }
    _recover_xmrig_swap
    [ ! -e "$ws/worker/xmrig" ] && [ ! -L "$ws/worker/xmrig" ]
) >/dev/null 2>&1 || bad "a symlinked xmrig.new was installed as the xmrig directory"

(
    ws="$TEST_DIR/swap-fallback"
    mkdir -p "$ws/xmrig.new"
    printf 'xmrig-ok\n' >"$ws/xmrig.swap"
    source "$SCRIPT"
    WORKER_ROOT="$ws"
    decide_rebuild() { :; }
    _recover_xmrig_swap
    [ -d "$ws/xmrig" ] && [ ! -e "$ws/xmrig.swap" ]
) >/dev/null 2>&1 || bad "a valid marker no longer rolls the staged build forward"

STUBS="$TEST_DIR/stubs"
mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$STUBS/sudo"
chmod +x "$STUBS/sudo"
CFG='{ "DONATION": 7, "pools": [{"url": "poolbox.lan:3333"}] }'
TUNE='{ "cpu": { "rx": 4 } }'

new_archive() {
    SRC="$TEST_DIR/src-$1"
    mkdir -p "$SRC"
    printf '%s\n' "$CFG" >"$SRC/config.json"
    printf '%s\n' "$TUNE" >"$SRC/tune-overrides.json"
}

run_restore() {
    local fr="$TEST_DIR/fr-$1"
    mkdir -p "$fr" "$TEST_DIR/tmp-$1"
    cp "$ROOT/VERSION" "$fr/"
    [ -n "${NO_LIVE_CONFIG:-}" ] || printf '{ "DONATION": 3, "pools": [{"url": "keep.lan:3333"}] }\n' >"$fr/config.json"
    RC=0
    OUT=$(cd "$fr" && TMPDIR="$TEST_DIR/tmp-$1" PATH="$STUBS:$PATH" RIGFORGE_HOME="$PWD" bash "$SCRIPT" restore -y "$2" </dev/null 2>&1) || RC=$?
}

expect_refused() {
    run_restore "$1" "$2"
    [ "$RC" != 0 ] || bad "$1: restore accepted the archive"
    grep -q "$3" <<<"$OUT" || bad "$1: expected message '$3', got: $OUT"
    [ "$(jq -r .DONATION "$TEST_DIR/fr-$1/config.json")" = 3 ] || bad "$1: the live config was replaced"
    [ ! -e "$TEST_DIR/fr-$1/data/worker/tune-overrides.json" ] || bad "$1: a tuning file was copied out"
    [ -z "$(ls -A "$TEST_DIR/tmp-$1")" ] || bad "$1: the staging folder was left behind"
}

new_archive good
chmod 777 "$SRC/tune-overrides.json"
tar -czf "$TEST_DIR/good.tar.gz" -C "$SRC" config.json tune-overrides.json
run_restore good "$TEST_DIR/good.tar.gz"
[ "$RC" = 0 ] || bad "good: a plain archive was refused: $OUT"
[ "$(jq -r .DONATION "$TEST_DIR/fr-good/config.json")" = 7 ] || bad "good: config.json was not restored"
[ "$(jq -r .cpu.rx "$TEST_DIR/fr-good/data/worker/tune-overrides.json")" = 4 ] || bad "good: tuning was not restored"
[ "$(stat -c %a "$TEST_DIR/fr-good/data/worker/tune-overrides.json" 2>/dev/null || stat -f %Lp "$TEST_DIR/fr-good/data/worker/tune-overrides.json")" != 777 ] || bad "good: archive permissions were restored"

fresh_mode_case() {
    new_archive "fresh-$1"
    chmod "$1" "$SRC/config.json"
    tar -czf "$TEST_DIR/fresh-$1.tar.gz" -C "$SRC" config.json tune-overrides.json
    NO_LIVE_CONFIG=1 run_restore "fresh-$1" "$TEST_DIR/fresh-$1.tar.gz"
    [ "$RC" = 0 ] || bad "fresh-$1: restore with no live config was refused: $OUT"
    local f="$TEST_DIR/fr-fresh-$1/config.json"
    [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ] || bad "fresh-$1: restored config.json is not mode 600"
}

fresh_mode_case 644
fresh_mode_case 600

new_archive dirs
mkdir -p "$SRC/sub/deeper"
printf 'x\n' >"$SRC/sub/deeper/file"
tar -czf "$TEST_DIR/dirs.tar.gz" -C "$SRC" .
run_restore dirs "$TEST_DIR/dirs.tar.gz"
[ "$RC" = 0 ] || bad "dirs: an archive with folders was refused: $OUT"

new_archive symlink
printf 'secret\n' >"$TEST_DIR/target"
rm -f "$SRC/tune-overrides.json"
ln -s "$TEST_DIR/target" "$SRC/tune-overrides.json"
tar -czf "$TEST_DIR/symlink.tar.gz" -C "$SRC" config.json tune-overrides.json
expect_refused symlink "$TEST_DIR/symlink.tar.gz" "not a regular file"

new_archive dirlink
ln -s "$TEST_DIR" "$SRC/linkdir"
tar -czf "$TEST_DIR/dirlink.tar.gz" -C "$SRC" config.json linkdir
expect_refused dirlink "$TEST_DIR/dirlink.tar.gz" "not a regular file"

new_archive hardlink
ln "$SRC/tune-overrides.json" "$SRC/rigforge-tune.json"
tar -czf "$TEST_DIR/hardlink.tar.gz" -C "$SRC" config.json tune-overrides.json rigforge-tune.json
expect_refused hardlink "$TEST_DIR/hardlink.tar.gz" "not a regular file"

new_archive fifo
mkfifo "$SRC/rigforge-bios.json"
tar -czf "$TEST_DIR/fifo.tar.gz" -C "$SRC" config.json rigforge-bios.json
expect_refused fifo "$TEST_DIR/fifo.tar.gz" "not a regular file"

new_archive parent
mkdir -p "$TEST_DIR/pdir/inner"
printf 'x\n' >"$TEST_DIR/pdir/outside.txt"
printf '%s\n' "$CFG" >"$TEST_DIR/pdir/inner/config.json"
(cd "$TEST_DIR/pdir/inner" && tar -czPf "$TEST_DIR/parent.tar.gz" config.json ../outside.txt)
expect_refused parent "$TEST_DIR/parent.tar.gz" "absolute or contains"

new_archive absolute
(cd "$SRC" && tar -czPf "$TEST_DIR/absolute.tar.gz" "$SRC/config.json" "$SRC/tune-overrides.json")
expect_refused absolute "$TEST_DIR/absolute.tar.gz" "absolute or contains"

BENCH_DIR="$TEST_DIR/bench"
mkdir -p "$BENCH_DIR"
cat >"$BENCH_DIR/in.json" <<'EOF'
{
    "api": { "id": "x" },
    "autosave": true,
    "background": true,
    "colors": false,
    "cpu": { "enabled": true, "rx": [0, 1], "huge-pages": true },
    "cuda": { "enabled": true, "loader": "/lib/x.so" },
    "dmi": true,
    "dns": { "ttl": 30 },
    "donate-level": 1,
    "donate-over-proxy": 1,
    "health-print-time": 60,
    "http": { "enabled": true },
    "log-file": "/var/log/x.log",
    "opencl": { "enabled": true, "loader": "/lib/y.so" },
    "pause-on-active": 30,
    "pause-on-battery": true,
    "pools": [{ "url": "poolbox.lan:3333" }],
    "print-time": 60,
    "randomx": { "mode": "fast", "wrmsr": true, "1gb-pages": true },
    "syslog": true,
    "tls": { "enabled": true },
    "verbose": 2,
    "watch": true,
    "benchmark": "1M",
    "plugin": "/lib/z.so"
}
EOF
(
    source "$SCRIPT"
    _bench_safe_config "$BENCH_DIR/in.json" "$BENCH_DIR/out.json"
) >/dev/null 2>&1 || bad "the benchmark config filter failed"
want='["autosave","background","colors","cpu","cuda","health-print-time","opencl","pause-on-active","pause-on-battery","print-time","randomx","verbose","watch"]'
[ "$(jq -c 'keys' "$BENCH_DIR/out.json")" = "$want" ] || bad "benchmark config keys were $(jq -c keys "$BENCH_DIR/out.json")"
[ "$(jq -c '[.cpu, .randomx]' "$BENCH_DIR/out.json")" = "$(jq -c '[.cpu, .randomx]' "$BENCH_DIR/in.json")" ] || bad "cpu or randomx changed in the benchmark config"
[ "$(jq -c '[.colors, .background, .autosave, .watch, ."pause-on-active", ."pause-on-battery", ."print-time", .verbose, .opencl, .cuda]' "$BENCH_DIR/out.json")" = '[true,false,false,false,false,false,60,2,false,false]' ] || bad "benchmark forced settings were wrong"

printf '{ "cpu": { "rx": 4 }, "randomx": { "mode": "fast" }, "print-time": 60 }\n' >"$BENCH_DIR/plain.json"
(
    source "$SCRIPT"
    _bench_safe_config "$BENCH_DIR/plain.json" "$BENCH_DIR/plain-out.json"
) >/dev/null 2>&1 || bad "the benchmark filter failed on a plain config"
[ "$(jq -cS . "$BENCH_DIR/plain-out.json")" = '{"autosave":false,"background":false,"colors":true,"cpu":{"rx":4},"cuda":false,"opencl":false,"pause-on-active":false,"pause-on-battery":false,"print-time":60,"randomx":{"mode":"fast"},"watch":false}' ] || bad "a plain config changed unexpectedly: $(jq -cS . "$BENCH_DIR/plain-out.json")"

printf '[1]\n' >"$BENCH_DIR/array.json"
if (
    source "$SCRIPT"
    _bench_safe_config "$BENCH_DIR/array.json" "$BENCH_DIR/array-out.json"
) >/dev/null 2>&1; then bad "a non-object benchmark config was accepted"; fi

exit "$FAIL"
