# shellcheck shell=bash disable=SC1090,SC2034,SC2317,SC2329
echo "== unit: package marker makes upgrade, link and dependency paths package-aware (#782) =="
PK="$(mktemp -d "$SANDBOX/pk.XXXXXX")"
mkdir -p "$PK/bin" "$PK/stubs" "$PK/curlbin" "$PK/state/spool"
mark() { if [ -n "$1" ]; then printf '%s\n' "$1" >"$PK/.rigforge-package"; else rm -f "$PK/.rigforge-package"; fi; }
printf '#!/usr/bin/env bash\necho "$*" >>"%s/git.log"\nexit 0\n' "$PK" >"$PK/stubs/git"
printf '#!/usr/bin/env bash\nprintf "{\\"tag_name\\":\\"v9.9.9\\"}"\n' >"$PK/curlbin/curl"
chmod +x "$PK/stubs/git" "$PK/curlbin/curl"
printf '1.0.0\n' >"$PK/VERSION"
printf '{"pools":[{"url":"h:3333"}]}\n' >"$PK/config.json"

(
    source "$SCRIPT"
    set +e
    RIGFORGE_LIB="$PK" RIGFORGE_STATE="$PK"
    mark ""
    ! _package_install || echo "none-detected"
    mark apt
    echo "apt:$(_package_channel)"
    mark brew
    echo "brew:$(_package_channel)"
    mark bogus
    ! _package_install || echo "bogus-detected"
    printf 'brew' >"$PK/elsewhere"
    mark apt
    echo "override:$(RIGFORGE_PACKAGE_MARKER="$PK/elsewhere" _package_channel)"
) >"$PK/detect.out"
assert_eq "package marker: apt and brew detected, none and bogus ignored, override honoured (#782)" "$(tr '\n' ' ' <"$PK/detect.out")" "apt:apt brew:brew override:brew "

for ch in apt brew; do
    mark "$ch"
    rm -f "$PK/git.log" "$PK/state/status.json"
    printf '{"version":"v9.9.9"}\n' >"$PK/state/spool/upgrade-abc123def4567890.json"
    (
        source "$SCRIPT"
        set +e
        OS_TYPE=Linux
        RIGFORGE_LIB="$PK" RIGFORGE_STATE="$PK"
        CONFIG_JSON="$PK/config.json"
        RIGFORGE_CONTROL_STATE="$PK/state"
        _control_claim_staged() { mv "$1" "$PK/staged.json" && printf '%s' "$PK/staged.json"; }
        PATH="$PK/stubs:$PATH" control_upgrade >/dev/null 2>&1
    )
    pk_st=$(cat "$PK/state/status.json" 2>/dev/null)
    assert_eq "$ch: control_upgrade records failed (#782)" "$(printf '%s' "$pk_st" | jq -r .status)" "failed"
    assert_contains "$ch: status names the channel command (#782)" "$pk_st" "$ch upgrade rigforge"
    assert_eq "$ch: control_upgrade never invokes git (#782)" "$(cat "$PK/git.log" 2>/dev/null)" ""
    pk_rc=0
    (
        source "$SCRIPT"
        RIGFORGE_LIB="$PK" RIGFORGE_STATE="$PK" PATH="$PK/stubs:$PATH" _control_upgrade_steps v9.9.9 >/dev/null 2>&1
    ) || pk_rc=$?
    assert_eq "$ch: a tag upgrade refuses (#782)" "$pk_rc" "1"
    assert_eq "$ch: a tag upgrade never invokes git (#782)" "$(cat "$PK/git.log" 2>/dev/null)" ""
    pk_out=$(
        source "$SCRIPT"
        RIGFORGE_LIB="$PK" RIGFORGE_STATE="$PK" PATH="$PK/curlbin:$PATH" _upgrade_check 2>&1
    )
    assert_contains "$ch: upgrade --check prints the channel command (#782)" "$pk_out" "$ch upgrade rigforge"
    assert_absent "$ch: upgrade --check prints no git steps (#782)" "$pk_out" "git checkout"
done
mark ""
pk_out=$(
    source "$SCRIPT"
    RIGFORGE_LIB="$PK" RIGFORGE_STATE="$PK" PATH="$PK/curlbin:$PATH" _upgrade_check 2>&1
)
assert_contains "no marker: upgrade --check still prints the git recipe (#782)" "$pk_out" "git checkout v9.9.9"
assert_absent "no marker: upgrade --check prints no channel command (#782)" "$pk_out" "upgrade rigforge"

for ch in "" apt; do
    mark "$ch"
    rm -f "$PK/bin/rigforge"
    (
        source "$SCRIPT"
        RIGFORGE_LIB="$PK" RIGFORGE_STATE="$PK" BIN_DIR="$PK/bin" ADD_TO_PATH=true link_cli >/dev/null 2>&1
    )
    pk_want=present
    [ -z "$ch" ] || pk_want=absent
    assert_eq "link_cli with marker '${ch:-none}' (#782)" "$([ -L "$PK/bin/rigforge" ] && echo present || echo absent)" "$pk_want"
done

for ch in "" apt brew; do
    mark "$ch"
    rm -f "$PK/dep.log"
    (
        source "$SCRIPT"
        OS_TYPE=Linux
        RIGFORGE_LIB="$PK" RIGFORGE_STATE="$PK"
        _detect_pkg_manager() { DEP_INSTALL="echo installed >>$PK/dep.log"; }
        _missing_deps() { echo jq; }
        install_dependencies >/dev/null 2>&1
    )
    pk_want="installed jq"
    [ -z "$ch" ] || pk_want=""
    assert_eq "install_dependencies with marker '${ch:-none}' (#782)" "$(cat "$PK/dep.log" 2>/dev/null)" "$pk_want"
done

for ch in "" apt; do
    printf '%s' "$ch" >"$DR/.rigforge-package"
    [ -n "$ch" ] || rm -f "$DR/.rigforge-package"
    pk_out="$(cd "$DR" && PATH="$STUBS:$PATH" CALL_LOG="$DR/calls.log" GRUB_DEFAULT="$DR/etc/grub" FSTAB="$DR/etc/fstab" \
        MEMINFO="$DR/etc/meminfo" RIGFORGE_HOME="$PWD" bash "$SCRIPT" setup --dry-run </dev/null 2>&1)"
    case "$ch" in
    apt)
        assert_contains "plan under an apt marker: dependencies skipped (#782)" "$pk_out" "package install (apt): the package manager owns the dependencies"
        assert_contains "plan under an apt marker: no symlink (#782)" "$pk_out" "package install (apt): the package owns the command"
        ;;
    *)
        assert_absent "plan without a marker: no package wording (#782)" "$pk_out" "package install ("
        ;;
    esac
done
rm -f "$DR/.rigforge-package"
