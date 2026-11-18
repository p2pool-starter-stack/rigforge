#!/usr/bin/env bash
# shellcheck disable=SC2016
set -uo pipefail
STANDALONE_586=0
if [ -z "${ROOT:-}" ]; then
    STANDALONE_586=1
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    SANDBOX="$(mktemp -d)"
    trap 'rm -rf "$SANDBOX"' EXIT
    PASS=0
    FAIL=0
    ok() {
        PASS=$((PASS + 1))
        printf '  PASS %s\n' "$1"
    }
    bad() {
        FAIL=$((FAIL + 1))
        printf '  FAIL %s: %s\n' "$1" "$2" >&2
    }
    assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $3, got $2"; fi; }
    assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing $3" ;; esac }
fi

echo "== unit: docs replay guest verification (#586) =="
T586="$(mktemp -d "$SANDBOX/docs-guest.XXXXXX")"
mkdir -p "$T586/bin" "$T586/clone/data/worker/xmrig/build" "$T586/state" "$T586/grub.d"
POOL_HOST="pool-$PPID"
POOL_ADDRESS="address-$PPID"
POOL_PORT="$((20000 + PPID % 10000))"
API_PORT="$((POOL_PORT + 1))"
API_BIND="bind-$PPID"
LOOPBACK_ADDRESS="loop-$PPID"

printf 'boot-before\n' >"$T586/boot-id"
printf 'root=fixture quiet\n' >"$T586/cmdline"
printf 'flags avx2 fixture\n' >"$T586/cpuinfo"
printf 'ID=ubuntu\n' >"$T586/os-release"
printf '0\n' >"$T586/hugepages-2m"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' >"$T586/grub"
printf 'generated grub fixture\n' >"$T586/grub.cfg"
printf 'fstab fixture\n' >"$T586/fstab"
printf 'limits fixture\n' >"$T586/limits"
printf 'modules fixture\n' >"$T586/modules"
: >"$T586/nft-present"
rm "$T586/nft-present"

jq -n --arg url "$POOL_HOST:$POOL_PORT" '{HOME_DIR:"DYNAMIC_HOME",pools:[{url:$url}]}' >"$T586/clone/config.json"
cat >"$T586/nft-chain.json" <<NFTCHAIN
{"nftables":[{"rule":{"family":"inet","table":"rigforge","chain":"api","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":@PORT@}},{"counter":{"packets":@DROPPED@}},{"drop"}]}}]}
NFTCHAIN
jq -n --arg url "$POOL_HOST:$POOL_PORT" --arg host "$API_BIND" --argjson port "$API_PORT" '{pools:[{url:$url,enabled:true}],"donate-level":0,"donate-over-proxy":0,http:{host:$host,port:$port,restricted:true,"access-token":null}}' >"$T586/clone/data/worker/xmrig/build/config.json"

printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac' >"$T586/bin/uname"
printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = -p ]; then echo systemd; fi' >"$T586/bin/ps"
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    'is-system-running) exit 0 ;;' \
    'list-unit-files|list-units) [ "${FAKE_SYSTEMCTL_FAIL:-0}" = 1 ] && exit 2; [ "${FAKE_UNITS:-}" = present ] && echo "xmrig.service enabled"; exit 0 ;;' \
    'is-enabled|is-active) [ "${FAKE_INSTALLED:-0}" = 1 ] ;;' \
    'show) printf "%s\n" "${FAKE_FRAGMENT:-/etc/systemd/system/xmrig.service}" ;;' \
    'esac' >"$T586/bin/systemctl"
printf '%s\n' '#!/usr/bin/env bash' '[ "${FAKE_PROCESSES:-}" = present ] && echo "123 xmrig"; exit 0' >"$T586/bin/pgrep"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *rev-parse*) printf "%s\n" "${FAKE_HEAD:-$(printf a%.0s 1 40)}" ;; *) exit 0 ;; esac' >"$T586/bin/git"
printf '%s\n' '#!/usr/bin/env bash' \
    '[ "${FAKE_SS_FAIL:-0}" = 1 ] && exit 2' \
    'case "$1" in' \
    '-Htnp) [ "${FAKE_PEER:-}" = present ] && printf "ESTAB 0 0 local %s:%s users:xmrig\n" "$FAKE_POOL_ADDRESS" "$FAKE_POOL_PORT" ;;' \
    '*) [ "${FAKE_LISTENER:-}" = present ] && printf "LISTEN 0 0 bind:%s users:xmrig\n" "$FAKE_API_PORT" ;;' \
    'esac' \
    'exit 0' >"$T586/bin/ss"
printf '%s\n' '#!/usr/bin/env bash' \
    '[ "${FAKE_NFT_MODE:-}" = fail ] && exit 2' \
    'if [ "$1" = -j ] && [ "$3" = chain ]; then dropped=0; [ -f "$FAKE_DROP_FILE" ] && dropped=$(cat "$FAKE_DROP_FILE"); sed "s/@PORT@/$FAKE_API_PORT/;s/@DROPPED@/$dropped/" "$FAKE_NFT_CHAIN_TEMPLATE"; exit 0; fi' \
    'if [ -f "$FAKE_NFT_FILE" ]; then printf '\''{"nftables":[{"table":{"family":"inet","name":"rigforge"}}]}\n'\''; else printf '\''{"nftables":[]}\n'\''; fi' >"$T586/bin/nft"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s STREAM fixture\n" "$FAKE_RESOLVED_ADDRESS"' >"$T586/bin/getent"
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '-o) printf "1: lo inet %s/8 scope host lo\n" "$FAKE_LOOPBACK_ADDRESS"; exit 0 ;;' \
    'netns) [ "$2" = exec ] && shift 3 && exec "$@"; exit 0 ;;' \
    'link) [ "$2" = show ] && exit 1; exit 0 ;;' \
    '-n) exit 0 ;;' \
    'esac' \
    'exit 0' >"$T586/bin/ip"
printf '%s\n' '#!/usr/bin/env bash' 'if [ "${FAKE_MOUNT:-ok}" = ok ]; then echo "hugetlbfs on /dev/hugepages type hugetlbfs (rw)"; else echo "proc on /proc type proc"; fi' >"$T586/bin/mount"
printf '%s\n' '#!/usr/bin/env bash' \
printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do if [ "$a" = --config ]; then cfg=$(cat); case "$cfg" in' \
    '*/status*) printf "{\"status\":\"%s\"}" "${FAKE_CONTROL_STATUS:-applied}"; exit 0 ;;' \
    '*/apply*|*/upgrade*) printf "{\"status\":\"accepted\",\"change_id\":\"0123456789abcdef\"}"; exit 0 ;;' \
    'esac; exit 7; fi; done' \
    'case "$*" in' \
    '*--interface*169.254.241.2*) if [ "${FAKE_REFUSE_MODE:-drop}" = pass ]; then printf 200; exit 0; fi; if [ "${FAKE_REFUSE_MODE:-drop}" = drop ]; then n=0; [ -f "$FAKE_DROP_FILE" ] && n=$(cat "$FAKE_DROP_FILE"); n=$((n + 1)); printf "%s" "$n" >"$FAKE_DROP_FILE"; fi; exit 7 ;;' \
    '*--interface*169.254.241.3*) printf "%s" "${FAKE_ACCEPT_CODE:-200}"; exit 0 ;;' \
    '*-X?PUT*) [ "${FAKE_CURL_MODE:-}" = transport ] && exit 7; [ "${FAKE_CURL_MODE:-}" = write200 ] && printf 200 || printf 403 ;;' \
    '*) n=0; [ -f "$FAKE_CURL_COUNT" ] && n=$(cat "$FAKE_CURL_COUNT"); n=$((n + 1)); printf "%s" "$n" >"$FAKE_CURL_COUNT"; printf "{\"donate_level\":%s,\"hashrate\":{\"total\":[1]},\"connection\":{\"accepted\":%s,\"rejected\":0}}\n" "${FAKE_DONATE_LEVEL:-0}" "$n" ;;' \
    'esac' >"$T586/bin/curl"
printf '%s\n' '#!/usr/bin/env bash' ':' >"$T586/bin/sleep"
chmod +x "$T586/bin"/*

guest586() {
    env PATH="$T586/bin:$PATH" \
        E2E_BOOT_ID_FILE="$T586/boot-id" E2E_CMDLINE_FILE="$T586/cmdline" \
        E2E_CPUINFO_FILE="$T586/cpuinfo" E2E_OS_RELEASE_FILE="$T586/os-release" E2E_HUGEPAGES_2M_FILE="$T586/hugepages-2m" \
        E2E_GRUB_DEFAULT_FILE="$T586/grub" E2E_GRUB_CONFIG_FILE="$T586/grub.cfg" \
        E2E_GRUB_DROPIN_DIR="$T586/grub.d" E2E_FSTAB_FILE="$T586/fstab" E2E_LIMITS_FILE="$T586/limits" \
        E2E_MODULES_FILE="$T586/modules" E2E_MSR_LOAD_FILE="$T586/msr-load" \
        E2E_SHARE_TIMEOUT=1 E2E_SHARE_INTERVAL=1 E2E_ACTIVE_TIMEOUT=1 FAKE_NFT_FILE="$T586/nft-present" \
        FAKE_POOL_ADDRESS="$POOL_ADDRESS" FAKE_RESOLVED_ADDRESS="$POOL_ADDRESS" FAKE_POOL_PORT="$POOL_PORT" FAKE_API_PORT="$API_PORT" \
        FAKE_LOOPBACK_ADDRESS="$LOOPBACK_ADDRESS" FAKE_CURL_COUNT="$T586/curl-count" \
        FAKE_DROP_FILE="$T586/drop-count" FAKE_NFT_CHAIN_TEMPLATE="$T586/nft-chain.json" E2E_CONTROL_STATE_DIR="$T586/ctrlstate" "$@" \
        bash "$ROOT/tests/e2e-docs-guest.sh" "${CASE_PHASE:?}" "$T586/clone" "$T586/state"
}

CASE_PHASE=baseline guest586
assert_rc "guest verifier captures a fresh AVX2 systemd baseline" "$?" 0
CASE_PHASE=dry-run-check guest586
assert_rc "guest verifier proves dry-run left stable system state unchanged" "$?" 0
printf 'boot-installed\n' >"$T586/boot-id"
: >"$T586/nft-present"
: >"$T586/curl-count"
peer_err="$(CASE_PHASE=installed guest586 FAKE_INSTALLED=1 FAKE_PEER=present FAKE_POOL_ADDRESS="other-$PPID" 2>&1)"
peer_rc=$?
assert_rc "guest verifier rejects a same-port peer at another address" "$peer_rc" 1
assert_contains "peer negative control names the unexpected endpoint" "$peer_err" "xmrig has an unexpected peer"
GENERATED_FIXTURE="$T586/clone/data/worker/xmrig/build/config.json"
cp "$GENERATED_FIXTURE" "$T586/generated-config.saved"
jq --arg url "generated-$PPID:$POOL_PORT" '.pools[0].url = $url' "$GENERATED_FIXTURE" >"$T586/generated-config.changed"
mv "$T586/generated-config.changed" "$GENERATED_FIXTURE"
: >"$T586/curl-count"
pool_config_err="$(CASE_PHASE=installed guest586 FAKE_INSTALLED=1 FAKE_PEER=present 2>&1)"
pool_config_rc=$?
assert_rc "guest verifier rejects a generated pool that differs from prepared config" "$pool_config_rc" 1
assert_contains "generated pool mismatch is explicit" "$pool_config_err" "generated pool differs from prepared config"
mv "$T586/generated-config.saved" "$GENERATED_FIXTURE"
nft_install_err="$(CASE_PHASE=installed guest586 FAKE_INSTALLED=1 FAKE_PEER=present FAKE_NFT_MODE=fail 2>&1)"
nft_install_rc=$?
assert_rc "installed verification fails closed on nft inventory errors" "$nft_install_rc" 1
assert_contains "installed nft inventory error is explicit" "$nft_install_err" "nft inventory failed"
for curl_mode in transport write200; do
    : >"$T586/curl-count"
    api_err="$(CASE_PHASE=installed guest586 FAKE_INSTALLED=1 FAKE_PEER=present FAKE_CURL_MODE="$curl_mode" 2>&1)"
    api_rc=$?
    assert_rc "guest verifier rejects API write probe mode $curl_mode" "$api_rc" 1
    assert_contains "API write failure mode $curl_mode is explicit" "$api_err" "base API write probe"
done
: >"$T586/curl-count"
CASE_PHASE=installed guest586 FAKE_INSTALLED=1 FAKE_PEER=present
assert_rc "guest verifier proves reboot autostart, pool, shares, API and nft state" "$?" 0
printf 'boot-removed\n' >"$T586/boot-id"
rm "$T586/nft-present"
CASE_PHASE=removed guest586
assert_rc "guest verifier proves rebooted uninstall cleanup" "$?" 0
: >"$T586/nft-present"
removed_err="$(CASE_PHASE=removed guest586 2>&1)"
removed_rc=$?
assert_rc "guest verifier fails when uninstall leaves the nft table" "$removed_rc" 1
assert_contains "leftover nft negative control names the residue" "$removed_err" "inet rigforge nft table remains"
rm "$T586/nft-present"
for failure in "FAKE_NFT_MODE=fail:nft" "FAKE_SS_FAIL=1:socket" "FAKE_SYSTEMCTL_FAIL=1:unit"; do
    setting="${failure%%:*}"
    label="${failure##*:}"
    command_name="${setting%%=*}"
    command_value="${setting#*=}"
    probe_err="$(CASE_PHASE=removed guest586 "$command_name=$command_value" 2>&1)"
    probe_rc=$?
    assert_rc "guest verifier fails closed on $label inventory errors" "$probe_rc" 1
    assert_contains "$label inventory error is explicit" "$probe_err" "inventory failed"
done

printf '1.18.1\n' >"$T586/clone/VERSION"
mkdir -p "$T586/ctrlstate" "$T586/ctrlstate-empty" "$T586/clone/backups"
touch "$T586/ctrlstate/last" "$T586/clone/backups/rigforge-backup-20261117-000000.tar.gz"

: >"$T586/drop-count"
CASE_PHASE=allowlist-refuse guest586
assert_rc "guest verifier refuses the non-loopback source and sees the drop counter rise" "$?" 0
not_refused="$(CASE_PHASE=allowlist-refuse guest586 FAKE_REFUSE_MODE=pass 2>&1)"
assert_rc "guest verifier fails when the second source is accepted" "$?" 1
assert_contains "accepted-source negative control is explicit" "$not_refused" "second source was not refused"
: >"$T586/drop-count"
norise="$(CASE_PHASE=allowlist-refuse guest586 FAKE_REFUSE_MODE=norise 2>&1)"
assert_rc "guest verifier fails when the drop counter is stalled" "$?" 1
assert_contains "stalled counter negative control is explicit" "$norise" "drop counter did not rise"
: >"$T586/drop-count"
CASE_PHASE=allowlist-refuse guest586
bad_accept="$(CASE_PHASE=allowlist-accept guest586 FAKE_ACCEPT_CODE=403 2>&1)"
assert_rc "guest verifier fails a refused allowed-source probe" "$?" 1
assert_contains "refused allowed-source negative control is explicit" "$bad_accept" "did not receive HTTP 200"
CASE_PHASE=allowlist-accept guest586
assert_rc "guest verifier accepts the allowed second source and keeps loopback" "$?" 0

tok_err="$(CASE_PHASE=control-apply guest586 FAKE_INSTALLED=1 2>&1)"
assert_rc "control apply refuses to run without the token" "$?" 1
assert_contains "missing token is explicit" "$tok_err" "control token is missing"
jq '."donate-level" = 1 | ."donate-over-proxy" = 1' "$GENERATED_FIXTURE" >"$T586/gen.tmp" && mv "$T586/gen.tmp" "$GENERATED_FIXTURE"
ctl_rej="$(CASE_PHASE=control-apply guest586 FAKE_INSTALLED=1 FAKE_DONATE_LEVEL=1 E2E_CONTROL_TOKEN=fixturetoken FAKE_CONTROL_STATUS=rejected 2>&1)"
assert_rc "control apply fails when the rig rejects the change" "$?" 1
assert_contains "rejected control status is explicit" "$ctl_rej" "ended 'rejected'"
CASE_PHASE=control-apply guest586 FAKE_INSTALLED=1 FAKE_DONATE_LEVEL=1 E2E_CONTROL_TOKEN=fixturetoken
assert_rc "guest verifier proves one applied control change" "$?" 0
jq '."donate-level" = 0 | ."donate-over-proxy" = 0' "$GENERATED_FIXTURE" >"$T586/gen.tmp" && mv "$T586/gen.tmp" "$GENERATED_FIXTURE"
CASE_PHASE=control-revert guest586 FAKE_INSTALLED=1 E2E_CONTROL_TOKEN=fixturetoken
assert_rc "guest verifier proves the rolled-back control change" "$?" 0

CASE_PHASE=upgrade-leg guest586 FAKE_INSTALLED=1 E2E_CONTROL_TOKEN=t E2E_UPGRADE_LEG=noop FAKE_CONTROL_STATUS=failed
assert_rc "noop leg fails on a failed status" "$?" 1
CASE_PHASE=upgrade-leg guest586 FAKE_INSTALLED=1 E2E_CONTROL_TOKEN=t E2E_UPGRADE_LEG=noop FAKE_CONTROL_STATUS=noop
assert_rc "remote-upgrade noop leg reaches noop with the checkout intact" "$?" 0
CASE_PHASE=upgrade-leg guest586 FAKE_INSTALLED=1 E2E_CONTROL_TOKEN=t E2E_UPGRADE_LEG=refused FAKE_CONTROL_STATUS=rolled_back
assert_rc "refused upgrade leg rolls back and leaves the throttle stamp" "$?" 0
no_stamp="$(CASE_PHASE=upgrade-leg guest586 FAKE_INSTALLED=1 E2E_CONTROL_TOKEN=t E2E_UPGRADE_LEG=refused FAKE_CONTROL_STATUS=rolled_back E2E_CONTROL_STATE_DIR="$T586/ctrlstate-empty" 2>&1)"
assert_rc "refused leg fails without a throttle stamp" "$?" 1
assert_contains "missing throttle stamp is explicit" "$no_stamp" "no throttle stamp"

: >"$T586/curl-count"
: >"$T586/nft-present"
bad_head="$(CASE_PHASE=upgraded guest586 FAKE_INSTALLED=1 FAKE_PEER=present E2E_EXPECTED_HEAD="$(printf 'b%.0s' 1 40)" 2>&1)"
assert_rc "upgraded verifier fails when the checkout is not the candidate" "$?" 1
assert_contains "candidate mismatch is explicit" "$bad_head" "not at the candidate commit"
CASE_PHASE=upgraded guest586 FAKE_INSTALLED=1 FAKE_PEER=present E2E_EXPECTED_HEAD="$(printf 'a%.0s' 1 40)"
assert_rc "upgraded verifier proves the candidate commit keeps shares landing at donation zero" "$?" 0

digest="$( { sha256sum "$T586/clone/config.json" || shasum -a 256 "$T586/clone/config.json"; } 2>/dev/null | awk '{print $1}')"
CASE_PHASE=restored guest586 E2E_RESTORED_CONFIG_SHA256="$digest"
assert_rc "restored verifier proves the backup round-trip digest" "$?" 0
stale="$(CASE_PHASE=restored guest586 E2E_RESTORED_CONFIG_SHA256="$(printf '0%.0s' 1 64)" 2>&1)"
assert_rc "restored verifier fails a digest mismatch" "$?" 1
assert_contains "digest mismatch is explicit" "$stale" "differs from the backup"
mv "$T586/clone/backups/rigforge-backup-20261117-000000.tar.gz" "$T586/archive.hold"
missing="$(CASE_PHASE=restored guest586 E2E_RESTORED_CONFIG_SHA256="$digest" 2>&1)"
assert_rc "restored verifier fails without the archive" "$?" 1
assert_contains "missing archive is explicit" "$missing" "backup archive is missing"
mv "$T586/archive.hold" "$T586/clone/backups/rigforge-backup-20261117-000000.tar.gz"

frag_err="$(CASE_PHASE=appliance guest586 FAKE_INSTALLED=1 2>&1)"
assert_rc "appliance verifier fails on a persistent unit fragment" "$?" 1
assert_contains "persistent fragment is explicit" "$frag_err" "not a runtime unit"
mount_err="$(CASE_PHASE=appliance guest586 FAKE_INSTALLED=1 FAKE_FRAGMENT=/run/systemd/system/xmrig.service FAKE_MOUNT=none 2>&1)"
assert_rc "appliance verifier fails without the runtime hugetlbfs mount" "$?" 1
assert_contains "missing hugetlbfs is explicit" "$mount_err" "hugetlbfs is not mounted"
CASE_PHASE=appliance guest586 FAKE_INSTALLED=1 FAKE_FRAGMENT=/run/systemd/system/xmrig.service
assert_rc "appliance verifier proves runtime-only units with the baseline files intact" "$?" 0

if [ "$STANDALONE_586" = 1 ]; then
    printf 'docs guest tests: %s passed, %s failed\n' "$PASS" "$FAIL"
    [ "$FAIL" = 0 ]
fi
