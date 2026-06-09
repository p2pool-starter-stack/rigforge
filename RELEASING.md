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
2. **Bench smoke check (real hardware).** On a **real Linux rig**, run `make smoke` (or
   `SMOKE_RUN_SETUP=1 make smoke` to build first). This runs the actual worker through `xmrig --bench`
   — fully offline (no pool, no wallet, no network) — and gates the release on the **binary actually
   starting and hashing** without a memory/config error. The regular suites stub XMRig, so they can't
   catch a broken build, a dataset/HugePages/MSR allocation failure, or a malformed generated
   `config.json`; this is the only step that does. It must report `SMOKE CHECK: PASS`.
   - **Linux-only for full effect:** macOS builds and configures but does no kernel tuning, so a mac
     bench validates build → config → hash but won't exercise HugePages/MSR.
   - Kept **out of CI** on purpose (a real build + HugePages are flaky-by-nature and live mining is
     against Actions' ToS) — it's a manual pre-tag gate the releaser runs.
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
