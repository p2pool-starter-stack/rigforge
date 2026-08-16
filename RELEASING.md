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
   sudo bash tests/e2e-real.sh control     # the writable control path (#236) against real systemd: enable, POST a change, poll to applied, revert
   sudo bash tests/e2e-real.sh upgrade     # the remote-upgrade chain (#308/#322) with REAL git: noop + refused-tag rollback legs, plus a mandatory forward leg that auto-derives the previous real release tag -> current and proves it, then reverts (skip with a reason: E2E_UPGRADE_SKIP_REASON="...")
   sudo bash tests/e2e-real.sh perf        # offline bench vs the committed per-host baseline + best-ever history (the release perf gate)
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

   Review it, then complete the promotion with a **fast-forward push** so `main` lands on `develop`'s
   release commit *exactly* — same sha, not just the same tree — and stays linear. GitHub closes the PR
   as merged once its commits are reachable from `main`:

   ```bash
   git fetch origin
   git merge-base --is-ancestor origin/main origin/develop \
     || { echo "NOT a fast-forward — main has commits develop lacks; back-merge first (see below)"; exit 1; }
   git push origin develop:main   # fast-forward; --admin-style bypass applies to the protected branch
   ```

   > **Don't finish this with the merge button.** Neither `gh pr merge` mode gives a fast-forward.
   > `--merge` always writes a *merge commit* (every past "promote via merge" on `main` — `23fcd27`,
   > `22dd8f2`, `9b04a37` — has two parents), so the tag would sit on that commit rather than on
   > develop's release commit, and `main` would gain a commit `develop` lacks, breaking the invariant
   > below one commit per release.
   >
   > **And never promote with `--rebase`.** It *rebases* develop's commits onto `main`, minting new shas —
   > so `main` ends up carrying **twins** of commits `develop` still holds under their original shas, and
   > the two branches share no recent ancestry. That defeats the very goal of putting the tag on
   > develop's release commit (the tag lands on the twin, which only shares the *tree*), and it makes
   > every later promotion PR come back `CONFLICTING`, needing a hand-built reconcile commit. It drifted
   > to 37 twin commits over three releases before being healed in `de4e781`; `cfd92fa` and `60aa883` are
   > the reconcile commits it cost. The invariant to preserve is **`main` is always an ancestor of
   > `develop`** — verify with `git merge-base --is-ancestor origin/main origin/develop` before promoting.
   > If a hotfix ever lands directly on `main`, back-merge it (`git merge origin/main` on `develop`) to
   > restore the invariant before the next release.

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
- pulls that version's section from [`CHANGELOG.md`](./CHANGELOG.md) as the release notes,
- creates the GitHub Release as a draft. Review the generated notes and bundles, then click
  Publish (pre-1.0 `0.x` tags are marked pre-release; `1.0.0`+ are full releases).

After a rig is re-tagged, record its benchmark for the release
(`E2E_PERF_TAG=vX.Y.Z E2E_PERF_RECORD=1 sudo bash tests/e2e-real.sh perf` on the rig) and commit
the updated `tests/perf-baselines/` files — the per-release history is what lets the perf gate
catch slow drift across releases (see `tests/perf-baselines/README.md`). In practice that means
miner-0 every time, since the release gate itself always runs there (see
[`tests/README.md`](./tests/README.md#the-shared-rig-miner-0)); the rest of the fleet isn't re-tagged
on every release, so its baselines are only as fresh as the last time each rig was actually
touched. `tests/perf-baselines/` legitimately carries gaps between releases for rigs that went
untouched — it is not a promise that every rig has an entry for every tag. The recording is also
the per-rig perf gate (#214): it judges against the committed baseline and best-ever history
before writing, refuses to record a regressed number (fix it, or consciously override with
`E2E_PERF_FORCE=1`), so a failed rig means investigate before calling it healthy. Once a rig's
baseline is merged, reset its copy (`sudo git checkout -- tests/perf-baselines/` in
`/opt/rigforge`): the recording dirties the rig's checkout, and the *next* release's
`git checkout <tag>` aborts on exactly those files (this bit both the v1.4.0 and v1.5.0 deploys).

To verify a downloaded bundle: `sha256sum -c SHA256SUMS` (see
[SECURITY.md › Release integrity](./SECURITY.md#release-integrity)).

> The release is created as a draft so a human reviews it before it goes public, a deliberate gate
> for a tool that installs a root miner. Drop `--draft` from `release.yml` to auto-publish on tag instead.

## Notes

- Keep `VERSION` and the latest `CHANGELOG.md` heading in lock-step; the test suite checks `VERSION`
  is valid SemVer.
- `VERSION` is also surfaced at runtime: `rigforge.sh version` (or `--version` / `-v`) reads it, so a
  release tag, the changelog heading, and what the script reports all stay in agreement.
