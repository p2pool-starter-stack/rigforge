#!/usr/bin/env bash
# The file-budget ratchet gate (#407): stop the biggest files in this repo from getting any bigger,
# without demanding anyone rewrite them today. Two rules:
#
#   1. A candidate file (tracked, or untracked and not gitignored) over the 400-line target must
#      record a ceiling in docs/dev/file-budget.tsv; over 800 the refusal names the hard ceiling
#      instead, because a NEW file has no reason to be born that big.
#   2. An existing offender gets its CURRENT line count recorded in docs/dev/file-budget.tsv as a
#      personal ceiling. A PR may not grow that file past its recorded ceiling. Ceilings only ever
#      go DOWN — this script rejects any budget edit that raises one, checked against the base
#      branch — and a file that shrinks back to <=400 must drop its entry.
#
# WHY THIS EXISTS, from the two costs pithead paid on the same curve before rigforge got here: the
# linter was using over 7 GB of RSS on a single grown test file and took whole sessions down with
# it, and later reached CI and blocked every PR until the invocation was split; and retrofitting one
# ran ~20 PRs, because the coupling a monolith accumulates (shared sandbox state, order-dependent
# assertions) only surfaces once you pull it apart. A ceiling recorded today costs nothing.
#
# Exemptions are enumerated by path/glob in is_exempt() below, each with its own reason. Binary
# files are detected generically (grep -I), never listed.
#
# rigforge.sh is DELIBERATELY NOT EXEMPT. pithead exempts its own shipped `pithead` script, and the
# reason is specific to it: that file is a BUILD PRODUCT generated from lib/pithead/*.sh, and the
# slices carry the rows instead. rigforge.sh is not generated from anything — it is the source, the
# largest hand-written file here after tests/run.sh, and exempting it would exempt most of what this
# gate exists to hold. It gets an ordinary ratcheting row like any other source file.
#
# Ported from pithead's scripts/lint-file-budget.sh, with its develop/develop-v2 twin resolution
# dropped: this repo has one integration branch, and carrying the twin logic would have been dead
# code asserting a branch model that does not exist here.
#
# Run `--self-test` first (fixtures for every failure mode, including the empty-enumeration guard);
# `--generate` reprints the budget for every current non-exempt offender, for seeding or refreshing
# the file by hand — it never writes the file itself and never lowers the bar for you.
set -euo pipefail

TARGET_LINES=400
HARD_CEILING=800
BUDGET_FILE="docs/dev/file-budget.tsv"

# The branch this PR ratchets against. `develop` is the integration branch (CONTRIBUTING.md); `main`
# is released-only and never the base of a working branch. Falls back to the bare local name, and if
# nothing resolves the monotonic check is SKIPPED WITH A LOUD NOTE rather than passing silently —
# a skipped check that reads like a green one is the failure this gate is trying not to become.
resolve_base_ref() {
    local dev
    for dev in origin/develop develop; do
        if git rev-parse -q --verify "$dev" >/dev/null 2>&1; then
            echo "$dev"
            return 0
        fi
    done
    echo ""
}

# A broken enumeration and a genuinely clean tree both read as "zero hits" — refuse to treat an
# empty candidate list as success. Mirrors lint-topology-classes.sh's own guard.
enforce_nonempty_enumeration() {
    if [ "$(git ls-files | wc -l)" -eq 0 ]; then
        echo "FATAL: git ls-files enumerated zero tracked files. A broken enumeration and a" >&2
        echo "clean tree both scan zero hits — refusing to report either as success." >&2
        return 1
    fi
    return 0
}

# --- exemptions, one glob per reason (case pattern matching: '*' matches '/' too) ---------------
is_exempt() {
    case "$1" in
    # Prose documentation, including CHANGELOG.md — it grows by nature (one entry per release) and
    # is not source to split. This gate governs code.
    *.md) return 0 ;;
    # Data/config, not source: config.reference.json, config.minimal.json, and JSON fixtures.
    *.json) return 0 ;;
    *) return 1 ;;
    esac
}

# grep -I treats a binary file as non-matching instead of reading it as text; an empty file never
# matches either, but an empty file also never trips a line-count ceiling, so folding the two
# together is safe. Skips images and other binary blobs generically, no path list needed.
is_binary_or_empty() {
    ! LC_ALL=C grep -Iq . "$1" 2>/dev/null
}

# Count lines by record, not by trailing newline (`wc -l` undercounts a file with no final newline
# by one — exactly the off-by-one a ceiling comparison would otherwise hide).
count_lines() {
    awk 'END { print NR + 0 }' "$1" 2>/dev/null || echo 0
}

# Every tracked OR untracked-but-not-gitignored, non-exempt, non-binary file: "path<TAB>lines", one
# per line. `git ls-files` alone only lists the INDEX — a new file sits invisible right up until
# `git add`, which is exactly the moment a budget gate exists to catch it. Union in `--others
# --exclude-standard` (untracked, honoring .gitignore) so the working tree, not the index, is what
# gets measured; the two lists are disjoint (`--others` never repeats a tracked path).
list_candidates() {
    local f
    {
        git ls-files
        git ls-files --others --exclude-standard
    } | while IFS= read -r f; do
        [ -f "$f" ] || continue
        is_exempt "$f" && continue
        is_binary_or_empty "$f" && continue
        printf '%s\t%s\n' "$f" "$(count_lines "$f")"
    done
}

# Parse a budget file (path<TAB>ceiling, '#' comments and blank lines skipped) from stdin.
parse_budget() {
    grep -vE '^[[:space:]]*(#|$)' | awk -F'\t' 'NF==2 {print $1"\t"$2}'
}

# --- the gate itself --------------------------------------------------------------------------
run_gate() {
    local fail=0 path lines ceiling budget_lines
    enforce_nonempty_enumeration || return 1

    budget_lines=$([ -f "$BUDGET_FILE" ] && parse_budget <"$BUDGET_FILE" || true)

    local candidates
    candidates=$(list_candidates)
    if [ -z "$candidates" ]; then
        echo "FATAL: the candidate scan (git ls-files, minus exemptions/binaries) returned zero" >&2
        echo "files. That is never a legitimately clean result for this tree — refusing to pass." >&2
        return 1
    fi

    while IFS=$'\t' read -r path lines; do
        [ -n "$path" ] || continue
        ceiling=$(printf '%s\n' "$budget_lines" | awk -F'\t' -v p="$path" '$1==p {print $2; exit}')
        if [ -n "$ceiling" ]; then
            if [ "$lines" -gt "$ceiling" ]; then
                echo "file-budget: FAIL — $path is $lines lines, over its recorded ceiling of $ceiling ($BUDGET_FILE)."
                fail=1
            elif [ "$lines" -le "$TARGET_LINES" ]; then
                echo "file-budget: FAIL — $path is $lines lines (<= $TARGET_LINES target) but still has a" \
                    "$BUDGET_FILE entry (ceiling $ceiling). Remove the entry."
                fail=1
            fi
        elif [ "$lines" -gt "$HARD_CEILING" ]; then
            echo "file-budget: FAIL — $path is $lines lines, over the hard ceiling of $HARD_CEILING for a" \
                "new/unbudgeted file (target: $TARGET_LINES)."
            fail=1
        elif [ "$lines" -gt "$TARGET_LINES" ]; then
            # The other half of the same rule: an entry IFF over target. --generate emits exactly
            # this set, so the gate refuses what its own generator would write.
            echo "file-budget: FAIL — $path is $lines lines (> $TARGET_LINES target) but has no" \
                "$BUDGET_FILE entry. Add one: scripts/lint-file-budget.sh --generate."
            fail=1
        fi
    done <<<"$candidates"

    # Every budget entry must name a real, currently-exempt-free file — a stale entry (deleted,
    # renamed, or exempted since) hides drift instead of proving anything.
    while IFS=$'\t' read -r path ceiling; do
        [ -n "$path" ] || continue
        if [ ! -f "$path" ] || is_exempt "$path"; then
            echo "file-budget: FAIL — $BUDGET_FILE lists '$path', which no longer exists (or is now" \
                "exempt). Remove the entry."
            fail=1
        fi
    done <<<"$budget_lines"

    check_monotonic || fail=1

    if [ "$fail" -ne 0 ]; then
        echo "See CONTRIBUTING.md — file budget gate."
        return 1
    fi
    echo "file budget OK — every over-target file has a ceiling, none grew past it, $BUDGET_FILE is monotonic."
    return 0
}

# Ceilings only ever go down. Compare the working-tree budget against the base branch's: any path
# present in both whose ceiling ROSE is a rejected edit, and any path with NO row on the base ref
# (a first appearance) must record the file's REAL count rather than reserve headroom under it.
# Those are the same rule: a number that is not the file's actual size is slack, and slack in a
# ratchet is the one thing it exists to prevent — nothing mechanical would object again until the
# file had grown into it. There is deliberately NO exemption arm here; pithead carries one for a
# generated artifact's un-split remainder, and this repo has no generated artifact.
check_monotonic() {
    local base old_lines new_lines fail=0 path old_ceiling new_ceiling actual
    base=$(resolve_base_ref)
    if [ -z "$base" ]; then
        # A skipped check reads exactly like a passed one, and this is the half of the ratchet that
        # matters most — so CI sets FILE_BUDGET_REQUIRE_BASE=1 and a missing base ref is FATAL there
        # rather than a note nobody reads. `actions/checkout` is shallow by default and does NOT
        # fetch origin/develop; the lint job asks for fetch-depth: 0 for exactly this reason, and
        # this flag is what turns a regression in that wiring into a red instead of a silent
        # degradation to "only half the gate runs".
        if [ "${FILE_BUDGET_REQUIRE_BASE:-0}" = 1 ]; then
            echo "file-budget: FAIL — no base ref (origin/develop or develop) resolvable, and" \
                "FILE_BUDGET_REQUIRE_BASE=1. The monotonic-ceiling check cannot run, and skipping it" \
                "silently is the failure this gate exists to prevent. Fetch the base branch" \
                "(actions/checkout fetch-depth: 0)." >&2
            return 1
        fi
        echo "file-budget: NOTE — no base ref (origin/develop or develop) resolvable; skipping the" \
            "monotonic-ceiling check. Set FILE_BUDGET_REQUIRE_BASE=1 to make this fatal (CI does)." >&2
        return 0
    fi
    [ -f "$BUDGET_FILE" ] || return 0
    old_lines=$(git show "$base:$BUDGET_FILE" 2>/dev/null | parse_budget || true)
    new_lines=$(parse_budget <"$BUDGET_FILE")

    # count_lines is this gate's own counter (not wc -l, which undercounts a file with no trailing
    # newline) and falls back to 0 when the path cannot be read, so a deleted or unreadable path
    # mismatches any ceiling and fails CLOSED rather than passing.
    while IFS=$'\t' read -r path new_ceiling; do
        [ -n "$path" ] || continue
        old_ceiling=$(printf '%s\n' "$old_lines" | awk -F'\t' -v p="$path" '$1==p {print $2; exit}')
        if [ -z "$old_ceiling" ]; then
            actual=$(count_lines "$path")
            if [ "$new_ceiling" != "$actual" ]; then
                echo "file-budget: FAIL — $BUDGET_FILE adds $path as a new row at ceiling" \
                    "$new_ceiling, but the file is $actual lines. A row's first appearance must" \
                    "record the real count, not reserve headroom."
                fail=1
            fi
            continue
        fi
        if [ "$new_ceiling" -gt "$old_ceiling" ]; then
            echo "file-budget: FAIL — $BUDGET_FILE raises $path's ceiling from $old_ceiling to" \
                "$new_ceiling. Ceilings only go down."
            fail=1
        fi
    done <<<"$new_lines"

    return "$fail"
}

# Reprint the budget the current tree implies (every non-exempt file over target). Never writes the
# file — review the diff and commit it by hand, same as any other ratchet edit.
generate_budget() {
    printf '%s\n' \
        '# Generated by scripts/lint-file-budget.sh --generate. See this script header for the' \
        '# target/ceiling rationale and CONTRIBUTING.md for the gate.'
    printf '# path<TAB>ceiling-in-lines. Ceilings only ever go down; a file at or below %s lines drops its entry.\n' \
        "$TARGET_LINES"
    list_candidates | awk -F'\t' -v t="$TARGET_LINES" '$2 > t {print}' | sort
}

# The fixtures live in lint-file-budget-selftest.sh, which SOURCES this file for the functions
# above. Sourcing must therefore define everything and run nothing: without this guard, `source`
# would fall straight into the dispatch below and run the gate against whatever directory the
# caller happened to be in. Executing this script directly dispatches exactly as it always did.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

case "${1:-}" in
--self-test)
    # Resolve the link before taking the dirname: through a symlink, `dirname "$0"` gives the
    # LINK's directory, so the exec misses and the gate exits 127 — a mis-typed failure rather than
    # a self-test verdict.
    exec bash "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lint-file-budget-selftest.sh"
    ;;
--generate)
    generate_budget
    exit 0
    ;;
"")
    run_gate
    exit $?
    ;;
*)
    echo "usage: $0 [--self-test|--generate]" >&2
    exit 2
    ;;
esac
