#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016
set -uo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
SRC=$(cd "$(dirname "$SCRIPT")" && pwd)
D=$(cd -P "$(mktemp -d)" && pwd)
trap 'rm -rf "$D"' EXIT
unset RIGFORGE_IMPL RIGFORGE_BIN RIGFORGE_HOME
export NO_COLOR=1
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
has() {
    case "$3" in
    *"$2"*) echo "  ok   $1" ;;
    *)
        echo "  FAIL $1: missing [$2] in [$3]"
        fail=1
        ;;
    esac
}
lacks() {
    case "$3" in
    *"$2"*)
        echo "  FAIL $1: unexpected [$2] in [$3]"
        fail=1
        ;;
    *) echo "  ok   $1" ;;
    esac
}

T="$D/tree"
mkdir -p "$T" "$D/work"
cp "$SCRIPT" "$T/rigforge.sh"
cp -R "$SRC/util" "$T/util"
MARK="$T/.rigforge-impl"

T2="$D/t2"
cp -R "$T" "$T2"
sed -i.bak 's/^_IMPL_NATIVE_VERBS=""/_IMPL_NATIVE_VERBS="help setup"/' "$T2/util/impl-handover.sh"
MARK2="$T2/.rigforge-impl"
BIN2="$T2/bin/rigforge-rs"

rig() {
    out=$(cd "$D/work" && bash "${TREE:-$T}/rigforge.sh" "$@" 2>"$D/err")
    rc=$?
    err=$(cat "$D/err")
}
rig2() { TREE="$T2" rig "$@"; }

echo "== unit: RIGFORGE_IMPL dispatcher, default bash (#706) =="
rig help
base_out=$out base_err=$err base_rc=$rc
check "help runs the Bash path with nothing set" 0 "$base_rc"
has "help prints the usage text" "[command]" "$base_out"
rig bogus-verb
bogus_out=$out bogus_err=$err bogus_rc=$rc
check "an unknown verb still fails the Bash way" 1 "$bogus_rc"
has "the Bash unknown-verb message is unchanged" "Unknown command: bogus-verb" "$bogus_err"
rig help extra
extra_out=$out extra_err=$err extra_rc=$rc
has "the extra-argument check still runs" "Unexpected argument for help: 'extra'" "$extra_err"

RIGFORGE_IMPL=bash rig help
check "explicit bash takes the same path: stdout" "$base_out" "$out"
check "explicit bash takes the same path: stderr" "$base_err" "$err"
check "explicit bash takes the same path: status" "$base_rc" "$rc"
RIGFORGE_IMPL=bash rig bogus-verb
check "explicit bash, failing verb: stderr and status" "$bogus_rc:$bogus_err" "$rc:$err"
RIGFORGE_IMPL="" rig help
check "an empty RIGFORGE_IMPL is the same as unset" "$base_rc:$base_out" "$rc:$out"
rig2 help
base2="$rc:$out"
check "a native verb with nothing selected runs the Bash path" "$base_rc" "$rc"
RIGFORGE_IMPL=bash rig2 help
check "explicit bash, native verb: the Bash path" "$base2" "$rc:$out"
RIGFORGE_IMPL="" rig2 help
check "an empty RIGFORGE_IMPL, native verb: the Bash path" "$base2" "$rc:$out"

echo "== unit: a verb that only exists in Bash never consults the switch =="
same() {
    rig help
    check "$1: help is unchanged" "$base_rc:$base_out:$base_err" "$rc:$out:$err"
    rig bogus-verb
    check "$1: a failing verb is unchanged" "$bogus_rc:$bogus_err" "$rc:$err"
}
RIGFORGE_IMPL=zzz same "unknown value"
RIGFORGE_IMPL=rust same "rust selected, binary missing"
printf 'zzz\n' >"$MARK"
same "unknown marker value"
: >"$MARK"
same "empty marker"
printf 'rust\n' >"$MARK"
same "marker rust, binary missing"
rm -f "$MARK"
mkdir "$MARK"
same "directory marker"
rmdir "$MARK"
ln -s "$D/no-such-file" "$MARK"
same "dangling link marker"
rm -f "$MARK"

echo "== unit: for a native verb an unknown value is an error, never a silent fallback =="
RIGFORGE_IMPL=zzz rig2 help
check "unknown value exits 1" 1 "$rc"
check "unknown value prints nothing on stdout" "" "$out"
has "unknown value names the value" "Unknown RIGFORGE_IMPL value 'zzz'" "$err"
has "unknown value names the way out" "RIGFORGE_IMPL=bash" "$err"
RIGFORGE_IMPL=Rust rig2 help
check "values are case-sensitive" 1 "$rc"
printf 'zzz\n' >"$MARK2"
rig2 help
check "an unknown marker value exits 1" 1 "$rc"
has "the marker error names the marker file" "$MARK2" "$err"
printf 'ru st\n' >"$MARK2"
rig2 help
has "a space inside the value is not trimmed away" "Unknown RIGFORGE_IMPL value 'ru st'" "$err"
: >"$MARK2"
rig2 help
check "an empty marker is an error" 1 "$rc"
has "the empty-marker error names the marker" "$MARK2" "$err"
rm -f "$MARK2"
mkdir "$MARK2"
rig2 help
check "a directory marker is an error" 1 "$rc"
has "the directory-marker error names the marker" "empty or unreadable" "$err"
lacks "the directory marker is not an unbound variable" "unbound" "$err"
rmdir "$MARK2"
ln -s "$D/no-such-file" "$MARK2"
rig2 help
check "a dangling link marker is an error" 1 "$rc"
rm -f "$MARK2"
printf 'bash\n' >"$MARK2"
rig2 help
check "marker bash takes the Bash path: output" "$base2" "$rc:$out"
rm -f "$MARK2"

echo "== unit: rust selected and the binary missing or unusable is an error for a native verb =="
RIGFORGE_IMPL=rust rig2 help
check "missing binary, native verb: exit 1" 1 "$rc"
check "missing binary, native verb: nothing on stdout" "" "$out"
has "missing binary, native verb: names the default binary path" "$BIN2" "$err"
has "missing binary, native verb: names the way out" "run with RIGFORGE_IMPL=bash" "$err"
has "missing binary, native verb: says what is wrong" "is missing or not executable" "$err"
lacks "missing binary, native verb: no marker named when the env var chose" ".rigforge-impl" "$err"
RIGFORGE_IMPL=rust RIGFORGE_BIN="$D/nope" rig2 help
has "RIGFORGE_BIN overrides the default path" "$D/nope" "$err"
lacks "RIGFORGE_BIN replaces the default path in the message" "$BIN2" "$err"
printf 'rust\n' >"$MARK2"
rig2 help
check "marker rust with no binary exits 1" 1 "$rc"
has "the error names the marker as the source" "$MARK2" "$err"
has "the error names the binary" "$BIN2" "$err"
RIGFORGE_IMPL=bash rig2 help
check "the environment variable beats the marker" "$base2" "$rc:$out"
printf 'rust \r\n' >"$MARK2"
rig2 help
has "a trailing space and CR in the marker are trimmed" "RIGFORGE_IMPL=rust is selected by the marker file" "$err"
printf 'rust' >"$MARK2"
rig2 help
has "a marker without a newline is read" "RIGFORGE_IMPL=rust is selected by the marker file" "$err"
rm -f "$MARK2"
printf '#!/bin/sh\nexit 0\n' >"$D/plain"
chmod 644 "$D/plain"
RIGFORGE_IMPL=rust RIGFORGE_BIN="$D/plain" rig2 help
check "a non-executable file is refused" 1 "$rc"
has "a non-executable file is named" "$D/plain" "$err"
has "a non-executable file: says what is wrong" "is missing or not executable" "$err"
mkdir "$D/adir"
RIGFORGE_IMPL=rust RIGFORGE_BIN="$D/adir" rig2 help
check "a directory is refused" 1 "$rc"
has "a directory: says what is wrong" "is missing or not executable" "$err"

echo "== unit: a verb that is not native runs the Bash path unchanged =="
printf '#!/bin/sh\necho ran >"%s/ran.flag"\nexit 9\n' "$D" >"$D/standin"
chmod 755 "$D/standin"
export RIGFORGE_IMPL=rust RIGFORGE_BIN="$D/standin"
rig help
check "rust mode, non-native verb: stdout" "$base_out" "$out"
check "rust mode, non-native verb: stderr" "$base_err" "$err"
check "rust mode, non-native verb: status" "$base_rc" "$rc"
rig bogus-verb
check "rust mode, failing verb: stderr and status" "$bogus_rc:$bogus_err" "$rc:$err"
check "rust mode, failing verb: stdout" "$bogus_out" "$out"
rig help extra
check "rust mode, extra argument: stderr and status" "$extra_rc:$extra_err" "$rc:$err"
check "rust mode, extra argument: stdout" "$extra_out" "$out"
check "the binary was never started for a non-native verb" no "$([ -e "$D/ran.flag" ] && echo yes || echo no)"
unset RIGFORGE_IMPL RIGFORGE_BIN

echo "== unit: a native verb (list set by the test) reaches the binary =="
cat >"$D/probe.sh" <<'PROBE'
printf 'argv0=%s\n' "$(ps -o args= -p $$ | cut -d' ' -f1)"
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'arg=%s\n' "$a"; done
printf 'home=%s\nxv=%s\nxc=%s\napp=%s\nclk=%s\n' "$RIGFORGE_HOME" "$XMRIG_VERSION" "$XMRIG_COMMIT" "$RIGFORGE_APPLIANCE" "$MIN_CLOCK_PCT"
echo to-stderr >&2
exit 7
PROBE
shell_bin=$(command -v bash)
want=$(bash -c 'source "$1"; printf "xv=%s\nxc=%s\napp=%s\nclk=%s\n" "$XMRIG_VERSION" "$XMRIG_COMMIT" "$RIGFORGE_APPLIANCE" "$MIN_CLOCK_PCT"' _ "$T/rigforge.sh")
driver() {
    out=$(RIGFORGE_IMPL=rust RIGFORGE_BIN="$shell_bin" bash -c 'source "$1"; _IMPL_NATIVE_VERBS="$2"; shift 2; _impl_handover "$@"; echo returned' stand-in-name "$T/rigforge.sh" "$@" 2>"$D/err")
    rc=$?
    err=$(cat "$D/err")
}
driver "$D/probe.sh" "$D/probe.sh" first "second word"
check "the binary's exit status comes back" 7 "$rc"
check "the binary's stderr stays on stderr" to-stderr "$err"
check "exec replaced the shell" "" "$(printf '%s' "$out" | grep returned || true)"
has "exec -a passes the name the script was called by" "argv0=stand-in-name" "$out"
has "the argv is passed unchanged" "$(printf 'argc=2\narg=first\narg=second word')" "$out"
has "RIGFORGE_HOME is the script directory" "home=$T" "$out"
check "the four load-time values equal the sourced shell's" "$want" "$(printf '%s\n' "$out" | grep -E '^(xv|xc|app|clk)=')"
out=$(RIGFORGE_HOME="$D/home" RIGFORGE_IMPL=rust RIGFORGE_BIN="$shell_bin" bash -c 'source "$1"; _IMPL_NATIVE_VERBS="$2"; _impl_handover "$2"' x "$T/rigforge.sh" "$D/probe.sh" 2>/dev/null)
has "an explicit RIGFORGE_HOME is passed on" "home=$D/home" "$out"
out=$(RIGFORGE_IMPL=rust RIGFORGE_BIN="$shell_bin" bash -c 'source "$1"; _IMPL_NATIVE_VERBS="$2"; _impl_handover other; printenv RIGFORGE_HOME XMRIG_VERSION XMRIG_COMMIT RIGFORGE_APPLIANCE MIN_CLOCK_PCT || echo none; echo continued' x "$T/rigforge.sh" "$D/probe.sh" 2>&1)
check "a non-native verb returns and exports nothing" "none
continued" "$out"
out=$(RIGFORGE_IMPL=rust RIGFORGE_BIN="$shell_bin" bash -c 'source "$1"; _IMPL_NATIVE_VERBS="a b"; _impl_handover "a b"; echo continued' x "$T/rigforge.sh" 2>&1)
check "a verb with a space never matches two list entries" continued "$out"
printf '\177ELFnot-a-program' >"$D/badbin"
chmod 755 "$D/badbin"
out=$(RIGFORGE_IMPL=rust RIGFORGE_BIN="$D/badbin" bash -c 'source "$1"; _IMPL_NATIVE_VERBS=v; _impl_handover v; echo returned' x "$T/rigforge.sh" 2>"$D/err")
rc=$?
err=$(cat "$D/err")
check "a binary that cannot be executed exits 1" 1 "$rc"
check "a binary that cannot be executed does not fall through" "" "$out"
has "the exec failure names the binary" "$D/badbin" "$err"
has "the exec failure names the way out" "RIGFORGE_IMPL=bash" "$err"
mkdir -p "$D/pathdir"
printf '#!/bin/sh\necho from-cwd\n' >"$D/work/barebin"
printf '#!/bin/sh\necho from-path\n' >"$D/pathdir/barebin"
chmod 755 "$D/work/barebin" "$D/pathdir/barebin"
out=$(cd "$D/work" && PATH="$D/pathdir:$PATH" RIGFORGE_IMPL=rust RIGFORGE_BIN=barebin bash -c 'source "$1"; _IMPL_NATIVE_VERBS=v; _impl_handover v' x "$T/rigforge.sh" 2>/dev/null)
check "a bare RIGFORGE_BIN name is the file in the current folder, not one on PATH" from-cwd "$out"
out=$(RIGFORGE_IMPL=rust RIGFORGE_BIN="$D/work/barebin" bash -c 'source "$1"; _IMPL_NATIVE_VERBS=setup; _impl_handover; echo returned' x "$T/rigforge.sh" 2>/dev/null)
check "no argument means the setup verb, as in the dispatcher" from-cwd "$out"
out=$(cd "$D/work" && RIGFORGE_IMPL=rust RIGFORGE_BIN="$D/badbin" bash "$T2/rigforge.sh" help 2>"$D/err")
rc=$?
err=$(cat "$D/err")
check "the real script with a bad binary exits 1" 1 "$rc"
has "the real script names the way out" "RIGFORGE_IMPL=bash" "$err"
lacks "the real script prints no abort banner first" "aborted while starting up" "$err"

echo "== unit: sourcing rigforge.sh is unaffected =="
for sel in zzz rust; do
    out=$(RIGFORGE_IMPL=$sel RIGFORGE_BIN="$D/nope" bash -c 'source "$1"; echo sourced' x "$T2/rigforge.sh" 2>&1)
    check "sourcing with RIGFORGE_IMPL=$sel does not dispatch" sourced "$out"
done
printf 'zzz\n' >"$MARK2"
out=$(bash -c 'source "$1"; echo sourced' x "$T2/rigforge.sh" 2>&1)
check "sourcing with a bad marker does not dispatch" sourced "$out"
rm -f "$MARK2"

echo "== unit: the text of the switch keeps the frozen shapes =="
block=$(sed -n '/_RIGFORGE_SOURCED" = "0" \]; then/,/^fi$/p' "$SCRIPT")
check "the call is the first statement of the not-sourced block" '    _impl_handover "$@"' "$(printf '%s\n' "$block" | sed -n 2p)"
check "the call appears once" 1 "$(grep -c '^ *_impl_handover "\$@"$' "$SCRIPT")"
check "the util file is sourced once" 1 "$(grep -c '^source "$(_script_dir)/util/impl-handover.sh"$' "$SCRIPT")"
check "no bash) or rust) label in the verb case" 0 "$(printf '%s\n' "$block" | grep -cE '^    (bash|rust)[ |)]' || true)"
check "the extra-argument template appears once" 1 "$(grep -c 'Unexpected argument for [a-z$]' "$SCRIPT")"
check "RIGFORGE_IMPL is not forwarded through sudo" 0 "$(grep -c 'RIGFORGE_IMPL' "$SCRIPT")"
check "the util file names no program to start" 0 "$(grep -cE '\$\(|`' "$SRC/util/impl-handover.sh" | tr -d ' ')"

echo "== unit: every rigforge.sh verb a unit template runs is one the dispatcher knows =="
verbs=$(printf '%s\n' "$block" | grep -oE '^    [a-z |-]+\)' | tr -d ' )' | tr '|' '\n')
units=$(cd "$SRC" && grep -hE 'Exec[A-Za-z]*=' systemd/*.template rigforge.sh | grep -oE 'rigforge\.sh +[a-z-]+' | awk '{print $2}' | sort -u)
check "the units run the five scheduled verbs and msr-apply" "api-refresh autotune control-apply control-upgrade msr-apply watchdog" "$(printf '%s ' $units | sed 's/ $//')"
for u in $units; do
    check "dispatcher knows the unit verb $u" yes "$(printf '%s\n' "$verbs" | grep -qx -- "$u" && echo yes || echo no)"
done

echo "== unit: the root guard covers the marker and the binary =="
R="$D/guard"
TREE="$R/rigforge"
mkdir -p "$TREE/util" "$TREE/systemd"
cp "$SRC/util/root-guard.sh" "$TREE/util/root-guard.sh"
touch "$TREE/rigforge.sh" "$TREE/systemd/x.template"
TAB="$R/stat.tab"
(
    source "$TREE/util/root-guard.sh"
    stat() {
        local p="${!#}" v
        [ -e "$p" ] || [ -L "$p" ] || return 1
        v=$(awk -v p="$p" '$1 == p { print $2; exit }' "$TAB")
        case "$v" in '') echo 0:0:755 ;; *) echo "$v" ;; esac
    }
    guard() {
        printf '%s\n' "$@" >"$TAB"
        out=$(_rg_tree_unsafe "$TREE")
        rc=$?
    }
    res() { printf '%s' "$rc:$out"; }
    guard
    echo "no marker and no binary: $(res)"
    mkdir "$TREE/bin"
    guard
    echo "empty bin folder: $(res)"
    : >"$TREE/bin/rigforge-rs"
    guard
    echo "root-owned binary: $(res)"
    guard "$TREE/bin/rigforge-rs 1000:1000:755"
    echo "user-owned binary: $(res)"
    guard "$TREE/bin 0:1000:775"
    echo "group-writable bin directory: $(res)"
    : >"$TREE/.rigforge-impl"
    guard "$TREE/.rigforge-impl 1000:1000:644"
    echo "user-owned marker: $(res)"
    guard
    echo "root-owned marker: $(res)"
) >"$D/guard.out"
g=$(cat "$D/guard.out")
has "a tree with no marker and no binary passes" "no marker and no binary: 1:" "$g"
has "an empty bin folder passes" "empty bin folder: 1:" "$g"
has "a root-owned binary passes" "root-owned binary: 1:" "$g"
has "a user-owned binary is refused" "user-owned binary: 0:$TREE/bin/rigforge-rs is owned by uid 1000" "$g"
has "a group-writable bin directory is refused" "group-writable bin directory: 0:$TREE/bin is writable by group 1000" "$g"
has "a user-owned marker is refused" "user-owned marker: 0:$TREE/.rigforge-impl is owned by uid 1000" "$g"
has "a root-owned marker passes" "root-owned marker: 1:" "$g"

exit "$fail"
