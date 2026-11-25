# Releasing RigForge

RigForge follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The current version is
tracked in [`VERSION`](./VERSION) and the history in [`CHANGELOG.md`](./CHANGELOG.md).

## Versioning

- MAJOR: incompatible `config.json` / CLI / behavior changes.
- MINOR: new, backwards-compatible functionality.
- PATCH: backwards-compatible fixes.

From `1.0.0` on, the `config.json` and CLI surface is stable, so a breaking change bumps MAJOR. (Pre-1.0
`0.x` releases could break the interface between minor versions while it settled.)

## Donation migration wording for v1.18.1

Include this wording in the release changelog and published release notes:

> Omitted `DONATION` now defaults to zero; explicit values in `config.json` are preserved.
> Existing XMRig builds rebuild once on upgrade to install a compiled donation minimum of zero.
> Subsequent donation reductions take effect on `apply`, which restarts XMRig, without rebuilding.

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
   sudo E2E_PERF_GATE=1 E2E_PERF_HISTORY=<history.jsonl> bash tests/e2e-real.sh perf   # offline bench; prints JSON keyed by hardware class and fails on a regression vs that history (drop E2E_PERF_GATE=1 to only report)
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
   testing): `e2e-real`'s `perf` phase emits JSON keyed by hardware class and compares the offline
   bench against the history you pass in `E2E_PERF_HISTORY`, and `e2e-pithead`'s `api-impact` phase
   proves the sister API doesn't shave live hashrate. Report mode is the default and never fails on a
   regression; run the release gate with `E2E_PERF_GATE=1`, and investigate any drop before tagging.

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
4. Bump [`VERSION`](./VERSION) to `X.Y.Z`, and move the `git clone --branch vX.Y.Z` pin in
   `README.md` and `docs/getting-started.md` to the same tag (the suite fails on an unpinned clone
   or a pin newer than `VERSION`).
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

- verifies the tagged commit is on `main` and that the tag matches `VERSION` (the build fails otherwise),
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

For a publicly verifiable perf result, explicitly opt into submission:

```bash
sudo env E2E_PERF_SUBMIT=1 E2E_PERF_HISTORY=<history.jsonl> bash tests/e2e-real.sh perf | tee <run.log>
```

This publishes hardware and performance information. The gate verifies the submitted result; a missing
ID or failed verification fails the phase. Copy the returned ID into
[`docs/benchmarks.md`](./docs/benchmarks.md) beside the release and CPU. Without this opt-in, the
gate remains offline.

After a rig is re-tagged, run `perf` on it and append the JSON line it prints
(`{"<class>":{"bench_1m_hs":<H/s>}}`, plus `benchmark_id` when submitted; `grep '^{'` of the output) to the history file you keep outside
the repo; that history, passed back as `E2E_PERF_HISTORY`, is what lets the gate catch slow drift
across releases. The class is the CPU model unless `E2E_PERF_CLASS` overrides it, so any rig of the
same hardware shares one history. Recording no longer touches the checkout, so there is nothing to
commit or reset. It is whichever rig ran the gate, which is **not** always the shared rig: v1.15.0 was
gated on one rig and v1.15.1 on another. A rig that dual-boots Windows has Secure Boot enabled,
kernel lockdown (`integrity`) denies every MSR write,
and `doctor` counts that as an issue and exits non-zero. Pick a rig with Secure Boot off.

The default changed from failing to reporting. With `E2E_PERF_GATE=1` (and no history, the gate fails rather than pass silently) a result more than the tolerance below the
latest or the best entry for its class fails as `perf REGRESSION` / `perf RATCHET`. Existing per-host
files in `tests/perf-baselines/` keep working, as the history, until `E2E_PERF_HISTORY` is set. They
are retired by deleting them once the history exists (see `tests/perf-baselines/README.md`); the old
`E2E_PERF_RECORD=1` / `E2E_PERF_FORCE=1` / `E2E_PERF_TAG` flow still writes them and still dirties the
checkout until then.

To verify a downloaded bundle: `sha256sum -c SHA256SUMS` (see
[SECURITY.md › Release integrity](./SECURITY.md#release-integrity)).

> The release is created as a draft so a human reviews it before it goes public, a deliberate gate
> for a tool that installs a root miner. Drop `--draft` from `release.yml` to auto-publish on tag instead.

## The APT feed

Publishing a stable release starts a `Publish APT feed` run (`apt-feed.yml`), which builds, signs
and deploys the signed flat apt feed to Pages; a published prerelease or draft only produces a
skipped job. It checks the tag equals `v$(VERSION)` and sits on `main`, and it runs in the
protected `github-pages` environment, so nothing is signed until the owner approves the run. The
trust anchor is the fingerprint and public key under `packaging/apt/` on `main`; a feed signed by
any other key fails the job closed. See
[SECURITY.md › The apt feed is signed](./SECURITY.md#the-apt-feed-is-signed)
for the trust model, custody, rotation and recovery.

Owner-only steps before the first feed (one time, in order):

1. Generate the signing key offline on the owner's machine (RSA 3072+, sign-only, never a
   networked box), and store two passphrase-protected backups offline: one on the owner's machine
   and one on the project NAS. Keep a revocation certificate with the backups.
2. Commit the armored public key to `packaging/apt/rigforge.asc` and the 40-hex fingerprint to
   `packaging/apt/fingerprint` via `develop` (replacing the `pending-key-generation` placeholder),
   and ship it in the first feed's release or an earlier one: `main` only holds released
   commits, and the workflow reads the anchor from `main`.
3. Add the repository secret `APT_SIGNING_KEY` (the armored private key) scoped to the
   `github-pages` environment, and the repository variable `APT_SIGNING_FINGERPRINT` with the
   same fingerprint. The armored copy that goes into the secret must carry no passphrase (CI
   cannot unlock one); the passphrase-protected exports stay offline as the backups.
4. Protect the `github-pages` environment with the owner as required reviewer — this approval is
   the gate that keeps a leaked token from signing a feed.
5. Enable Pages for the repository with **GitHub Actions** as the source, then allow the
   release-tag pattern (for example `v[0-9]*`) in the `github-pages` environment's **Deployment
   branches and tags**, alongside the default branch: GitHub creates that environment with a
   default-branch-only deployment rule when you pick the Actions source, and that rule alone
   would refuse every release-tag run at the environment gate, leaving only the
   `workflow_dispatch` rollback from the default branch.
6. Add a tag ruleset (or branch-protection tag pattern) for `v[0-9]*` so only the release
   operator can create release tags.

Complete all six steps before publishing the first stable release, and make sure that release
carries the .deb and its `SHA256SUMS` line (#784), which the job downloads and checksum-verifies.
Until the variable is set the job skips, and until the steps 4 and 5 rules land, a manual run
from the default branch could sign and deploy without approval while the release-tag run is
refused at the environment gate.

Rollback: the feed deploys as `apt/` (the flat feed every apt source points at) plus an archived
`apt/<version>/` per release. To restore the previous feed, re-run `Publish APT feed` from the
default branch with **Run workflow** and that release's tag — dispatch runs the workflow file of
whichever branch is selected, so dispatching is restricted to the default branch. The job
re-verifies the tag against `main`, requires both release assets to be unmodified since the
release was published, and republishes. Every deploy re-verifies each archived feed it keeps
against the pinned key; an archive that does not verify (for example one signed with a rotated
key) is dropped from `apt/versions`, while its `.deb` stays on its GitHub release.

## The Homebrew formula

Every release uploads a generated `rigforge.rb` beside the tarball (`scripts/build-homebrew-formula.sh`
renders `Formula/rigforge.rb.in` with the tarball URL and the sha256 from `SHA256SUMS`, and fails if
they disagree). Publishing a stable release then starts `Bump Homebrew formula`
(`homebrew-formula.yml`), which re-derives the formula from the published assets and opens or
updates a pull request from the fixed branch `homebrew/formula-bump` against `main`; it never
pushes to `main`. The formula is live for `brew tap` users only after that PR merges. Drafts,
prereleases and a repository without the bot configured skip the job.

Owner-only steps before the first bump (one time): create a GitHub App with contents and pull
requests write access on this repository only, install it here, then add the repository variable
`FORMULA_BOT_APP_ID` and the secret `FORMULA_BOT_PRIVATE_KEY`.

## Notes

- Keep `VERSION` and the latest `CHANGELOG.md` heading in lock-step; the test suite checks `VERSION`
  is valid SemVer.
- `VERSION` is also surfaced at runtime: `rigforge.sh version` (or `--version` / `-v`) reads it, so a
  release tag, the changelog heading, and what the script reports all stay in agreement.
