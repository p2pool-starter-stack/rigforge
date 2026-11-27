#!/usr/bin/env bash
# Files, updates or closes the one security issue for a ref from an osv-scanner JSON result.
# Usage: osv-file-issue.sh <ref> <result.json> [<scanned-sha> [<run-url>]]
set -euo pipefail

ref=${1:?usage: osv-file-issue.sh <ref> <result.json> [sha [run-url]]}
result=${2:?usage: osv-file-issue.sh <ref> <result.json> [sha [run-url]]}
sha=${3:-unknown}
run_url=${4:-}
GH=${GH:-gh}
FLOOR=${OSV_FLOOR:-7.0}

[[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "refusing ref '$ref'" >&2
    exit 1
}
jq -e '.results' "$result" >/dev/null

title="Security: dependency vulnerabilities on ${ref}"
in30=$(date -u -d '+30 days' +%F 2>/dev/null || date -u -v+30d +%F)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

jq -r '
  [.results[]?.packages[]? | . as $p | .groups[]? | . as $g
   | {pkg: $p.package.name, ver: $p.package.version, ids: ($g.ids | join(", ")),
      score: ((try ($g.max_severity | tonumber) catch 0) // 0),
      fixed: ([$p.vulnerabilities[]? | select(.id as $i | $g.ids | index($i))
               | .affected[]? | select(.package.name == $p.package.name)
               | .ranges[]?.events[]? | .fixed // empty] | first // "")}]
  | unique | sort_by(-.score) | .[] | [.pkg, .ver, .ids, .score, .fixed] | @tsv' \
    "$result" >"$work/rows.tsv"

n=$("$GH" issue list --state open --label security-baseline --limit 200 --json number,title |
    jq -r --arg t "$title" 'map(select(.title == $t)) | .[0].number // empty')

high=0
awk -F'\t' -v f="$FLOOR" '$4 + 0 >= f + 0 { c++ } END { exit !c }' "$work/rows.tsv" && high=1

if [ "$high" = 0 ]; then
    if [ -n "$n" ]; then
        "$GH" issue close "$n" --comment "A clean osv-scanner run on ${ref} at ${sha} found nothing at or above severity ${FLOOR}."
        echo "clean: closed #$n"
    else
        echo "clean: nothing to file for ${ref}"
    fi
    exit 0
fi

prev=""
[ -n "$n" ] && prev=$("$GH" issue view "$n" --json body --jq .body)

row() {
    local pkg ver ids score fixed kind date
    IFS=$'\t' read -r pkg ver ids score fixed <<<"$1"
    kind=review
    [ -n "$fixed" ] && kind=expires
    date=$(printf '%s\n' "$prev" | sed -nE "/\| ${ids} \|/s/.*(${kind}): ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\2/p" | head -1)
    printf '| %s | %s | %s | %s | %s | %s: %s |\n' "$pkg" "$ver" "$ids" "$score" "${fixed:--}" "$kind" "${date:-$in30}"
}
table() {
    printf '| package | version | advisories | CVSS | fixed in | deadline |\n|---|---|---|---|---|---|\n'
    while IFS= read -r line; do
        [ -n "$line" ] && row "$line"
    done
}

{
    printf '## What'"'"'s the problem\n\n'
    printf 'osv-scanner found known vulnerabilities in the dependency manifests of `%s` (scanned at `%s`).\n\n' "$ref" "$sha"
    printf '### At or above severity %s\n\n' "$FLOOR"
    awk -F'\t' -v f="$FLOOR" '$4 + 0 >= f + 0' "$work/rows.tsv" | table
    if awk -F'\t' -v f="$FLOOR" '$4 + 0 < f + 0 { c++ } END { exit !c }' "$work/rows.tsv"; then
        printf '\n### Lower severity (rollup)\n\n'
        awk -F'\t' -v f="$FLOOR" '$4 + 0 < f + 0' "$work/rows.tsv" | table
    fi
    printf '\nAdvisory ids resolve at https://osv.dev/. Advisory text is not copied here.\n\n'
    printf '## What it impacts\n\nThe dependency tree shipped from or used to build this ref.\n\n'
    printf '## How I found it\n\nThe daily osv-scanner sweep'
    [ -n "$run_url" ] && printf ' (%s)' "$run_url"
    printf '.\n\n## How important is it\n\nRows at or above severity %s are priority. A row with a fix carries `expires:` 30 days out; a row without one carries `review:` and never blocks anything.\n\n' "$FLOOR"
    printf '## Acceptance criteria\n\n- A later sweep of this ref reports nothing at or above severity %s, and closes this issue.\n\n' "$FLOOR"
    printf '## Possible solutions\n\nBump the listed package to the fixed version, or pin it through an overrides entry; for an unfixed advisory, record why it is accepted.\n'
} >"$work/body.md"

"$GH" label create security-baseline --force --description "Daily dependency sweep finding" >/dev/null
"$GH" label create "branch:${ref}" --force --description "Finding on ${ref}" >/dev/null

if [ -n "$n" ]; then
    "$GH" issue edit "$n" --body-file "$work/body.md"
    echo "updated #$n"
else
    "$GH" issue create --title "$title" --label security --label security-baseline --label "branch:${ref}" --body-file "$work/body.md"
fi
