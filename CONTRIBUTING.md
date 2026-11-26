# Contributing to RigForge

RigForge is the companion miner for the
[Pithead](https://github.com/p2pool-starter-stack/pithead) P2Pool stack. Bug
fixes, CPU tuning profiles, and docs changes are all welcome.

If your idea is about the stack as a whole rather than the miner, the Pithead
repo may be the better home for it.

## Before you start

- For anything beyond a small fix, open an issue first so we can agree on the
  approach before you spend time on it. This avoids duplicated work.
- Check the existing issues to see if someone is already on it.

## Making changes

RigForge is portable Bash that has to run on Ubuntu/Debian. macOS is best effort: it has no CI or bench
coverage, but the Darwin code paths still work and stay working, so don't break them gratuitously:

- Keep it portable. Avoid GNU-only flags and other Linux-isms where a
  POSIX-friendly alternative exists, and guard platform-specific code paths.
- Run `make lint` before you push and fix any warnings. It runs ShellCheck and `shfmt` over the
  script, utilities, and the test scripts, exactly as CI does:

  ```bash
  make lint    # or: make test  (lint + the full dependency-free suite)
  ```

  CI runs the same checks with pinned tools (shfmt 3.14.1, diff-cover 11.0.2 for patch coverage,
  and zizmor 1.32.0 for workflow security), so use matching versions when reproducing a CI finding.
  (`make fmt` auto-applies the `shfmt` formatting.) `make lint` also runs the topology gate and the **file budget gate** below.
- Update the README or other docs when you change behavior or add options.
- New `config.json` keys are lowercase `snake_case`, matching Pithead. The three SCREAMING legacy
  keys (`ACCESS_TOKEN`, `DONATION`, `HOME_DIR`) are frozen as-is — never rename a shipped key.

## Pre-commit hooks

Install the hooks once and they run on every commit, catching issues before they reach CI:

```bash
make dev-setup            # installs the linter toolchain (brew/apt) + the git hooks in one go
# — or by hand:
pipx install pre-commit   # or: pip install pre-commit
pre-commit install
```

This runs `make lint` (ShellCheck + shfmt over the Makefile's `SHELL_FILES`),
[gitleaks](https://github.com/gitleaks/gitleaks) secret scanning (the same pinned version CI runs, so
a committed token or pool credential is caught before it's pushed), and a few hygiene checks:
private-key detection, a large-file guard, and final-newline and trailing-whitespace fixers.

### File budget gate

`make lint` fails if a source file grows past its ceiling. Two rules, and
`scripts/lint-file-budget.sh` is the whole implementation:

- A file over **400 lines** must have a row in `docs/dev/file-budget.tsv` recording its current line
  count. Over **800** with no row, the refusal names the hard ceiling instead — a new file has no
  reason to be born that big.
- **Ceilings only ever go down.** The gate compares your budget file against `develop` and rejects
  any row whose ceiling rose. A row's *first* appearance must record the file's real count, not
  reserve headroom above it. A file that shrinks back to 400 or under drops its row.

```bash
make lint-file-budget                    # self-test, then the gate
scripts/lint-file-budget.sh --generate   # reprint the budget this tree implies; commit it by hand
```

Prose (`*.md`), data (`*.json`), the generated `Cargo.lock`, and binaries are exempt. Prose grows by
nature and is not source to split; JSON here is config and fixtures; `Cargo.lock` is written by
cargo; binary files are skipped by detection, not by a path list. A glob in `is_exempt` matches `/`
too. `rigforge.sh` is deliberately *not* exempt.

Rust source (`*.rs`) is ordinary source under this gate: a `.rs` file over 400 lines needs a row, a
new one never starts above the target, and there is no Rust exemption. Split a growing module
instead of asking for a row.

**If your change is refused because the ceiling equals the file's current size**, the ratchet has left
no slack, which is intended. Ask first whether a line-neutral form of the change exists; that question
usually dissolves the problem. If there genuinely is none, fold the addition into the same commit as a
cut that makes room for it — never a follow-on PR, which cannot raise the ceiling to fit.

**Regenerate the budget file rather than merging it**, and never resolve a conflict in it by taking a
side: both sides are measurements of different trees, and taking one bakes in a count that was never
true of the merged result. The gate never rewrites this baseline: `--generate` prints a proposed copy
to stdout, and a contributor deliberately redirects and reviews it.

### Config & docs linting

The YAML, workflow, Markdown, and link checks gate in CI and have matching Make targets for local runs:

```bash
make lint-yaml     # yamllint the workflows + configs   (.yamllint)
make lint-actions  # actionlint the workflows           (bad needs/refs, invalid runners, shell bugs in run blocks)
make lint-md       # markdownlint the docs              (.markdownlint-cli2.yaml + npm lockfile; needs Node 22+)
make lint-links    # lychee link-check the docs         (.lychee.toml; needs lychee — runs weekly in CI)
make lint-all      # shell + yaml + markdown + workflows in one go
make ci            # everything CI runs that can run locally (adds the container e2e when Docker is up)
```

The Markdown linter is pinned in `package.json` + `package-lock.json`, which `make lint-md` installs
from with `npm ci`; validate a pin update with `make lint-md`.

### CI failure categories

Every step in `.github/workflows/ci.yml` and `.github/workflows/security.yml` carries a
`setup:`/`assert:`/`cleanup:`/`scan:` category as the first word of its name and an id prefixed by
that category, and every job ends with an `if: always()` `assert: categorize outcome` step
(`scripts/ci-categorize.sh`) that prints each step's outcome under its category to the job summary.
A red gate therefore names the category that broke: `setup-*` rows mean the toolchain never came
up, `assert-*` rows are the gate's own verdict, `scan-*` rows are a gitleaks or zizmor finding that
blocks the merge, and `cleanup-*` rows show what was left after the run. `tests/test-workflow-contract.sh`
(in `make test-suite`) fails when a step loses its category, id, or categorize coverage, when a step
or job gains an `if:` condition off the approved allowlist, or when a preserved gate (the full-history
gitleaks scan and its pinned install, the online zizmor advisory audit, the file-budget base check,
the allowlist kernel-test pair, the stock-home proof, the Homebrew formula proof, every
`make lint*`/`make test*` entry point) stops appearing with its exact command.

Dependabot opens bump PRs (labelled `dependencies` so they queue first) for every manifest it can
read: GitHub Actions, the pre-commit hooks, the Python CI tools in `tools/requirements-ci.txt`, the
npm devDependency, and the container test images pinned by tag and digest in the Dockerfiles under
`tests/e2e/`, `tests/coverage/` and `tests/docker/`. The tools no manifest can express —
shellcheck, shfmt, actionlint, gitleaks, lychee and jq, installed by curl with a sha256 check — are
watched by the weekly `tool-bump.yml` watcher; the Rust toolchain pin in `rust-toolchain.toml` and
cargo-deny are registered there too, and Dependabot's `cargo` entry covers `Cargo.lock`. The watcher
reports stale pins without changing them; failed or malformed upstream responses remain unchecked
and fail the watcher. It also confirms that the sibling scheduled workflows ran on their last
schedule: only a scheduled run counts, and a lookup that finds nothing is unchecked, never a pass.

The Rust workspace (`Cargo.toml`, `crates/`) is gated by `make rust-check`: `rust-fmt`, `rust-clippy`,
`rust-test`, `rust-deny` (needs cargo-deny), `rust-musl` (needs the pinned musl target and readelf) and
`rust-msrv`. `make check` fails, not skips, when cargo is present but cargo-deny, readelf or the musl
target is missing. `make check` runs `lint-all`, the suite and those gates, and prints a skip line where
cargo is missing. `lint`, `test` and the pre-commit hooks never need cargo. The jobs live in
`.github/workflows/rust.yml`; the aarch64 build there is best effort and never fails the workflow.

An [`.editorconfig`](./.editorconfig) encodes the whitespace conventions (`shfmt -i 4`, LF, final
newline) so most editors match these checks automatically.

## Branching

RigForge uses a two-branch model (same as [Pithead](https://github.com/p2pool-starter-stack/pithead)):

- `develop` is the default, integration branch. All PRs target `develop`.
- `main` is the release branch. `develop` is merged into `main` at each release, and version tags
  are cut from `main`.

## Submitting a pull request

1. Fork the repo and create a topic branch off `develop`.
2. Make your change and confirm `shellcheck` passes.
3. Open a PR against `develop` and fill out the template.
4. A PR into `develop` merges on green required checks and review of the head SHA.
   Merges are explicit, never automatic: bring the branch up to date with
   `develop`, then `gh pr merge --squash`. Only the owner's account merges; a PR
   into `main` also needs the code owner's review.

Keep PRs focused and the description clear about what changed and why. Small,
reviewable changes get merged faster.

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).
