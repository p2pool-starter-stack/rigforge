# Releasing RigForge

RigForge follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is
tracked in [`VERSION`](./VERSION) and the history in [`CHANGELOG.md`](./CHANGELOG.md).

## Versioning

- **MAJOR** — incompatible `config.json` / CLI / behaviour changes.
- **MINOR** — new, backwards-compatible functionality.
- **PATCH** — backwards-compatible fixes.

Pre-1.0 (`0.x`), minor versions may include breaking changes while the interface settles.

## Cutting a release

1. Ensure `main` is green: `make test` (and `make test-e2e` if Docker is available).
2. **Full real-hardware e2e (the release gate).** CI exercises everything it can (lint, the
   dependency-free suite, the Docker `/etc` e2e, the coverage gate) — but it can't compile XMRig,
   reserve HugePages, write MSRs, set the governor, or actually hash. So on a **real Linux rig**, run
   the genuine deploy end to end and assert each step:
   ```bash
   sudo bash tests/e2e-real.sh provision   # real deps + XMRig build + tuning + kernel tuning + service
   sudo reboot                             # HugePages (1G + GRUB cmdline) take effect on boot; reconnect
   sudo bash tests/e2e-real.sh verify      # doctor (HugePages/MSR/governor/service) + bench (real H/s) + a short tune
   sudo bash tests/e2e-real.sh teardown    # uninstall + assert a clean revert
   ```
   Each phase must report `E2E-REAL (<phase>): PASS`. This is what proves a release bundle actually
   builds, tunes, and hashes on real hardware — the suites all stub XMRig and can't.
   - **Put a real, reachable pool in `config.json` first.** Without one, `setup` writes an unroutable
     placeholder and `verify` **skips** the connect + share-submission round-trip (it can't run against an
     unreachable pool). To prove the full mining round-trip before tagging, point `pools[0].url` at a
     real low-difficulty pool you control (e.g. the stack's test pool).
   - **Quick subset:** `make smoke` (bench-only) is the fast version when you just need to confirm a
     built worker still hashes; the full `e2e-real` flow above supersedes it for a real release.
   - Kept **out of CI** on purpose (a real build + HugePages + mining are flaky-by-nature and against
     Actions' ToS) — it's a manual pre-tag gate the releaser runs.
3. In [`CHANGELOG.md`](./CHANGELOG.md), move the `## [Unreleased]` entries under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading, then leave a fresh empty `## [Unreleased]` above it.
4. Bump [`VERSION`](./VERSION) to `X.Y.Z`.
5. Commit the two together:
   ```bash
   git commit -am "release: vX.Y.Z"
   ```
6. Tag and push (annotated tag, **matching `VERSION`**):
   ```bash
   git tag -a vX.Y.Z -m "RigForge vX.Y.Z"
   git push origin main --follow-tags
   ```

That's it — pushing the tag triggers the **release pipeline**
([`.github/workflows/release.yml`](./.github/workflows/release.yml)), which:

- **verifies** the tag matches `VERSION` (the build fails otherwise),
- packages the deploy bundle (`rigforge.sh`, `util/`, `systemd/`, `config.json.template`,
  `config.advanced.example.json`, `README.md`, `docs/`, `images/`, `LICENSE`, `VERSION`) as
  `rigforge-vX.Y.Z.zip` **and** `.tar.gz` — `tests/`, `.github/`, and other dev files are excluded,
- generates `SHA256SUMS` for the artifacts,
- pulls that version's section from [`CHANGELOG.md`](./CHANGELOG.md) as the release notes,
- publishes the GitHub Release (0.x tags are marked pre-release).

To verify a downloaded bundle: `sha256sum -c SHA256SUMS`.

## Notes

- Keep `VERSION` and the latest `CHANGELOG.md` heading in lock-step — the test suite checks `VERSION`
  is valid SemVer.
- `VERSION` is also surfaced at runtime: `rigforge.sh version` (or `--version` / `-v`) reads it, so a
  release tag, the changelog heading, and what the script reports all stay in agreement.
