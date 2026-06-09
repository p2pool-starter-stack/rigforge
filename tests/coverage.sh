#!/usr/bin/env bash
#
# Coverage runner (#68): measure line coverage of rigforge.sh + util/proposed-grub.sh by running the
# dependency-free suite (tests/run.sh) under kcov, and enforce a committed total floor (a ratchet).
#
# kcov is Linux + ptrace based, so this runs the suite inside a PINNED kcov Docker image (by digest,
# matching how the e2e job pins its Ubuntu image). The suite needs jq, which the kcov image lacks, so
# we mount a PINNED static jq from the upstream release (the same pin-by-sha256 approach used for the
# linters — no apt, no drift). Because the black-box tests now run the REAL rigforge.sh (via
# RIGFORGE_HOME against a sandbox, not a copy), kcov credits both the sourced and the command-dispatch
# paths to the git files.
#
# Outputs Cobertura XML (coverage/cobertura.xml, paths normalised to repo-relative) for the CI
# patch-coverage gate (diff-cover) plus an HTML report under coverage/.
#
# Usage:
#   make coverage                 # measure + enforce the floor (needs Docker; Linux coverage only)
#   COVERAGE_NO_FAIL=1 make coverage   # measure + report only, don't fail under the floor
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- Pinned, reproducible toolchain (no apt) ---------------------------------
# kcov v42 (linux/amd64), pinned by digest like the e2e image.
KCOV_IMAGE="kcov/kcov@sha256:30c442617f3d8e040bf0ec2cba19cc2ee517b668f3a3d50b2d3de1c435138a8a"
# Static jq for use INSIDE the kcov (Debian) container — the suite needs it and the image lacks it.
JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
JQ_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"

FLOOR_FILE="$ROOT/tests/coverage-floor.txt"
OUT="$ROOT/coverage"
CACHE="$ROOT/.coverage-cache"

command -v docker >/dev/null 2>&1 || {
    echo "coverage: docker is required (kcov is Linux/ptrace based, so the suite runs in a container)." >&2
    exit 2
}

# --- Fetch + verify the pinned static jq -------------------------------------
mkdir -p "$CACHE"
JQ_BIN="$CACHE/jq-linux-amd64"
if [ ! -x "$JQ_BIN" ]; then
    echo "coverage: fetching pinned static jq..."
    curl -fsSL "$JQ_URL" -o "$JQ_BIN"
    echo "${JQ_SHA256}  ${JQ_BIN}" | sha256sum -c -
    chmod +x "$JQ_BIN"
fi

# --- Run the suite under kcov ------------------------------------------------
# The repo is mounted at /src; include only the two git files by absolute path, which excludes any
# per-test sandbox copies and keeps the number stable. ptrace needs the seccomp/cap relaxations.
rm -rf "$OUT"
mkdir -p "$OUT"
echo "coverage: running tests/run.sh under kcov (this is slower than 'make test')..."
docker run --rm --security-opt seccomp=unconfined --cap-add SYS_PTRACE \
    -v "$ROOT:/src" -v "$JQ_BIN:/usr/local/bin/jq:ro" -w /src \
    --entrypoint kcov "$KCOV_IMAGE" \
    --include-pattern=/src/rigforge.sh,/src/util/proposed-grub.sh \
    --clean /src/coverage ./tests/run.sh

# kcov writes root-owned files onto the bind mount; hand them back to the caller so later steps and
# workspace cleanup can read/remove them.
if [ "$(id -u)" -ne 0 ]; then
    sudo chown -R "$(id -u):$(id -g)" "$OUT" 2>/dev/null || true
fi

# --- Locate the report (the kcov per-executable dir for our run) -------------
COV_JSON="$(find "$OUT" -name coverage.json -not -path '*kcov-merged*' | head -1)"
COB_SRC="$(find "$OUT" -name cobertura.xml -not -path '*kcov-merged*' | head -1)"
[ -n "$COV_JSON" ] && [ -n "$COB_SRC" ] || {
    echo "coverage: kcov produced no report — see the suite output above." >&2
    exit 1
}

# Guard against the silent-zero failure mode (e.g. wrong invocation form): if kcov recorded nothing for
# our files, fail loudly rather than passing a meaningless 0%.
TOTAL_LINES="$("$JQ_BIN" -r '.total_lines' "$COV_JSON")"
if [ "${TOTAL_LINES:-0}" -le 0 ] 2>/dev/null; then
    echo "coverage: kcov recorded 0 instrumented lines for rigforge.sh/util — coverage not collected." >&2
    echo "          (check that the black-box tests run \$SCRIPT and the include-pattern paths match.)" >&2
    exit 1
fi

# Normalise the Cobertura paths to repo-relative (strip the /src container prefix) so diff-cover, run on
# the host against origin/main, matches them to the git files.
mkdir -p "$OUT"
sed -e 's#/src/##g' -e 's#<source>/src</source>#<source>.</source>#g' "$COB_SRC" >"$OUT/cobertura.xml"

# --- Report + enforce the floor ----------------------------------------------
PCT="$("$JQ_BIN" -r '.percent_covered' "$COV_JSON")"
FLOOR="$(tr -d '[:space:]' <"$FLOOR_FILE" 2>/dev/null || echo 0)"

echo ""
echo "  rigforge.sh + util/proposed-grub.sh coverage"
"$JQ_BIN" -r '.files[] | "    \(.covered_lines)/\(.total_lines)\t\(.percent_covered)%\t\(.file)"' "$COV_JSON"
echo "  ------------------------------------------------------------"
printf '  TOTAL: %s%%   (floor: %s%%)\n\n' "$PCT" "$FLOOR"

if [ "${COVERAGE_NO_FAIL:-0}" = "1" ]; then
    echo "coverage: report-only (COVERAGE_NO_FAIL=1) — floor not enforced."
    exit 0
fi
if awk -v p="$PCT" -v f="$FLOOR" 'BEGIN { exit !(p + 0 >= f + 0) }'; then
    echo "COVERAGE: PASS — ${PCT}% >= floor ${FLOOR}%."
else
    echo "COVERAGE: FAIL — ${PCT}% < floor ${FLOOR}%. Add tests, or lower the floor in tests/coverage-floor.txt if intentional." >&2
    exit 1
fi
