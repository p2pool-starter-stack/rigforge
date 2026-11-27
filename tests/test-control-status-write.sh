#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D/home"
source "$SCRIPT"
set +e
fail=0
CID=0123456789abcdef
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sum() { find "$1" -type f -exec cat {} + | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16; }
regular644() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode "$1")" = 644 ] && echo y || echo n; }
target() {
    mkdir -p "$1"
    for i in $(seq 1 "$2"); do printf 'keep %s' "$i" >"$1/$(printf '%016x' "$i").json"; done
    chmod 700 "$1"
}

echo "== unit: a normal folder gets the same records, names and modes =="
S="$D/s1"
mkdir -p "$S/pending"
printf '{}' >"$S/pending/$CID.json"
RIGFORGE_CONTROL_TERMINAL_WRITTEN=""
_control_status "$S/status.json" applied "$CID" "watchdog,DONATION" "" ""
check "status.json is a regular file with mode 644" y "$(regular644 "$S/status.json")"
check "status.json carries the outcome" "applied $CID" "$(jq -r '.status + " " + .change_id' "$S/status.json")"
check "the indexed record is a regular file with mode 644" y "$(regular644 "$S/changes/$CID.json")"
check "the indexed record has the same bytes as status.json" "$(cat "$S/status.json")" "$(cat "$S/changes/$CID.json")"
check "the pending marker is removed" gone "$([ -e "$S/pending/$CID.json" ] && echo kept || echo gone)"
check "only the record names remain in the folder" "changes pending status.json" "$(ls -A "$S" | tr '\n' ' ' | sed 's/ $//')"
check "only the record remains in changes" "$CID.json" "$(ls -A "$S/changes")"
check "a terminal outcome is noted" 1 "$RIGFORGE_CONTROL_TERMINAL_WRITTEN"
RIGFORGE_CONTROL_TERMINAL_WRITTEN=""
_control_status "$S/status.json" started "$CID" version "" ""
check "a started record is not noted as terminal" "" "$RIGFORGE_CONTROL_TERMINAL_WRITTEN"
S="$D/s8/missing"
(
    umask 077
    _control_status "$S/status.json" applied "$CID" "DONATION" "" ""
)
check "a missing state folder is created and both records keep mode 644" "y y" "$(regular644 "$S/status.json") $(regular644 "$S/changes/$CID.json")"
_control_status "$S/status.json" applied cidW "DONATION" "" ""
check "a change id that is not 16 hex updates status.json only" "cidW $CID.json" "$(jq -r .change_id "$S/status.json") $(ls -A "$S/changes")"
if mv --version >/dev/null 2>&1; then
    mkdir -p "$D/s9/status.json"
    printf 'keep' >"$D/s9/status.json/inner"
    _control_status "$D/s9/status.json" applied "$CID" "DONATION" "" ""
    check "a folder at status.json is left as it is" "inner" "$(ls -A "$D/s9/status.json")"
    check "no temporary entry is left behind" "changes status.json" "$(ls -A "$D/s9" | tr '\n' ' ' | sed 's/ $//')"
else
    echo "  skip a folder at status.json needs GNU mv"
fi

echo "== unit: links at record names are replaced, not followed =="
S="$D/s2"
mkdir -p "$S/changes"
target "$D/t-old" 1
ln -s "$D/t-old/0000000000000001.json" "$S/status.json.tmp.$$"
ln -s "$D/t-old/0000000000000001.json" "$S/changes/$CID.json.tmp.$$"
target "$D/t-status" 3
ln -s "$D/t-status" "$S/status.json"
target "$D/t-rec" 3
ln -s "$D/t-rec" "$S/changes/$CID.json"
before_old=$(sum "$D/t-old") before_status=$(sum "$D/t-status") before_rec=$(sum "$D/t-rec")
_control_status "$S/status.json" applied "$CID" "DONATION" "" ""
check "a link at the old temporary names keeps its target" "$before_old 1" "$(sum "$D/t-old") $(find "$D/t-old" -type f | wc -l | tr -d ' ')"
check "a link at status.json keeps its target folder" "$before_status 3 700" "$(sum "$D/t-status") $(find "$D/t-status" -type f | wc -l | tr -d ' ') $(mode "$D/t-status")"
check "a link at the indexed record keeps its target folder" "$before_rec 3 700" "$(sum "$D/t-rec") $(find "$D/t-rec" -type f | wc -l | tr -d ' ') $(mode "$D/t-rec")"
check "status.json is written as a regular file with mode 644" y "$(regular644 "$S/status.json")"
check "the indexed record is written as a regular file with mode 644" y "$(regular644 "$S/changes/$CID.json")"

echo "== unit: changes and pending are used only when they are real folders =="
S="$D/s3"
mkdir -p "$S"
target "$D/t-changes" 25
ln -s "$D/t-changes" "$S/changes"
target "$D/t-pending" 1
printf 'keep' >"$D/t-pending/$CID.json"
ln -s "$D/t-pending" "$S/pending"
before_changes=$(sum "$D/t-changes") before_pending=$(sum "$D/t-pending")
: >"$D/mktemp-dirs"
mktemp() {
    pwd -P >>"$D/mktemp-dirs"
    command mktemp "$@"
}
_control_status "$S/status.json" applied "$CID" "DONATION" "" ""
unset -f mktemp
check "no temporary folder is made inside a linked changes folder" "" "$(grep -F "$(cd -P "$D/t-changes" && pwd -P)" "$D/mktemp-dirs")"
check "a linked changes folder keeps its files" "$before_changes 25 700" "$(sum "$D/t-changes") $(find "$D/t-changes" -type f | wc -l | tr -d ' ') $(mode "$D/t-changes")"
check "a linked pending folder keeps its marker" "$before_pending 2" "$(sum "$D/t-pending") $(find "$D/t-pending" -type f | wc -l | tr -d ' ')"
check "status.json is still written" y "$(regular644 "$S/status.json")"

echo "== unit: the state folder may itself be a link =="
mkdir -p "$D/private/state"
ln -s "$D/private/state" "$D/s4"
_control_status "$D/s4/status.json" applied "$CID" "DONATION" "" ""
check "status.json lands in the linked folder" y "$(regular644 "$D/private/state/status.json")"
check "the indexed record lands in the linked folder" y "$(regular644 "$D/private/state/changes/$CID.json")"

echo "== unit: a temporary folder that is not the one created is not used =="
S="$D/s5"
mkdir -p "$S" "$D/t-swap"
mktemp() { ln -s "$D/t-swap" .rigforge-status.swapped && echo .rigforge-status.swapped; }
_control_status "$S/status.json" applied "$CID" "DONATION" "" ""
check "nothing is written through a linked temporary name" "" "$(ls -A "$D/t-swap")"
check "no record is written beside the linked temporary folder" absent "$([ -e "$D/status.json" ] && echo present || echo absent)"
if [ "$(id -u)" = 0 ]; then
    S="$D/s6"
    mkdir -p "$S"
    mktemp() { mkdir .rigforge-status.other && chown 65534 .rigforge-status.other && echo .rigforge-status.other; }
    _control_status "$S/status.json" applied "$CID" "DONATION" "" ""
    check "a temporary folder owned by another account is not used" "" "$(ls -A "$S/.rigforge-status.other")"
    check "no status.json is written from it" absent "$([ -e "$S/status.json" ] && echo present || echo absent)"
else
    echo "  skip a temporary folder owned by another account needs root"
fi
mktemp() { return 1; }
S="$D/s7"
mkdir -p "$S"
_control_status "$S/status.json" applied "$CID" "DONATION" "" ""
check "a failed temporary folder writes no status.json" absent "$([ -e "$S/status.json" ] && echo present || echo absent)"
unset -f mktemp

echo "== unit: the caller keeps running when the record cannot be written =="
printf 'x' >"$D/plain"
check "an unusable state folder does not end a set -e caller" survived "$(
    set -e
    _control_status "$D/plain/status.json" applied "$CID" "DONATION" "" ""
    echo survived
)"
check "a written record without a pending folder does not end a set -e caller" survived "$(
    set -e
    _control_status "$D/s10/status.json" applied "$CID" "DONATION" "" ""
    echo survived
)"
check "a terminal outcome is still noted" 1 "$(
    RIGFORGE_CONTROL_TERMINAL_WRITTEN=""
    _control_status "$D/plain/status.json" applied "$CID" "DONATION" "" ""
    echo "$RIGFORGE_CONTROL_TERMINAL_WRITTEN"
)"

[ "$fail" = 0 ] && echo "PASS control status write" || echo "FAIL control status write"
exit "$fail"
