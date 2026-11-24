#!/usr/bin/env bash
set -uo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir "$D/bin"
printf '#!/usr/bin/env bash\necho "SUDO: $*"\nexec env -i PATH="$PATH" "$@"\n' >"$D/bin/sudo"
cat >"$D/rig" <<DRIVER
#!/usr/bin/env bash
if [ -z "\${RIGFORGE_FORCE_ELEVATE:-}" ]; then
    env | sort
    echo "ARGS: \$*"
    exit 0
fi
source "$SCRIPT"
OS_TYPE=Linux
"\$@"
DRIVER
chmod +x "$D/bin/sudo" "$D/rig"
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected [$2] got [$3]"
        fail=1
    fi
}
elevate() { PATH="$D/bin:$PATH" RIGFORGE_HOME="$D" RIGFORGE_FORCE_ELEVATE=1 bash "$D/rig" "$@" 2>&1; }
count() { printf '%s\n' "$out" | grep -c "$1"; }

for v in $(compgen -e | grep -E '^(TUNE|AUTOTUNE)_'); do unset "$v"; done
out=$(elevate tune --live)
check "with nothing to forward the sudo command is unchanged" 1 "$(count "^SUDO: $D/rig tune --live\$")"

export TUNE_BENCH=1M AUTOTUNE_X='a b' OTHER_VAR=leak
out=$(elevate tune --live)
check "TUNE_ survives a sudo that resets the environment" 1 "$(count '^TUNE_BENCH=1M$')"
check "AUTOTUNE_ survives with spaces intact" 1 "$(count '^AUTOTUNE_X=a b$')"
check "other variables are not forwarded" 0 "$(count '^OTHER_VAR=')"
check "arguments are passed through" 1 "$(count '^ARGS: tune --live$')"
out=$(elevate bios)
check "bios keeps them too" 1 "$(count '^TUNE_BENCH=1M$')"
out=$(elevate stress)
check "stress keeps them too" 1 "$(count '^TUNE_BENCH=1M$')"
exit "$fail"
