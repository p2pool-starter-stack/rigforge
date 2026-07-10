# Releasing RigForge

RigForge follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is
tracked in [`VERSION`](./VERSION) and the history in [`CHANGELOG.md`](./CHANGELOG.md).

## Versioning

- MAJOR: incompatible `config.json` / CLI / behavior changes.
- MINOR: new, backwards-compatible functionality.
- PATCH: backwards-compatible fixes.

From `1.0.0` on, the `config.json` and CLI surface is stable, so a breaking change bumps MAJOR. (Pre-1.0
`0.x` releases could break the interface between minor versions while it settled.)

## Cutting a release

Work lands on `develop` (the integration branch); a release is the point where `develop` is
promoted to `main` and tagged. The steps below build the release commit on `develop`, merge it to
`main`, and tag from `main`.

1. Ensure `develop` is green: `make test` (and `make test-e2e` if Docker is available).
2. Full real-hardware e2e (the release gate). CI exercises everything it can (lint, the
   dependency-free suite, the Docker `/etc` e2e, the coverage gate), but it can't compile XMRig,
   reserve HugePages, write MSRs, set the governor, or actually hash. So on a real Linux rig, run
   the genuine deploy end to end and assert each step:

   ```bash
   sudo bash tests/e2e-real.sh provision   # real deps + XMRig build + tuning + kernel tuning + service
   sudo reboot                             # HugePages (1G + GRUB cmdline) take effect on boot; reconnect
   sudo bash tests/e2e-real.sh verify      # doctor (HugePages/MSR/governor/service) + bench (real H/s) + a short tune + a live auto-tune pass
   sudo bash tests/e2e-real.sh teardown    # uninstall + assert a clean revert
   ```

   When a live Pithead stack is reachable, also run the worker↔stack contract gate (stack on its
   latest release tag — record `pithead version` in the run log). It asserts the mining round-trip,
   the `:8080` API contract, stratum auth (pass `E2E_STRATUM_PASS` if the stack uses one), dashboard
   visibility (`E2E_DASH_URL`), and that the sister API does not shave hashrate under polling load:

   ```bash
   PITHEAD_URL=gouda.lan:3333 sudo -E make e2e-pithead
   ```

   Both gates carry the standardized performance checks (see `tests/README.md` › Performance
   testing): `e2e-real`'s `perf` phase compares the offline bench against the committed per-host
   baseline in `tests/perf-baselines/`, and `e2e-pithead`'s `api-impact` phase proves the sister
   API doesn't shave live hashrate. A perf regression fails the gate — investigate or consciously
   re-record the baseline before tagging.

   ```bash
   ```

   Each phase must report `E2E-REAL (<phase>): PASS`. This proves a release bundle actually
   builds, tunes, and hashes on real hardware, which the suites can't since they all stub XMRig.
   - Put a real, reachable pool in `config.json` first. Without one, `setup` writes an unroutable
     placeholder and `verify` fails the connect + share-submission round-trip. That round-trip is
     mandatory, since proving the rig really mines is the whole point of the gate. Point `pools[0].url` at
     a real low-difficulty pool you control (e.g. the stack's test pool). For a deliberate offline smoke
     run with no pool on hand, set `E2E_ALLOW_OFFLINE_POOL=1` to downgrade it to an explicit skip.
   - Quick subset: `make smoke` (bench-only) is the fast version when you just need to confirm a
     built worker still hashes; the full `e2e-real` flow above supersedes it for a real release.
   - Kept out of CI on purpose (a real build + HugePages + mining are flaky by nature and against
     Actions' ToS); it's a manual pre-tag gate the releaser runs.
3. In [`CHANGELOG.md`](./CHANGELOG.md), move the `## [Unreleased]` entries under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading, then leave a fresh empty `## [Unreleased]` above it.
4. Bump [`VERSION`](./VERSION) to `X.Y.Z`.
5. Commit the two together on `develop`:

   ```bash
   git commit -am "release: vX.Y.Z"
   git push origin develop
   ```

6. Promote `develop` to `main` **through a pull request** — `main` is a protected release branch, so the
   promotion goes through a reviewable PR (its own gate + audit trail), not a direct push:

   ```bash
   gh pr create --base main --head develop --title "release: vX.Y.Z" \
     --body "Promote develop to main for the vX.Y.Z release."
   ```

   Review and merge it. Keep `main` linear with a **fast-forward (rebase) merge** so the tag sits on the
   same commit as `develop`'s release commit:

   ```bash
   gh pr merge --rebase --admin   # fast-forward main to develop; --admin lets the releaser merge
   ```

7. Tag and push from `main` (annotated tag, matching `VERSION`) once the PR is merged:

   ```bash
   git checkout main && git pull --ff-only origin main
   git tag -a vX.Y.Z -m "RigForge vX.Y.Z"
   git push origin main --follow-tags
   ```

Pushing the tag triggers the release pipeline
([`.github/workflows/release.yml`](./.github/workflows/release.yml)), which:

- verifies the tag matches `VERSION` (the build fails otherwise),
- packages the deploy bundle (`rigforge.sh`, `util/`, `systemd/`, `config.minimal.json`,
  `config.reference.json`, `README.md`, `docs/`, `images/`, `LICENSE`, `VERSION`) as
  `rigforge-vX.Y.Z.zip` and `.tar.gz` (`tests/`, `.github/`, and other dev files are excluded),
- generates `SHA256SUMS` for the artifacts,
- signs `SHA256SUMS` with minisign (`SHA256SUMS.minisig`; skipped with a notice when the
  `MINISIGN_SECRET_KEY` secret is absent, e.g. on forks) — check the draft has the `.minisig` asset,
- pulls that version's section from [`CHANGELOG.md`](./CHANGELOG.md) as the release notes,
- creates the GitHub Release as a draft. Review the generated notes and bundles, then click
  Publish (pre-1.0 `0.x` tags are marked pre-release; `1.0.0`+ are full releases).

To verify a downloaded bundle: `minisign -Vm SHA256SUMS -p minisign.pub` (see
[SECURITY.md › Release signing](./SECURITY.md#release-signing)), then `sha256sum -c SHA256SUMS`.

> The release is created as a draft so a human reviews it before it goes public, a deliberate gate
> for a tool that installs a root miner. Drop `--draft` from `release.yml` to auto-publish on tag instead.

## Notes

- Keep `VERSION` and the latest `CHANGELOG.md` heading in lock-step; the test suite checks `VERSION`
  is valid SemVer.
- `VERSION` is also surfaced at runtime: `rigforge.sh version` (or `--version` / `-v`) reads it, so a
  release tag, the changelog heading, and what the script reports all stay in agreement.
