#!/usr/bin/env bash
set -euo pipefail

ALLOW="AUTOTUNE_MODE TUNE_MODE TUNE_TMP"

knobs() {
    grep -ohE '\$\{(AUTO)?TUNE_[A-Z0-9_]+:?[-=]' "$@" | sed -E 's/^\$\{//; s/:?[-=]$//' | sort -u
}

check() {
    local docs="$1" names n bad=0
    shift
    names=$(knobs "$@") || names=""
    if [ -z "$names" ]; then
        echo "FATAL: no TUNE_/AUTOTUNE_ settings found in: $*" >&2
        return 1
    fi
    for n in $names; do
        case " $ALLOW " in *" $n "*) continue ;; esac
        if ! grep -rqw -- "$n" "$docs"; then
            echo "undocumented setting: $n is read from the environment but mentioned nowhere under $docs/" >&2
            bad=1
        fi
    done
    return "$bad"
}

self_test() {
    t=$(mktemp -d)
    trap 'rm -rf "$t"' EXIT
    mkdir -p "$t/docs"
    printf '%s\n' 'a="${TUNE_FOO:-1}"' 'b="${AUTOTUNE_BAR:=2}"' 'c="${TUNE_TMP:-}"' 'd="${TUNE_FOO_X:+x}"' >"$t/src.sh"
    printf '| `TUNE_FOO` | 1 |\n' >"$t/docs/a.md"
    if check "$t/docs" "$t/src.sh" 2>"$t/err"; then
        echo "self-test FAILED: an undocumented AUTOTUNE_BAR passed" >&2
        return 1
    fi
    grep -q 'undocumented setting: AUTOTUNE_BAR' "$t/err" || {
        echo "self-test FAILED: AUTOTUNE_BAR was not named" >&2
        return 1
    }
    printf 'AUTOTUNE_BAR_LONG\n' >>"$t/docs/a.md"
    if check "$t/docs" "$t/src.sh" 2>/dev/null; then
        echo "self-test FAILED: a longer name counted as a mention of AUTOTUNE_BAR" >&2
        return 1
    fi
    printf 'Set AUTOTUNE_BAR.\n' >>"$t/docs/a.md"
    check "$t/docs" "$t/src.sh" || {
        echo "self-test FAILED: documented settings were refused" >&2
        return 1
    }
    : >"$t/empty.sh"
    if check "$t/docs" "$t/empty.sh" 2>/dev/null; then
        echo "self-test FAILED: an empty scan passed" >&2
        return 1
    fi
    echo "lint-env-docs self-test: ok"
}

case "${1:-}" in
--self-test) self_test ;;
"")
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    check docs rigforge.sh util/*.sh
    echo "lint-env-docs: every TUNE_/AUTOTUNE_ setting is documented under docs/"
    ;;
*)
    echo "usage: $0 [--self-test]" >&2
    exit 2
    ;;
esac
