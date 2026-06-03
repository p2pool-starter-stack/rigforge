# Security Policy

RigForge compiles XMRig from upstream source and applies privileged system
tuning — it runs as root, configures kernel HugePages and MSR access, and
installs a `systemd` service. Because of that footprint, we take security
reports seriously and appreciate responsible disclosure.

## Supported versions

Only the latest `main` is supported. Please reproduce against current `main`
before reporting.

| Version        | Supported |
|----------------|-----------|
| `main` (latest)| ✅        |
| older commits  | ❌        |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Instead, use GitHub's private vulnerability reporting on this repository:

1. Go to the **Security** tab.
2. Click **Report a vulnerability** (under *Security Advisories*).
3. Describe the issue, the affected version/commit, and steps to reproduce.

We'll acknowledge your report, investigate, and keep you updated on a fix and
disclosure timeline. Thanks for helping keep RigForge users safe.
