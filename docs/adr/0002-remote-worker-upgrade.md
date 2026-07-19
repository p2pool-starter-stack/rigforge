# ADR 0002: Remote worker-upgrade control path

- **Status:** Accepted (D-OPEN-1 signed off 2026-07-17). The invariant reversal is approved; #308 implementation is unblocked. A security/privacy best-practices review is folding hardening refinements into the D-series (see Resolution). Extends [ADR 0001](0001-writable-worker-config-control-path.md); the pithead #597 consumer contract is coordinated cross-repo.
- **Date:** 2026-07-17
- **Deciders:** RigForge maintainer + pithead #597 owner (cross-repo).

## Resolution (2026-07-17)

- **D-OPEN-1 → accepted.** The maintainer signed off the invariant reversal: the control channel may extend from a tuning surface to a code-update surface, deliberately, behind the second default-off `control_upgrade` flag (D1). This is the go decision that unblocks #308.
- **D-OPEN-2 → confirmed.** The trust model in D5 is settled: hash-only, git-tag checkout, no signing, GitHub as trust root, residual fleet-RCE-on-account-compromise accepted with account hardening as the mitigation. Recorded in SECURITY.md (Release integrity).
- **D-OPEN-3 → v1.11.** The producer ships in the v1.11 milestone, ahead of pithead #597.
- **Hardening review (in progress):** a due-diligence pass against secure-remote-update and systemd-sandboxing best practices may add decisions (D8+); any that change the consumer contract are coordinated with pithead #597.

## Context

ADR 0001 gave RigForge a writable control path (#236, `:8082`), and drew a hard line around it (D3): the channel accepts a fixed allowlist of *operationally-mutable* keys — `pools`, `DONATION`, `autotune`, `watchdog`, `watchdog_interval_min`, `max_temp_c` — and explicitly excludes anything that touches identity, filesystem paths, auth, or code. The stated posture is that the control path is a **tuning channel, not a code-execution one**.

pithead #597 ("one-click remote worker upgrade") needs a **producer** on the RigForge side that does not exist: a way for the dashboard to upgrade a rig's RigForge to the latest release without SSHing to each box. That is by definition a code-update surface — the rig would fetch and run new root code on a remote trigger. It **reverses** ADR 0001's central invariant, so it lands ADR-first and behind its own second opt-in, rather than by widening the D3 allowlist.

This ADR decides the shape of that upgrade path. The existing read-only sister API (#99/#164) and the tuning control path (#236) are unchanged.

## Decision

Add a **separate, opt-in, fail-closed upgrade path**, layered on top of the existing control path and mirroring its unprivileged-receiver / privileged-applier split. The upgrade capability is a *second* switch, not an extension of the tuning allowlist.

### D1. A second opt-in flag, layered on `control`, default-off

The upgrade path is gated by a new `control_upgrade` key (default `"disabled"`), validated in `parse_config` beside the existing `control` gate and requiring `control: "enabled"` first. Rationale: enabling remote tuning (#236) must not silently also grant a remote code-update surface. An operator who runs the tuning control path today gains nothing new until they deliberately turn on `control_upgrade` as well. Added to the `known`-keys allowlist and to the bash↔python drift-guard set.

### D2. Distinct `/upgrade` endpoint, distinct spool — never folded into `/apply`

The receiver (`util/control-server.py`) gains a `POST /upgrade` distinct from `/apply`, refused with `403` unless `control_upgrade` is on. It stages to a spool file named **`upgrade-*.json`**, deliberately *not* the `pending-*.json` pattern the control-apply `systemd.path` unit watches — an upgrade intent must not wake the config-apply oneshot (which would reject it as non-allowlisted keys). A dedicated `rigforge-control-upgrade.{path,service}` pair (root oneshot, `Nice=19`, `IOSchedulingClass=idle`) mirrors the control-apply units and runs `rigforge.sh control-upgrade`. A code update is a different trust posture than a config write and gets its own unit, spool, and verb.

### D3. Unprivileged receiver stages only; the privileged oneshot fetches and runs

As in ADR 0001 D2, the network-facing receiver stays unprivileged (`DynamicUser`): it authenticates, checks the flag, and **stages** the request; it never fetches or runs code itself. The privileged path-triggered oneshot does the fetch-and-upgrade through the existing gated flow. The response is `202 Accepted` with a change id; the consumer polls `/status` to a terminal outcome (a non-terminal `started` appears first while the oneshot runs — #320, see D6).

### D4. Dashboard-supplied target, bounded by monotonic + reachability guards

The staged body is tiny: `{"version": "vX.Y.Z"}`, and it **is** the target. The rig does **not** make its own `api.github.com/releases/latest` call: a per-rig version-check dial re-introduces the "version beacon" the project's no-phone-home posture forbids (it leaks each rig's public IP over clearnet, correlatable over time), and behind one NAT the fleet would share GitHub's 60/hr unauthenticated bucket, so a fan-out or a looping trigger could `403` every rig at once. pithead #597 already re-derives the real latest host-side over Tor; the rig trusts that supplied tag but **bounds what it will act on**, so a compromised trigger can only ever pick a *real, published, reachable release newer than what is installed* — never an arbitrary tag, a downgrade, or a dangling commit:

- **Monotonic anti-rollback** — refuse a target version ≤ installed (D10).
- **Reachable-from-main** — refuse a commit that is not an ancestor of `origin/main` (D10; amended by #318).
- **Immutable releases + tag protection** (D10) make the tag→commit binding a platform guarantee.

The rig still `git`-fetches the tag directly from GitHub — the code has to come from somewhere, and that fetch happens only on an actual upgrade (rare, throttled), not on every trigger — but it makes no separate version-check dial. Anything that fails a guard ends terminal: `failed`, except the two benign refusals distinguished since #320 — `noop` (already on the target) and `throttled` (inside the D6 window). This trades away rig-*independent* confirmation of "is this THE latest" (the dashboard, over Tor, is the deriver) for privacy, fewer moving parts, and no fleet rate-limit coupling; the anti-rollback + reachability guards are what make trusting a supplied target safe.

### D5. Trust model: hash-only, git-tag checkout, no signing (settled)

The upgrade fetches via a **git checkout at the release tag**. Git's Merkle structure guarantees the checked-out tree is internally consistent and matches the tag's commit atomically — this defeats in-transit tampering and mix-and-match (you cannot get a Frankenstein of files that never shipped together), and the XMRig source it then builds is itself pinned and commit-verified. It is **not**, however, an independent *authenticity* anchor: the rig learns the expected commit from the same GitHub it is fetching from (no out-of-band pinned hash), so authenticity rests on **trusting GitHub over TLS**, not on the hash. Framing the commit hash as the integrity guarantee would overstate it; the honest statement is "integrity in transit + atomicity from git; authenticity from GitHub + TLS." **No release signing.** A detached signature would only add protection under a GitHub-account/distribution-point compromise, and only if a public key were pinned out-of-band with an offline key — key-custody complexity this project's users (who deploy from git tags) don't warrant. Tag mutability (a repo-write attacker moving a tag) is closed at the platform layer instead — see D10.

GitHub is therefore accepted as the trust root. The residual risk is explicit: a full GitHub-account or release compromise could push malicious root code fleet-wide through this path, because the rig fetches "latest from GitHub" and runs it as root unattended, with no human in the loop that the manual install path keeps. **This risk is accepted deliberately** rather than planning around a compromise of GitHub itself; the proportionate mitigation is hardening the GitHub account (hardware-key 2FA, tight release and branch-protection permissions), not signing. Recorded in SECURITY.md (Release integrity). This closes the "signing as prerequisite" question raised on #308 as **won't-do**, and pithead #597's signing gate is dropped to match.

### D6. Fail-closed, throttled, rollback-guarded, with a terminal status

`control-upgrade` is fail-closed and every step is rollback-guarded, reusing the upgrade flow's existing rebuild-only-if-the-pin-changed logic. A **pre-dial throttle stamp** on the rig bounds how often it will reach out to GitHub, so a looping or hostile consumer cannot turn the fleet into a beacon or a request amplifier. Outcomes use the same `/status` surface as control-apply, extended with a **`failed`** terminal (with reason) alongside `applied` / `rolled_back`, so a pre-apply refusal (non-latest, throttled, fetch/build error) surfaces a clear terminal result to the consumer's poll rather than hanging in a non-terminal state.

*Amended (#320, consumer feedback from pithead #597):* the status vocabulary grew three additive members so a poller never has to string-match `reason`. A non-terminal **`started`** is written the moment the oneshot claims the intent (D8 move done), so "mid-run" and "oneshot died mid-run" are distinguishable from "queued"; **`noop`** replaces `failed` for the already-on-target refusal (idempotent, not an error); **`throttled`** replaces `failed` for the D6 throttle refusal (retry-later, not an error). `applied`'s `reason` echoes the landed version. All other refusals stay `failed`.

### D7. Auth and source-pinning inherited from ADR 0001 D4/D9

`/upgrade` reuses the control path's Bearer `ACCESS_TOKEN` and the `api_allow_from` source pin (which D1 already requires for `control: enabled`), and the same nftables scoping (#142). The stack host is the only trusted writer; the miner never accepts an upgrade trigger from a miner-advertised or arbitrary host. The cleartext-token-on-LAN posture (ADR 0001 D9) applies unchanged — the mining LAN is the trust boundary.

## Hardening decisions (2026-07-17 due-diligence review)

Added after a best-practices pass against TUF/Uptane, SLSA/OpenSSF, the systemd.exec sandboxing baseline, GitHub's API/immutable-releases docs, and XMRig's RandomX tuning guide. These refine the D-series without changing the accepted shape (D1–D7).

### D8. Sandbox the receiver; the builder can't be, so its security is validation + handoff

*Refined during implementation (#308).* The **unprivileged receiver** keeps the existing #236 sandbox (`DynamicUser`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `RestrictSUIDSGID`, `LockPersonality`, `NoNewPrivileges`) — it only stages, so it stays locked down and unchanged.

The **root builder oneshot cannot be meaningfully sandboxed**, and the earlier D8 plan (empty `CapabilityBoundingSet`, `ProtectSystem`, etc.) turned out to be wrong for it. The upgrade oneshot re-runs RigForge's own installer — `rigforge.sh upgrade` compiles XMRig, then `install_service` writes units under `/etc/systemd`, and the flow shells out through `sudo`. So `ProtectSystem=strict/full` (blocks writing `/etc/systemd`), `ProtectHome` (a checkout under `/home`), `NoNewPrivileges` (blocks the installer's `sudo`), and an empty `CapabilityBoundingSet` each break what the unit legitimately must do. It therefore mirrors the existing control-apply oneshot exactly: root, `Type=oneshot`, `Nice=19`, `IOSchedulingClass=idle`, and nothing that would strait-jacket a re-install. This is a deliberate, documented consequence of extending the channel to a code-update surface — the security for this path does **not** come from unit flags.

It comes from the **verb**, which treats the staged file as untrusted input: `systemd.path` validates nothing, so the oneshot's first act is to `rename()` the intent into a root-owned `processing/` dir the `DynamicUser` cannot write — freezing it against any swap — and *then* refuse a symlink and parse it as a claim (a single whitelisted field, `version` matching `^v[0-9]+\.[0-9]+\.[0-9]+$`, never sourced/evaled). Doing the move first is deliberate: checking for a symlink *before* the move would be a TOCTOU (the `DynamicUser` owns the spool and could swap the file in the window); after the move the file lives in a root-only dir and can't be swapped. That plus the D4/D6/D10 validation (target-newer-and-reachable bounds, throttle, anti-rollback) and a **rollback that reverts a failed forward build** — not just a failed liveness check, so a build error never leaves the tree pinned to an unbuilt release — is where this path is actually defended.

`systemd.path` validates nothing about the staged file — it only watches for its existence — so the spool file is fully attacker-controlled input from the root unit's perspective (the same "observed content is data, not a command" boundary, in code). Defenses: the receiver writes atomically (`rename()` into place, `StateDirectoryMode=0700`); the root oneshot's **first action is `rename()` the trigger into a root-owned dir the `DynamicUser` cannot write** (atomically removing any swap/symlink/TOCTOU window), reads it once with `O_NOFOLLOW`, and parses it as a claim — a single whitelisted field (tag matching `^v[0-9]+\.[0-9]+\.[0-9]+$`), never sourced/evaled, never passed unquoted to a shell, the repo URL hardcoded in the unit. Concurrent triggers are serialized by systemd itself: the `Type=oneshot` unit runs one instance at a time, and each run drains the spool newest-wins, so superseded intents are dropped rather than replayed. *(Amended #321: an earlier version of this decision claimed "a `flock` serializes concurrent triggers" — the only `flock` on this path guards the D6 throttle stamp, released before the build starts; the verb itself is serialized by the oneshot semantics above. If oneshot semantics are ever not enough, take a verb-scoped lock spanning fetch/build.)*

### D9. Protect hashrate by spatial build isolation, not just priority (the no-perf-impact requirement)

`Nice=19` + `IOSchedulingClass=idle` govern CPU time-slices and disk I/O — **not L3 cache or memory bandwidth**, which is exactly what RandomX is sensitive to (~2 MB L3 per mining thread plus a 2 GB dataset). A nice'd compiler still evicts the miner's scratchpad from L3 and steals memory bandwidth, so priority alone does **not** protect hashrate. Decision: build in place **while the miner keeps running**, but spatially isolate the compile — `taskset`/cpuset it onto cores the miner is not pinned to (a spare CCD on the EPYC 7642; on the single-CCD 7800X3D, temporarily reduce miner threads and give the build a small `-jN`), keep XMRig's Cache QoS (Intel CAT) fencing if enabled, and cap `-j` with an OOM bias so the build dies before the miner under memory pressure. Keep `Nice=19`/`idle` as scheduler/IO hygiene. The restart at swap is the only real disruption (a few seconds), and it is **health-gated with binary rollback** — the miner must return to a live baseline hashrate or the prior binary is restored. This beats "stop, then build" (~10 min of zero hashrate).

### D10. Close tag mutability and rollback at the platform + client layers (no signing key)

Low-cost integrity controls that need no standing signing key, shoring up the GitHub-as-trust-root bet in D5:

- **Enable GitHub Immutable Releases** (GA 2025-10) + a tag-protection ruleset on the release-tag pattern. This locks a release's tag to a specific commit, blocks tag moves, and blocks repo-resurrection (reusing a tag after delete/recreate — directly relevant, since `main` was deleted and recreated on 2026-07-17). It turns "the tag could be silently moved" from an accepted risk into a platform guarantee. **Operational prerequisite for recommending the feature on.**
- **Reachable-from-main check:** refuse a target whose commit is not an ancestor of `origin/main` (`git merge-base --is-ancestor`), per SLSA's "source revision reachable from an expected branch." Kills the tag-points-at-a-dangling-commit class. *Amended 2026-07-18 (#318): originally "reachable from `origin/<default>`" via `origin/HEAD`. But the repo's default branch is `develop`, and since the develop→main promotion moved to merge commits, release tags point at main-only commits — so a freshly cloned rig (whose `origin/HEAD` resolves to develop) refused every legitimate release. Releases are cut from main; main is the expected branch, so the guard pins `origin/main` explicitly. Fail-closed corollary: a clone without `origin/main` (e.g. single-branch) also refuses.*
- **Monotonic anti-rollback:** refuse a target version ≤ the installed version (TUF's rollback defense). This is the primary guard against a compromised trigger naming an older, known-vulnerable release, and it is what makes accepting a dashboard-supplied target safe (see D4).
- **Roadmap, not now:** keyless cosign via GitHub Actions OIDC is near-free to adopt later (no long-lived key) and would move the fleet from "trust GitHub" to "trust GitHub + a public transparency log." Deferred, not a blocker.

## Alternatives considered

- **Widen the ADR 0001 D3 allowlist to include a `version`/upgrade key.** Rejected: a code update is not an operationally-mutable config knob; folding it into the tuning path would silently grant every existing remote-tuning user a remote-RCE surface. A second opt-in (D1) is the point.
- **Sign releases (cosign, as pithead did) and verify before running.** Considered and rejected for this project (D5): signing only helps against a distribution-point compromise and only with an out-of-band pinned/offline key; the key-custody burden isn't warranted, and GitHub is accepted as the trust root.
- **Let the consumer choose the target version.** Rejected: the receiver/intent must not be able to pin a rig to an arbitrary tag (downgrade/rollback-to-vulnerable). The rig re-derives latest and refuses anything else (D4).
- **Receiver fetches and runs directly (scoped-privilege network process).** Rejected for the same reason as ADR 0001 D2: the network-facing process stays unprivileged and stages only.
- **No network upgrade path; keep SSH + `rigforge.sh upgrade`.** Lowest surface and still fully supported, but does not give pithead #597 a programmatic per-worker upgrade producer, which is the point of #308.

## Consequences

- **This is the one place RigForge reverses ADR 0001's "tuning channel, not code execution" invariant** — deliberately, behind a second default-off flag, and documented as such.
- New opt-in surface, off by default, fail-closed. A rig that does not enable `control_upgrade` carries zero new capability; a rig on `control` alone is unchanged.
- Residual risk accepted: GitHub-account/release compromise → fleet-wide root RCE (D5). Mitigation is account hardening, not signing.
- Producer for pithead #597. Backwards compatible (a new MINOR capability). It must ship in a RigForge release before pithead #597 can run end-to-end; pithead #596 (version badge) has no RigForge dependency and ships first.
- Consumer contract: `POST :8082/upgrade {"version":"vX.Y.Z"}` → `202 Accepted` + change id → poll `:8082/status` for a non-terminal `started`, then terminal `applied` (reason names the landed version) / `rolled_back` / `noop` (already on target) / `throttled` (retry after the window) / `failed` (#320 amendment, D6). The host never trusts a host/port/token from the intent; the rig bounds the dashboard-supplied target with monotonic anti-rollback + reachable-from-main guards (D4/D10) rather than making its own version-check dial.

## Open questions (resolved 2026-07-17 — see Resolution above)

- **D-OPEN-1 (central):** Accept the invariant reversal — extending the control channel from a tuning surface to a code-update surface (D2/Consequences)? → **Accepted.** The sign-off that gates the code.
- **D-OPEN-2:** Confirm the trust model (D5): hash-only, git-tag checkout, no signing, GitHub as trust root, residual fleet-RCE risk accepted. → **Confirmed** (recorded in SECURITY.md).
- **D-OPEN-3:** Version/milestone. → **v1.11**, ahead of pithead #597.

## References

- Consumer: pithead #597 (one-click remote upgrade — orchestration + UI), pithead #596 (version badge), pithead #598 (v1.10 worker-upgrade roadmap).
- Extends: [ADR 0001](0001-writable-worker-config-control-path.md) (writable control path, #236) — D2 receiver/applier split, D4 dual auth, D9 cleartext-LAN posture.
- RigForge precedent: #99/#164 (read-only sister API), #142 (`api_allow_from` nftables scoping), #137/#205 (release signing, removed). Trust model recorded in SECURITY.md (Release integrity).
