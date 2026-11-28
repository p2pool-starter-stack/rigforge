#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

CI=.github/workflows/ci.yml
SEC=.github/workflows/security.yml
HELPER=scripts/ci-categorize.sh

for f in "$CI" "$SEC" "$HELPER"; do
    [ -f "$f" ] || fail "$f is missing"
done

python3 - "$CI" "$SEC" <<'PY'
import re
import sys

NAME_RE = re.compile(r'^"(setup|assert|cleanup|scan): .+"$')
ID_RE = re.compile(r'^(setup|assert|cleanup|scan)_[a-z0-9_]+$')
CAT_ENV_RE = re.compile(r'^\$\{\{ steps\.([a-z0-9_]+)\.outcome \}\}$')
STEP_RE = re.compile(r'^      - (.*)$')
ATTR8_RE = re.compile(r'^        ([\w-]+):(.*)$')
ATTR10_RE = re.compile(r'^          ([\w-]+):(.*)$')
JOB_RE = re.compile(r'^  ([a-z][a-z0-9_-]*):$')
JOB_IF_RE = re.compile(r'^    if: (.+)$')
FULL_HISTORY = {"ci.yml": {"lint", "stock-home", "coverage"}, "security.yml": {"gitleaks"}}
FORK_GUARD = ("github.event_name != 'pull_request' || "
              "github.event.pull_request.head.repo.full_name == github.repository")
JOB_IF_ALLOWED = {
    "apt-feed": FORK_GUARD,
    "gitleaks": "github.event_name != 'schedule'",
    "backlog-expiry": "github.event_name == 'pull_request' && (github.base_ref == 'develop' || startsWith(github.base_ref, 'develop-v'))",
    "zizmor-issue": "${{ always() && (github.event_name == 'schedule' || inputs.file_issue) && (needs.zizmor.result == 'success' || needs.zizmor.result == 'failure') }}",
    "dependency-review": "github.event_name == 'pull_request'",
}
problems = []


def parse_steps(start, end, lines, wf, job):
    steps = []
    cur = None
    mode = None
    for line in lines[start:end]:
        m = STEP_RE.match(line)
        if m:
            cur = {"attrs": {}, "env": {}, "with": {}, "if": None, "run": None, "line": line}
            steps.append(cur)
            mode = None
            fa = re.match(r'^([\w-]+):(.*)$', m.group(1))
            if fa:
                store_attr(cur, fa.group(1), fa.group(2).strip(), wf, job, line)
            continue
        if cur is None:
            continue
        m = ATTR8_RE.match(line)
        if m:
            mode = store_attr(cur, m.group(1), m.group(2).strip(), wf, job, line)
            continue
        m = ATTR10_RE.match(line)
        if m and mode == "env":
            cur["env"][m.group(1)] = m.group(2).strip()
        elif m and mode == "with":
            cur["with"][m.group(1)] = m.group(2).strip()
    return steps


def store_attr(step, key, val, wf, job, line):
    if key == "env":
        if val:
            problems.append(f"{wf}:{job}: inline env mapping not supported near: {line.strip()}")
        return "env"
    if key == "with":
        return "with"
    if key == "run":
        step["run"] = val
        return "run"
    if key == "if":
        step["if"] = val
        return None
    if key in step["attrs"]:
        problems.append(f"{wf}:{job}: duplicate {key} in step near: {line.strip()}")
    step["attrs"][key] = val
    return None


for wf in sys.argv[1:]:
    lines = open(wf).read().splitlines()
    full_history = FULL_HISTORY.get(wf.split("/")[-1], set())
    jobs = []
    in_jobs = False
    for i, line in enumerate(lines):
        if line == "jobs:":
            in_jobs = True
            continue
        if in_jobs:
            m = JOB_RE.match(line)
            if m:
                jobs.append((m.group(1), i))
    if not jobs:
        problems.append(f"{wf}: no jobs parsed")
        continue
    scan_count = 0
    cleanup_count = 0
    for pos, (job, start) in enumerate(jobs):
        end = jobs[pos + 1][1] if pos + 1 < len(jobs) else len(lines)
        steps = parse_steps(start, end, lines, wf, job)
        job_if = None
        for line in lines[start:end]:
            m = JOB_IF_RE.match(line)
            if m:
                job_if = m.group(1).strip()
        want_if = JOB_IF_ALLOWED.get(job)
        if (job_if or want_if) and job_if != want_if:
            problems.append(f"{wf}:{job}: job if {job_if} is not this job's approved condition")
        if not steps:
            problems.append(f"{wf}:{job}: no steps parsed")
            continue
        ids = []
        catz = []
        for s in steps:
            name = s["attrs"].get("name")
            sid = s["attrs"].get("id")
            where = f"{wf}:{job}: step at line {s['line'].strip()[:60]}"
            sidv = s["attrs"].get("id")
            if sidv == "assert_sudo_resolution":
                allowed_ifs = ("runner.os == 'Linux'",)
            elif sidv == "assert_categorize":
                allowed_ifs = ("always()",)
            elif sidv == "cleanup_allowlist_image":
                allowed_ifs = ("always() && steps.setup_allowlist_image.outcome == 'success'",)
            elif sidv and sidv.startswith("cleanup_"):
                allowed_ifs = (None, "always()")
            else:
                allowed_ifs = (None,)
            if s["if"] not in allowed_ifs:
                problems.append(f"{where} if {s['if']} is not approved for this step")
            if name is None:
                problems.append(f"{where} has no name")
            elif not NAME_RE.match(name):
                problems.append(f'{where} name {name} must be quoted as "setup: |assert: |cleanup: |scan: ..."')
            if sid is None:
                problems.append(f"{where} has no id")
            else:
                if not ID_RE.match(sid):
                    problems.append(f"{where} id {sid} must be <category>_<slug>")
                elif name and NAME_RE.match(name) and name[1:sid.index('_') + 1] != sid[:sid.index('_')]:
                    problems.append(f"{where} name category does not match id {sid}")
                ids.append(sid)
            cat = sid.split('_')[0] if sid and ID_RE.match(sid) else None
            if cat == "scan":
                scan_count += 1
            if cat == "cleanup":
                cleanup_count += 1
            if name == '"assert: categorize outcome"':
                catz.append(s)
        if len(ids) != len(set(ids)):
            problems.append(f"{wf}:{job}: duplicate step ids")
        if job in full_history:
            full = False
            for s in steps:
                if "actions/checkout" in s["attrs"].get("uses", ""):
                    if s["with"].get("fetch-depth", "").split(" ")[0] == "0":
                        full = True
            if not full:
                problems.append(f"{wf}:{job}: its actions/checkout must keep fetch-depth: 0 (full history is a gate)")
        if len(catz) != 1:
            problems.append(f"{wf}:{job}: expected exactly one categorize step, found {len(catz)}")
            continue
        c = catz[0]
        if c["attrs"].get("id") != "assert_categorize":
            problems.append(f'{wf}:{job}: categorize step id must be assert_categorize')
        if c["if"] != "always()":
            problems.append(f"{wf}:{job}: categorize step must run if: always()")
        if c["run"] != 'bash scripts/ci-categorize.sh "$GITHUB_JOB"':
            problems.append(f'{wf}:{job}: categorize step must run bash scripts/ci-categorize.sh "$GITHUB_JOB"')
        expected = {}
        for s in steps:
            sid = s["attrs"].get("id")
            if sid and sid != "assert_categorize":
                expected[f"CAT_{sid.upper()}"] = sid
        got = c["env"]
        for key, sid in expected.items():
            if key not in got:
                problems.append(f"{wf}:{job}: categorize env lacks {key} for step {sid}")
            elif CAT_ENV_RE.match(got[key] or "") is None or CAT_ENV_RE.match(got[key]).group(1) != sid:
                problems.append(f"{wf}:{job}: categorize env {key} must read ${{{{ steps.{sid}.outcome }}}}")
        for key in got:
            if key not in expected:
                problems.append(f"{wf}:{job}: categorize env {key} names no step id of this job")
    if wf.endswith("security.yml") and scan_count < 1:
        problems.append(f"{wf}: no scan-category steps in the Security workflow")
    if wf.endswith("ci.yml"):
        if scan_count:
            problems.append(f"{wf}: scan-category steps belong to the Security workflow")
        if cleanup_count < 1:
            problems.append(f"{wf}: no cleanup-category step emitted the cleanup category")

if problems:
    for p in problems:
        print(f"PROBLEM: {p}", file=sys.stderr)
    sys.exit(1)
print("ok: every ci.yml and security.yml step is categorized and covered by its job's categorize step")
PY

if grep -qF 'continue-on-error' "$CI" "$SEC"; then
    fail "continue-on-error appeared in the CI/Security premerge gates"
fi

if grep -hF '||' "$CI" "$SEC" | grep -vE '^[[:space:]]*if:|\$\{\{' | grep -q .; then
    fail "a shell || fallback appeared in the CI/Security premerge gates"
fi

for want in \
    'run: make lint' \
    'run: make lint-yaml' \
    'run: make lint-md' \
    'run: make lint-actions' \
    'run: make test-suite' \
    'run: make test-e2e' \
    'run: make coverage' \
    'run: sudo bash tests/test-apt-feed.sh' \
    'run: timeout 1800 bash tests/test-stock-home.sh "$TEST_REVISION" "$TEST_EXPECTATION"' \
    'run: docker build -q -t rigforge-allowlist tests/docker' \
    'run: docker run --rm --privileged -v "$PWD:/src:ro" rigforge-allowlist bash /src/tests/test-api-allowlist-linux.sh' \
    'run: docker rmi rigforge-allowlist' \
    'run: diff-cover coverage/cobertura.xml --compare-branch="origin/$BASE_REF" --fail-under="${PATCH_COVERAGE_MIN}"'; do
    grep -qxF "        $want" "$CI" || fail "ci.yml gate weakened: '$want' is no longer the exact step command"
done

for want in \
    'FILE_BUDGET_REQUIRE_BASE: "1"' \
    '          echo "${ACTIONLINT_SHA256}  ${tarball}" | sha256sum -c -' \
    '          echo "${SHELLCHECK_SHA256}  ${tarball}" | sha256sum -c -' \
    '          echo "${SHFMT_SHA256}  shfmt" | sha256sum -c -' \
    '"$RUNNER_TEMP/ci-python-tools/bin/pip" install -r tools/requirements-ci.txt' \
    '          brew test p2pool-starter-stack/rigforge/rigforge' \
    '          test "$(rigforge --version)" = "RigForge $want"' \
    'PATCH_COVERAGE_MIN: "90"' \
    '    branches: [main, develop]'; do
    grep -qF "$want" "$CI" || fail "ci.yml gate weakened: '$want' is gone"
done

for want in \
    '  push:' \
    '  pull_request:' \
    '          - label: historical' \
    '            revision: b2d4c3d9ca1da74d0e6d5ccce772d401acc8be03' \
    '            expect: broken' \
    '          - label: current' \
    '            revision: HEAD' \
    '            expect: working' \
    '        os: [ubuntu-24.04, macos-15]'; do
    grep -qxF "$want" "$CI" || fail "ci.yml contract line '$want' is gone"
done

for want in \
    'run: gitleaks git . --redact --no-banner --verbose' \
    'run: zizmor .github/workflows/'; do
    grep -qxF "        $want" "$SEC" || fail "security.yml gate weakened: '$want' is no longer the exact step command"
done

for want in \
    '          echo "${GITLEAKS_SHA256}  ${tarball}" | sha256sum -c -' \
    '"$RUNNER_TEMP/ci-python-tools/bin/pip" install -r tools/requirements-ci.txt' \
    'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' \
    '    branches: [main, develop]'; do
    grep -qF "$want" "$SEC" || fail "security.yml gate weakened: '$want' is gone"
done

for want in \
    '  push:' \
    '  pull_request:' \
    '  schedule:'; do
    grep -qxF "$want" "$SEC" || fail "security.yml trigger '$want' is gone"
done

if grep -qF 'MAKEFLAGS' "$CI" "$SEC"; then
    fail "MAKEFLAGS (the make dry-run switch) appeared in the CI/Security premerge gates"
fi

if grep -qE '^[[:space:]]*(defaults:|shell:|types:|paths(-ignore)?:)' "$CI" "$SEC"; then
    fail "a defaults/shell/types/paths key (a workflow silencing hook) appeared in the CI/Security gates"
fi

if grep -qF 'MAKEFLAGS' Makefile; then
    fail "MAKEFLAGS appeared in the Makefile the gates invoke"
fi

grep -qxF '        entry: make lint-actions' .pre-commit-config.yaml || fail ".pre-commit-config.yaml lacks the make lint-actions hook"
grep -qxF '        files: ^\.github/workflows/.*\.ya?ml$' .pre-commit-config.yaml || fail "the make lint-actions hook does not trigger on workflow files"

grep -qF 'CAT_SCAN_GITLEAKS:' "$SEC" || fail "security.yml gitleaks scan outcome is not emitted"
grep -qF 'CAT_SCAN_ZIZMOR:' "$SEC" || fail "security.yml zizmor scan outcome is not emitted"

grep -qxF "$(printf '\tbash tests/test-workflow-contract.sh')" Makefile ||
    fail "Makefile test-suite no longer runs the workflow contract suite (#619)"

env -i PATH="$PATH" CAT_SETUP_TOOLS=success CAT_ASSERT_LINT_YAML=failure bash "$HELPER" demo-job \
    >"$SCRATCH/out" || fail "categorize helper rejected valid CAT_ variables"
grep -qF 'setup-tools = success' "$SCRATCH/out" || fail "categorize helper dropped a setup row"
grep -qF 'assert-lint-yaml = failure' "$SCRATCH/out" || fail "categorize helper dropped an assert row"
grep -qF '## Outcome categories — demo-job' "$SCRATCH/out" || fail "categorize helper omitted the job heading"
: >"$SCRATCH/summary"
env -i PATH="$PATH" GITHUB_STEP_SUMMARY="$SCRATCH/summary" CAT_SCAN_GITLEAKS=failure bash "$HELPER" demo-job \
    >/dev/null || fail "categorize helper rejected GITHUB_STEP_SUMMARY"
grep -qF 'scan-gitleaks = failure' "$SCRATCH/summary" || fail "categorize helper did not append the scan outcome to the step summary"
if env -i PATH="$PATH" bash "$HELPER" demo-job >/dev/null 2>&1; then
    fail "categorize helper passed with no CAT_ variables (a silently empty categorization)"
fi
if env -i PATH="$PATH" CAT_SETUP_X=success bash "$HELPER" >/dev/null 2>&1; then
    fail "categorize helper passed without naming a job"
fi

if command -v actionlint >/dev/null 2>&1; then
    actionlint >/dev/null 2>"$SCRATCH/actionlint.err" ||
        fail "actionlint found workflow problems: $(head -n 3 "$SCRATCH/actionlint.err")"
    printf 'ok: actionlint is clean over .github/workflows\n'
else
    printf 'skip: actionlint not on PATH (CI runs make lint-actions in the Lint (yamllint) job)\n'
fi

printf 'ok: workflow contract (#619)\n'
