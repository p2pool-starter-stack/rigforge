# Pithead Integration

The contract between a RigForge worker and the Pithead dashboard. RigForge works against any RandomX
pool, but it's built as the companion miner for
[Pithead](https://github.com/p2pool-starter-stack/pithead), a self-hosted Monero + P2Pool + Tari mining
stack.

There are two connections between a worker and the stack:

1. Mining: the worker → the stack's stratum proxy on `:3333`.
2. Stats: the dashboard → the worker's XMRig HTTP API on `:8080`.

---

## 1. Mining connection (`:3333`)

Point a pool at the stack: `{ "pools": [{ "url": "your-stack:3333" }] }`, the stack's `xmrig-proxy`
endpoint (its proxy listens on `3333`). The stack handles pool selection, payouts, and the P2Pool/XvB
split centrally, so the worker config stays minimal and you never put a wallet address in it.

- The XMRig pool `user` field is just a label for the rig. It defaults to the hostname (set `pools[].user`
  to name it) so you can tell workers apart on the dashboard.
- Point as many workers as you like at the same stack endpoint; the stack aggregates them.
- Workers talk to the pool over plain Stratum on your local network; they do not need Tor.
- The endpoint must be reachable from the worker; if the stack host has a firewall, allow the Stratum port
  (3333) on the LAN.

### Stratum authentication (optional)

By default the stack's `:3333` is open: any rig that can reach it may mine, and the pool `pass` is
ignored (RigForge defaults it to `"x"`). If the operator turns authentication on by setting
[`p2pool.stratum_password`](https://github.com/p2pool-starter-stack/pithead/blob/main/docs/workers.md#authentication)
on the stack, the proxy then rejects any rig whose `pass` doesn't match: XMRig logs `Permission denied`
and the rig won't mine. Put that same secret in the rig's pool `pass`:

```jsonc
// config.json — set "pass" to the stack's p2pool.stratum_password
{
    "pools": [
        { "url": "your-stack:3333", "pass": "the-stratum-password" }
    ]
}
```

Then `./rigforge.sh apply` (or `setup`) regenerates the worker config with the new password.

On a fresh rig you don't need to edit anything: the interactive first run (`setup` with no
`config.json` yet) prompts for the stratum password and writes it for you — press Enter to skip it
if your stack doesn't use one.

- It's the same secret on every rig. The operator finds it on the stack side: it's printed after
  `pithead apply`/`setup`, stored in the stack's `.env` as `PROXY_STRATUM_PASSWORD`, and shown by
  `pithead status`.
- The password travels cleartext over your LAN's plain Stratum, so this is access control (who may mine),
  not encryption. Keep `:3333` on a trusted LAN (the stack's `p2pool.stratum_bind` / a firewall do the
  rest) — or add [stratum over TLS](#stratum-over-tls-optional) below for confidentiality.
- This is unrelated to the `DONATION` knob (that's this rig's dev-fee donation) and to the optional API
  `ACCESS_TOKEN` below (that gates the read-only stats API on `:8080`, which is open by default).

#### Rotating the password

1. On the stack: change or regenerate `p2pool.stratum_password`, run `pithead apply`, and read the
   new secret from `pithead status`.
2. On each rig: set `pools[].pass` in `config.json` to the new secret and run `sudo ./rigforge.sh apply`.
3. Until step 2 lands on a rig, it logs `Permission denied` and drops off the dashboard — that's the
   expected signal that it still has the old secret, not a fault (see
   [Troubleshooting](#troubleshooting)).

### Sister API (optional, `:8081`)

Set `"api": "enabled"` (+ `sudo ./rigforge.sh apply`) and the worker serves a second **read-only**
HTTP endpoint the stack can consume for data XMRig doesn't know (the enriched feed for
pithead#235):

- `GET /1/summary` and `GET /2/summary` — XMRig's own body passed through **verbatim** (a strict
  superset: everything the `:8080` probe returns is here unchanged), plus one namespaced
  `rigforge` object: `version`/`xmrig_version`/`xmrig_commit` (provenance), `tune` (applied
  overrides, last run's target/best/candidates, the autotune schedule), `power` (RAPL watts and
  hashrate-per-watt over a 1s window; `null` when unmeasurable), `health` (the doctor probes
  as JSON: HugePages, MSR state, governor, RAM channels/speeds, XMP and SMT state, throttling),
  `watchdog` (armed state, thermal-hold, `max_temp_c`), `config` (the effective **writable**
  config — exactly the control-path allowlist, pool secrets masked; see the prefill note in §3), and
  `config_meta` (`{revision, changed_at, source, last_change_id}` — `revision` is a content hash of the
  writable config that changes iff that config changes, so a poller can detect a change made directly
  on the rig; `source` is `control`/`local`/`restore`; see §3).
- `GET /health` and `GET /tune` — the `rigforge.health` / `rigforge.tune` objects bare.
- When XMRig's own API is unreachable the response is still `200` with
  `"rigforge": {..., "xmrig_api": "unreachable"}` — a down miner is exactly when the health data
  matters.

Same token rule as `:8080`: open when `ACCESS_TOKEN` is unset (the default), the exact `Bearer`
otherwise — the sister API deliberately mirrors XMRig's own API conventions: the versioned `/1`/`/2`
paths, the same `Bearer`/`401` semantics, JSON-only bodies, and minimal headers. The release gate's
`network` phase enforces the boundary on the wire: the miner's only TCP peers are the configured
pool, `:8081` exists exactly while enabled, and no response byte ever contains `ACCESS_TOKEN` or a
pool `pass`. `:8080` stays the canonical Pithead summary probe; `:8081` is additive. Port/bind are
`api_port`/`api_bind`. Architecture mirrors XMRig's own API: a tiny persistent server ships
pre-computed state (a request costs microseconds — polling cannot shave hashrate), refreshed every
15s by an idle-priority timer, so responses are at most ~15s stale.

### Stratum over TLS (optional)

Needs stack-side support that hasn't shipped yet (Pithead is tracking it as
[pithead#261](https://github.com/p2pool-starter-stack/pithead/issues/261)) — but everything below
already works today against **any** TLS stratum endpoint, e.g. a public pool's TLS port.

```jsonc
// config.json — TLS on, server cert pinned by its SHA-256 fingerprint
{
    "pools": [
        { "url": "your-stack:3334", "tls": true, "tls-fingerprint": "<64 hex chars>" }
    ]
}
```

Then `sudo ./rigforge.sh apply`. (The `:3334` port is only an example — use whatever port the stack
documents once pithead#261 fixes its port model.)

**The trust model, plainly:** XMRig does no CA validation on stratum TLS. With `"tls": true` and no
fingerprint, the link is encrypted but not authenticated — fine against passive snooping, no defense
against an active man-in-the-middle. The fingerprint pin IS the server authentication. Get it with:

```bash
echo | openssl s_client -connect your-stack:3334 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':'
```

- TLS is confidentiality; the stratum password (above) is access control. They're orthogonal — set
  both on an untrusted network.
- Rotation: when the stack rotates its certificate, update `tls-fingerprint` on each rig and run
  `apply` (same runbook shape as the password). A stale pin shows up as
  `Failed to verify server certificate fingerprint` in the XMRig log.

---

## 2. Stats connection — the Worker API (`:8080`)

Each worker exposes XMRig's HTTP API so Pithead's dashboard can show per-rig stats (hashrate, shares,
uptime). RigForge configures the API to match Pithead's contract exactly, so there's nothing to set up
stack-side:

| Setting | Value | Why |
|---|---|---|
| Port | `8080` | Pithead reads `GET http://<rig>:8080/1/summary`; the port is fixed dashboard-side. |
| Bind | `0.0.0.0` (all interfaces) | The dashboard polls each worker from the stack host over the LAN. |
| Mode | `restricted: true` (read-only) | The API can be read but not used to control the miner remotely. |
| Auth token | none (open) by default; set `ACCESS_TOKEN` to require a Bearer token | Pithead's stock probe is no-auth, so an open, read-only API works without extra config. Setting `ACCESS_TOKEN` turns auth on; see below. |

Pithead discovers workers from the stratum proxy's connection list (the pool `user` label, which is the
rig name), so there's nothing to register stack-side. Workers run on a trusted LAN and need no Tor.

---

## The token rule (important)

> NOTE: By default the worker API is open (read-only, no token), which matches Pithead's default probe
> (`workers.api_auth: none`). Nothing to coordinate. Leave `ACCESS_TOKEN` unset and it works.

If you do want a token (e.g. you don't fully trust the LAN), set `ACCESS_TOKEN` here and match it on the
dashboard side:

- a single shared token → Pithead `workers.api_auth: token` + `workers.api_token: <the token>`;
- the rig name as the token (`ACCESS_TOKEN` = the first pool's `user`) → Pithead `workers.api_auth: name`.

Likewise, don't bind the API to localhost only and don't change the port without matching it on the stack
side (`workers.api_port`): a non-`8080` port, or a worker reachable at a different host than the one it
connects from, also need matching configuration on both sides
(Pithead [#171](https://github.com/p2pool-starter-stack/pithead/issues/171) /
[#172](https://github.com/p2pool-starter-stack/pithead/issues/172)).

---

## 3. Writable control path (`:8082`, producer for Worker Inspect)

Off by default. When you set `"control": "enabled"` (plus the required `ACCESS_TOKEN` and
`api_allow_from`), the rig serves a *separate* authenticated write endpoint that lets the stack
apply config changes through RigForge — the RigForge-side producer for pithead's Worker Inspect
(pithead #185). It is deliberately independent of the read API: a `POST :8082/apply` of an
allowlisted change (`pools`, `DONATION`, `autotune`, `watchdog`, `watchdog_interval_min`,
`max_temp_c`) returns `202 Accepted`; RigForge validates, snapshots the old config, applies it, and
rolls back anything that doesn't come back live. The stack reads the new effective config back from
`:8081/2/summary` and polls `:8082/status` for the outcome. The write path is pinned to the stack
host by `api_allow_from` (mandatory) — the miner never accepts a config from anywhere else. Full
mechanics and the security model: [Operations › Writable control path](operations.md#writable-control-path-opt-in)
and [ADR 0001](adr/0001-writable-worker-config-control-path.md).

**Polling a specific change (`?change_id`).** The no-arg `GET :8082/status` returns the *most
recent* change's outcome, which a concurrent change (another dashboard edit, a local `apply`, an
autotune restart) can step on between your `POST` and your poll. To avoid that race, poll
`GET :8082/status?change_id=<the 16-hex id from the 202>` — it returns *that* change's recorded
outcome (`applied`/`rejected`/`rolled_back`/`failed` + `reason`/`backup`/`changed_keys`/`warnings`), or `404`
if it isn't among the last ~20 recorded. Same bearer auth as `/status`. Pair it with
`config_meta.revision` on the read feed to confirm the effective config actually moved.

**Prefill from a live read (`rigforge.config`).** The enriched feed exposes the rig's current
writable config as `rigforge.config` on `:8081/1/summary` (= `/2/summary`) — exactly the keys
`/apply` accepts (`pools`, `DONATION`, `autotune`, `watchdog`, `watchdog_interval_min`,
`max_temp_c`), read the same way RigForge parses them (canonical strings, e.g. `perf` →
`performance`). Worker Inspect can prefill its editor from this live read instead of its own
last-applied record, and it's served even when the miner is down (it comes from `config.json`, not
XMRig). Pool secrets are masked: `pools[].pass` and any `tls-fingerprint` are omitted — so a
round-trip that re-sends the `pools` array must re-supply the pool password (the read never carries it).

**The control path is a tuning channel, not a safety-removal one.** A `POST /apply` that would
disable the `watchdog` or unset / set an out-of-band `max_temp_c` (a rig's thermal cutoff) is refused
with `400` — change thermal protection locally on the rig with `rigforge.sh` if that's really
intended. Any change touching `watchdog`/`max_temp_c` is surfaced in `:8082/status` as a
`warnings[]` entry, so the dashboard can require an extra confirmation. The control token is
write-capable and travels in cleartext HTTP; `api_allow_from` scopes the source but doesn't protect
the token in flight, so isolate the mining LAN — see
[Security › what RigForge exposes](../SECURITY.md#what-rigforge-exposes-and-what-it-doesnt).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Rig won't mine / XMRig logs `Permission denied` at login | The stack has stratum authentication on (`p2pool.stratum_password`); set the pool `pass` to that secret. See [Stratum authentication](#stratum-authentication-optional). |
| XMRig logs `Failed to verify server certificate fingerprint` | The `tls-fingerprint` pin doesn't match the server's certificate (rotated cert or a typo). Re-run the openssl one-liner in [Stratum over TLS](#stratum-over-tls-optional) and `apply`. |
| Worker missing from the dashboard | The dashboard discovers rigs from their stratum `user` label; confirm the worker is actually connected to the pool and mining. |
| Rig shows as connected but no stats | By default the API is open and the dashboard reads it with no token. If you set an `ACCESS_TOKEN` here, the dashboard must match it (`workers.api_auth: token` + `workers.api_token`, or `name` if the token is the rig name); otherwise clear `ACCESS_TOKEN` and re-run setup. |
| Stats unreachable from the stack host | Confirm the worker's `:8080` is reachable from the stack host over the LAN (firewall, correct IP). RigForge binds `0.0.0.0` by default. |

---

## See also

- [Configuration › ACCESS_TOKEN](configuration.md#configuration-reference) — the token default and rule.
- [Getting Started](getting-started.md) — provisioning a worker pointed at the stack.
- [Pithead docs](https://github.com/p2pool-starter-stack/pithead/tree/main/docs) — the stack side of
  the contract.
