#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/tests/manifest.json"

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

if [ ! -f "$MANIFEST" ]; then
    echo "manifest.json not found at $MANIFEST" >&2
    exit 1
fi

version=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('version',''))" "$MANIFEST")
[ "$version" -ge 1 ] 2>/dev/null || {
    echo "missing or invalid 'version' >= 1" >&2
    exit 1
}

n_suites=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['suites']))" "$MANIFEST")
[ "$n_suites" -gt 0 ] || {
    echo "no suites in manifest" >&2
    exit 1
}

ok "manifest has version=$version and $n_suites suites"

python3 -c "
import json, sys, os, re

manifest_file = sys.argv[1]
root = sys.argv[2]

d = json.load(open(manifest_file))
suites = d['suites']

errors = []
required_keys = ['name','file','phases','timeout_seconds','inputs','exit_codes','needs']

for i, s in enumerate(suites):
    name = s.get('name', f'[#{i}]')

    for k in required_keys:
        if k not in s:
            errors.append(f'suite [{name}] missing field {k}')

    rel_file = s.get('file', '')
    full_path = os.path.join(root, rel_file)

    if not os.path.isfile(full_path):
        errors.append(f'suite [{name}] file {rel_file} does not exist')
        continue

    with open(full_path) as f:
        text = f.read()

    for phase in s.get('phases', []):
        if not re.search(r'(?<!\w)' + re.escape(phase) + r'(?!\w)', text):
            errors.append(f'suite [{name}] phase {phase!r} not found in {rel_file}')

    t = s.get('timeout_seconds')
    if not isinstance(t, int) or t <= 0:
        errors.append(f'suite [{name}] invalid timeout_seconds: {t!r}')

    for inp in s.get('inputs', []):
        if not isinstance(inp, str) or not inp:
            errors.append(f'suite [{name}] invalid input: {inp!r}')

    for k, v in s.get('exit_codes', {}).items():
        if not isinstance(k, str) or not isinstance(v, str):
            errors.append(f'suite [{name}] invalid exit_code: {k!r}:{v!r}')

    for n in s.get('needs', []):
        if not isinstance(n, str) or not n:
            errors.append(f'suite [{name}] invalid needs entry: {n!r}')

text = json.dumps(d)
for term in ['github', 'actions', 'ghci', 'bench-ci', 'runner']:
    if re.search(r'(?<!\w)' + term + r'(?!\w)', text, re.I):
        errors.append(f'manifest references CI/host term: {term}')

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
else:
    print('ok')
" "$MANIFEST" "$ROOT"

result=$?
if [ "$result" -eq 0 ]; then
    ok "all suites pass schema, content, and CI-ref checks"
else
    fail "suite validation errors found"
fi

ok "manifest covers $n_suites suites"

echo ""
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
