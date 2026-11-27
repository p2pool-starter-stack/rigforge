#!/usr/bin/env bash
# shellcheck shell=bash

_IMPL_NATIVE_VERBS=""

_impl_handover() {
    local root="${BASH_SOURCE[0]%/util/impl-handover.sh}" verb="${1:-setup}" v native=0
    local impl="${RIGFORGE_IMPL:-}" from="the environment" marker bin line=
    for v in $_IMPL_NATIVE_VERBS; do
        if [ "$v" = "$verb" ]; then native=1; fi
    done
    if [ "$native" = 0 ]; then return 0; fi
    marker="$root/.rigforge-impl"
    if [ -z "$impl" ] && { [ -e "$marker" ] || [ -L "$marker" ]; }; then
        IFS= read -r line 2>/dev/null <"$marker" || true
        impl="${line%"${line##*[![:space:]]}"}"
        from="the marker file $marker"
        [ -n "$impl" ] || error "RIGFORGE_IMPL is selected by $from, which is empty or unreadable. Fix or delete the marker, or run with RIGFORGE_IMPL=bash."
    fi
    case "$impl" in
    "" | bash) return 0 ;;
    rust) ;;
    *) error "Unknown RIGFORGE_IMPL value '$impl' (set by $from). Use 'bash' or 'rust'; to leave this selection run with RIGFORGE_IMPL=bash." ;;
    esac
    bin="${RIGFORGE_BIN:-$root/bin/rigforge-rs}"
    [ "${bin#*/}" != "$bin" ] || bin="./$bin"
    if [ ! -f "$bin" ] || [ ! -x "$bin" ]; then
        error "RIGFORGE_IMPL=rust is selected by $from, but the binary $bin is missing or not executable. Install it, or run with RIGFORGE_IMPL=bash."
    fi
    export RIGFORGE_HOME="${SCRIPT_DIR:-$root}"
    export XMRIG_VERSION XMRIG_COMMIT RIGFORGE_APPLIANCE MIN_CLOCK_PCT
    trap - ERR
    shopt -s execfail
    set +e
    exec -a "$0" "$bin" "$@"
    error "RIGFORGE_IMPL=rust is selected by $from, but the binary $bin cannot be executed. Install a binary built for this machine, or run with RIGFORGE_IMPL=bash."
}
