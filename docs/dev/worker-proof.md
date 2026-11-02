# Ordered worker proof receipts

`tests/e2e-pithead.sh` keeps each invocation on one reserved rig, in one shell,
under one config/runtime snapshot. This change enables no concurrency and removes
no per-PR or release witness. `network-summary` remains sanitized diagnostic
information; it is not a completion receipt.

## Stateful groups and retained assertions

`all` runs the rows below in order. `network-sequence` runs the first four rows in
that same order. Neither may be reconstructed by joining independently reset
phases. Standalone phases remain available for diagnosis and existing row owners;
they cannot substitute for either complete group.

| Phase row | Retained successful assertions | Dependency and restoration |
| --- | --- | --- |
| `connect` (3) | Stratum job, accepted share, generated worker label | Sets the pool and restarts the physical worker. |
| `worker-api` (5) | Open read, bind policy, restricted write refusal, unauthenticated refusal, matching bearer read | Uses the connected worker; restores the open token posture. |
| `api-impact` (3) | Sister API available, loaded hashrate within baseline tolerance, responsiveness under mining load | Uses live hashing; starts/stops recorded load processes and disables the sister API. |
| `network` (8) | Pool-only peers, control-implied listener, enabled API listener, miner-only listener policy, complete summary superset and metadata, token leak sweep, pool-password leak sweep, disabled listener closed | Consumes the preceding mutations; restores disabled API/control and the open token posture. |
| `stratum-auth` (4) | Right credential mines, wrong credential rejected, no jobs with wrong credential, recovery with right credential | Fault and recovery stay together; original config is restored by outer cleanup. |
| `dashboard` (2) | Worker initially online, stopped worker becomes offline | Requires initial presence; stops then restarts the same worker. |
| `dev-fee` (1) | Legacy minimum migration, zero donation, runtime reductions without rebuilding, original artifacts restored | The existing compound assertion includes real build/runtime and artifact restoration. |
| `control` (5) | Apply accepted, donation applied, config persisted, appliance pool edit atomically refused, thermal change reaches a new feed within its deadline | Preserves systemd/timer profiling and the full observation window; restores profiling and outer snapshot. |
| `access-tokens` (7) | Named token refused by miner, raw and derived reads accepted by sister API, apply accepted and applied, both revocation checks | Mutation and revocation stay together; outer cleanup restores tokens and donation. |

Each replay group (`control-replay-thermal`, `control-replay-pools`) retains its
runner-owned fixture/reservation, nested connect assertions (3), scalar apply
sequence, pools mutation, optional thermal mutation, publication window and final
assertion (1). Nested connect belongs to that replay row, not a separate group.
Neither replay is added to or removed from `all`.

Failures stop subsequent mutations. Cleanup still finishes refresh profiling,
stops recorded load processes, restores and reapplies the saved config, compares
its bytes, restores the original XMRig active state, and retains the snapshot if
restoration fails. Receipt emission follows cleanup on normal and error exits.
An interrupted or incomplete group cannot pass by presenting its successful prefix.

## Binding an invocation

The runner may supply `E2E_PROOF_CONTEXT` as one JSON object with exactly these
fields. Do not put deployment coordinates, credentials, config bodies or private
paths into this object.

| Field | Meaning |
| --- | --- |
| `schema` | Integer `1`. |
| `head` | Exact lowercase, forty-character Git commit ID. |
| `ref` | Full Git ref identifying that commit. The ref must resolve locally. |
| `input` | SHA-256 digest of the immutable, non-secret input manifest agreed by the runner. |
| `run` | Fresh thirty-two-character lowercase hexadecimal attempt ID. |
| `group` | Exact existing phase argument, `all`, or `network-sequence`. |
| `row` | Runner-owned opaque lowercase row slug, unique within the required plan. |
| `platform` | `linux-x86_64` or `linux-aarch64`, checked against the executing system. |
| `allowed_skips` | Explicit map of permitted phase IDs to fixed skip reasons; normally `{}`. |

Before acquiring the rig lock and after restoration, the producer checks the
requested HEAD, ref resolution, platform, tracked-tree cleanliness, and absence of
untracked executable inputs under the product/test directories. These calls mark
the exact checkout path as trusted so root can read operator-owned checkouts.
The input digest is a runner assertion: this script cannot establish the coordinator
revision, image identities or fixture provenance. The runner must resolve and
freeze those inputs before dispatch and retain the corresponding manifest.

Without context the script emits `worker-proof: {"schema":1,"bound":false}` and
retains the existing CLI behavior. This is explicitly unavailable bound evidence;
the receipt checker rejects it. Supplying malformed context fails before rig
mutation. This compatibility path does not implement the future required status.

## Receipt and required AND

A bound invocation emits the prefix `worker-proof:`, a space, and a JSON object:
`schema`, `context`, `phases`, `cleanup`, and `exit_code`. Each phase has exactly
`id`, `passed`, `failed`, and `skipped` (a list of fixed reason codes). The counts
include assertions made in child shells. No assertion prose or response data is
copied into the receipt. Counts are checked against the complete rows above;
neither fewer nor extra assertions silently pass.

Only two existing fixture-absence skips are eligible for explicit authorization:

- `stratum-auth: stratum-fixture-absent`, in `all` only. The standalone auth gate
  still requires its fixture.
- `dashboard: dashboard-fixture-absent`, in `all` or `dashboard`.

A skipped row must contain exactly its authorized reason and no successful or
failed assertions. A passing row remains valid when its skip was permitted but
unused. Unknown or unexplained skips fail. An offline check after missing initial
presence remains a failure and cannot be authorized as a skip.

Extract each receipt as JSON into its own artifact and validate against an
independently supplied plan, a nonempty JSON array of expected contexts:

```bash
python3 tests/worker-proof.py check PLAN.json RECEIPT.json MORE-RECEIPTS.json
```

The plan must retain every required row for one head/ref/input/attempt. Receipt
arrival order may vary, but phase order within each group cannot. The checker
rejects missing, duplicate, substituted or stale rows; wrong platform or context;
missing, reordered, duplicated or unknown phases; partial assertion counts;
unapproved skips; malformed/truncated data; nonzero exit; and failed cleanup.
It must receive the trusted plan, never derive expectations from the artifacts it
is checking. Receipts are not signed attestations: trust remains with the runner
that owns the checkout, plan, fixtures and artifact collection.

## Acceptance still required before rollout

The sibling runner and evidence-preflight repositories must wire this required AND
into the same current-head product/release status. Until then, local receipt
validation alone does not establish the fleet gate. Keep all existing required
statuses and per-PR proofs, including both independent bench-ci `make check` runs.
The shared proof manifest and rank-7 immutable inputs remain coordinated work;
review complete before/after behavior, assertion, input and platform inventories
by hand until that manifest is available. Unknown or truncated evidence blocks
acceptance, and existing row ownership remains authoritative.

After rank-1 capacity acceptance, only independently proven groups may overlap,
with distinct mutable rigs **and** stacks. Measure existing benches; obtain the
owner's decision before adding a lane. Keep hashing/accepted-share, systemd/feed,
donation, performance baselines, all `e2e-real` release phases, and every other
currently required live/release witness.

Before rollout, run hosted checks and paired live serial/concurrent acceptance on
the same immutable inputs. Compare complete assertion/platform manifests, gate
median/p90, occupied setup hours, failures and restoration. Record the baseline on
normal authorized runs; one week after rollout compare paired PR/head latency,
stage median/p90 minutes, occupied hours, failures and cleanup outcomes, reporting
sample sizes and load. Roll back on lost evidence, cleanup failure or increased
KVM queueing. None of those live measurements is claimed by the local regressions.
