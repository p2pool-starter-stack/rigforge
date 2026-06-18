---
name: Bug report
about: Something went wrong while setting up or running RigForge
title: ''
labels: bug
assignees: ''
---

## What happened

A clear description of the bug — what you expected and what actually happened.

## Environment

- **OS / version:** (e.g. Ubuntu 22.04, Debian 12, macOS 14)
- **CPU:** (e.g. AMD Ryzen 9 7950X3D, EPYC 7402)
- **RigForge commit:** (output of `git rev-parse --short HEAD`)
- **Pool / stack:** (Pithead, or another RandomX pool)

## Steps to reproduce

1.
2.
3.

## Logs

Relevant output from the setup script and/or the miner. On Linux:

```bash
sudo journalctl -u xmrig --no-pager | tail -n 50
```

<details>
<summary>Logs</summary>

```text
paste logs here
```

</details>

## Additional context

Anything else that might help (BIOS/Secure Boot settings, HugePages state from
`grep Huge /proc/meminfo`, etc.).
