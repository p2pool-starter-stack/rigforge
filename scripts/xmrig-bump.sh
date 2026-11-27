#!/usr/bin/env bash
set -Eeuo pipefail

own_prs() {
    gh pr list --state "$1" --head "$2" --json number,headRepositoryOwner \
        --jq "map(select(.headRepositoryOwner.login==\"${GITHUB_REPOSITORY_OWNER}\")) | length"
}

case "${1:-}" in
newer)
    [ "$2" != "$3" ] || exit 1
    [ "$(printf '%s\n%s\n' "${2#v}" "${3#v}" | sort -V | tail -1)" = "${3#v}" ]
    ;;
declined)
    [ "$(own_prs open "$2")" = 0 ] && [ "$(own_prs closed "$2")" != 0 ]
    ;;
prepare)
    branch=$2 current=$3 tag=$4 commit=$5
    if [ -n "$(git ls-remote "$ORIGIN_URL" "refs/heads/${branch}" | cut -f1)" ]; then
        git fetch --depth 1 "$ORIGIN_URL" "$branch"
        git checkout -b "$branch" FETCH_HEAD
    else
        git checkout -b "$branch"
    fi
    sed -i.bak "s|XMRIG_VERSION:-${current}}|XMRIG_VERSION:-${tag}}|" rigforge.sh
    sed -i.bak "s|XMRIG_COMMIT:-[0-9a-f]\{40\}}|XMRIG_COMMIT:-${commit}}|" rigforge.sh
    rm -f rigforge.sh.bak
    grep -q "XMRIG_VERSION:-${tag}}" rigforge.sh
    grep -q "XMRIG_COMMIT:-${commit}}" rigforge.sh
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add rigforge.sh
    if ! git diff --cached --quiet; then
        git commit -qm "chore: bump the XMRig pin to ${tag} (bot, build-verified)"
    fi
    git push "$ORIGIN_URL" "$branch"
    ;;
*)
    echo "usage: xmrig-bump.sh newer|declined|prepare" >&2
    exit 2
    ;;
esac
