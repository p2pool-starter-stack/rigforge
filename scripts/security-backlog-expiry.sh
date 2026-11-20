#!/usr/bin/env bash
# Warn (then fail) a PR while a fixable security-baseline issue for its base branch is past its expiry.
set -euo pipefail

: "${BASE_REF:?}" "${TODAY:?}" "${ENFORCE_FROM:?}"
HEAD_REF=${HEAD_REF:-}
PR_AUTHOR=${PR_AUTHOR:-}
PR_LABELS=${PR_LABELS:-}
PR_BODY=${PR_BODY:-}

case "$BASE_REF" in
develop | develop-v*) ;;
*)
    echo "base $BASE_REF is not gated"
    exit 0
    ;;
esac

if [ "$PR_AUTHOR" = "dependabot[bot]" ] || [[ "$HEAD_REF" == bot/xmrig-* ]]; then
    echo "exempt: dependency bot PR"
    exit 0
fi
case ",$PR_LABELS," in
*,security,*)
    echo "exempt: PR is labelled security"
    exit 0
    ;;
esac

if [ -n "${ISSUES_FILE:-}" ]; then
    issues=$(cat "$ISSUES_FILE")
else
    issues=$(gh issue list --state open --label security-baseline --label "branch:$BASE_REF" \
        --limit 100 --json number,body)
fi

rows=$(jq -r '.[] | [.number, (first((.body // "") | scan("(?:^|\\n)\\s*expires:\\s*([0-9]{4}-[0-9]{2}-[0-9]{2})")[0]) // "")] | @tsv' <<<"$issues")
lapsed=0
while IFS=$'\t' read -r number expires; do
    [ -n "$expires" ] || continue
    [[ "$expires" < "$TODAY" ]] || continue
    if grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#${number}([^0-9]|$)" <<<"$PR_BODY"; then
        echo "issue #$number expired $expires but this PR closes it"
        continue
    fi
    echo "::warning::Security baseline issue #$number expired on $expires"
    lapsed=$((lapsed + 1))
done <<<"$rows"

if [ "$lapsed" -eq 0 ]; then
    echo "no lapsed security backlog issue for $BASE_REF"
elif [[ "$TODAY" < "$ENFORCE_FROM" ]]; then
    echo "$lapsed lapsed issue(s); warn-only until $ENFORCE_FROM"
else
    echo "$lapsed lapsed issue(s) block this PR"
    exit 1
fi
