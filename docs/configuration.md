# Configuration

RigForge is driven by a small `config.json` in the repo root. It holds only the handful of things the
script can't infer — everything else (CPU profile, thread count, HugePage sizing) is detected and
applied for you.

On first run, if there's no `config.json`, `setup` creates a minimal one interactively (it asks for
your pool URL). You can also pre-create one from
[`config.json.template`](../config.json.template).

Every field is **validated** when setup parses the config — a malformed pool URL, an out-of-range port,
a bad hostname, a non-boolean flag, or an unsafe `HOME_DIR` stops setup with a clear message rather than
producing a config the miner would reject.

---

## Minimal config

The only thing you must set is the **pool** — RigForge uses XMRig's native `pools` array, and a pool
only needs its `url` (a `host:port`). Everything else falls back to a sensible default:

```json
{
    "pools": [
        { "url": "<YOUR_POOL_HOST>:3333" }
    ]
}
```

That's a complete config — replace `<YOUR_POOL_HOST>:3333` with your pool's host and port (Pithead's
proxy listens on `3333`). The interactive first-run setup writes exactly this minimal shape.

> **Two-tier config (like Pithead).** Keep `config.json` minimal and only add the keys you actually
> want to change. [`config.advanced.example.json`](../config.advanced.example.json) is a reference that
> lists **every** key with its default — copy in only what you need; anything you omit keeps the
> default. The reference table below documents each key.

---

## Configuration reference

| Key | Default | What it does |
|---|---|---|
| `pools` | _(required)_ | XMRig's native pools array — the pool(s) to mine to. Each entry needs a `url` (`host:port`); every other field falls back to a Pithead default. A pool's `user` is the rig's dashboard label (defaults to the hostname). List multiple entries for failover. See [Pools](#pools-full-control). |
| `ACCESS_TOKEN` | the rig name (first pool's `user`) | The XMRig HTTP API bearer token. Leave it unset so it defaults to the rig name — **Pithead authenticates as `Bearer <rig name>`**, so the token must equal the rig name (or be unset). See [Pithead Integration](pithead-integration.md). |
| `DONATION` | `1` | XMRig donate level, an integer **0–100** (percent). Patched into the build (`donate.h`) **and** written to the generated config, so it must be a valid integer or setup fails fast. |
| `HOME_DIR` | `DYNAMIC_HOME` | Where worker files live. `DYNAMIC_HOME` puts them in `data/worker` inside the repo; set an absolute path to use `<path>/worker` instead. |
| `autotune` | `false` | When `true`, setup installs a systemd timer that periodically live-tunes the worker. See [Operations › Live auto-tuning](operations.md#live-auto-tuning-opt-in). |

---

## How the generated XMRig config is built

You don't write XMRig's config — RigForge generates it. It starts from a bundled template, then sets
the parts it manages — your `pools`, `donate-level`, the `http` API block, and the per-CPU
`cpu`/`randomx` tuning — and writes the result into the worker root as the live `config.json` XMRig
runs from. The template is internal; there's no config key for it.

> ⚠️ **Don't put a wallet address in the worker `user` when using Pithead.** The stack handles
> payouts centrally; the pool `user` is just a rig **label** (it defaults to the hostname so you can
> tell workers apart on the dashboard).

---

## Pools (full control)

The pool target is XMRig's native **`pools`** array, passed straight through to XMRig — you can use any
field XMRig supports. **Only `url` matters; everything else falls back to a Pithead-friendly default**,
so you specify only what you care about:

| Field | Default if blank/omitted |
|---|---|
| `url` | _(required)_ — `host:port` (e.g. `your-stack:3333`; Pithead's proxy listens on `3333`). For an IPv6 literal, use the bracketed `[2001:db8::1]:3333` form. |
| `user` | the machine hostname — this is the rig's **label** on the dashboard; set it to name the rig |
| `pass` | `"x"` |
| `keepalive` | `true` |
| `tls` | `false` |
| `enabled` | `true` |

- **With [Pithead](https://github.com/p2pool-starter-stack/pithead)** — point `url` at the stack host
  and its proxy port (e.g. `"stack.lan:3333"`); the stack handles pool selection, payouts, and the
  P2Pool/XvB split centrally, so you never put a wallet address in the worker. See
  [Pithead Integration](pithead-integration.md).
- **With any other RandomX pool** — point `url` at that pool's stratum endpoint (with its port and
  `tls` as needed). RigForge builds stock upstream XMRig, so it speaks standard Stratum to any pool.

The host must be an IP or DNS-resolvable hostname; for a stable LAN address, set a DHCP reservation or
a static IP, and allow the Stratum port through any firewall.

### Backup pools (failover)

List multiple entries — XMRig tries them **in order** and fails over to the next if one is unreachable,
handy for a primary stack with a public-pool fallback:

```json
{
    "pools": [
        { "url": "stack.lan:3333" },
        { "url": "pool.supportxmr.com:443", "tls": true }
    ]
}
```

Here the worker mines to `stack.lan:3333` and falls back to `pool.supportxmr.com:443` over TLS, with
`user`/`pass`/`keepalive` filled in for both.

---

## Changing settings later

Edit `config.json`, then re-run setup:

```bash
sudo ./rigforge.sh
```

Re-runs are idempotent — setup regenerates the managed XMRig config and re-applies system tuning
without duplicating anything, and skips the recompile if the pinned XMRig is already built. Changes to
the generated config (e.g. a `pools` change) take effect on the next service restart.

> **Note on `DONATION`:** the donate level is also compiled into the XMRig binary at build time. Since
> re-running setup skips the recompile when XMRig is already built, changing `DONATION` afterwards
> updates the runtime config but **not** the binary's built-in level. To re-patch the binary, force a
> rebuild — remove `<WORKER_ROOT>/xmrig` (or bump the pinned XMRig) and run setup again.

---

## See also

- [Getting Started](getting-started.md) — first-run setup.
- [Hardware Requirements](hardware.md) — the auto-detected tuning that drives the generated `cpu` section.
- [Pithead Integration](pithead-integration.md) — the API token and discovery rules.
