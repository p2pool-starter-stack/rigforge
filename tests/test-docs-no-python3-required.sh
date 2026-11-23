#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DOCS=(README.md SECURITY.md RELEASING.md CONTRIBUTING.md
    docs/how-it-works.md docs/getting-started.md docs/operations.md
    docs/configuration.md docs/hardware.md docs/faq.md
    docs/pithead-integration.md docs/shared-host.md AGENTS.md)
FOUND=""
for f in "${DOCS[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in
        *tests/* | *test-contract* | *test-docs-replay* | *virsh* | *pre-commit* | *standard-library* | *pipx*) continue ;;
        esac
        FOUND="${FOUND}${f}: ${line}"$'\n'
    done < <(grep -inE '(python3.*(is|required|prerequisite|must be)|requires python3|install python3|python3 is a)' "$f" 2>/dev/null || true)
done
if [ -n "$FOUND" ]; then
    echo "FAIL: product docs still claim python3 is a runtime requirement:"
    while IFS= read -r line; do
        echo "  $line"
    done <<<"${FOUND%$'\n'}"
    exit 1
fi
echo "OK: no product document requires python3 as a runtime dependency"
