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

The optional writable control path (`:8082`, `"control": "enabled"` — **off by default**, #236) is
the one endpoint that accepts writes, and it is fail-closed by construction. Enabling it requires
*both* a Bearer `ACCESS_TOKEN` and an `api_allow_from` source pin, or setup refuses to start it —
the stack host is the only trusted writer, so the miner never accepts a config from a
miner-advertised or arbitrary host. The network receiver is unprivileged (`DynamicUser`) and only
stages a change; a separate root oneshot re-validates it against RigForge's key allowlist (only
operationally-mutable keys — never `ACCESS_TOKEN`, `miner_user`, `HOME_DIR`, or the API/control keys
themselves), writes it durably, and rolls back anything that doesn't come back live. Config is
written by `jq` (values quoted structurally) and the old config is snapshotted to `config-backups/`
first, so a bad or hostile change cannot inject a command, corrupt `config.json`, or lose the
previous config. See [ADR 0001](docs/adr/0001-writable-worker-config-control-path.md).

The control token is write-capable and travels in cleartext (#256). The `Authorization: Bearer`
header rides plain HTTP — the sister and control APIs are python3-stdlib `HTTPServer` with no TLS —
and with the control path enabled that token now grants **writes** (redirect a rig's `pools`, change
its thermal settings). `api_allow_from` scopes *who may connect* (source IP); it does **not** encrypt
the token in flight, so a same-subnet passive sniffer or an ARP-spoof MITM that captures the header
could replay it. The mining LAN is the trust boundary: **isolate it from untrusted devices, treat
`ACCESS_TOKEN` as a secret, and don't enable the control path on a shared or hostile network.** TLS
on the LAN API is intentionally *not* shipped — it adds cert-management burden for a LAN appliance
whose threat model is already "trusted mining subnet," and LAN isolation is the supported posture; if
your environment needs encryption, terminate TLS at a reverse proxy in front of `:8082`/`:8081`.

The control path is a tuning channel, not a safety-removal one (#257). A remote `POST /apply` that
would strip a rig's thermal protection — disabling the `watchdog`, or unsetting / setting an
out-of-band `max_temp_c` — is refused with `400`; only a local `rigforge.sh apply` on the box (the
operator is physically present) can remove thermal protection. Any *allowed* change that touches
`watchdog`/`max_temp_c` is flagged in `:8082/status` `warnings[]` so the dashboard can force an extra
confirmation. So a fat-finger or a captured token cannot silently leave a rig without its thermal cutoff.

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
  are version- and checksum-verified. Dependabot keeps the action pins current and flags advisories,
  and a weekly workflow watches upstream XMRig releases — a new version arrives as a bot-opened,
  build-verified PR (never fetched-and-run; a human merges, the normal gates apply).
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

### Release integrity

Releases ship a `SHA256SUMS` file generated by the release workflow. Verifying it proves the
bundle you downloaded is byte-identical to what CI built from the tagged commit:

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

What it does **not** prove is origin: checksums and bundles live in the same place, so an
attacker who fully controls the GitHub account could regenerate both. Release *signing*
(minisign) existed briefly for that gap and was removed by decision on 2026-07-11: its
protection only materializes for users who pin the public key somewhere outside this repo, and
the key-custody burden wasn't worth it for this project's users, who deploy from git tags. If
that trade ever changes (a real download-based user base), the signing machinery lives in the
git history of `.github/workflows/release.yml` (#137, #205).

For the strongest guarantee available today, deploy from a git checkout at the release tag —
the commit hash is the integrity anchor, and the XMRig source it builds is itself pinned and
commit-verified.

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
