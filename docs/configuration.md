# Configuration

RigForge is driven by a small `config.json` in the repo root. It holds only the handful of things the
script can't infer — everything else (CPU profile, thread count, HugePage sizing) is detected and
applied for you.

On first run, if there's no `config.json`, `setup` creates a minimal one interactively (it asks for
your pool host). You can also pre-create one from
[`config.json.template`](../config.json.template).

---

## Minimal config

```json
{
    "HOME_DIR": "DYNAMIC_HOME",
    "DONATION": 1,
    "WORKER_CONFIG_FILE": "./worker-config/example-config.json.template",
    "POOL_HOST": "YOUR_POOL_HOST_OR_IP"
}
```

`POOL_HOST` is the only field you must set. The rest have sensible defaults.

---

## Configuration reference

| Key | Default | What it does |
|---|---|---|
| `POOL_HOST` | _(required)_ | Your pool / stratum host or IP. Goes straight into the XMRig pool URL as `POOL_HOST:3333`. Must be a hostname, FQDN, or IP — it's validated before the build (the unfilled template placeholder and shell/URL metacharacters are rejected). |
| `HOME_DIR` | `DYNAMIC_HOME` | Where worker files live. `DYNAMIC_HOME` puts them in `data/worker` inside the repo; set an absolute path to use `<path>/worker` instead. |
| `DONATION` | `1` | XMRig donate level, an integer **0–100** (percent). Patched into the build (`donate.h`) **and** written to the generated config, so it must be a valid integer or setup fails fast. |
| `WORKER_CONFIG_FILE` | `./worker-config/example-config.json.template` | The XMRig config **template** RigForge tunes from. Relative paths resolve against the repo; absolute paths are used as-is. The default suits most setups. |
| `ACCESS_TOKEN` | the machine's `hostname` | The XMRig HTTP API bearer token. Leave it unset so it defaults to the hostname — **Pithead authenticates as `Bearer <rig name>`**, so the token must equal the rig name (or be unset). See [Pithead Integration](pithead-integration.md). |

### Backward compatibility

The former `P2POOL_NODE_HOSTNAME` key is still accepted as an **alias** for `POOL_HOST`, so existing
configs keep working untouched. If both are present, `POOL_HOST` wins. New configs should use
`POOL_HOST`.

---

## The XMRig worker template

`WORKER_CONFIG_FILE` points at an XMRig config **template** (default:
[`worker-config/example-config.json.template`](../worker-config/)). RigForge reads it, then overwrites
the parts it manages — the `pools` list (collapsed to a single `POOL_HOST:3333` entry), `donate-level`,
the `http` API block, and the per-CPU `cpu`/`randomx` sections — and writes the result into the worker
root as the live `config.json` XMRig runs from.

Anything in the template that RigForge **doesn't** manage is passed through. If you need to customize
XMRig beyond what RigForge sets (extra pool fallbacks, logging tweaks, etc.), edit the template — but
note that the managed sections will be regenerated on every run, so don't hand-edit those.

> ⚠️ **Don't put a wallet address in the worker config when using Pithead.** The stack handles
> payouts centrally; the `user` field is just a rig **label** (it defaults to the hostname so you can
> tell workers apart on the dashboard).

---

## Connecting to a pool or stack

RigForge points XMRig at a single **Stratum endpoint**, `POOL_HOST:3333`:

- **With [Pithead](https://github.com/p2pool-starter-stack/pithead)** — set `POOL_HOST` to the stack
  host. The stack's `xmrig-proxy` listens on `3333` and handles pool selection, payouts, and the
  P2Pool/XvB split centrally, so the worker config stays minimal. See
  [Pithead Integration](pithead-integration.md).
- **With any other RandomX pool** — set `POOL_HOST` to the pool's stratum host. RigForge builds stock
  upstream XMRig, which speaks standard Stratum, so it works against any RandomX pool that listens on
  `3333`.

The host must be an IP or DNS-resolvable hostname; for a stable LAN address, set a DHCP reservation or
a static IP. If the host has a firewall, allow the Stratum port (3333) on the LAN.

---

## Changing settings later

Edit `config.json`, then re-run setup:

```bash
sudo ./rigforge.sh
```

Re-runs are idempotent — setup regenerates the managed XMRig config and re-applies system tuning
without duplicating anything, and skips the recompile if the pinned XMRig is already built. Changes to
the generated config (e.g. `POOL_HOST`) take effect on the next service restart.

> **Note on `DONATION`:** the donate level is also compiled into the XMRig binary at build time. Since
> re-running setup skips the recompile when XMRig is already built, changing `DONATION` afterwards
> updates the runtime config but **not** the binary's built-in level. To re-patch the binary, force a
> rebuild — remove `<WORKER_ROOT>/xmrig` (or bump the pinned XMRig) and run setup again.

---

## See also

- [Getting Started](getting-started.md) — first-run setup.
- [Hardware Requirements](hardware.md) — the auto-detected tuning that drives the generated `cpu` section.
- [Pithead Integration](pithead-integration.md) — the API token and discovery rules.
