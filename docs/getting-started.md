# Getting Started

This guide takes you from a fresh machine to a tuned, running XMRig worker. The whole process is
driven by a single script — `rigforge.sh` — and most of it is automated.

> **TL;DR**
> ```bash
> git clone https://github.com/p2pool-starter-stack/rigforge.git
> cd rigforge
> chmod +x rigforge.sh
> sudo ./rigforge.sh
> ```
> Answer one prompt (your pool/stack host), let it build, and — on Linux — reboot once to apply the
> kernel tuning. The `xmrig` service starts automatically after the reboot.

---

## 1. Prerequisites

| Requirement | Recommendation |
|---|---|
| **Operating system** | Ubuntu Server **22.04+** (or Debian 12) is the officially supported target. macOS works for development and light use; other Linux distros are courtesy. |
| **CPU** | 64-bit x86 with **AVX2** is strongly recommended for RandomX performance. More and faster cores mean more hashrate. |
| **RAM** | **~2.3 GB free** for RandomX *fast mode* (a 2080 MB dataset + 256 MB cache), plus ~2 MB of L3 cache per mining thread. **4 GB+** recommended. |
| **Privileges** | `root` (the script installs packages and tunes the kernel — run it with `sudo`). |
| **Network** | The worker must reach your pool / stack host on its Stratum port (Pithead uses **3333**). Workers run on a trusted LAN and do **not** need Tor. |

> 📐 **Full sizing guidance** — minimum vs. recommended specs and the per-CPU tuning profiles — is in
> **[Hardware Requirements](hardware.md)**. The **stack host** these workers connect to is sized
> separately in [Pithead's hardware guide](https://github.com/p2pool-starter-stack/pithead/blob/main/docs/hardware.md).

You don't need to install build dependencies yourself — RigForge installs the toolchain (`cmake`,
`libuv`, `hwloc`, …) for you on first run. You only need `git` to clone the repo.

---

## 2. Get the code

```bash
git clone https://github.com/p2pool-starter-stack/rigforge.git
cd rigforge
chmod +x rigforge.sh
```

Have your **pool / stack host or IP** ready — for a Pithead stack, that's the stack machine's
address (the worker connects to its proxy on port `3333`). You do **not** need a wallet address: with
Pithead the stack handles payouts centrally.

---

## 3. Run setup

```bash
sudo ./rigforge.sh
```

`setup` is the default command and is safe to re-run. On a fresh machine it walks through:

1. **Dependencies.** Installs the build toolchain and runtime libraries for your OS.
2. **First-run config.** If there's no `config.json`, it asks for the one thing it needs — your
   **pool / stratum host or IP** — and writes a minimal config. (You can also pre-create one; see
   [Configuration](configuration.md).)
3. **Build.** Clones and compiles XMRig from source, pinned to a known version/commit and patched to
   your `DONATION` level. Build output is captured to a logfile.
4. **Hardware tuning.** Detects your CPU and writes a matching XMRig config (NUMA, ASM, thread layout,
   MSR). See [How It Works](tuning.md).
5. **Kernel tuning (Linux only).** Configures **HugePages** (1 GB and 2 MB), MSR access, `hugetlbfs`
   mounts, and memlock limits. The GRUB change requires a **reboot**.
6. **Service.** Installs and enables the `xmrig` systemd service with a `cpupower` performance
   governor and log rotation.

Re-running `setup` is **idempotent**: it skips the (slow) recompile when the pinned XMRig is already
built, and it won't duplicate the kernel/limits edits. To rebuild only when the pinned version
changed, use [`upgrade`](operations.md#commands).

---

## 4. Reboot (Linux only)

To apply HugePages and the other kernel tuning, a reboot is **required** on Linux — the script tells
you when:

```bash
sudo reboot
```

After the reboot the `xmrig` service starts automatically. (macOS needs no reboot.)

---

## 5. Verify it's mining

```bash
sudo systemctl status xmrig      # service should be active (running)
sudo journalctl -u xmrig -f      # live logs — watch for accepted shares
```

Confirm the optimizations applied:

```bash
grep Huge /proc/meminfo                         # HugePages_Total should be non-zero
grep -i msr <WORKER_ROOT>/xmrig.log             # MSR mod applied (no errors)
```

`<WORKER_ROOT>` is `data/worker` inside the repo by default. If you see MSR errors, you may need to
**disable Secure Boot** in your BIOS/UEFI — see [Operations › Troubleshooting](operations.md#troubleshooting).

---

## Next steps

- [Configuration](configuration.md) — every config key, and the XMRig worker template.
- [Operations & Maintenance](operations.md) — the command reference, logs, upgrades, troubleshooting.
- [Pithead Integration](pithead-integration.md) — how the dashboard discovers and reads each worker.
