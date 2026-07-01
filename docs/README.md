# Documentation

Reference for provisioning, configuring, and operating a RigForge mining worker.

New here? Start with the [Getting Started](getting-started.md) guide. It takes you from a fresh
Ubuntu machine to a tuned, running XMRig worker in one command. The other guides go deeper on
individual topics once you're up and running.

## Guides

| Guide | What it covers |
|---|---|
| [Getting Started](getting-started.md) | Prerequisites, installation, first-run setup, the Linux reboot, and how to verify the worker is mining. |
| [Hardware Requirements](hardware.md) | Worker CPU / RAM / HugePages requirements and the per-CPU tuning profiles RigForge applies. |
| [Benchmarks](benchmarks.md) | Measured stock-vs-tuned hashrate and efficiency (H/s per watt) on real hardware, mining live, with the method and caveats. |
| [Configuration](configuration.md) | Every `config.json` key and default, minimal vs. advanced setups, and how the XMRig config is generated. |
| [Operations & Maintenance](operations.md) | The full command reference, service management, logs, upgrades, and troubleshooting. |
| [How It Works](how-it-works.md) | What the script actually does: dependencies, compile-from-source, HugePages, MSR, NUMA, the governor, and the systemd service. |
| [Pithead Integration](pithead-integration.md) | The worker ↔ dashboard contract: discovery via `:3333`, the read-only HTTP API on `:8080`, and the token rules. |
| [FAQ](faq.md) | Common questions, plus why RigForge vs. setting XMRig up by hand. |

For how RigForge is versioned and released, see [`RELEASING.md`](../RELEASING.md) and
[`CHANGELOG.md`](../CHANGELOG.md).

## Quick links

- **Just want to start mining?** → [Getting Started](getting-started.md)
- **What do I run day to day?** → [Operations › Common tasks](operations.md#common-tasks)
- **Redeploy after a `git pull`?** → [Operations › Upgrading](operations.md#upgrading-xmrig-redeploy-after-a-git-pull)
- **Run a live tune now?** → [Operations › Live auto-tuning](operations.md#live-auto-tuning-opt-in)
- **Will my CPU do well?** → [Hardware Requirements](hardware.md)
- **How much does the tuning help?** → [Benchmarks](benchmarks.md)
- **Change a setting?** → [Configuration](configuration.md)
- **Mining to a public pool (SupportXMR, etc.)?** → [Configuration › Connecting to a public pool](configuration.md#connecting-to-a-public-pool-supportxmr-etc)
- **Connecting to a Pithead stack?** → [Pithead Integration](pithead-integration.md)
- **Something's not working?** → [Operations › Troubleshooting](operations.md#troubleshooting)
