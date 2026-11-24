#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rigforge.sh}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
export RIGFORGE_HOME="$D" RIGFORGE_APPLIANCE=0
source "$SCRIPT"
set +e
fails=0
check() {
    [ "$2" = "$3" ] || {
        printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3" >&2
        fails=$((fails + 1))
    }
}
has() {
    case "$2" in *"$3"*) ;; *)
        printf 'FAIL %s: [%s] lacks [%s]\n' "$1" "$2" "$3" >&2
        fails=$((fails + 1))
        ;;
    esac
}
lacks() {
    case "$2" in *"$3"*)
        printf 'FAIL %s: [%s] has [%s]\n' "$1" "$2" "$3" >&2
        fails=$((fails + 1))
        ;;
    esac
}
mark() { if [ -n "$1" ]; then printf '%s\n' "$1" >"$D/.rigforge-package"; else rm -f "$D/.rigforge-package"; fi; }

mark ""
_package_install && check "no marker is not a package install" yes no
mark apt
check "apt marker is detected" "$(_package_channel)" apt
mark brew
check "brew marker is detected" "$(_package_channel)" brew
mark bogus
_package_install && check "unknown marker value is ignored" yes no
mark apt
RIGFORGE_PACKAGE_MARKER="$D/elsewhere" _package_install && check "marker override moves the lookup" yes no
printf 'brew' >"$D/elsewhere"
check "marker override is read" "$(RIGFORGE_PACKAGE_MARKER="$D/elsewhere" _package_channel)" brew

mkdir -p "$D/bin" "$D/stubs" "$D/state/spool"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/git.log"\nexit 0\n' "$D" >"$D/stubs/git"
chmod +x "$D/stubs/git"
export PATH="$D/stubs:$PATH"
printf '1.0.0\n' >"$D/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$D/config.json"

for ch in apt brew; do
    mark "$ch"
    rm -f "$D/git.log" "$D/state/status.json"
    printf '{"version":"v9.9.9"}\n' >"$D/state/spool/upgrade-abc123def4567890.json"
    (
        OS_TYPE=Linux
        SCRIPT_DIR="$D"
        CONFIG_JSON="$D/config.json"
        RIGFORGE_CONTROL_STATE="$D/state"
        _control_claim_staged() { mv "$1" "$D/staged.json" && printf '%s' "$D/staged.json"; }
        control_upgrade >/dev/null 2>&1
    )
    st=$(cat "$D/state/status.json" 2>/dev/null)
    check "$ch: control_upgrade records failed" "$(printf '%s' "$st" | jq -r .status)" failed
    has "$ch: status names the channel command" "$st" "$ch upgrade rigforge"
    check "$ch: control_upgrade never invokes git" "$(cat "$D/git.log" 2>/dev/null)" ""
    (SCRIPT_DIR="$D" _control_upgrade_steps v9.9.9 >/dev/null 2>&1)
    check "$ch: a tag upgrade refuses" "$?" 1
    check "$ch: a tag upgrade never invokes git" "$(cat "$D/git.log" 2>/dev/null)" ""
done

mkdir -p "$D/curlbin"
printf '#!/usr/bin/env bash\nprintf "{\\"tag_name\\":\\"v9.9.9\\"}"\n' >"$D/curlbin/curl"
chmod +x "$D/curlbin/curl"
for ch in apt brew; do
    mark "$ch"
    out=$(SCRIPT_DIR="$D" PATH="$D/curlbin:$PATH" _upgrade_check 2>&1)
    has "$ch: --check prints the channel command" "$out" "$ch upgrade rigforge"
    lacks "$ch: --check prints no git steps" "$out" "git checkout"
done
mark ""
out=$(SCRIPT_DIR="$D" PATH="$D/curlbin:$PATH" _upgrade_check 2>&1)
has "no marker: --check still prints the git recipe" "$out" "git checkout v9.9.9"
lacks "no marker: --check prints no channel command" "$out" "upgrade rigforge"

for ch in "" apt; do
    mark "$ch"
    rm -f "$D/bin/rigforge"
    (SCRIPT_DIR="$D" BIN_DIR="$D/bin" ADD_TO_PATH=true link_cli >/dev/null 2>&1)
    want=present
    [ -z "$ch" ] || want=absent
    check "link_cli with marker '${ch:-none}'" "$([ -L "$D/bin/rigforge" ] && echo present || echo absent)" "$want"
done

for ch in "" apt brew; do
    mark "$ch"
    rm -f "$D/dep.log"
    (
        OS_TYPE=Linux
        SCRIPT_DIR="$D"
        _detect_pkg_manager() { DEP_INSTALL="echo installed >>$D/dep.log"; }
        _missing_deps() { echo jq; }
        install_dependencies >/dev/null 2>&1
    )
    want="installed jq"
    [ -z "$ch" ] || want=""
    check "install_dependencies with marker '${ch:-none}'" "$(cat "$D/dep.log" 2>/dev/null)" "$want"
done

[ "$fails" -eq 0 ] || exit 1
printf 'package mode: PASS\n'
