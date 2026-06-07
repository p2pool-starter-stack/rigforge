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
2. In [`CHANGELOG.md`](./CHANGELOG.md), move the `## [Unreleased]` entries under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading, then leave a fresh empty `## [Unreleased]` above it.
3. Bump [`VERSION`](./VERSION) to `X.Y.Z`.
4. Commit the two together:
   ```bash
   git commit -am "release: vX.Y.Z"
   ```
5. Tag and push (annotated tag, **matching `VERSION`**):
   ```bash
   git tag -a vX.Y.Z -m "RigForge vX.Y.Z"
   git push origin main --follow-tags
   ```

That's it — pushing the tag triggers the **release pipeline**
([`.github/workflows/release.yml`](./.github/workflows/release.yml)), which:

- **verifies** the tag matches `VERSION` (the build fails otherwise),
- packages the deploy bundle (`rigforge.sh`, `util/`, `worker-config/`, `systemd/`,
  `config.json.template`, `README.md`, `docs/`, `LICENSE`, `VERSION`) as `rigforge-vX.Y.Z.zip` **and**
  `.tar.gz` — `tests/`, `.github/`, and other dev files are excluded,
- generates `SHA256SUMS` for the artifacts,
- pulls that version's section from [`CHANGELOG.md`](./CHANGELOG.md) as the release notes,
- publishes the GitHub Release (0.x tags are marked pre-release).

To verify a downloaded bundle: `sha256sum -c SHA256SUMS`.

## Notes

- Keep `VERSION` and the latest `CHANGELOG.md` heading in lock-step — the test suite checks `VERSION`
  is valid SemVer.
- Surfacing the version at runtime (e.g. a `rigforge.sh --version` / `version` subcommand) is tracked
  separately under the command-surface work (#11).
