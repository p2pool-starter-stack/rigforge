#!/usr/bin/env bash
# shellcheck shell=bash

_package_channel() {
    local marker="${RIGFORGE_PACKAGE_MARKER:-$RIGFORGE_LIB/.rigforge-package}" v
    [ -f "$marker" ] || return 1
    v=$(tr -d '[:space:]' <"$marker")
    case "$v" in apt | brew) printf '%s' "$v" ;; *) return 1 ;; esac
}

_package_install() { _package_channel >/dev/null; }

_package_upgrade_cmd() {
    case "$(_package_channel)" in
    apt) printf 'sudo apt upgrade rigforge' ;;
    brew) printf 'brew upgrade rigforge' ;;
    esac
}
