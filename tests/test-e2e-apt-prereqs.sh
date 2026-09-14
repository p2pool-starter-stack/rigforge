# shellcheck shell=bash disable=SC2016,SC2034
echo "== unit: e2e apt prerequisites retry (#449) =="
T449="$(mktemp -d "$SANDBOX/apt-prereqs.XXXXXX")"
mkdir -p "$T449/bin"
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in update) n=$(awk '\''END { print NR + 0 }'\'' "$APT_ATTEMPTS"); echo try >>"$APT_ATTEMPTS"; [ "$n" -ge "$APT_FAIL_FOR" ] || { echo "Hash Sum mismatch" >&2; exit 100; } ;; esac' \
    'exit 0' >"$T449/bin/apt-get"
chmod +x "$T449/bin/apt-get"

apt_prereq_case() { # <failed attempts> -> transcript
    : >"$T449/attempts"
    : >"$T449/sleeps"
    APT_FAIL_FOR="$1" APT_ATTEMPTS="$T449/attempts" APT_SLEEPS="$T449/sleeps" ROOT="$ROOT" PATH="$T449/bin:$PATH" bash -c '
        sleep() { printf "%s\n" "$1" >>"$APT_SLEEPS"; }
        E2E_LIB_ONLY=1 source "$ROOT/tests/e2e/in-container.sh"
        if _apt_prereqs; then result=OK; else result=ABORT; fi
        printf "%s attempts=%s sleeps=%s\n" "$result" "$(awk '\''END { print NR + 0 }'\'' "$APT_ATTEMPTS")" "$(paste -sd, "$APT_SLEEPS")"
    ' 2>&1
}

assert_eq "e2e: a hash/size mismatch is named as a mirror mid-sync, NOT the network (#442)" "$( (E2E_LIB_ONLY=1 source "$ROOT/tests/e2e/in-container.sh" && _apt_failure_reason "E: Failed to fetch x  Hash Sum mismatch") 2>/dev/null)" "the archive served an index that does not match its Release file (a mirror mid-sync; it clears on a re-run)"
assert_eq "e2e: apt's other mirror-desync string is the same class (#442)" "$( (E2E_LIB_ONLY=1 source "$ROOT/tests/e2e/in-container.sh" && _apt_failure_reason "E: Failed to fetch y  File has unexpected size (10 != 12)") 2>/dev/null)" "the archive served an index that does not match its Release file (a mirror mid-sync; it clears on a re-run)"
assert_eq "e2e: near-miss control — 'unexpected size' outside apt's own sentence is not a mirror (#442)" "$( (E2E_LIB_ONLY=1 source "$ROOT/tests/e2e/in-container.sh" && _apt_failure_reason "E: rsync reported an unexpected size for /x") 2>/dev/null)" "see the apt output above for the cause"
assert_eq "e2e: control — every other failure defers to apt's own output (#442)" "$( (E2E_LIB_ONLY=1 source "$ROOT/tests/e2e/in-container.sh" && _apt_failure_reason "E: Unable to locate package jq") 2>/dev/null)" "see the apt output above for the cause"

out="$(apt_prereq_case 0)"
assert_contains "e2e: apt success stops after its first attempt (#449)" "$out" "OK attempts=1 sleeps="
out="$(apt_prereq_case 1)"
assert_contains "e2e: apt retries once, then breaks on success (#449)" "$out" "OK attempts=2 sleeps=5"
assert_contains "e2e: apt retry notice names the attempt and bound (#449)" "$out" "attempt 1/3"
out="$(apt_prereq_case 3)"
assert_contains "e2e: apt failure spends the three-attempt bound (#449)" "$out" "ABORT attempts=3 sleeps=5,10"
assert_contains "e2e: apt abort names the mirror mid-sync (#449)" "$out" "failed after 3 attempts — the archive served an index that does not match its Release file (a mirror mid-sync; it clears on a re-run)"
assert_absent "e2e: apt abort no longer blames the network (#449)" "$out" "no network / archive down"
