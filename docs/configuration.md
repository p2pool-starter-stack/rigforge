# Configuration

RigForge is driven by a small `config.json` in the repo root. It holds only the handful of things the
script can't infer — everything else (CPU profile, thread count, HugePage sizing) is detected and
applied for you.

On first run, if there's no `config.json`, `setup` creates a minimal one interactively (it asks for
your pool URL). You can also pre-create one from
[`config.json.template`](../config.json.template).

Every field is **validated** when setup parses the config. A malformed pool URL, an out-of-range port,
a bad hostname, a non-boolean flag, or an unsafe `HOME_DIR` stops setup with a clear message rather than
producing a config the miner would reject.

---

## Minimal config

The only thing you must set is the **pool**. RigForge uses XMRig's native `pools` array, and a pool
only needs its `url` (a `host:port`). Everything else falls back to a sensible default:

```json
{
    "pools": [
        { "url": "<YOUR_POOL_HOST>:3333" }
    ]
}
```

That's a complete config. Replace `<YOUR_POOL_HOST>:3333` with your pool's host and port (Pithead's
proxy listens on `3333`). The interactive first-run setup writes exactly this minimal shape.

> **Mining to a public pool like [SupportXMR](https://www.supportxmr.com)?** A `url` alone isn't
> enough: public pools also need your **Monero wallet** as the pool `user` (and usually a TLS port).
> Jump to [Connecting to a public pool](#connecting-to-a-public-pool-supportxmr-etc) for a copy-paste
> example.

> **Two-tier config (like Pithead).** Keep `config.json` minimal and only add the keys you actually
> want to change. [`config.advanced.example.json`](../config.advanced.example.json) is a reference that
> lists every key with its default. Copy in only what you need; anything you omit keeps the default.
> The reference table below documents each key.

---

## Configuration reference

| Key | Default | What it does |
|---|---|---|
| `pools` | *(required)* | XMRig's native pools array — the pool(s) to mine to. Each entry needs a `url` (`host:port`); every other field falls back to a Pithead default. A pool's `user` is the rig's dashboard label (defaults to the hostname). List multiple entries for failover. See [Pools](#pools-full-control). |
| `ACCESS_TOKEN` | the rig name (first pool's `user`) | The XMRig HTTP API bearer token. Leave it unset so it defaults to the rig name — **Pithead authenticates as `Bearer <rig name>`**, so the token must equal the rig name (or be unset). See [Pithead Integration](pithead-integration.md). |
| `DONATION` | `1` | XMRig donate level, an integer **0–100** (percent). Patched into the build (`donate.h`) **and** written to the generated config, so it must be a valid integer or setup fails fast. |
| `HOME_DIR` | `DYNAMIC_HOME` | Where worker files live. `DYNAMIC_HOME` puts them in `data/worker` inside the repo; set an absolute path to use `<path>/worker` instead. |
| `autotune` | `"disabled"` | Periodic live tuning, as a target: `"disabled"` (default) installs no timer; `"performance"` schedules a periodic tune for **raw hashrate**; `"efficiency"` schedules one for **hashrate-per-watt** (needs a power source — built-in RAPL or `TUNE_POWER_CMD` — else it falls back to `performance` with a warning). Legacy booleans still parse (`true` → `performance`, `false` → `disabled`). This key controls the *schedule*; to run one live pass by hand, use `tune --now` (or `tune --now --long` for a full all-knob sweep). See [Operations › Live auto-tuning](operations.md#live-auto-tuning-opt-in). |
| `add_to_path` | `false` | When `true`, setup installs a `rigforge` command on your PATH (a symlink in `/usr/local/bin`) so you can run `sudo rigforge <cmd>` from any directory. Off by default — setup makes no system-wide convenience change you didn't ask for. `uninstall` removes it. |

---

## How the generated XMRig config is built

You don't write XMRig's config. RigForge generates the whole thing in-script and writes it into the
worker root as the live `config.json` the service runs from. There's no template file to keep in sync
and no config key for it. Every run (re-runs included) rebuilds the config from four sources:

1. **Your `config.json`** — the `pools` array (with `user`/`pass`/`keepalive`/`tls` and failover
   defaults filled in), the `donate-level`, and the `http` API block (bound to the LAN, read-only,
   token = rig name). These are the keys documented in the [reference table](#configuration-reference).
2. **Detected hardware** — the per-CPU `cpu`/`randomx` tuning (thread count, `asm`, MSR, NUMA,
   HugePages). RigForge leans on XMRig's own cache-aware auto-detection rather than a CPU-model table,
   so it stays correct for CPUs it's never seen. See [Hardware Requirements](hardware.md).
3. **Static defaults** — the fixed knobs every worker shares, emitted directly: `autosave`,
   `randomx.mode: fast`, `randomx.init`, `opencl`/`cuda` off, and the `http` port `8080`.
4. **Tuned overrides** *(if present)* — if you've run [`tune`](operations.md#tuning), its winning
   knobs in `tune-overrides.json` are merged on top as the final step, so tuning wins for just the keys
   it sets and your `config.json` is never edited.

Because the config is rebuilt from these sources every time, editing the generated `config.json` by
hand is pointless. Change your repo-root `config.json` (or `tune`) and re-run instead.

> ⚠️ **Don't put a wallet address in the worker `user` when using Pithead.** The stack handles
> payouts centrally; the pool `user` is just a rig **label** (it defaults to the hostname so you can
> tell workers apart on the dashboard).

---

## Pools (full control)

The pool target is XMRig's native **`pools`** array, passed straight through to XMRig, so you can use any
field XMRig supports. Only `url` is **required**; every other field has a default, so you specify only
what you care about:

| Field | Default if blank/omitted |
|---|---|
| `url` | *(required)* — `host:port` (e.g. `pool.supportxmr.com:443` or `your-stack:3333`). For an IPv6 literal, use the bracketed `[2001:db8::1]:3333` form. |
| `user` | the machine hostname. For **Pithead** this is just the rig's dashboard **label**; for a **public pool** set it to your **Monero wallet address** (see below). |
| `pass` | `"x"` — the stratum password / worker name. For an **open** Pithead stack the default works; if the operator enabled the stack's `p2pool.stratum_password`, set this to that secret or the proxy rejects the rig. See [Pithead Integration › Stratum authentication](pithead-integration.md#stratum-authentication-optional). |
| `keepalive` | `true` |
| `tls` | `false` — set `true` when you connect on the pool's TLS/SSL port. |
| `enabled` | `true` |

There are two common setups; pick the one that matches where you're mining.

### Connecting to a Pithead stack

[Pithead](https://github.com/p2pool-starter-stack/pithead) handles pool selection, payouts, and the
P2Pool/XvB split centrally, so the worker only needs the stack host and its proxy port (`3333`). The
`user` is just a **label** for the dashboard, so **don't put a wallet address here**:

```json
{
    "pools": [
        { "url": "stack.lan:3333", "user": "garage-rig" }
    ]
}
```

`user` is optional (it defaults to the hostname); set it to tell workers apart on the dashboard. See
[Pithead Integration](pithead-integration.md) for discovery and the API token.

### Connecting to a public pool (SupportXMR, etc.)

A public pool pays **you**, so it needs your **Monero wallet address** as the login (`user`) and almost
always a **TLS port**. RigForge builds stock upstream XMRig, so it speaks standard Stratum to any
RandomX pool. Fill in the pool's endpoint and your wallet:

```json
{
    "pools": [
        {
            "url": "pool.supportxmr.com:443",
            "user": "YOUR_MONERO_WALLET_ADDRESS",
            "pass": "garage-rig",
            "tls": true
        }
    ]
}
```

- **`user` = your Monero wallet address.** This is who gets paid. Many pools also accept
  `WALLET.workername` here to label the rig in their dashboard.
- **`pass` = a worker name** (or just `"x"`; most public pools ignore the password).
- **`url` + `tls` = the pool's stratum endpoint.** Use the pool's **TLS/SSL port** (often `:443` or
  `:5555`) with `"tls": true`; a plain, unencrypted port needs no `tls`. Your pool's *Getting started* /
  *Connect* page lists its exact host, ports, and whether it wants `wallet` or `wallet.worker`.

Save that as `config.json`, then `sudo ./rigforge.sh apply` (a fresh `setup` picks it up too).

The pool host must be an IP or DNS-resolvable hostname; allow its Stratum port through any firewall.

### Backup pools (failover)

List multiple entries. XMRig tries them **in order** and fails over to the next if one is unreachable,
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

Edit `config.json`, then apply it in one step:

```bash
sudo ./rigforge.sh apply
```

`apply` re-reads `config.json`, regenerates the live XMRig config, and **restarts the service**, with no
recompile. It's the fast, purpose-built path for a `pools` change, a new rig label, TLS, failover
pools, and the like. (On macOS there's no service, so `apply` regenerates the config and you restart
the miner yourself; see [Operations › Running on macOS](operations.md#running-on-macos).)

You can also re-run full setup (`sudo ./rigforge.sh`), but that's meant for **re-provisioning** the
whole worker (dependencies, build, kernel tuning, service). To avoid interrupting a running miner, a
setup re-run on an already-built worker regenerates the config **without restarting**, so the new
config only takes effect on the next restart. When you just want to apply an edit, reach for `apply`;
it does the restart for you. Both are idempotent and skip the recompile when the pinned XMRig is
already built.

> **Note on `DONATION`:** the donate level is also compiled into the XMRig binary at build time, so on
> an already-built worker neither `apply` nor a setup re-run changes it; both update only the runtime
> config. To re-patch the binary, force a rebuild: remove `<WORKER_ROOT>/xmrig` (or bump the pinned
> XMRig) and run setup, or run [`upgrade`](operations.md#upgrading-xmrig-redeploy-after-a-git-pull) after bumping the pin.

---

## See also

- [Getting Started](getting-started.md) — first-run setup.
- [Hardware Requirements](hardware.md) — the auto-detected tuning that drives the generated `cpu` section.
- [Pithead Integration](pithead-integration.md) — the API token and discovery rules.
