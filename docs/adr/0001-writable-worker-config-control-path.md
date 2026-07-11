# ADR 0001: Writable worker-config control path

- **Status:** Proposed (decision-gating — see [#236](https://github.com/p2pool-starter-stack/rigforge/issues/236)). Not to be implemented until the marked decisions are signed off by the maintainer and coordinated with the pithead consumer.
- **Date:** 2026-07-11
- **Deciders:** RigForge maintainer + pithead #185 owner (cross-repo).

## Context

The sister API (#99/#164, `util/api-server.py`) is read-only by construction: `do_POST = do_PUT = do_DELETE = do_PATCH = _read_only`, GET-only fixed routes, bodies pre-computed off the request path by the refresh timer, served by a single-threaded unprivileged (`DynamicUser`) process that reads `config.json` through a systemd `LoadCredential`. That posture is deliberate and stays: a read must never be able to touch mining or hold privilege.

pithead #185 ("Worker Inspect": read *and edit* a worker's config from the dashboard, with versioned history and hashrate-per-config) needs a **producer** on the RigForge side that does not yet exist. Writing straight to XMRig's native `/1/config` is rejected upfront: it bypasses RigForge, so the change would not persist (lost on the next `apply`/restart), would fight the autotune and watchdog timers, and would skip RigForge's validation. RigForge owns `config.json` and must remain the single source of truth, which means RigForge must mediate any remote write.

This ADR decides the **shape** of that control path so implementation can follow. It does not implement it.

## Decision

Add a **separate, opt-in, fail-closed control path** distinct from the read-only sister API, with an unprivileged network receiver decoupled from the privileged applier. Concretely:

### D1. Separate path, never a write verb on the read server

The read server stays GET-only and untouched. The control path is its own opt-in mechanism behind its own config key (`control`, default `"disabled"`) and its own port (`control_port`), never sharing the read API's process or port. Rationale: a mutation is a different trust posture than a read (mirrors pithead #33's host-mutation discipline), and the read process is `DynamicUser` and cannot write the 0600 `config.json` or run `apply` anyway.

### D2. Unprivileged receiver, decoupled privileged applier (RECOMMENDED — needs sign-off)

The network-facing receiver runs unprivileged. It authenticates, validates, and **stages** an accepted change to a spool file it is allowed to write; it does not itself persist to `config.json` or restart anything. A privileged, systemd-triggered oneshot (a `systemd.path` unit watching the spool, running `rigforge.sh apply` as root) performs the persist + restart through the existing gated path, keeping autotune and watchdog coherent.

Consequence: the write is **accepted-then-applied**, not applied inline. The HTTP response is `202 Accepted` with a change id; pithead reads the new effective config back from the existing read API (`/2/summary`, which the refresh timer already serves) once apply completes. This preserves the invariant that reads never touch mutation and mutations never touch the read fast-path.

The alternative — a receiver that runs with just enough privilege (a narrow `sudoers` entry for `rigforge.sh apply`) to persist and restart synchronously, so the HTTP call can return the applied result inline — is simpler for the consumer but puts a network-facing process one call away from a root apply. **This synchronous-vs-decoupled choice is the central open decision (see D-OPEN-1).**

### D3. Bounded write unit: an allowlist of mutable knobs, not arbitrary config

The control path accepts changes only to a fixed allowlist of operationally-mutable keys:

- `pools` (validated with the same host/port/pass rules `parse_config` and first-run setup already enforce)
- `DONATION`, `autotune`, `watchdog`, `watchdog_interval_min`, `max_temp_c`
- per-pool `tls-fingerprint`

Explicitly **not** writable through this path (they change identity, trust, filesystem paths, or the control path's own auth, so remote mutation would be a privilege or trust escalation): `HOME_DIR`, `miner_user`, `ACCESS_TOKEN`, `api`/`api_port`/`api_bind`/`api_allow_from`, and `control`/`control_port` themselves. Those stay operator-only, changed on the rig.

Unknown keys are default-denied, extending the existing `known` allowlist discipline in `_warn_unknown_config_keys` (`rigforge.sh`) from "warn" to "reject" on the write path.

### D4. Mandatory dual auth, fail-closed, default-off

Enabling `control` requires **both** `ACCESS_TOKEN` set **and** `api_allow_from` set. If either is missing, `setup`/`apply` refuses to enable the control path with a hard error, not a warning: a writable path with no Bearer token or no source restriction is an unauthenticated remote config-write. The nftables scoping from #142 extends to `control_port`, so it is reachable only from the stack host and loopback. The stack is the only trusted writer; the miner never accepts a config from a miner-advertised or otherwise arbitrary host (the SSRF surface pithead #122/#185 flag).

### D5. Validate before persist; no field reaches a shell unquoted

Validation runs on the staged change before anything is written. `config.json` is written by `jq` (values quoted structurally, as today), and the pool-field regexes are the injection guards, following the `api_allow_from` precedent where the validating regex is also the injection guard. A failed validation refuses the change and persists nothing.

### D6. Rollback on failed apply (RECOMMENDED — needs sign-off)

Before a control-applied change, snapshot the current `config.json` to a `.last-good` copy; if `apply` fails to bring the miner back to a live hashrate, restore `.last-good` and report the failure. A remote edit that wedges a rig must self-heal, not require a truck roll.

### D7. Report source of change

Stamp each applied change with `source: "control"` and a timestamp, surfaced on the read API (a field on `/health` or the `rigforge` block) so pithead #185 can distinguish "dashboard edit" from "changed on the rig" and diff old to new.

## Alternatives considered

- **Write verbs on the sister API.** Rejected: violates the read-only invariant, and the `DynamicUser` read process cannot persist or apply.
- **Direct PUT to XMRig `/1/config`.** Rejected (see Context): bypasses RigForge, does not persist, fights the timers.
- **Always-on privileged HTTP listener.** Rejected: a persistent root-capable network listener is the attack surface RigForge deliberately avoided; D2 keeps the network process unprivileged.
- **No network write path; keep using SSH + `rigforge.sh apply`.** Viable and lowest-surface, but does not give pithead #185 a programmatic `apply(config)` producer, which is the point of #236.

## Consequences

- New opt-in surface, off by default, fail-closed. Rigs that do not enable `control` are unchanged and carry zero new listener.
- The read/write separation is preserved end to end: the read fast-path stays microsecond and unprivileged; the mutation path is staged and gated.
- Backwards compatible: a new MINOR capability. Version/milestone sequencing is the maintainer's call (see D-OPEN-4) given v1.6.0 was framed as the final 1.x before the appliance era.
- The consumer contract is: `POST` a bounded change → `202 Accepted` + change id → poll `/2/summary` for the new effective config. pithead keeps its own versioned history and hashrate-per-config correlation.

## Open questions (must be resolved before implementation)

- **D-OPEN-1 (central):** Synchronous scoped-privilege receiver vs. decoupled staged applier (D2). Recommendation: decoupled/staged. Confirm, because it sets the consumer contract (inline applied-result vs accepted-then-poll).
- **D-OPEN-2 (cross-repo):** Stand up a new `control_port`, or ride pithead's existing per-worker authenticated channel (pithead #172)? A new port is self-contained; reusing #172 avoids a second auth surface. Needs the pithead owner.
- **D-OPEN-3:** Exact writable-knob boundary in D3 — in particular, is remote **pool switching** desired (useful for failover orchestration) or a footgun (a compromised stack redirects hashrate)? Leaning: allow it only because `api_allow_from` already pins the writer to the stack host, but call it out.
- **D-OPEN-4:** Version/milestone sequencing — 1.7.x, or fold into the 2.0 appliance line? Producer must land before pithead #185 (pithead v1.5) ships.

## References

- Consumer: pithead #185 (Worker Inspect). Per-worker addressing/auth reused: pithead #172. Mutation discipline mirrored: pithead #33.
- RigForge precedent: #99/#164 (read-only sister API), #142 (`api_allow_from` nftables scoping), #122 (SSRF surface), #138 (the `known` key allowlist).
