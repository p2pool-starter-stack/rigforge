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

As in ADR 0001 D2, the network-facing receiver stays unprivileged (`DynamicUser`): it authenticates, checks the flag, and **stages** the request; it never fetches or runs code itself. The privileged path-triggered oneshot does the fetch-and-upgrade through the existing gated flow. The response is `202 Accepted` with a change id; the consumer polls `/status` for the terminal outcome.

### D4. The receiver cannot choose what gets installed — the rig re-derives the target

The staged body is tiny: `{"version": "vX.Y.Z"}`. That value is a **confirmation guard, not a target selector**. The `control-upgrade` verb re-derives the real latest release tag directly from the GitHub release API (reusing `_upgrade_check`) and **refuses if the requested version ≠ the real latest** (terminal `failed`). A rig only ever upgrades to *latest-or-nothing*; neither the intent nor a compromised consumer can pin a rig to an arbitrary (e.g. downgrade-to-vulnerable) tag. pithead #597 independently re-derives the same target host-side over Tor — belt and suspenders.

### D5. Trust model: hash-only, git-tag checkout, no signing (settled)

The upgrade fetches via a **git checkout at the release tag**; the commit hash is the integrity anchor (the "strongest guarantee" SECURITY.md already names for manual installs), and the XMRig source it then builds is itself pinned and commit-verified. **No release signing.** A detached signature would only add protection under a GitHub-account/distribution-point compromise, and only if a public key were pinned out-of-band with an offline key — key-custody complexity this project's users (who deploy from git tags) don't warrant.

GitHub is therefore accepted as the trust root. The residual risk is explicit: a full GitHub-account or release compromise could push malicious root code fleet-wide through this path, because the rig fetches "latest from GitHub" and runs it as root unattended, with no human in the loop that the manual install path keeps. **This risk is accepted deliberately** rather than planning around a compromise of GitHub itself; the proportionate mitigation is hardening the GitHub account (hardware-key 2FA, tight release and branch-protection permissions), not signing. Recorded in SECURITY.md (Release integrity). This closes the "signing as prerequisite" question raised on #308 as **won't-do**, and pithead #597's signing gate is dropped to match.

### D6. Fail-closed, throttled, rollback-guarded, with a terminal status

`control-upgrade` is fail-closed and every step is rollback-guarded, reusing the upgrade flow's existing rebuild-only-if-the-pin-changed logic. A **pre-dial throttle stamp** on the rig bounds how often it will reach out to GitHub, so a looping or hostile consumer cannot turn the fleet into a beacon or a request amplifier. Outcomes use the same `/status` surface as control-apply, extended with a **`failed`** terminal (with reason) alongside `applied` / `rolled_back`, so a pre-apply refusal (non-latest, throttled, fetch/build error) surfaces a clear terminal result to the consumer's poll rather than hanging in a non-terminal state.

### D7. Auth and source-pinning inherited from ADR 0001 D4/D9

`/upgrade` reuses the control path's Bearer `ACCESS_TOKEN` and the `api_allow_from` source pin (which D1 already requires for `control: enabled`), and the same nftables scoping (#142). The stack host is the only trusted writer; the miner never accepts an upgrade trigger from a miner-advertised or arbitrary host. The cleartext-token-on-LAN posture (ADR 0001 D9) applies unchanged — the mining LAN is the trust boundary.

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
- Consumer contract: `POST :8082/upgrade {"version":"vX.Y.Z"}` → `202 Accepted` + change id → poll `:8082/status` for `applied` / `rolled_back` / `failed`. The host never trusts a host/port/token from the intent; both host and rig re-derive the real target.

## Open questions (resolved 2026-07-17 — see Resolution above)

- **D-OPEN-1 (central):** Accept the invariant reversal — extending the control channel from a tuning surface to a code-update surface (D2/Consequences)? → **Accepted.** The sign-off that gates the code.
- **D-OPEN-2:** Confirm the trust model (D5): hash-only, git-tag checkout, no signing, GitHub as trust root, residual fleet-RCE risk accepted. → **Confirmed** (recorded in SECURITY.md).
- **D-OPEN-3:** Version/milestone. → **v1.11**, ahead of pithead #597.

## References

- Consumer: pithead #597 (one-click remote upgrade — orchestration + UI), pithead #596 (version badge), pithead #598 (v1.10 worker-upgrade roadmap).
- Extends: [ADR 0001](0001-writable-worker-config-control-path.md) (writable control path, #236) — D2 receiver/applier split, D4 dual auth, D9 cleartext-LAN posture.
- RigForge precedent: #99/#164 (read-only sister API), #142 (`api_allow_from` nftables scoping), #137/#205 (release signing, removed). Trust model recorded in SECURITY.md (Release integrity).
