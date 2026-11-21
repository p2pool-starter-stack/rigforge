# ADR 0003: Package-owned installs, upgrade authority, signing custody and Tor

- **Status:** Accepted. Records the owner's rulings of 2026-11-17 (DIY install routes) and 2026-11-20 (key custody and upgrade behaviour). The 2026-11-20 custody ruling applies to both RigForge and pithead and supersedes pithead #3459's 2026-11-01 offline-key ruling. Docs story for the epic #778; implementation stories are #780–#789.
- **Date:** 2026-11-21
- **Deciders:** RigForge owner + maintainer.

## Context

RigForge installs by git clone or release tarball and upgrades by git checkout at the release tag (ADR 0002). On 2026-11-17 the owner ruled that DIY installs get an apt route (Ubuntu 24.04 first) and a Homebrew route (macOS best effort), and that every upgrade path must be able to run behind Tor; the epic #778 refines #731 (.deb and APT feed) and #732 (Homebrew formula). Three decisions had no home, and the packaging stories would otherwise pick incompatible answers:

1. **Upgrade authority.** A git self-upgrade (`control_upgrade`, tag checkout) and a package manager cannot both own one tree. Nothing said who upgrades a package-installed RigForge.
2. **Signing-key custody.** SECURITY.md records the removal of release signing: minisign was removed on 2026-07-11 (#205/#229) and ADR 0002 D5 accepts GitHub as the trust root for the git path; the signed apt feed will be the project's first signing since. pithead #3459 (2026-11-01) ruled the key offline and never a CI secret; #731 assumed a CI secret. Both channels needed one ruling before any key exists.
3. **Code/state split.** `rigforge.sh` writes `config.json`, its `.rigforge-*` markers, `config-backups/`, `backups/`, support tarballs and the default worker root beside itself, so the code dir doubles as the state dir. A root-owned, read-only package tree cannot hold those files; the code/state and code/lookup splits (#780, #781) must land before any package exists.

## Decision

### D1. Package ownership and upgrade authority

A package-owned tree is upgraded **only** by its package manager — `apt upgrade rigforge` or `brew upgrade rigforge` — and never by git. The package layout drops a `.rigforge-package` marker (value `apt` or `brew`) in the lib dir (#782), detected like the appliance marker. With it:

- `control_upgrade` and any tag upgrade refuse before touching git and report the channel command instead.
- `upgrade --check` compares versions through the existing Tor-capable fetcher and prints the channel command, not git steps.
- `install_dependencies` and the PATH-link step are skipped; the package owns both.

Git-clone and appliance installs keep today's behaviour unchanged, with no marker present.

### D2. Upgrade and purge behaviour

- An apt upgrade of an already-configured host queues the real upgrade **outside dpkg**: postinst writes an upgrade-pending marker under `/var/lib/rigforge` and starts the one-shot `rigforge upgrade` unit via `systemctl start --no-block` (#785). A first install (no config) is inert.
- The miner **restarts automatically, but only after a successful upgrade** (owner, 2026-11-20). On failure the previous build keeps running, the marker and failure stay visible in `status`/`doctor`, postinst still exits 0 so dpkg never half-configures the package, and retry is one documented `rigforge upgrade` command. `apt-mark hold` defers.
- `brew upgrade` never restarts a running miner — it prints a hint; the auto-restart ruling applies to apt only (#787).
- **Purge** removes `/etc/rigforge` and `/var/lib/rigforge` but **never reverts system tuning** — not GRUB, hugepages, MSR or sysctl. Only `rigforge uninstall` undoes tuning (#784). Remove keeps config and state.

### D3. Signing-key custody (owner, 2026-11-20 — supersedes pithead #3459)

Custody for both RigForge and pithead follows the live model of the owner's node-manager companion repository: **a CI secret in a protected environment, with offline backups.** Specifically:

- A dedicated OpenPGP key, used for nothing else, is held as the repository secret `APT_SIGNING_KEY`, scoped to a **protected GitHub environment that requires the owner's approval before anything is signed**. A run without approval signs nothing.
- The release workflow imports the secret into a throwaway GNUPGHOME, signs, and removes it on exit. No key material persists on a runner.
- The **40-hex fingerprint is committed in the repo** (a pinned file, mirrored in README and SECURITY.md) and mirrored in the repository variable `APT_SIGNING_FINGERPRINT`. The build **refuses unless the imported secret key matches the pinned fingerprint**; the job is skipped when the variable is unset.
- **Passphrase-protected offline backups** of the private key live on the owner's machine and on the NAS (hosts and paths intentionally not recorded here).
- A **tag ruleset protects release tags**.

The pithead #3459 ruling of 2026-11-01 (offline key, never a CI secret) is **superseded**: signing at cut time on a release host is rejected as unscalable; the protected environment with owner approval is the compensating control that makes the CI secret acceptable.

### D4. Backup, restore and rotation

- **Backup:** export the key pair at generation and after every rotation, protect it with a strong passphrase, and store it in both offline locations (owner's machine and NAS). The passphrase is kept separately from the backups.
- **Restore:** import into a throwaway GNUPGHOME, verify the import reports the fingerprint pinned in the repo, then sign only through the protected environment. A restore that cannot prove the pinned fingerprint publishes nothing.
- **Rotation:** generate a new key; publish the new public key and fingerprint **in a release** (pinned file, README, SECURITY.md); move the secret and the variable; users re-import the key into `/etc/apt/keyrings` (new keyring file, then `apt-get update`). Old releases stay verifiable with the old public key.
- **Revocation / compromise:** revoke the old key with its stored certificate, rotate the secret, publish the new fingerprint through SECURITY.md, and never sign anything new with the compromised key. The pinned fingerprint change is itself the announcement channel users watch.

### D5. Signing scope

Feed signing applies to the **apt channel only**. Release tarballs and `SHA256SUMS` stay checksums-only, and the git-tag remote-upgrade path keeps ADR 0002's no-signing trust model (D5/D10) unchanged. This ADR qualifies, and does not reverse, SECURITY.md's no-signing posture: that posture governs the git route and the release assets, not the apt feed.

### D6. Apt feed rules

Shared with the node-manager precedent:

- A **flat feed** (`Packages`, `Release`, `InRelease`, `Release.gpg`) built with `apt-ftparchive` (#786).
- Published to the repository's own **GitHub Pages via Actions**, as a versioned directory behind a pointer so the previous feed can be restored.
- The feed changes **only on a published stable release** — never on tag push, draft or prerelease.
- A release tag must equal `v$(VERSION)` and be an ancestor of `main`.
- The verifying fingerprint is **pinned from `main`**, not from the release being built.
- **Verified before deploy:** the publish job checks `InRelease`/`Release.gpg` with `gpg --verify` against the pinned fingerprint and installs from a file:// source with a real apt client (`apt-get update`, `apt-get download`); a tampered `Release` file must be rejected by apt in a test.

### D7. Homebrew tap

The **tap is this repository**, installed by explicit URL (`brew tap p2pool-starter-stack/rigforge <repo url>`). `Formula/rigforge.rb` is generated at release from `Formula/rigforge.rb.in`, uploaded as a release asset beside the tarball it pins, and bumped on `main` by a **bot pull request**; the formula is live **only after that PR merges**. Linuxbrew's user-owned prefix stays CLI-only behind the root-owned-code guard (#783). A separate tap repository is rejected.

### D8. Tor

RigForge does not install or run Tor; it guarantees every RigForge-fetching route can be routed through a SOCKS5 proxy (typically a local Tor client) with no clearnet fallback:

- **apt:** `Acquire::http::Proxy`/`Acquire::https::Proxy` set to `socks5h://127.0.0.1:9050/` (drop-in under `/etc/apt/apt.conf.d/`); `socks5h` resolves names at the proxy, and apt fails rather than falling back.
- **brew:** `ALL_PROXY=socks5h://127.0.0.1:9050` covers the curl downloads, and the tap clone needs a git proxy setting (`git config http.proxy …`) because git ignores `ALL_PROXY`.
- **Rig-side fetches** (XMRig clone, `upgrade --check`, remote-upgrade fetch, package-mode version check) stay covered by `tor_socks5` (1.19.0).
- #788 proves each channel proxy-only on every release; SECURITY.md keeps recording that package-manager installs are otherwise the operator's to route.

### D9. Support matrix

Ubuntu 24.04 amd64 full support; Ubuntu 26.04 when #733 ships; macOS best effort with a documented degraded-feature list (root tuning — GRUB, hugepages, MSR — is unavailable to brew); Linuxbrew CLI-only; aarch64 best effort.

## Alternatives considered

- **Offline-only signing key, never a CI secret** (pithead #3459, 2026-11-01). Rejected on 2026-11-20: cut-time signing on a release host does not scale to per-release publishing for two repos, and the protected environment with mandatory owner approval closes the standing-secret concern. Superseded for both repositories (D3).
- **Sign release tarballs too.** Rejected: tarball users already pin the tag or verify `SHA256SUMS`; signing them would widen custody for no added protection (D5).
- **Upgrade a package-owned tree through the existing git path.** Rejected: two update mechanisms fighting over one tree (D1).
- **Activate the upgrade inside postinst** (node-manager's pattern). Rejected for RigForge: an XMRig rebuild runs minutes and would hold the dpkg lock; the one-shot unit outside dpkg keeps dpkg's promise (D2).
- **A separate homebrew-rigforge tap repository.** Rejected: the owner's pattern is the repository as its own tap (D7).
- **Fold these decisions into SECURITY.md alone.** Smaller, but it would lose the decision record this repo keeps in `docs/adr` (ADR 0002 precedent); SECURITY.md now links here and states the qualified no-signing posture.

## Consequences

- **Ordering.** #780 (state split) and #781 (lib-dir split) are blockers: no package can exist until a root-owned read-only code tree can run. Git-clone and appliance installs must stay byte-identical by default (golden unit renders, existing suite unchanged).
- **Before the first signed publish** the owner must: generate the key, add the secret and the fingerprint variable, store the passphrase-protected offline backups, create the protected environment with owner approval, enable GitHub Pages from Actions, and add the tag ruleset (#786, recorded as owner steps in RELEASING.md without hosts or paths).
- SECURITY.md's no-signing statement is qualified to the git route and the checksums-only assets; the apt feed is signed under D3–D6.
- No packaging script, doc or test may mention an internal test-runner or developer-tooling repository, or contain a hostname, address or home path.

## References

- Epic: #778. Stories: #779 (this ADR), #780–#789. Refined: #731 (apt), #732 (Homebrew).
- Cross-repo: pithead #3459 (superseded custody ruling).
- Precedent: [ADR 0002](0002-remote-worker-upgrade.md) D5/D10 (git-path trust model, immutable releases and tag protection); the `.rigforge-appliance` marker pattern; node-manager's packaging and release jobs (patterns adopted, no details copied).
- SECURITY.md: "Release integrity" (qualified by D5).
