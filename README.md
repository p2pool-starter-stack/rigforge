# 🔥 RigForge

### Provision a hardware-tuned XMRig miner in one command.

RigForge turns a fresh Ubuntu/Debian (or macOS) machine into a fully tuned [XMRig](https://github.com/xmrig/xmrig)
mining worker — it installs the toolchain, compiles XMRig from source, applies kernel- and CPU-level
tuning for maximum RandomX hashrate, and runs it as a managed service. You point it at a pool and
walk away.

It's built as the companion miner for the
**[Pithead](https://github.com/p2pool-starter-stack/pithead)** — connect
as many RigForge workers as you like to your stack's single endpoint — but it works against **any
RandomX Stratum pool**.

> **RigForge is not a custom miner.** It compiles stock, upstream XMRig and wraps it in the setup,
> hardware tuning, and service management that are otherwise fiddly to get right by hand.

---

## ✨ What it does

- **Automated setup** — installs build dependencies (`cmake`, `libuv`, `hwloc`, …) and compiles
  XMRig from the latest source.
- **Hardware-aware tuning** — detects the CPU (e.g. AMD EPYC, Ryzen X3D) and applies a matching
  performance profile (NUMA binding, ASM, thread layout, MSR registers).
- **Kernel & system tuning (Linux)** — topology-aware HugePages (1 GB and 2 MB), MSR access for
  hardware-prefetcher control, and `hugetlbfs` mounts + memlock limits.
- **Service management (Linux)** — runs XMRig as a `systemd` service with a `cpupower` performance
  governor and automatic log rotation.
- **Interactive config** — if no config exists, it asks for the one thing it needs: your pool /
  stack hostname or IP.

---

## 🛠 Hardware Requirements

A worker is where the actual RandomX hashing happens, so its **CPU is what determines your
hashrate**. The requirements themselves are modest — most of the performance comes from tuning,
which this script applies for you.

| Resource | Requirement | Recommended |
|---|---|---|
| **CPU** | 64-bit x86 with **AVX2** support | A high-core-count CPU (e.g. AMD Ryzen / EPYC) — more and faster cores mean more hashrate. The script auto-detects the CPU and applies a matching profile. |
| **RAM** | **~2.3 GB free** for RandomX *fast mode* — a 2080 MB dataset + 256 MB cache — plus **~2 MB of L3 cache per mining thread** | **4 GB+**; budget more on high-core-count CPUs |
| **HugePages** | Optional, but a significant speedup | The script configures **2 MB and 1 GB** HugePages (plus MSR access) for you — Linux only, and it needs a **reboot** to take effect |
| **OS** | Ubuntu 22.04+, Debian 12, or macOS | — |
| **Network** | Reach your pool / stack host on its Stratum port (Pithead uses **3333**) | Local network; workers do **not** need Tor |

> RandomX *light mode* needs only 256 MB of RAM but is far slower — **fast mode** (the default) is
> what you want for real hashrate. These memory figures are from XMRig's own
> [RandomX optimization guide](https://xmrig.com/docs/miner/randomx-optimization-guide).

### Miner version

There's **no required XMRig version** — RigForge always builds the latest upstream XMRig, and any
RandomX-capable XMRig (5.0+, 2019) speaks the standard Stratum protocol that Pithead's proxy and
P2Pool accept. The stack's component versions don't dictate a miner version.

---

## 🔌 Connecting to a pool or stack

RigForge points XMRig at a single **Stratum endpoint**. With the
[Pithead](https://github.com/p2pool-starter-stack/pithead) that's the
stack's `xmrig-proxy` on port **3333** — the stack handles pool selection, payouts, and the
P2Pool/XvB split centrally, so the worker config stays minimal and you **never put a wallet address
in it**.

During setup RigForge asks for your **stack/pool hostname or IP** and writes it into `config.json`
(the `P2POOL_NODE_HOSTNAME` field). The pool/stack host must be an IP or a DNS-resolvable hostname
(for a stable LAN address, set a DHCP reservation or static IP).

To connect any XMRig instance **by hand instead**, this is the whole pool config:

```json
{
    "pools": [
        {
            "url": "YOUR_STACK_IP:3333",
            "user": "my-rig-01"
        }
    ]
}
```

- The `user` field is just a label for the rig — use its hostname so you can tell workers apart on the dashboard.
- The endpoint must be reachable from the worker; if the host has a firewall, allow the Stratum port (3333) on the LAN.
- Workers talk to the pool over plain Stratum on your local network — they do **not** need Tor.

---

## 🔭 Worker API (Pithead integration)

Each worker exposes XMRig's HTTP API so [Pithead](https://github.com/p2pool-starter-stack/pithead)'s
dashboard can show per-rig stats (hashrate, shares, uptime). RigForge configures the API to match
Pithead's contract exactly, so no per-worker setup is needed stack-side:

| Setting | Value | Why |
|---|---|---|
| **Port** | `8080` | Pithead reads `GET http://<rig>:8080/1/summary`; the port is fixed dashboard-side. |
| **Bind** | `0.0.0.0` (all interfaces) | The dashboard polls each worker from the stack host over the LAN. |
| **Mode** | `restricted: true` (read-only) | The API can be **read** but not used to **control** the miner remotely. |
| **Auth token** | the rig's hostname (or `ACCESS_TOKEN` in `config.json`) | Pithead authenticates as `Bearer <rig name>`, so the token must equal the rig name (or be unset). |

Pithead discovers workers from the stratum proxy's connection list (the pool `user` label, which is
the rig name) — there's nothing to register stack-side. Workers run on a **trusted LAN** and need no
Tor.

> ⚠️ **Don't set a random/custom API token** for a Pithead-connected worker: the dashboard
> authenticates as `Bearer <rig name>`, so a decoupled token means it can't read the worker. A custom
> token, a non-`8080` API port, or a worker reachable at a different host than the one it connects
> from all require matching configuration on **both** sides — those are later milestones
> (RigForge #21/#23; Pithead #171/#172).

---

## 🚀 Deployment

On the machine you want to turn into a miner:

```bash
git clone https://github.com/p2pool-starter-stack/rigforge.git
cd rigforge
chmod +x rigforge.sh
sudo ./rigforge.sh
```

The script needs root to install packages and tune the system. On first run it creates a minimal
`config.json` interactively (you provide your stack/pool hostname); you can also pre-create one from
[`config.json.template`](./config.json.template):

```json
{
    "HOME_DIR": "DYNAMIC_HOME",
    "DONATION": 1,
    "WORKER_CONFIG_FILE": "./worker-config/example-config.json.template",
    "P2POOL_NODE_HOSTNAME": "YOUR_STACK_IP_OR_HOSTNAME"
}
```

- `P2POOL_NODE_HOSTNAME` — the only field you must set: your stack/pool host.
- `HOME_DIR` — where worker files live. `DYNAMIC_HOME` defaults to `data/` inside this folder.
- `WORKER_CONFIG_FILE` — the XMRig config template to tune from; the default suits most setups.
- `DONATION` — XMRig donate level (patched into the build).

### Reboot (Linux only)

To apply HugePages and other kernel tuning, a reboot is **required** on Linux — the script tells you
when. After the reboot the `xmrig` service starts automatically. (macOS needs no reboot.)

```bash
sudo reboot
```

---

## 🛠️ Maintenance & logging (Linux)

```bash
sudo systemctl status xmrig     # service status
sudo systemctl stop xmrig       # stop the miner
sudo systemctl start xmrig      # start the miner
sudo journalctl -u xmrig -f     # live logs
```

- **Log file:** `<WORKER_ROOT>/xmrig.log` (e.g. `data/worker/xmrig.log`).
- **Rotation:** a `logrotate` policy is installed automatically to compress and archive logs.

---

## 🔍 Verification (Linux)

After rebooting, confirm the optimizations applied:

**HugePages**

```bash
grep Huge /proc/meminfo
```

`HugePages_Total`, `HugePages_Free`, and `Hugepagesize` should be non-zero and match what the script
configured.

**MSR (Model-Specific Registers)**

```bash
grep -i msr <WORKER_ROOT>/xmrig.log
```

If you see MSR errors, you may need to **disable Secure Boot** in your BIOS/UEFI.

---

## Hardware sizing for the stack host

RigForge sizes the **miner**. The **stack host** these workers connect to (Monero node, P2Pool,
proxy, dashboard) is sized separately — see Pithead's
[Hardware Requirements](https://github.com/p2pool-starter-stack/pithead/blob/main/docs/hardware.md).

---

## 🧪 Testing & development

RigForge ships a dependency-free test suite plus an opt-in container end-to-end run. Both mirror the
CI jobs, so `make test` locally is what CI checks.

```bash
make lint        # shellcheck the script, utilities, and test scripts
make test        # lint + the dependency-free suite (runs on macOS or Linux, no Docker)
make test-e2e    # full end-to-end in disposable Linux containers (needs Docker)
```

**What `make test` covers** — it sources `rigforge.sh` and exercises its functions in isolation, with
every external/privileged command (`git`, `make`, `cmake`, `sudo`, `systemctl`, `modprobe`,
`apt-get`, …) and all hardware detection (`uname`, `lscpu`, `sysctl`, `nproc`, `hostname`) replaced by
fakes on `PATH`. Because the hardware is faked, **one run on any machine simulates every supported
platform** — it asserts the generated XMRig config for the AMD EPYC, Ryzen X3D, generic-Linux and
macOS profiles, plus config parsing, `DONATION` validation, the `.local` hostname handling, and a full
stubbed deployment run (executed twice to prove idempotency).

**What `make test-e2e` adds** — it runs the *real* `rigforge.sh` end-to-end inside a throwaway
`ubuntu` container (RigForge's documented Linux target, `linux/amd64`), against a real, disposable
`/etc`. This validates the Linux-only deploy path with genuine tools — GNU `sed`, `envsubst`, the
`fstab`/`limits`/GRUB edits and their idempotency — which can't run natively on a macOS host. Only the
heavy XMRig compile and the package install are stubbed. It skips cleanly if Docker isn't available.

No XMRig binary is compiled by the tests — the heavy native build is stubbed; the suite asserts the
*orchestration* (clone → patch `donate.h` → cmake → make) and the generated configuration instead.

---

## 📝 License

Provided "as-is" under the [MIT License](./LICENSE).
