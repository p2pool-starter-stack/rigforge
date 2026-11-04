#!/usr/bin/env bash
# shellcheck shell=bash
_donation_binary_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

_donation_level_matches() {
    local want="$1" got="" waited=0
    while [ "$waited" -lt 60 ]; do
        got=$(api8080 http://127.0.0.1:8080/2/summary | jq -r '.donate_level // empty' 2>/dev/null || true)
        [ "$got" = "$want" ] && break
        sleep 2
        waited=$((waited + 2))
    done
    [ "$got" = "$want" ] && [ "$(jq -r '."donate-level"' "$GEN_CFG")" = "$want" ]
}

_donation_migration_proof() (
    local tree worker binary backup proof original before identity active=0 snapshot_ready=0 level rc
    tree=$(dirname "$(dirname "$GEN_CFG")")
    worker=$(dirname "$tree")
    binary="$tree/build/xmrig"
    [ "$(basename "$tree")" = xmrig ] && [ -x "$binary" ] || return 1
    backup=$(mktemp -d "${TMPDIR:?}/rigforge-donation.XXXXXX") || return 1
    systemctl is-active --quiet xmrig && active=1
    _donation_original_tree() {
        local candidate
        for candidate in "$tree" "$worker"/xmrig-*; do
            if [ -f "$candidate/$proof" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
        return 1
    }
    _donation_restore_build() {
        local saved
        if [ "$snapshot_ready" = 0 ]; then
            if [ "$active" = 1 ]; then "$RIGFORGE" start || return 1; fi
            rm -rf "$backup"
            return
        fi
        saved=$(_donation_original_tree) || return 1
        "$RIGFORGE" stop || return 1
        rm -rf "$tree" && cp -a "$backup/xmrig" "$tree" || return 1
        if [ "$saved" != "$tree" ]; then rm -rf "$saved" || return 1; fi
        cp -p "$backup/config.json" "$CFG" || return 1
        "$RIGFORGE" apply && "$RIGFORGE" stop || return 1
        rm -rf "$tree" && cp -a "$backup/xmrig" "$tree" || return 1
        cp -p "$backup/xmrig-config.json" "$GEN_CFG" || return 1
        diff -qr "$backup/xmrig" "$tree" >/dev/null &&
            cmp -s "$backup/config.json" "$CFG" && cmp -s "$backup/xmrig-config.json" "$GEN_CFG" || return 1
        if [ -f "$backup/build.log" ]; then
            cp -p "$backup/build.log" "$worker/build.log" || return 1
        else
            rm -f "$worker/build.log" || return 1
        fi
        if [ "$active" = 1 ]; then "$RIGFORGE" start || return 1; fi
        rm -rf "$backup" || return 1
        printf 'donation-restore: original binary, marker, configs and service state restored\n'
    }
    trap 'rc=$?; trap - EXIT; if ! _donation_restore_build; then printf "donation artifact restoration failed\n" >&2; rc=1; fi; exit "$rc"' EXIT
    "$RIGFORGE" stop || return 1
    if ! cp -p "$CFG" "$backup/config.json" || ! cp -p "$GEN_CFG" "$backup/xmrig-config.json" || ! cp -a "$tree" "$backup/xmrig"; then
        return 1
    fi
    if [ -f "$worker/build.log" ] && ! cp -p "$worker/build.log" "$backup/build.log"; then
        return 1
    fi
    proof=$(mktemp "$tree/.rigforge-donation-proof.XXXXXX") || return 1
    proof=$(basename "$proof")
    snapshot_ready=1
    set_cfg '.DONATION=$level | .autotune="disabled"' soft --argjson level 0 || return 1
    rm -f "$tree/.rigforge-donate-min" "$worker/build.log" || return 1
    KEEP_ARCHIVES=2147483647 "$RIGFORGE" upgrade || return 1
    grep -Eq 'Building CXX object .*Pools[.]cpp[.]o' "$worker/build.log" &&
        grep -Fq 'Linking CXX executable xmrig' "$worker/build.log" || return 1
    grep -E 'Building CXX object .*Pools[.]cpp[.]o|Linking CXX executable xmrig' "$worker/build.log" || return 1
    original=$(_donation_original_tree) || return 1
    [ "$original" != "$tree" ] && [ -x "$binary" ] && [ ! "$original/build/xmrig" -ef "$binary" ] || return 1
    [ "$(cat "$tree/.rigforge-donate-min")" = 0 ] &&
        grep -Fxq 'constexpr const int kMinimumDonateLevel = 0;' "$tree/src/donate.h" &&
        grep -Fxq 'constexpr const int kDefaultDonateLevel = 0;' "$tree/src/donate.h" || return 1
    [ "$(cat "$tree/.rigforge-commit")" = "$(git -C "$tree" rev-parse HEAD)" ] || return 1
    "$RIGFORGE" start || return 1
    _donation_level_matches 0 || return 1
    printf 'donation-migration: missing minimum marker rebuilt; compiled minimum=0; reported donation=0\n'
    before=$(cksum "$binary") && identity=$(_donation_binary_identity "$binary") || return 1
    for level in 1 0 5 2; do
        set_cfg '.DONATION=$level' soft --argjson level "$level" || return 1
        _donation_level_matches "$level" && [ "$(cksum "$binary")" = "$before" ] &&
            [ "$(_donation_binary_identity "$binary")" = "$identity" ] || return 1
        printf 'donation-runtime: configured=%s reported=%s newly-built-binary=unchanged\n' "$level" "$level"
    done
)

phase_dev_fee() {
    phase "dev-fee — legacy build migration and runtime donation reductions (#602)"
    if _donation_migration_proof; then
        ok "candidate upgrade rebuilds a missing donation minimum, reports zero, applies 1→0 and 5→2 without rebuilding, and restores original artifacts (#602)"
    else
        bad "donation migration, runtime reduction or original-artifact restoration failed (#602)"
        return 1
    fi
}
