#!/usr/bin/env bash
# Docs lint (#584): every documented clone of this repo is pinned to a release tag, never the
# default branch (develop), and no pin is newer than VERSION. Static; no hardware or network.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VER=$(tr -d '[:space:]' <"$ROOT/VERSION")

# clone_pin_problem <line> <version>: prints why a clone line is unacceptable, nothing when it is fine.
clone_pin_problem() {
    local tag
    tag=$(printf '%s\n' "$1" | sed -n 's/.*git clone --branch \(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) .*/\1/p')
    if [ -z "$tag" ]; then
        echo "no --branch vX.Y.Z pin"
    elif [ "$(printf '%s\n%s\n' "${tag#v}" "$2" | sort -V | tail -1)" != "$2" ]; then
        echo "pin $tag is newer than VERSION $2"
    fi
}

fail=0
expect() { # <label> <line> <version> <want-problem: yes|no>
    local got=no
    [ -z "$(clone_pin_problem "$2" "$3")" ] || got=yes
    if [ "$got" = "$4" ]; then printf 'PASS: %s\n' "$1"; else
        printf 'FAIL: %s\n' "$1" >&2
        fail=1
    fi
}
U=https://github.com/p2pool-starter-stack/rigforge.git
expect "checker rejects a bare clone" "git clone $U" 1.18.0 yes
expect "checker rejects a branch name pin" "git clone --branch develop $U" 1.18.0 yes
expect "checker accepts a tag pin" "git clone --branch v1.18.0 $U" 1.18.0 no
expect "checker accepts an older tag" "git clone --branch v1.9.0 $U" 1.18.0 no
expect "checker rejects a tag newer than VERSION" "git clone --branch v1.19.0 $U" 1.18.0 yes
expect "checker compares versions numerically" "git clone --branch v1.9.0 $U" 1.10.0 no

n=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    problem=$(clone_pin_problem "$line" "$VER")
    if [ -z "$problem" ]; then printf 'PASS: pinned clone: %s\n' "${line#"$ROOT/"}"; else
        printf 'FAIL: %s: %s\n' "$problem" "${line#"$ROOT/"}" >&2
        fail=1
    fi
done < <(grep -rn 'git clone .*github.com/p2pool-starter-stack/rigforge' "$ROOT/README.md" "$ROOT/docs" --include='*.md' || true)
[ "$n" -gt 0 ] || {
    echo 'FAIL: no documented clone found; the lint would pass vacuously' >&2
    fail=1
}
exit "$fail"
