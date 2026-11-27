#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${XMRIG_BUMP_SCRIPT:-$ROOT/scripts/xmrig-bump.sh}"
WF="$ROOT/.github/workflows/xmrig-bump.yml"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

newer() { bash "$SCRIPT" newer "$1" "$2"; }
newer v6.26.0 v6.26.1 || fail "a newer upstream release must be bumped to"
newer v6.26.0 v6.27.0 || fail "a newer minor release must be bumped to"
newer v6.9.0 v6.10.0 || fail "versions must compare numerically, not as text"
! newer v6.26.0 v6.26.0 || fail "an equal pin must not open a bump"
! newer v6.26.0 v6.25.9 || fail "a pulled or older upstream release must not open a downgrade PR"
! newer v6.26.0 v6.9.0 || fail "v6.9.0 is older than v6.26.0"

mkdir "$SCRATCH/bin"
cat >"$SCRATCH/bin/gh" <<'GH'
#!/usr/bin/env bash
[ -z "${STUB_FAIL:-}" ] || exit 1
case "$4" in
open) printf '%s\n' "$STUB_OPEN" ;;
closed) printf '%s\n' "$STUB_CLOSED" ;;
esac | jq -r "${10}"
GH
chmod +x "$SCRATCH/bin/gh"
own='[{"number":1,"headRepositoryOwner":{"login":"o"}}]'
fork='[{"number":2,"headRepositoryOwner":{"login":"evil"}}]'
pr_state() { PATH="$SCRATCH/bin:$PATH" GITHUB_REPOSITORY_OWNER=o STUB_OPEN=$1 STUB_CLOSED=$2 bash "$SCRIPT" state bot/x; }
[ "$(pr_state '[]' "$own")" = declined ] || fail "a closed bump PR with none open is a human decline and must stay declined"
[ "$(pr_state '[]' '[]')" = none ] || fail "no PR at all is not a decline"
[ "$(pr_state "$own" "$own")" = open ] || fail "an open bump PR is not a decline"
[ "$(pr_state "$fork" '[]')" = none ] || fail "a fork PR squatting on the bot branch name must not suppress the bump"
[ "$(pr_state '[]' "$fork")" = none ] || fail "a closed fork PR must not read as a decline"
! PATH="$SCRATCH/bin:$PATH" GITHUB_REPOSITORY_OWNER=o STUB_FAIL=1 STUB_OPEN='[]' STUB_CLOSED='[]' bash "$SCRIPT" state bot/x >/dev/null 2>&1 ||
    fail "a failed gh query must fail the run, not read as no PR or a decline"

OLD=$(printf 'a%.0s' $(seq 40))
NEW=$(printf 'b%.0s' $(seq 40))
BR=bot/xmrig-v1.1.0
MSG="chore: bump the XMRig pin to v1.1.0 (bot, build-verified)"
git init -q --bare "$SCRATCH/origin.git"
git init -q -b trunk "$SCRATCH/work"
cd "$SCRATCH/work"
git config user.name t
git config user.email t@t
# shellcheck disable=SC2016
printf 'XMRIG_VERSION="${XMRIG_VERSION:-v1.0.0}"\nXMRIG_COMMIT="${XMRIG_COMMIT:-%s}"\n' "$OLD" >rigforge.sh
printf 'orig\n' >other.txt
git add -A
git commit -qm base
git remote add origin "$SCRATCH/origin.git"
git push -q origin trunk
export ORIGIN_URL="$SCRATCH/origin.git"
remote() { git -C "$SCRATCH/origin.git" "$@"; }

printf 'tampered by the build\n' >other.txt
bash "$SCRIPT" prepare "$BR" v1.0.0 v1.1.0 "$NEW" >/dev/null 2>&1 || fail "prepare must succeed on a fresh bump"
[ "$(remote show "$BR:other.txt")" = orig ] ||
    fail "only rigforge.sh may be committed; a file the build touched must never ride along"
[ "$(remote diff --name-only trunk "$BR")" = rigforge.sh ] ||
    fail "the bump commit must change exactly rigforge.sh"
remote show "$BR:rigforge.sh" | grep -q "XMRIG_VERSION:-v1.1.0}" || fail "the version pin must be rewritten"
remote show "$BR:rigforge.sh" | grep -q "XMRIG_COMMIT:-$NEW}" || fail "the commit pin must be rewritten"

git checkout -q trunk
git branch -q -D "$BR"
git checkout -q -- .
bash "$SCRIPT" prepare "$BR" v1.0.0 v1.1.0 "$NEW" >/dev/null 2>&1 ||
    fail "a rerun after an interrupted run must reuse the pushed branch instead of failing on a non-fast-forward push"

git checkout -q trunk
git branch -q -D "$BR"
git push -q origin ":refs/heads/$BR"
git checkout -q -b stale
git commit -q --allow-empty -m interrupted
git push -q origin "stale:refs/heads/$BR"
git checkout -q trunk
bash "$SCRIPT" prepare "$BR" v1.0.0 v1.1.0 "$NEW" >/dev/null 2>&1 ||
    fail "a branch left behind by an interrupted run must be built on, not force-pushed over"
[ "$(remote log --format=%s -1 "$BR")" = "$MSG" ] || fail "the bump commit must sit on top of the reused branch"
[ "$(remote log --format=%s -2 "$BR" | tail -1)" = interrupted ] || fail "the interrupted run's commit must be kept"

git checkout -q trunk
git branch -q -D "$BR"
git push -q origin ":refs/heads/$BR"
git checkout -q -b smuggle
printf 'x\n' >smuggled.txt
git add smuggled.txt
git commit -q -m smuggle
git push -q origin "smuggle:refs/heads/$BR"
git checkout -q trunk
! bash "$SCRIPT" prepare "$BR" v1.0.0 v1.1.0 "$NEW" >/dev/null 2>&1 ||
    fail "a pre-existing branch carrying changes beyond rigforge.sh must not be built on"

grep -q 'group: xmrig-bump' "$WF" ||
    fail "overlapping runs (cron plus a manual dispatch) must be serialized by a concurrency group"
grep -q 'xmrig-bump.sh newer' "$WF" || fail "the workflow must use the version-order guard"
grep -q 'xmrig-bump.sh state' "$WF" || fail "the workflow must honour a declined bump"
grep -q 'xmrig-bump.sh prepare' "$WF" || fail "the workflow must prepare the branch through the tested script"

printf 'PASS: xmrig bump guards\n'
