#!/usr/bin/env bash
# Opens or updates the one open security issue with an exact title, or closes it.
# Usage: file-security-issue.sh open|close <title> <body-file> [extra-label...]
set -euo pipefail

mode=${1:?usage: file-security-issue.sh open|close <title> <body-file> [label...]}
title=${2:?title}
body=${3:?body-file}
shift 3 || true
GH=${GH:-gh}

n=$("$GH" issue list --state open --label security --limit 200 --json number,title |
    jq -r --arg t "$title" 'map(select(.title == $t)) | .[0].number // empty')

case "$mode" in
open)
    if [ -n "$n" ]; then
        "$GH" issue edit "$n" --body-file "$body"
        echo "updated #$n"
    else
        labels=(--label security)
        for l in "$@"; do labels+=(--label "$l"); done
        "$GH" issue create --title "$title" "${labels[@]}" --body-file "$body"
    fi
    ;;
close)
    if [ -n "$n" ]; then
        "$GH" issue close "$n" --comment "$(cat "$body")"
        echo "closed #$n"
    else
        echo "no open issue to close"
    fi
    ;;
*)
    echo "mode must be open or close" >&2
    exit 1
    ;;
esac
