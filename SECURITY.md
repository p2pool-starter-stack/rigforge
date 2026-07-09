# Security Policy

RigForge compiles XMRig from upstream source and applies privileged system
tuning. It runs as root, configures kernel HugePages and MSR access, and
installs a `systemd` service. Given that footprint, we take security reports
seriously and appreciate responsible disclosure.

## What RigForge exposes (and what it doesn't)

No telemetry, ever. RigForge never phones home. There is no analytics, no
version ping, and no usage beacon. The only outbound connections it makes are to
*your* pool, to the pinned XMRig source on GitHub (a shallow clone whose commit is
verified against a hardcoded hash before it's built), and to your distro's package
mirrors. The XMRig developer donation defaults to 1%, XMRig's own upstream
default rather than a RigForge markup. It goes to the XMRig project's address (RigForge
substitutes no wallet of its own into the mining path), and is set to 0 with
`"DONATION": 0` in `config.json`.

The worker stats API (`:8080`). Each worker runs XMRig's HTTP API so a
[Pithead](https://github.com/p2pool-starter-stack/pithead) dashboard can read
per-rig stats over the LAN. Know exactly what it is:

- Read-only. It's configured `restricted: true`, so the API can be read but
  never used to control the miner (no remote pause, config change, or shutdown).
- Open by default. Reads need no token out of the box, matching Pithead's
  stock no-auth probe. Set `ACCESS_TOKEN` in `config.json` to require a
  `Bearer` token on every read instead.
- LAN-bound by default. It binds `0.0.0.0:8080` because the Pithead dashboard
  polls each worker from the stack host. The data it can return is mining stats:
  hashrate, the configured pool URL, the worker label, and the CPU model.

Not running Pithead? Nothing else needs the port; `tune` and `doctor` read
the API over `127.0.0.1`. So if you mine solo or to a public pool, you can firewall
`:8080` off entirely without losing anything:

```bash
sudo ufw deny 8080/tcp          # block it outright …
sudo ufw allow from <DASHBOARD_IP> to any port 8080 proto tcp   # … or scope it to one host
```

## Supply chain & secret scanning

RigForge is built to be reproducible and tamper-evident:

- Pinned, verified inputs. XMRig is cloned at a pinned commit and verified against a hardcoded
  hash before it builds; GitHub Actions are SHA-pinned; CI tool installs (shellcheck, shfmt, gitleaks)
  are version- and checksum-verified. Dependabot keeps the action pins current and flags advisories.
- Secret scanning. [gitleaks](https://github.com/gitleaks/gitleaks) scans the full git history on
  every push and PR, and runs as a pre-commit hook, so credentials can't slip into the repo.
- Workflow auditing. [zizmor](https://github.com/zizmorcore/zizmor) static-audits the CI workflows
  for template injection, over-broad token scopes, and credential persistence; jobs run with a
  least-privilege, read-only `GITHUB_TOKEN` by default.

## Supported versions

Only the latest `main` is supported. Please reproduce against current `main`
before reporting.

| Version        | Supported |
|----------------|-----------|
| `main` (latest)| ✅        |
| older commits  | ❌        |

## Reporting a vulnerability

Please do not open a public issue for security problems.

Instead, use GitHub's private vulnerability reporting on this repository:

1. Go to the **Security** tab.
2. Click **Report a vulnerability** (under *Security Advisories*).
3. Describe the issue, the affected version/commit, and steps to reproduce.

We'll acknowledge your report, investigate, and keep you updated on a fix and
disclosure timeline. Thanks for helping keep RigForge users safe.
