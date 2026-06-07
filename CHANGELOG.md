# Changelog

All notable changes to RigForge are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is in
[`VERSION`](./VERSION); see [`RELEASING.md`](./RELEASING.md) for how a release is cut.

## [Unreleased]

### Added
- Dependency-free test suite, Ubuntu end-to-end harness, and CI (#5).
- Pinned, checksum-verified XMRig build via `XMRIG_VERSION` / `XMRIG_COMMIT` (#18, #2).
- Community-health files: SECURITY policy, CONTRIBUTING guide, issue/PR templates (#16).
- This `VERSION` file, changelog, and documented release process (#3).

### Changed
- XMRig HTTP API on Linux is now read-only (`restricted: true`) while staying LAN-reachable, so
  Pithead can still read per-rig stats at `:8080` (#17, #7).
- Removed the `.local` / Avahi mDNS handling — point workers at an IP or DNS-resolvable hostname (#15, #14).

[Unreleased]: https://github.com/p2pool-starter-stack/rigforge/commits/main
