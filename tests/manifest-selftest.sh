#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/tests/manifest.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s\n' "$1" >&2
}
ok() {
    PASS=$((PASS + 1))
    printf '  OK:   %s\n' "$1"
}

validate() {
    python3 -I - "$1" "$ROOT" <<'PY'
import json, os, re, sys

manifest_file, root = sys.argv[1], sys.argv[2]
d = json.load(open(manifest_file))
errors = []
required = ['name', 'file', 'phases', 'timeout_seconds', 'inputs', 'exit_codes', 'needs']
needs_enum = {'needs_vm', 'needs_hardware', 'needs_docker', 'needs_root', 'needs_macos'}


def words(text):
    return set(re.findall(r'[A-Za-z0-9_]+', text))


def dispatch_block(text):
    starts = [m.start() for m in re.finditer(r'^case "\$\{?1[^"]*"\s+in\s*$', text, re.M)]
    if not starts:
        return None
    block = text[starts[-1]:]
    end = re.search(r'^esac\s*$', block, re.M)
    return block[: end.end()] if end else block


def arms(block):
    out = []
    for m in re.finditer(r'^([A-Za-z][\w-]*(?:\s*\|\s*[\w-]+)*)\)', block, re.M):
        out.extend(x.strip() for x in m.group(1).split('|'))
    return out


def arm_body(block, name):
    m = re.search(r'^(?:[\w-]+\s*\|\s*)*' + re.escape(name) + r'(?:\s*\|\s*[\w-]+)*\)(.*?)^\s*;;', block, re.M | re.S)
    return m.group(1) if m else ''


def header_inputs(text):
    out = set()
    code = '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
    for line in text.splitlines()[1:]:
        if not line.startswith('#'):
            if line.strip():
                break
            continue
        out.update(re.findall(r'\bE2E_[A-Z0-9_]+\b', line))
        for n in re.findall(r'\b([A-Z][A-Z0-9_]*[A-Z0-9])=', line):
            if not re.search(r'(?<![\w(])' + n + '=', code):
                out.add(n)
    return out


seen = set()
for i, s in enumerate(d.get('suites', [])):
    name = s.get('name', '[#%d]' % i)
    if name in seen:
        errors.append('duplicate suite name %s' % name)
    seen.add(name)
    for k in required:
        if k not in s:
            errors.append('suite [%s] missing field %s' % (name, k))
    rel = s.get('file', '')
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        errors.append('suite [%s] file %s does not exist' % (name, rel))
        continue
    text = open(path).read()
    phases = s.get('phases', [])
    if not isinstance(phases, list) or not all(isinstance(p, str) and p for p in phases):
        errors.append('suite [%s] invalid phases' % name)
        phases = []
    block = dispatch_block(text)
    actual = set(arms(block)) if block else set()
    if set(phases) != actual or len(set(phases)) != len(phases):
        errors.append('suite [%s] phases %s != dispatch arms %s in %s' % (name, sorted(phases), sorted(actual), rel))
    all_runs = s.get('all_runs')
    if all_runs is not None:
        body = arm_body(block or '', 'all')
        tokens = {t.replace('_', '-') for t in re.findall(r'\b(?:phase_)?([a-z][a-z_]*)\b', body)}
        expect = tokens & set(phases)
        if set(all_runs) != expect:
            errors.append('suite [%s] all_runs %s != phases run by all %s' % (name, sorted(all_runs), sorted(expect)))
    t = s.get('timeout_seconds')
    if not isinstance(t, int) or isinstance(t, bool) or t <= 0:
        errors.append('suite [%s] invalid timeout_seconds: %r' % (name, t))
    inputs = s.get('inputs', [])
    present = words(text)
    for sub in os.listdir(os.path.dirname(path)):
        if sub.endswith(('.sh', '.py')):
            present |= words(open(os.path.join(os.path.dirname(path), sub)).read())
    for inp in inputs:
        if not isinstance(inp, str) or inp not in present:
            errors.append('suite [%s] input %r not found beside %s' % (name, inp, rel))
    for inp in header_inputs(text) - set(inputs):
        errors.append('suite [%s] documented input %s missing from manifest' % (name, inp))
    for k, v in s.get('exit_codes', {}).items():
        if not isinstance(k, str) or not k.isdigit() or not isinstance(v, str):
            errors.append('suite [%s] invalid exit_code: %r:%r' % (name, k, v))
    for n in s.get('needs', []):
        if n not in needs_enum:
            errors.append('suite [%s] needs %r not in %s' % (name, n, sorted(needs_enum)))

listed = {s.get('file') for s in d.get('suites', [])}
callers = [os.path.join(root, 'Makefile')]
wf = os.path.join(root, '.github', 'workflows')
callers += [os.path.join(wf, f) for f in sorted(os.listdir(wf)) if f.endswith(('.yml', '.yaml'))]
for c in callers:
    for ref in sorted(set(re.findall(r'\btests/[\w./-]+\.(?:sh|py)\b', open(c).read()))):
        if ref != 'tests/manifest-selftest.sh' and ref not in listed:
            errors.append('%s runs %s, which has no manifest suite' % (os.path.relpath(c, root), ref))

blob = json.dumps(d)
for term in ['github', 'actions', 'ghci', 'bench-ci', 'runner']:
    if re.search(r'(?<!\w)' + term + r'(?!\w)', blob, re.I):
        errors.append('manifest references CI/host term: %s' % term)

for e in errors:
    print(e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
}

mutate() {
    python3 -I - "$MANIFEST" "$WORK/mutated.json" "$1" <<'PY'
import json, sys

d = json.load(open(sys.argv[1]))
suite = {s['name']: s for s in d['suites']}
case = sys.argv[3]
if case == 'drop-phase':
    suite['e2e-real']['phases'].remove('teardown')
elif case == 'invent-phase':
    suite['e2e-real']['phases'].append('state')
elif case == 'drop-input':
    suite['e2e-real']['inputs'].remove('E2E_PERF_TAG')
elif case == 'bad-needs':
    suite['e2e-real']['needs'].append('real-hardware')
elif case == 'bad-all-runs':
    suite['e2e-pithead']['all_runs'].remove('dev-fee')
elif case == 'drop-suite':
    d['suites'].remove(suite['unit'])
elif case == 'drop-knob':
    suite['smoke']['inputs'].remove('SMOKE_RUN_SETUP')
json.dump(d, open(sys.argv[2], 'w'))
PY
}

[ -f "$MANIFEST" ] || {
    echo "manifest.json not found at $MANIFEST" >&2
    exit 1
}

if validate "$MANIFEST"; then
    ok "manifest matches every harness dispatch, input header, needs vocabulary, suite caller and the CI-term rule"
else
    fail "manifest does not match the harnesses"
fi

for case in drop-phase invent-phase drop-input bad-needs bad-all-runs drop-suite drop-knob; do
    mutate "$case"
    if validate "$WORK/mutated.json" 2>/dev/null; then
        fail "selftest accepted the $case mutation"
    else
        ok "selftest rejects the $case mutation"
    fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
