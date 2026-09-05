#!/usr/bin/env bash
# Fixtures for scripts/lint-file-budget.sh (#407). Each case builds a THROWAWAY git repo, plants one
# specific situation, runs the real gate inside it, and asserts on the verdict AND on the message —
# a gate that fails for the wrong reason is not this gate working.
#
# Every failure case is paired with the clean case it was derived from, so a fixture that has stopped
# arming (the tree no longer has the shape the case is about) shows up as an unexpected PASS rather
# than as a silent green. The clean case is the control: without it, a gate that refused EVERYTHING
# would pass every row below.
#
# Run via `scripts/lint-file-budget.sh --self-test`, which execs this file.
set -euo pipefail

GATE="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lint-file-budget.sh"
[ -f "$GATE" ] || {
    echo "self-test FAIL: cannot find the gate beside this file at $GATE" >&2
    exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
st_fail=0

pass() { echo "  self-test ok: $1"; }
fail() {
    echo "  self-test FAIL: $1"
    st_fail=1
}

# A repo with `develop` as the base branch, the gate installed, and one ordinary small source file so
# the candidate enumeration is never empty for a reason the case did not intend.
# NOTE: this runs inside $( ), i.e. a SUBSHELL — a counter incremented here would never reach the
# parent, and every case would silently reuse one repo. mktemp is the only naming that survives that.
mkrepo() { # -> echoes the repo path
    local d
    d=$(mktemp -d "$TMP/repo.XXXXXX")
    mkdir -p "$d/scripts" "$d/docs/dev"
    cp "$GATE" "$d/scripts/lint-file-budget.sh"
    printf 'echo hello\n' >"$d/small.sh"
    git -C "$d" init -q -b develop
    git -C "$d" config user.email selftest@example.invalid
    git -C "$d" config user.name selftest
    echo "$d"
}

# Write a file of exactly <n> lines.
mklines() { # <path> <n>
    local p="$1" count="$2" i
    : >"$p"
    for ((i = 1; i <= count; i++)); do printf 'line %s\n' "$i" >>"$p"; done
}

commit_all() { # <repo> <msg>
    git -C "$1" add -A
    git -C "$1" commit -qm "$2"
}

# Run the gate in <repo>; sets RC and OUT.
run_gate_in() { # <repo>
    OUT=$(cd "$1" && bash scripts/lint-file-budget.sh 2>&1) && RC=0 || RC=$?
}

expect_pass() { # <desc> <repo>
    run_gate_in "$2"
    if [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1 (expected pass, got rc $RC: $OUT)"; fi
}

expect_fail() { # <desc> <repo> <needle the message must carry>
    run_gate_in "$2"
    if [ "$RC" -eq 0 ]; then
        fail "$1 (expected a refusal, the gate PASSED — this fixture may have stopped arming)"
    elif [[ "$OUT" != *"$3"* ]]; then
        fail "$1 (refused, but not for the stated reason; wanted [$3], got: $OUT)"
    else
        pass "$1"
    fi
}

budget() { # <repo> <rows...>  — writes docs/dev/file-budget.tsv
    local d="$1"
    shift
    {
        echo "# selftest budget"
        printf '%s\n' "$@"
    } >"$d/docs/dev/file-budget.tsv"
}

# --- the control: a correctly budgeted tree passes ----------------------------------------------
# Everything below is this repo with ONE thing changed, so a row that fails tells you which thing.
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
expect_pass "a tree whose over-target file has a matching ceiling passes" "$R"

# --- rule 1: an over-target file with no row ----------------------------------------------------
R=$(mkrepo)
mklines "$R/big.sh" 500
commit_all "$R" base
expect_fail "an over-target file with no budget row is refused" "$R" "has no"

# --- rule 1: a NEW file over the hard ceiling ---------------------------------------------------
R=$(mkrepo)
mklines "$R/huge.sh" 900
commit_all "$R" base
expect_fail "an unbudgeted file over the hard ceiling names the hard ceiling" "$R" "hard ceiling of 800"

# --- rule 2: growth past a recorded ceiling -----------------------------------------------------
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
mklines "$R/big.sh" 501 # one line over: the ratchet's whole point is that one is enough
expect_fail "growing a budgeted file by ONE line past its ceiling is refused" "$R" "over its recorded ceiling"

# --- rule 2: a file that shrank back under target must drop its row -----------------------------
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
mklines "$R/big.sh" 100
expect_fail "a file back under target must drop its entry" "$R" "Remove the entry"

# --- a stale row naming a file that no longer exists ---------------------------------------------
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')" "$(printf 'gone.sh\t900')"
commit_all "$R" base
expect_fail "a row naming a file that does not exist is refused" "$R" "no longer exists"

# --- a row naming an EXEMPT path (the exemption and the budget must not disagree) ----------------
R=$(mkrepo)
mklines "$R/big.sh" 500
mklines "$R/notes.md" 900
budget "$R" "$(printf 'big.sh\t500')" "$(printf 'notes.md\t900')"
commit_all "$R" base
expect_fail "a row naming an exempt path is refused" "$R" "now exempt"

# --- exemptions really exempt: a huge .md and .json trip nothing ---------------------------------
R=$(mkrepo)
mklines "$R/notes.md" 900
mklines "$R/config.json" 900
commit_all "$R" base
expect_pass "a 900-line .md and .json are exempt and trip nothing" "$R"

# --- binaries are skipped generically, not by a path list ----------------------------------------
R=$(mkrepo)
printf '\000\001\002\003' >"$R/blob.bin"
for _ in $(seq 1 900); do printf '\000\n' >>"$R/blob.bin"; done
commit_all "$R" base
expect_pass "a 900-line binary file is skipped by the grep -I detector" "$R"

# --- monotonic: a ceiling may not RISE against the base ------------------------------------------
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
mklines "$R/big.sh" 600
budget "$R" "$(printf 'big.sh\t600')" # record the growth AND raise the ceiling: still refused
expect_fail "raising a recorded ceiling is refused even when it matches the file" "$R" "Ceilings only go down"

# --- monotonic: a first appearance must record the real count, not reserve headroom --------------
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
mklines "$R/other.sh" 450
budget "$R" "$(printf 'big.sh\t500')" "$(printf 'other.sh\t900')"
expect_fail "a new row that reserves headroom above the real count is refused" "$R" "not reserve headroom"

# The same case with the honest number is the control — without it, the row above would also pass if
# the gate simply refused every new row.
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
mklines "$R/other.sh" 450
budget "$R" "$(printf 'big.sh\t500')" "$(printf 'other.sh\t450')"
expect_pass "a new row recording the file's real count is accepted" "$R"

# --- count_lines counts records, not trailing newlines -------------------------------------------
# `wc -l` reports 449 for a 450-record file with no final newline. A ceiling of 450 written from
# `wc -l` would be 449 and the gate would refuse it — so this pins that the gate's own counter and
# the number a contributor is told to record are the same number.
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
mklines "$R/nonl.sh" 449
printf 'line 450' >>"$R/nonl.sh" # 450th record, no trailing newline
budget "$R" "$(printf 'big.sh\t500')" "$(printf 'nonl.sh\t450')"
expect_pass "a file with no trailing newline is counted by record, not by wc -l" "$R"

# --- the empty-enumeration guard -----------------------------------------------------------------
# A broken enumeration and a clean tree both scan zero files; only one of them is success.
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
if OUT=$(cd "$R" && PATH="$TMP/nogit:$PATH" bash -c '
    mkdir -p "'"$TMP"'/nogit"
    printf "#!/usr/bin/env bash\nexit 0\n" > "'"$TMP"'/nogit/git"
    chmod +x "'"$TMP"'/nogit/git"
    PATH="'"$TMP"'/nogit:$PATH" bash scripts/lint-file-budget.sh' 2>&1); then
    fail "an empty git-ls-files enumeration did not fail loudly"
elif [[ "$OUT" == *"enumerated zero tracked files"* ]]; then
    pass "an empty git-ls-files enumeration fails loudly instead of reading as clean"
else
    # Deliberately NOT a bare *FATAL* match. The gate has a SECOND fatal guard for an empty
    # CANDIDATE list, which also fires on this fixture; matching only "FATAL" made this row green
    # off the wrong door, and a mutation that deleted enforce_nonempty_enumeration outright still
    # passed it. Name the guard under test.
    fail "the empty-enumeration run failed, but not via enforce_nonempty_enumeration (got: $OUT)"
fi

# --- no base ref: the monotonic check SKIPS, loudly, and does not silently pass -------------------
# A skipped check that reads like a green one is what this whole gate is trying not to become.
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
git -C "$R" branch -m develop other
run_gate_in "$R"
if [ "$RC" -ne 0 ]; then
    fail "with no base ref the gate should still run its other rules (got rc $RC: $OUT)"
elif [[ "$OUT" == *"skipping the"* ]]; then
    pass "with no base ref resolvable the monotonic check is skipped with a visible note"
else
    fail "with no base ref the monotonic check was skipped SILENTLY (got: $OUT)"
fi

# --- ...and under FILE_BUDGET_REQUIRE_BASE=1 the same situation is FATAL, not a note --------------
# This is the pair that matters: the row above proves the gate keeps working without a base ref, and
# this one proves CI cannot be left running only half the gate by a broken checkout.
R=$(mkrepo)
mklines "$R/big.sh" 500
budget "$R" "$(printf 'big.sh\t500')"
commit_all "$R" base
git -C "$R" branch -m develop other
OUT=$(cd "$R" && FILE_BUDGET_REQUIRE_BASE=1 bash scripts/lint-file-budget.sh 2>&1) && RC=0 || RC=$?
if [ "$RC" -eq 0 ]; then
    fail "FILE_BUDGET_REQUIRE_BASE=1 with no base ref should be fatal, but the gate passed"
elif [[ "$OUT" == *"FILE_BUDGET_REQUIRE_BASE=1"* ]]; then
    pass "FILE_BUDGET_REQUIRE_BASE=1 turns a missing base ref into a refusal, not a skip"
else
    fail "FILE_BUDGET_REQUIRE_BASE=1 refused, but not for the missing base ref (got: $OUT)"
fi

if [ "$st_fail" -eq 0 ]; then
    echo "lint-file-budget self-test OK"
    exit 0
fi
echo "lint-file-budget self-test FAILED"
exit 1
