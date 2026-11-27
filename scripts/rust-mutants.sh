#!/usr/bin/env bash
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
table=${1:-$root/tests/rust/mutants.tsv}
cargo_cmd=${CARGO:-cargo}
target=${RUST_MUTANTS_TARGET:-${TMPDIR:-/tmp}/rigforge-mutants-target}
only=${RUST_MUTANTS_ROWS:-}
tab=$(printf '\t')
nl=$'\n'

[ -r "$table" ] || {
    echo "rust-mutants: cannot read $table" >&2
    exit 2
}

work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
cp -R "$root/crates" "$root/Cargo.toml" "$root/Cargo.lock" "$root/rust-toolchain.toml" "$work/" || exit 2

run_tests() {
    local filter=$1 log=$2
    # shellcheck disable=SC2086
    (cd "$work" && CARGO_TARGET_DIR=$target $cargo_cmd test --locked -p rigforge-core $filter) >"$log" 2>&1
}

selected() {
    [ -z "$only" ] && return 0
    case " $only " in
    *" $1 "*) return 0 ;;
    esac
    return 1
}

total=0
killed=0
bad=0
baselined=""
n=0

while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    selected "$n" || continue
    total=$((total + 1))
    file=${line%%"$tab"*}
    rest=${line#*"$tab"}
    from=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    to=${rest%%"$tab"*}
    filter=${rest#*"$tab"}
    from=${from//@N/$nl}
    to=${to//@N/$nl}
    log=$work/row-$n.log

    if [ ! -f "$root/$file" ] || [ -z "$from" ] || [ "$from" = "$to" ] || [ -z "$filter" ]; then
        echo "row $n REFUSED (bad row): $file"
        bad=$((bad + 1))
        continue
    fi

    orig=$(
        cat "$root/$file"
        printf x
    )
    orig=${orig%x}
    stripped=${orig//"$from"/}
    count=$(((${#orig} - ${#stripped}) / ${#from}))
    if [ "$count" -ne 1 ]; then
        echo "row $n REFUSED (text found $count times, need exactly 1): $file"
        bad=$((bad + 1))
        continue
    fi

    case "$baselined" in
    *"[$filter]"*) ;;
    *)
        if ! run_tests "$filter" "$log"; then
            echo "row $n BASELINE RED: $filter is not green on the untouched tree"
            bad=$((bad + 1))
            continue
        fi
        baselined="${baselined}[$filter]"
        ;;
    esac

    printf '%s%s%s' "${orig%%"$from"*}" "$to" "${orig#*"$from"}" >"$work/$file"
    run_tests "$filter" "$log"
    status=$?
    printf '%s' "$orig" >"$work/$file"

    if [ "$status" -eq 0 ]; then
        echo "row $n SURVIVED: $file :: $filter"
        bad=$((bad + 1))
    elif grep -q 'could not compile\|^error\[' "$log"; then
        echo "row $n DID NOT COMPILE (not a kill): $file"
        bad=$((bad + 1))
    elif grep -q 'test result: FAILED' "$log"; then
        echo "row $n killed: $file :: $filter"
        killed=$((killed + 1))
    else
        echo "row $n UNCLEAR (red without a failed test): $file"
        tail -n 15 "$log"
        bad=$((bad + 1))
    fi
done <"$table"

echo "rust-mutants: $killed of $total rows killed, $bad not"
[ "$total" -gt 0 ] && [ "$bad" -eq 0 ]
