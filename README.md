<div align="center">

<img src="./images/rigforge-mark.svg" alt="RigForge" width="110">

# RigForge

### Provision a hardware-tuned XMRig miner in one command.

[![CI](https://github.com/p2pool-starter-stack/rigforge/actions/workflows/ci.yml/badge.svg)](https://github.com/p2pool-starter-stack/rigforge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform: Ubuntu 22.04+](https://img.shields.io/badge/Platform-Ubuntu%2022.04%2B-E95420?logo=ubuntu&logoColor=white)
[![Miner: XMRig](https://img.shields.io/badge/Miner-XMRig-F26822?logo=monero&logoColor=white)](https://github.com/xmrig/xmrig)
[![Companion: Pithead](https://img.shields.io/badge/Companion-Pithead-F26822)](https://github.com/p2pool-starter-stack/pithead)

RigForge turns a fresh Ubuntu/Debian (or macOS) machine into a fully tuned [XMRig](https://github.com/xmrig/xmrig)
mining worker — it installs the toolchain, compiles XMRig from source, applies kernel- and CPU-level
tuning for maximum RandomX hashrate, and runs it as a managed service. You point it at a pool and
walk away.

It works against **any RandomX Stratum pool**, and it's built as the companion miner for
**[Pithead](https://github.com/p2pool-starter-stack/pithead)** — connect as many RigForge workers as
you like to your stack's single endpoint.

</div>

> **RigForge is not a custom miner.** It compiles stock, upstream XMRig and wraps it in the setup,
> hardware tuning, and service management that are otherwise fiddly to get right by hand.

---

## ✨ What it does

- **Automated setup** — installs build dependencies (`cmake`, `libuv`, `hwloc`, …) and compiles a
  pinned, commit-verified XMRig from source.
- **Hardware-aware tuning** — leans on XMRig's cache-aware auto-detection (thread count, assembly
  path, MSR preset, NUMA) and layers on dedicated-miner defaults for maximum hashrate.
- **Kernel & system tuning (Linux)** — topology-aware HugePages (1 GB and 2 MB), MSR access for
  hardware-prefetcher control, and `hugetlbfs` mounts + memlock limits.
- **Service management (Linux)** — runs XMRig as a `systemd` service with a `cpupower` performance
  governor and automatic log rotation.
- **Interactive config** — if no config exists, it asks for the one thing it needs: your pool URL.
- **Idempotent** — re-running skips the recompile when the pinned XMRig is already built and never
  double-applies system tuning.

---

## 🚀 Quick Start

On the machine you want to turn into a miner:

```bash
git clone https://github.com/p2pool-starter-stack/rigforge.git
cd rigforge
chmod +x rigforge.sh
sudo ./rigforge.sh
```

The script needs root to install packages and tune the system. On first run it asks for your pool URL
and writes a minimal `config.json`. On **Linux**, reboot once afterwards to apply the
HugePages tuning — the `xmrig` service then starts automatically.

➡️ **Full walkthrough:** [docs/getting-started.md](docs/getting-started.md)

---

## 📚 Documentation

| Guide | What's inside |
|---|---|
| **[Getting Started](docs/getting-started.md)** | Prerequisites, install, first-run setup, the Linux reboot, and verification. |
| **[Hardware Requirements](docs/hardware.md)** | Worker CPU / RAM / HugePages requirements and the per-CPU tuning profiles. |
| **[Configuration](docs/configuration.md)** | Every `config.json` key and default, and how the XMRig config is generated. |
| **[Operations & Maintenance](docs/operations.md)** | The full command reference, service management, logs, upgrades, and troubleshooting. |
| **[How It Works](docs/tuning.md)** | What the script actually does — compile, HugePages, MSR, NUMA, governor, service. |
| **[Pithead Integration](docs/pithead-integration.md)** | The worker ↔ dashboard contract: discovery via `:3333`, the read-only API on `:8080`, and the token rules. |
| **[FAQ](docs/faq.md)** | Common questions, plus why RigForge vs. doing it by hand. |

Browse the full index at **[docs/](docs/README.md)**.

---

## 🛠️ Common commands

```bash
sudo ./rigforge.sh              # provision (or re-provision) the worker — idempotent
sudo ./rigforge.sh apply        # apply config.json edits: regenerate + restart (no rebuild)
sudo ./rigforge.sh upgrade      # rebuild + restart only if the pinned XMRig changed
sudo ./rigforge.sh doctor       # health check: HugePages, MSR, governor, service
sudo ./rigforge.sh status       # service status      (also: logs / start / stop / restart)
./rigforge.sh version           # print the version   (also: help)
```

See [Operations & Maintenance](docs/operations.md) for the full reference.

---

## 🧪 Testing & development

RigForge ships a dependency-free test suite plus an opt-in container end-to-end run. Both mirror the
CI jobs, so `make test` locally is what CI checks.

```bash
make lint        # shellcheck + shfmt the script, utilities, and test scripts
make test        # lint + the dependency-free suite (runs on macOS or Linux, no Docker)
make test-e2e    # full end-to-end in disposable Linux containers (needs Docker)
make smoke       # release pre-tag gate: real xmrig --bench proves the built worker hashes (manual)
```

**What `make test` covers** — it sources `rigforge.sh` and exercises its functions in isolation, with
every external/privileged command (`git`, `make`, `cmake`, `sudo`, `systemctl`, `modprobe`,
`apt-get`, …) and all hardware detection (`uname`, `lscpu`, `sysctl`, `nproc`, `hostname`) replaced by
fakes on `PATH`. Because the hardware is faked, **one run on any machine simulates every supported
platform** — it asserts the generated XMRig config for EPYC / Ryzen X3D / generic-Linux inputs and the
macOS path, plus config parsing, `DONATION` validation, host resolution, and a full stubbed
deployment run (executed twice to prove idempotency).

**What `make test-e2e` adds** — it runs the *real* `rigforge.sh` end-to-end inside a throwaway
`ubuntu` container (RigForge's documented Linux target, `linux/amd64`), against a real, disposable
`/etc`. This validates the Linux-only deploy path with genuine tools — GNU `sed`, `envsubst`, the
`fstab`/`limits`/GRUB edits and their idempotency — which can't run natively on a macOS host. Only the
heavy XMRig compile and the package install are stubbed. It skips cleanly if Docker isn't available.

No XMRig binary is compiled by the tests — the heavy native build is stubbed; the suite asserts the
*orchestration* (clone → patch `donate.h` → cmake → make) and the generated configuration instead.

**`make smoke`** closes that gap at release time. Because the suites never compile or run XMRig, they
can't prove the shipped binary actually starts and hashes. `make smoke` benches a real worker
(`xmrig --bench`, fully offline) on a real rig and passes only if a hashrate is reported and the run is
clean — it's a manual, Linux-only-for-full-effect pre-tag gate, not a CI job. See
[RELEASING.md](./RELEASING.md).

For how RigForge is versioned and released, see [RELEASING.md](./RELEASING.md) and
[CHANGELOG.md](./CHANGELOG.md).

---

## 🤝 Donate

If RigForge saved you time and you'd like to support it, donations to this XMR wallet are appreciated:

    89VGXHYEYdTJ4qQPoSZSD4BQsXCm6vCjUF2y2Vm42mA8ESLXA4XpmsvWMFB2stQw7p5UXnyZ81EMtgkCYqjYBPow8v7btKv

---

## 📝 License

Provided "as-is" under the [MIT License](./LICENSE).
