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
5. Tag and push (annotated tag, matching `VERSION`):
   ```bash
   git tag -a vX.Y.Z -m "RigForge vX.Y.Z"
   git push origin main --follow-tags
   ```
6. Create the GitHub Release from the `vX.Y.Z` tag, pasting that version's `CHANGELOG.md` section as
   the notes.

## Notes

- Keep `VERSION` and the latest `CHANGELOG.md` heading in lock-step — the test suite checks `VERSION`
  is valid SemVer.
- Surfacing the version at runtime (e.g. a `rigforge.sh --version` / `version` subcommand) is tracked
  separately under the command-surface work (#11).
