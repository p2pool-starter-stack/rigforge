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
   sudo bash tests/e2e-real.sh watchdog    # the thermal-hold path (#349) against the real sensor and real systemd: lowers max_temp_c below the live reading, runs the verb once, asserts the stop + hold marker + journal evidence, restores on every exit path (skips explicitly when no temperature reading is available)
   sudo bash tests/e2e-real.sh perf        # offline bench vs the committed per-host baseline + best-ever history (the release perf gate)
   sudo bash tests/e2e-real.sh teardown    # uninstall + assert a clean revert
   ```

   When a live Pithead stack is reachable, also run the worker↔stack contract gate (stack on its
   latest release tag — record `pithead version` in the run log). It asserts the mining round-trip,
   the `:8080` API contract, stratum auth (pass `E2E_STRATUM_PASS` if the stack uses one), dashboard
   visibility (`E2E_DASH_URL`), and that the sister API does not shave hashrate under polling load:

   ```bash
   PITHEAD_URL=<stack-host>:3333 sudo -E make e2e-pithead
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

6. Promote `develop` to `main`. Open a pull request first — it carries the review, the CI run and the
   audit trail for the promotion, and `main`'s ruleset requires one:

   ```bash
   gh pr create --base main --head develop --title "release: vX.Y.Z" \
     --body "Promote develop to main for the vX.Y.Z release."
   ```

   Before review, record the PR's exact head in a private local ref. Set `RELEASE_PR` to the number
   printed by `gh pr create`, then give the printed sha to the reviewer. Their verdict must name that
   same sha:

   ```bash
   : "${RELEASE_PR:?set RELEASE_PR to the promotion PR number}"
   repo=$(gh api repos/{owner}/{repo} --jq .full_name)
   reviewed_commit=$(gh api "repos/$repo/pulls/$RELEASE_PR" --jq .head.sha)
   git update-ref refs/rigforge/release-candidate "$reviewed_commit" \
     || { echo "cannot record the reviewed commit — refusing to continue"; exit 1; }
   printf 'Review release candidate %s\n' "$reviewed_commit"
   ```

   After a PASS at that sha, land it with a **fast-forward push** rather than the merge button, so
   `main` ends up on the reviewed release commit *exactly* — same sha, not merely the same tree — and
   stays linear. GitHub closes the PR as merged once its commits are reachable from `main`:

   ```bash
   release_commit=$(git rev-parse refs/rigforge/release-candidate)
   git fetch origin \
     || { echo "fetch failed — refusing to promote cached refs"; exit 1; }
   test "$(git rev-parse refs/remotes/origin/develop)" = "$release_commit" \
     || { echo "develop moved after review — stop and review the new commit"; exit 1; }
   main_commit=$(git rev-parse refs/remotes/origin/main)
   git merge-base --is-ancestor "$main_commit" "$release_commit" \
     || { echo "NOT a fast-forward — main has commits develop lacks; back-merge first (see below)"; exit 1; }
   git push origin "$release_commit:refs/heads/main"
   test "$(git ls-remote --heads origin refs/heads/main | cut -f1)" = "$release_commit" \
     || { echo "main does not point at the audited release commit"; exit 1; }
   ```

   The recorded sha closes the review-to-fetch race. The explicit push closes a second trap: a
   refspec source such as `develop:main` resolves the unqualified `develop` **locally**, so it can
   push a stale local branch even when every preflight read `origin/develop`. The commands above bind
   review, gate, push, and readback to one object.

   The `Main Branch` ruleset targets `refs/heads/main` only (`develop` carries no rules at all) and has
   `pull_request`, `non_fast_forward` and `deletion`, with `OrganizationAdmin` bypass at
   `bypass_mode: always`. The push satisfies `non_fast_forward` — that rule blocks force-pushes, and
   this is a genuine fast-forward — and needs the bypass for `pull_request`. The organization-admin
   bypass admitted both corrective fast-forward pushes during v1.17.0. If a future push is refused,
   fall back to `gh pr merge --merge --admin` and then back-merge (`git merge origin/main` on
   `develop`) to restore the invariant before the next release.

   > **The invariant is the point: `main` must stay an ancestor of `develop`.** Both `gh pr merge`
   > modes break it, in different ways, and the repo has been broken by each in turn.
   >
   > `--merge` writes a merge commit onto `main` that `develop` never receives. That is how the last
   > divergence started: `23fcd27` ("release: v1.12.0 (promote develop to main via merge)",
   > 2026-07-19) has two parents, and its second parent `3220f57` is the last commit the two branches
   > shared. Nothing back-merged it, so they never re-converged.
   >
   > `--rebase` is worse: it *rebases* develop's commits onto `main`, minting new shas, so `main` ends
   > up carrying **twins** of commits `develop` still holds under their original shas. Later promotion
   > PRs then come back `CONFLICTING` and need a hand-built reconcile commit — `cfd92fa` (v1.15.0) and
   > `60aa883` (v1.15.1) are two of those, and PR #368 is a promotion that could not be merged at all.
   >
   > Five releases were cut while diverged (v1.13.0, v1.13.1, v1.14.0, v1.15.0, v1.15.1), drifting to
   > 37 commits on `main` that `develop` lacked, until `de4e781` healed it. In that whole window **no
   > tag ever sat on develop's release commit** — every one of v1.12.0…v1.15.1 is unreachable from
   > develop as it stood before the heal. A fast-forward is what puts them back on the same commit.
   >
   > Verify with `git merge-base --is-ancestor origin/main origin/develop` before promoting. If a
   > hotfix ever lands directly on `main`, back-merge it (`git merge origin/main` on `develop`) to
   > restore the invariant before the next release.

7. Tag and push from `main` (annotated tag, matching `VERSION`) once the PR is merged:

   ```bash
   release_commit=$(git rev-parse refs/rigforge/release-candidate)
   git checkout main \
     || { echo "cannot check out main — refusing to tag"; exit 1; }
   git pull --ff-only origin main \
     || { echo "pull failed — refusing to tag a cached main"; exit 1; }
   test "$(git rev-parse HEAD)" = "$release_commit" \
     || { echo "main moved after review — stop and review the new commit"; exit 1; }
   git tag -a vX.Y.Z "$release_commit" -m "RigForge vX.Y.Z" \
     || { echo "tag creation failed — refusing to push an existing local tag"; exit 1; }
   git push origin refs/tags/vX.Y.Z
   test "$(git ls-remote --tags origin 'refs/tags/vX.Y.Z^{}' | cut -f1)" = "$release_commit" \
     || { echo "the remote tag does not dereference to the release commit"; exit 1; }
   git update-ref -d refs/rigforge/release-candidate
   ```

   The private local ref carries the reviewed commit across release steps and makes a concurrent
   `main` change fail closed. Push the named tag explicitly: `--follow-tags` can truthfully report
   that the branch is current without proving the intended tag moved, so the remote dereference is
   the release evidence.

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

For a full release, make the published release the repository's `latest` marker explicitly and read
it back. Rigs' `upgrade --check` and remote upgrade path follow that endpoint; “published” and
“latest” are separate release state:

```bash
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
release_id=$(gh api "repos/$repo/releases/tags/vX.Y.Z" --jq .id)
gh api -X PATCH "repos/$repo/releases/$release_id" -f make_latest=true
test "$(gh api "repos/$repo/releases/latest" --jq .tag_name)" = vX.Y.Z \
  || { echo "published release is not the repository's latest marker"; exit 1; }
```

The `Release latest marker` workflow repeats that read after every non-prerelease publish and fails
loudly if the marker differs. It is a guard, not a substitute for the explicit publish step above.

After a rig is re-tagged, record its benchmark for the release
(`E2E_PERF_TAG=vX.Y.Z E2E_PERF_RECORD=1 sudo bash tests/e2e-real.sh perf` on the rig) and commit
the updated `tests/perf-baselines/` files — the per-release history is what lets the perf gate
catch slow drift across releases (see `tests/perf-baselines/README.md`). It is whichever rig ran the
gate, which is **not** always miner-0 despite [`tests/README.md`](./tests/README.md#the-shared-rig-miner-0)
calling it the shared rig: v1.15.0 was gated on miner-2 and v1.15.1 on miner-3, and miner-0 currently
cannot pass the gate at all — it dual-boots Windows, so Secure Boot is enabled, kernel lockdown
(`integrity`) denies every MSR write, and `doctor` counts that as an issue and exits non-zero. Pick a
rig with Secure Boot off. The rest of the fleet isn't re-tagged on every release, so its baselines are
only as fresh as the last time each rig was actually touched. `tests/perf-baselines/` legitimately
carries gaps between releases for rigs that went untouched — it is not a promise that every rig has
an entry for every tag. The recording is also the per-rig perf gate (#214): it judges against the
committed baseline and best-ever history before writing, refuses to record a regressed number (fix
it, or consciously override with `E2E_PERF_FORCE=1`), so a failed rig means investigate before
calling it healthy. Once a rig's baseline is merged, reset its copy
(`sudo git checkout -- tests/perf-baselines/` in `/opt/rigforge`): the recording dirties the rig's
checkout, and the *next* release's
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
