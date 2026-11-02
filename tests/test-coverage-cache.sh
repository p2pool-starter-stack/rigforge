#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
PROJECT="$SCRATCH/project"
STUBS="$SCRATCH/stubs"
TMPDIR="$SCRATCH/tmp"
trap 'chmod u+w "$PROJECT/.coverage-cache" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT
mkdir -p "$STUBS" "$TMPDIR"
git clone --shared --no-checkout --quiet "$ROOT" "$PROJECT"
git -C "$PROJECT" read-tree HEAD
mkdir -p "$PROJECT/tests" "$PROJECT/util"
printf '/coverage/\n/.coverage-cache/\n' >"$PROJECT/.gitignore"
if ! command -v sha256sum >/dev/null 2>&1; then
    cat >"$STUBS/sha256sum" <<'EOF'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
EOF
    chmod +x "$STUBS/sha256sum"
    export PATH="$STUBS:$PATH"
fi
cp "$ROOT/tests/coverage.sh" "$PROJECT/tests/coverage.sh"
printf '90\n' >"$PROJECT/tests/coverage-floor.txt"
printf '#!/usr/bin/env bash\nprintf candidate-one\\n\n' >"$PROJECT/rigforge.sh"
printf '#!/usr/bin/env bash\n:\n' >"$PROJECT/util/proposed-grub.sh"

cat >"$SCRATCH/jq-fixture" <<'EOF'
#!/usr/bin/env bash
exec "$COVERAGE_TEST_JQ" "$@"
EOF
chmod +x "$SCRATCH/jq-fixture"
JQ_SHA256=$(sha256sum "$SCRATCH/jq-fixture" | awk '{print $1}')
sed -E "s/^(JQ_SHA256=).*/\\1\"$JQ_SHA256\"/" "$PROJECT/tests/coverage.sh" >"$PROJECT/tests/coverage.sh.new"
mv "$PROJECT/tests/coverage.sh.new" "$PROJECT/tests/coverage.sh"
chmod +x "$PROJECT/tests/coverage.sh"

export COVERAGE_TEST_JQ
COVERAGE_TEST_JQ=$(command -v jq)
export COVERAGE_TEST_ROOT="$PROJECT"
export COVERAGE_TEST_DOWNLOAD="$SCRATCH/jq-fixture"
export COVERAGE_TEST_SHA256="$JQ_SHA256"
export COVERAGE_TEST_HEAD
COVERAGE_TEST_HEAD=$(git -C "$ROOT" rev-parse --verify HEAD)
export COVERAGE_TEST_CURL_LOG="$SCRATCH/curl.log"
export COVERAGE_TEST_DOCKER_LOG="$SCRATCH/docker.log"
export COVERAGE_TEST_WORK_LOG="$SCRATCH/work.log"
export TMPDIR

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'curl\n' >>"$COVERAGE_TEST_CURL_LOG"
out=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        out=$2
        shift 2
    else
        shift
    fi
done
[ -n "$out" ]
printf '%s\n' "${out%/*}" >>"$COVERAGE_TEST_WORK_LOG"
case "${COVERAGE_TEST_CURL_MODE:-good}" in
good) cp "$COVERAGE_TEST_DOWNLOAD" "$out" ;;
bad) printf 'bad download\n' >"$out" ;;
partial-fail)
    printf 'partial download\n' >"$out"
    exit 22
    ;;
*) exit 97 ;;
esac
EOF

cat >"$STUBS/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'docker\n' >>"$COVERAGE_TEST_DOCKER_LOG"
jq_mount=
have_clean=0
have_scope=0
have_platform=0
previous=
for arg in "$@"; do
    if [ "$previous" = -v ] && [ "${arg#*:}" = /usr/local/bin/jq:ro ]; then
        jq_mount=${arg%:/usr/local/bin/jq:ro}
    fi
    [ "$arg" = --clean ] && have_clean=1
    [ "$arg" = --include-pattern=/src/rigforge.sh,/src/util/proposed-grub.sh ] && have_scope=1
    [ "$previous" = --platform ] && [ "$arg" = linux/amd64 ] && have_platform=1
    previous=$arg
done
[ "$have_clean" -eq 1 ] || exit 91
[ "$have_scope" -eq 1 ] || exit 92
[ "$have_platform" -eq 1 ] || exit 97
[ -n "$jq_mount" ] || exit 93
[ -x "$jq_mount" ] || exit 94
[ "$(sha256sum "$jq_mount" | awk '{print $1}')" = "$COVERAGE_TEST_SHA256" ] || exit 95
printf '%s\n' "${jq_mount%/*}" >>"$COVERAGE_TEST_WORK_LOG"
work_mode=$(stat -c %a "${jq_mount%/*}" 2>/dev/null || stat -f %Lp "${jq_mount%/*}")
[ "$work_mode" = 700 ] || exit 99
case "$jq_mount" in
"$COVERAGE_TEST_ROOT"/.coverage-cache/*) exit 96 ;;
esac
case "${COVERAGE_TEST_DOCKER_MODE:-pass}" in
fail) exit 23 ;;
noreport) exit 0 ;;
esac
report="$COVERAGE_TEST_ROOT/coverage/run"
mkdir -p "$report"
case "${COVERAGE_TEST_DOCKER_MODE:-pass}" in
zero) lines=0; covered=0; percent=0 ;;
low) lines=100; covered=89; percent=89 ;;
*) lines=100; covered=95; percent=95 ;;
esac
cat >"$report/coverage.json" <<JSON
{"total_lines":$lines,"percent_covered":$percent,"files":[{"covered_lines":$covered,"total_lines":$lines,"percent_covered":$percent,"file":"/src/rigforge.sh"}]}
JSON
cat >"$report/cobertura.xml" <<XML
<coverage><sources><source>/src</source></sources><class filename="/src/rigforge.sh"/></coverage>
XML
EOF
cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUBS/curl" "$STUBS/docker" "$STUBS/sudo"

export PATH="$STUBS:$PATH"
CACHE="$PROJECT/.coverage-cache/jq-1.8.2-linux-amd64-$JQ_SHA256"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

run_coverage() {
    local output=$1
    shift
    set +e
    env "$@" bash "$PROJECT/tests/coverage.sh" >"$output" 2>&1
    local rc=$?
    set -e
    return "$rc"
}

assert_clean_staging() {
    local work
    [ -f "$COVERAGE_TEST_WORK_LOG" ] || return 0
    while IFS= read -r work; do
        [ ! -e "$work" ] || fail "private staging directory was retained"
    done <"$COVERAGE_TEST_WORK_LOG"
}

count_log() {
    [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || printf 0
}

OUT="$SCRATCH/output"
printf legacy >"$PROJECT/.coverage-cache-legacy"
mkdir -p "$PROJECT/.coverage-cache"
mv "$PROJECT/.coverage-cache-legacy" "$PROJECT/.coverage-cache/jq-linux-amd64"
chmod +x "$PROJECT/.coverage-cache/jq-linux-amd64"
if ! run_coverage "$OUT"; then
    fail "cold cache run failed"
fi
[ -f "$CACHE" ] || fail "cache key omits the jq version, platform, or digest"
[ "$(sha256sum "$CACHE" | awk '{print $1}')" = "$JQ_SHA256" ] || fail "cold cache published unverified bytes"
[ "$(count_log "$COVERAGE_TEST_CURL_LOG")" -eq 1 ] || fail "cold cache did not download exactly once"
[ "$(count_log "$COVERAGE_TEST_DOCKER_LOG")" -eq 1 ] || fail "cold cache did not run coverage exactly once"
[ "$(cat "$PROJECT/.coverage-cache/jq-linux-amd64")" = legacy ] || fail "legacy cache entry was consumed"
grep -Fq 'COVERAGE: PASS' "$OUT" || fail "coverage floor no longer passes"
grep -Fq 'filename="rigforge.sh"' "$PROJECT/coverage/cobertura.xml" || fail "Cobertura paths were not normalized"
[ "$(cat "$PROJECT/coverage/source-commit.txt")" = "$COVERAGE_TEST_HEAD" ] || fail "source commit does not match the tested HEAD"
candidate_sha=$(sha256sum "$PROJECT/rigforge.sh" | awk '{print $1}')
grep -Fqx "file $candidate_sha rigforge.sh" "$PROJECT/coverage/source-files.sha256" || fail "source manifest omits the tested candidate"
grep -Fqx 'absent - VERSION' "$PROJECT/coverage/source-files.sha256" || fail "source manifest omits a missing tracked input"
assert_clean_staging

chmod 444 "$CACHE"
chmod 555 "$PROJECT/.coverage-cache"
cache_before=$(sha256sum "$CACHE")
if ! run_coverage "$OUT"; then
    fail "read-only warm cache run failed"
fi
[ "$(count_log "$COVERAGE_TEST_CURL_LOG")" -eq 1 ] || fail "warm cache downloaded again"
[ "$(sha256sum "$CACHE")" = "$cache_before" ] || fail "warm cache was mutated"
[ ! -x "$CACHE" ] || fail "warm cache permissions were mutated"
[ "$(count_log "$COVERAGE_TEST_DOCKER_LOG")" -eq 2 ] || fail "warm cache did not reach coverage"
assert_clean_staging
chmod 755 "$PROJECT/.coverage-cache"

chmod u+w "$CACHE"
printf 'corrupt\n' >"$CACHE"
mkdir -p "$PROJECT/coverage"
printf stale >"$PROJECT/coverage/stale"
if run_coverage "$OUT"; then
    fail "corrupt cache was accepted"
fi
[ "$(count_log "$COVERAGE_TEST_CURL_LOG")" -eq 1 ] || fail "corrupt cache was automatically repaired"
[ "$(count_log "$COVERAGE_TEST_DOCKER_LOG")" -eq 2 ] || fail "corrupt cache reached Docker"
[ ! -e "$PROJECT/coverage/stale" ] || fail "old report survived corrupt tool failure"
grep -Fq corrupt "$CACHE" || fail "corrupt cache was replaced"
assert_clean_staging

rm "$CACHE"
for mode in bad partial-fail; do
    mkdir -p "$PROJECT/coverage"
    printf stale >"$PROJECT/coverage/stale"
    if run_coverage "$OUT" COVERAGE_TEST_CURL_MODE="$mode"; then
        fail "$mode download was accepted"
    fi
    [ ! -e "$CACHE" ] || fail "$mode download was published"
    [ ! -e "$PROJECT/coverage/stale" ] || fail "old report survived $mode download"
    assert_clean_staging
done

for kind in symlink directory; do
    if [ "$kind" = symlink ]; then
        ln -s "$COVERAGE_TEST_DOWNLOAD" "$CACHE"
    else
        mkdir "$CACHE"
    fi
    docker_before=$(count_log "$COVERAGE_TEST_DOCKER_LOG")
    curl_before=$(count_log "$COVERAGE_TEST_CURL_LOG")
    if run_coverage "$OUT"; then
        fail "$kind cache entry was accepted"
    fi
    [ "$(count_log "$COVERAGE_TEST_DOCKER_LOG")" -eq "$docker_before" ] || fail "$kind cache entry reached Docker"
    [ "$(count_log "$COVERAGE_TEST_CURL_LOG")" -eq "$curl_before" ] || fail "$kind cache entry triggered a download"
    grep -Fq 'non-regular' "$OUT" || fail "$kind cache refusal diagnostic changed"
    if [ "$kind" = symlink ]; then
        rm "$CACHE"
    else
        rmdir "$CACHE"
    fi
    assert_clean_staging
done

if ! run_coverage "$OUT"; then
    fail "cache recovery after manual deletion failed"
fi
first_manifest=$(cat "$PROJECT/coverage/source-files.sha256")
printf '#!/usr/bin/env bash\nprintf candidate-two\\n\n' >"$PROJECT/rigforge.sh"
if ! run_coverage "$OUT"; then
    fail "repeated coverage run failed"
fi
second_manifest=$(cat "$PROJECT/coverage/source-files.sha256")
[ "$first_manifest" != "$second_manifest" ] || fail "changed source did not refresh the manifest"
candidate_sha=$(sha256sum "$PROJECT/rigforge.sh" | awk '{print $1}')
grep -Fqx "file $candidate_sha rigforge.sh" "$PROJECT/coverage/source-files.sha256" || fail "source manifest retained the old candidate"

manifest_lines=$(wc -l <"$PROJECT/coverage/source-files.sha256" | tr -d ' ')
newline_name=$'source-line\nbreak'
printf 'newline fixture\n' >"$PROJECT/$newline_name"
if ! run_coverage "$OUT"; then
    fail "newline source path run failed"
fi
newline_sha=$(sha256sum <"$PROJECT/$newline_name" | awk '{print $1}')
printf -v escaped_name '%q' "$newline_name"
grep -Fqx "file $newline_sha $escaped_name" "$PROJECT/coverage/source-files.sha256" || fail "newline source path was not shell-escaped"
[ "$(wc -l <"$PROJECT/coverage/source-files.sha256" | tr -d ' ')" -eq $((manifest_lines + 1)) ] || fail "newline source path created extra manifest records"

printf 'same target bytes\n' >"$SCRATCH/link-target-one"
printf 'same target bytes\n' >"$SCRATCH/link-target-two"
ln -s "$SCRATCH/link-target-one" "$PROJECT/source-link"
ln -s "$SCRATCH/link-target-one" "$PROJECT/-link"
if ! run_coverage "$OUT"; then
    fail "external symlink source run failed"
fi
link_sha=$(printf '%s\n' "$SCRATCH/link-target-one" | sha256sum | awk '{print $1}')
grep -Fqx "symlink $link_sha source-link" "$PROJECT/coverage/source-files.sha256" || fail "symlink identity was not hashed"
grep -Fqx "symlink $link_sha -link" "$PROJECT/coverage/source-files.sha256" || fail "leading-dash symlink identity was not hashed"
link_manifest=$(cat "$PROJECT/coverage/source-files.sha256")
rm "$PROJECT/source-link"
ln -s "$SCRATCH/link-target-two" "$PROJECT/source-link"
if ! run_coverage "$OUT"; then
    fail "repointed symlink source run failed"
fi
link_sha=$(printf '%s\n' "$SCRATCH/link-target-two" | sha256sum | awk '{print $1}')
grep -Fqx "symlink $link_sha source-link" "$PROJECT/coverage/source-files.sha256" || fail "repointed symlink retained its old identity"
[ "$(cat "$PROJECT/coverage/source-files.sha256")" != "$link_manifest" ] || fail "equal-content symlink targets shared an identity"

rm "$PROJECT/source-link"
ln -s "$SCRATCH/missing-target" "$PROJECT/source-link"
if ! run_coverage "$OUT"; then
    fail "missing-target symlink source run failed"
fi
link_sha=$(printf '%s\n' "$SCRATCH/missing-target" | sha256sum | awk '{print $1}')
grep -Fqx "symlink $link_sha source-link" "$PROJECT/coverage/source-files.sha256" || fail "missing-target symlink was followed"

mode_manifest=$(cat "$PROJECT/coverage/source-files.sha256")
chmod +x "$PROJECT/rigforge.sh"
if ! run_coverage "$OUT"; then
    fail "executable source mode run failed"
fi
grep -Fqx "executable $candidate_sha rigforge.sh" "$PROJECT/coverage/source-files.sha256" || fail "executable source mode was omitted"
[ "$(cat "$PROJECT/coverage/source-files.sha256")" != "$mode_manifest" ] || fail "executable source mode did not change the manifest"

cp "$SCRATCH/jq-fixture" "$SCRATCH/jq-fixture-next"
printf '\n' >>"$SCRATCH/jq-fixture-next"
next_sha=$(sha256sum "$SCRATCH/jq-fixture-next" | awk '{print $1}')
sed -E "s/^(JQ_SHA256=).*/\\1\"$next_sha\"/" "$PROJECT/tests/coverage.sh" >"$PROJECT/tests/coverage.sh.new"
mv "$PROJECT/tests/coverage.sh.new" "$PROJECT/tests/coverage.sh"
chmod +x "$PROJECT/tests/coverage.sh"
export COVERAGE_TEST_DOWNLOAD="$SCRATCH/jq-fixture-next"
export COVERAGE_TEST_SHA256="$next_sha"
next_cache="$PROJECT/.coverage-cache/jq-1.8.2-linux-amd64-$next_sha"
curl_before=$(count_log "$COVERAGE_TEST_CURL_LOG")
if ! run_coverage "$OUT"; then
    fail "changed jq pin run failed"
fi
[ -f "$CACHE" ] || fail "changed jq pin removed the previous identity"
[ -f "$next_cache" ] || fail "changed jq pin reused the previous identity"
[ "$(count_log "$COVERAGE_TEST_CURL_LOG")" -eq $((curl_before + 1)) ] || fail "changed jq pin did not download its own bytes"

parent_head=$(git -C "$PROJECT" rev-parse HEAD^)
git -C "$PROJECT" update-ref --no-deref HEAD "$parent_head"
docker_before=$(count_log "$COVERAGE_TEST_DOCKER_LOG")
if ! run_coverage "$OUT"; then
    fail "changed source commit run failed"
fi
[ "$(cat "$PROJECT/coverage/source-commit.txt")" = "$parent_head" ] || fail "changed source commit retained stale provenance"
[ "$(count_log "$COVERAGE_TEST_DOCKER_LOG")" -eq $((docker_before + 1)) ] || fail "changed source commit reused an old report"

mkdir -p "$PROJECT/coverage"
printf stale >"$PROJECT/coverage/stale"
if run_coverage "$OUT" COVERAGE_TEST_DOCKER_MODE=fail; then
    fail "Docker failure passed"
fi
[ ! -e "$PROJECT/coverage/stale" ] || fail "old report survived Docker failure"
assert_clean_staging

if run_coverage "$OUT" COVERAGE_TEST_DOCKER_MODE=zero; then
    fail "zero instrumented lines passed"
fi
grep -Fq '0 instrumented lines' "$OUT" || fail "zero-line diagnostic changed"
if run_coverage "$OUT" COVERAGE_TEST_DOCKER_MODE=noreport; then
    fail "missing report passed"
fi
grep -Fq 'produced no report' "$OUT" || fail "missing-report diagnostic changed"
if run_coverage "$OUT" COVERAGE_TEST_DOCKER_MODE=low; then
    fail "coverage below the floor passed"
fi
grep -Fq 'COVERAGE: FAIL' "$OUT" || fail "floor failure diagnostic changed"
if ! run_coverage "$OUT" COVERAGE_TEST_DOCKER_MODE=low COVERAGE_NO_FAIL=1; then
    fail "report-only coverage failed below the floor"
fi
grep -Fq 'report-only' "$OUT" || fail "report-only diagnostic changed"
assert_clean_staging

printf 'PASS: coverage cache is digest-keyed, verified, staged, and fail-closed\n'
