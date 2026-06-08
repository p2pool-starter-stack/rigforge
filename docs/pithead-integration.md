# Pithead Integration

RigForge works against any RandomX pool, but it's built as the companion miner for
**[Pithead](https://github.com/p2pool-starter-stack/pithead)** — a self-hosted Monero + P2Pool + Tari
mining stack. This page describes the contract between a RigForge worker and the Pithead dashboard, so
the two read as one product.

There are two connections between a worker and the stack:

1. **Mining** — the worker → the stack's stratum proxy on `:3333`.
2. **Stats** — the dashboard → the worker's XMRig HTTP API on `:8080`.

---

## 1. Mining connection (`:3333`)

Point a pool at the stack — `{ "pools": [{ "url": "your-stack:3333" }] }`, the stack's `xmrig-proxy`
endpoint (its proxy listens on `3333`). The stack handles pool selection, payouts, and the P2Pool/XvB
split centrally, so the worker config stays minimal and you **never put a wallet address in it**.

- The XMRig pool `user` field is just a **label** for the rig — it defaults to the hostname (set
  `pools[].user` to name it) so you can tell workers apart on the dashboard.
- Point as many workers as you like at the same stack endpoint; the stack aggregates them.
- Workers talk to the pool over plain Stratum on your local network — they do **not** need Tor.
- The endpoint must be reachable from the worker; if the stack host has a firewall, allow the Stratum
  port (3333) on the LAN.

---

## 2. Stats connection — the Worker API (`:8080`)

Each worker exposes XMRig's HTTP API so Pithead's dashboard can show per-rig stats (hashrate, shares,
uptime). RigForge configures the API to match Pithead's contract **exactly**, so there's nothing to
set up stack-side:

| Setting | Value | Why |
|---|---|---|
| **Port** | `8080` | Pithead reads `GET http://<rig>:8080/1/summary`; the port is fixed dashboard-side. |
| **Bind** | `0.0.0.0` (all interfaces) | The dashboard polls each worker from the stack host over the LAN. |
| **Mode** | `restricted: true` (read-only) | The API can be **read** but not used to **control** the miner remotely. |
| **Auth token** | the rig name — the first pool's `user` (default hostname), or an explicit `ACCESS_TOKEN` | Pithead authenticates as `Bearer <rig name>`, so the token defaults to the rig name and stays in sync even when you set a custom `pools[].user`. |

Pithead discovers workers from the stratum proxy's connection list (the pool `user` label, which is the
rig name) — there's **nothing to register** stack-side. Workers run on a trusted LAN and need no Tor.

---

## The token rule (important)

> ⚠️ **Don't set a random/custom API token for a Pithead-connected worker.** The dashboard
> authenticates as `Bearer <rig name>`, so a decoupled token means it can't read the worker. Leave
> `ACCESS_TOKEN` unset (it defaults to the rig name) unless you've matched it on both sides.

Likewise, **don't** bind the API to localhost only and **don't** change the port: a custom token, a
non-`8080` API port, or a worker reachable at a different host than the one it connects from all require
matching configuration on **both** sides — that cross-side coordination is later Pithead-side work
(Pithead [#171](https://github.com/p2pool-starter-stack/pithead/issues/171) /
[#172](https://github.com/p2pool-starter-stack/pithead/issues/172)).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| **Worker missing from the dashboard** | The dashboard discovers rigs from their stratum `user` label — confirm the worker is actually connected to the pool and mining. |
| **Rig shows as connected but no stats** | The HTTP API token must equal the rig name (or be unset). If you set a custom `ACCESS_TOKEN`, the dashboard can't read it — clear it and re-run setup. |
| **Stats unreachable from the stack host** | Confirm the worker's `:8080` is reachable from the stack host over the LAN (firewall, correct IP). RigForge binds `0.0.0.0` by default. |

---

## See also

- [Configuration › ACCESS_TOKEN](configuration.md#configuration-reference) — the token default and rule.
- [Getting Started](getting-started.md) — provisioning a worker pointed at the stack.
- [Pithead docs](https://github.com/p2pool-starter-stack/pithead/tree/main/docs) — the stack side of
  the contract.
