# Security Policy

RigForge compiles XMRig from upstream source and applies privileged system
tuning. It runs as root, configures kernel HugePages and MSR access, and
installs a `systemd` service. Given that footprint, we take security reports
seriously and appreciate responsible disclosure.

## What RigForge exposes (and what it doesn't)

No telemetry, ever. RigForge never phones home. There is no analytics, no
version ping, and no usage beacon. (`upgrade --check` queries the GitHub releases
API, but only when you run it — nothing is scheduled and nothing else calls it.)
The only outbound connections it makes are to
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

The optional sister API (`:8081`, `"api": "enabled"` — **off by default**) follows the same
posture: read-only by construction (GET only, fixed routes, nothing from a request is executed or
logged), gated by the same `ACCESS_TOKEN`, and served by a single persistent python3-stdlib
process that only ships pre-computed files (`ProtectSystem=strict`, `NoNewPrivileges`, lowest CPU
priority — it can never compete with the miner, and a config it cannot parse is fatal at startup
rather than silently dropping the token). The probe pass that produces those files runs from a
separate idle-priority timer. It additionally serves RigForge's tune/health/power data — still
stats, never a control surface.

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

Bug reports: `rigforge.sh support-bundle` produces a redacted tarball (token and pool password
structurally removed via jq, wallet masked). Redaction covers RigForge's own fields — review the
extracted bundle before posting it anywhere public; a secret pasted into a custom field is yours
to catch.

The sister API server itself runs unprivileged (`DynamicUser=`), reads the config through a
systemd credential rather than owning the 0600 file, compares tokens in constant time, and caps
request-arrival time so a held-open connection can't wedge it. `doctor` calls out the fully-open
posture (no token, no `api_allow_from`) so it can't leave a trusted LAN unnoticed.

### Release signing

Release checksums prove integrity, not origin — an attacker who can swap the release assets can swap
`SHA256SUMS` right alongside them. So the release workflow signs `SHA256SUMS` with
[minisign](https://jedisct1.github.io/minisign/) and uploads the signature as `SHA256SUMS.minisig`.
Because the signature covers the checksum file, every asset listed in it is signed by inclusion —
including any artifact added later.

The public key (also committed as [`minisign.pub`](./minisign.pub) at the repo root — get it from the
repo, not from the release download you are verifying):

```text
MINISIGN_PUBKEY_PLACEHOLDER
```

To verify a release: download the assets plus `SHA256SUMS` and `SHA256SUMS.minisig`, then

```bash
minisign -Vm SHA256SUMS -P "MINISIGN_PUBKEY_PLACEHOLDER"   # or: -p minisign.pub from a repo checkout
sha256sum -c SHA256SUMS --ignore-missing
```

The trusted comment in the signature names the tag (`RigForge vX.Y.Z`), so a signature can't be
replayed onto a different release's checksum file — check it matches the release you downloaded.

Key rotation: if the key is rotated or compromised, a fresh keypair replaces `minisign.pub` and the
key above, the old key stays listed here under a "retired keys" line with its last-valid tag, the
`MINISIGN_SECRET_KEY` Actions secret is updated, and the rotation is called out in the next
release's notes. Old releases stay verifiable against the retired key.

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
