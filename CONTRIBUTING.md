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

RigForge is portable Bash that has to run on Ubuntu/Debian and macOS:

- Keep it portable. Avoid GNU-only flags and other Linux-isms where a
  POSIX-friendly alternative exists, and guard platform-specific code paths.
- Run `make lint` before you push and fix any warnings. It runs ShellCheck and `shfmt` over the
  script, utilities, and the test scripts, exactly as CI does:

  ```bash
  make lint    # or: make test  (lint + the full dependency-free suite)
  ```

  CI runs the same checks, so a clean local run keeps your PR green. (`make fmt` auto-applies the
  `shfmt` formatting.) `make lint` also runs the topology gate and the **file budget gate** below.
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

Prose (`*.md`), data (`*.json`), and binaries are exempt — the reasons are enumerated one per glob in
the script. `rigforge.sh` is deliberately *not* exempt.

**If your change is refused because the ceiling equals the file's current size**, the ratchet has left
no slack, which is intended. Ask first whether a line-neutral form of the change exists; that question
usually dissolves the problem. If there genuinely is none, fold the addition into the same commit as a
cut that makes room for it — never a follow-on PR, which cannot raise the ceiling to fit.

**Regenerate the budget file rather than merging it**, and never resolve a conflict in it by taking a
side: both sides are measurements of different trees, and taking one bakes in a count that was never
true of the merged result.

### Config & docs linting

The YAML, Markdown, and link checks gate in CI and have matching Make targets for local runs:

```bash
make lint-yaml     # yamllint the workflows + configs   (.yamllint)
make lint-md       # markdownlint the docs              (.markdownlint-cli2.yaml; needs node)
make lint-links    # lychee link-check the docs         (.lychee.toml; needs lychee — runs weekly in CI)
make lint-all      # shell + yaml + markdown + workflows in one go
make ci            # everything CI runs that can run locally (adds the container e2e when Docker is up)
```

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
4. All PRs require review before merging; a code owner will take a look.

Keep PRs focused and the description clear about what changed and why. Small,
reviewable changes get merged faster.

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).
