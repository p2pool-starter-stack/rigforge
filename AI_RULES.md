# Working in RigForge

RigForge is a portable Bash CLI plus systemd services that provision and run an
XMRig worker for a Pithead coordinator, or any RandomX Stratum pool. This is the
shared source for `AGENTS.md`, `CLAUDE.md`, and `.cursorrules`.

## Start here

- [Contributing](CONTRIBUTING.md): setup, the checks, the file-budget gate,
  branching, and pull requests.
- [How it works](docs/how-it-works.md), [configuration](docs/configuration.md),
  [operations](docs/operations.md) and
  [Pithead integration](docs/pithead-integration.md): the product's contracts.
- [Releasing](RELEASING.md): the operator's process. Version bumps, tags and
  releases are never part of a fix.
- Design records live in [docs/adr](docs/adr).

## Change boundaries

- Branch from `develop`; `main` holds released commits. Preserve other worktrees
  and uncommitted changes. Keep moves and behaviour changes in separate commits.
- `rigforge.sh` is the product. Keep it and `util/` under the
  [file budget](docs/dev/file-budget.tsv), which only ratchets down; split along
  behaviour boundaries.
- Never edit `VERSION` or `CHANGELOG.md` in a fix; a release carries them.
- A rig is shared hardware. Never run the CLI against a real rig or the bench's
  own RigForge deploy from a worktree. Hardware tests go through bench-ci as jobs
  on a pushed commit, and the runner reserves and restores the rig.
- Keep credentials, hostnames, addresses, home paths and raw bench evidence out
  of public files. `make lint-topology` is part of `make lint` and stays green.

## Verify

`make test` is `lint` plus the dependency-free suite, on macOS or Linux, no
Docker. `make ci` adds the yaml, markdown and workflow linters and, when Docker
is up, the container e2e. `make coverage` enforces the kcov floor (Docker). The
file-budget freeze check is `FILE_BUDGET_REQUIRE_BASE=1 bash
scripts/lint-file-budget.sh`, that exact singular path. The worker-to-coordinator
contract gate runs on a rig against the bench's stack, as a bench-ci `tier4-e2e`
job. Report skipped, unavailable or failed checks explicitly; a started command
is not a PASS.

## Merge rule

A PR into `develop` merges on green required checks plus the `adversarial-review`
status recorded on its head SHA by a session that did not author it, human-driven
or automated: bring the branch up to date with `develop`, get the review at that
head, then `gh pr merge --squash`. Never `--admin`, never auto-merge. A PR into
`main` also needs the code owner. Releases are the operator's, always.
