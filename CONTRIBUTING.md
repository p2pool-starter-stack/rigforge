# Contributing to RigForge

Thanks for your interest in improving RigForge! Whether it's a bug fix, a new
CPU tuning profile, or a docs tweak, contributions are welcome.

RigForge is the companion miner for the
[Pithead](https://github.com/p2pool-starter-stack/pithead) P2Pool stack. If your
idea is really about the stack as a whole rather than the miner, that repo may be
the better home for it.

## Before you start

- For anything beyond a small fix, **open an issue first** so we can agree on the
  approach before you spend time on it. This avoids duplicated or wasted effort.
- Check the existing issues to see if someone is already on it.

## Making changes

RigForge is portable Bash that has to run on Ubuntu/Debian and macOS, so:

- Keep it **portable bash** — avoid GNU-only flags and other Linux-isms where a
  POSIX-friendly alternative exists, and guard platform-specific code paths.
- Run **`make lint`** before you push and fix any warnings — it runs ShellCheck and `shfmt` over the
  script, utilities, **and** the test scripts, exactly as CI does:

  ```bash
  make lint    # or: make test  (lint + the full dependency-free suite)
  ```

  CI runs the same checks, so a clean local run keeps your PR green. (`make fmt` auto-applies the
  `shfmt` formatting.)
- Update the README or other docs when you change behaviour or add options.

## Pre-commit hooks

Install the hooks once and they run on every commit, catching issues before they reach CI:

```bash
pipx install pre-commit   # or: pip install pre-commit
pre-commit install
```

This runs `make lint` (ShellCheck + shfmt over the Makefile's `SHELL_FILES`),
[gitleaks](https://github.com/gitleaks/gitleaks) secret scanning (the same pinned version CI runs, so
a committed token or pool credential is caught before it's pushed), and a few hygiene checks
(private-key detection, a large-file guard, final-newline and trailing-whitespace fixers).

### Config & docs linting

The YAML, Markdown, and link checks gate in CI and have matching Make targets for local runs:

```bash
make lint-yaml     # yamllint the workflows + configs   (.yamllint)
make lint-md       # markdownlint the docs              (.markdownlint-cli2.yaml; needs node)
make lint-links    # lychee link-check the docs         (.lychee.toml; needs lychee — runs weekly in CI)
make lint-all      # shell + yaml + markdown in one go
```

An [`.editorconfig`](./.editorconfig) encodes the whitespace conventions (`shfmt -i 4`, LF, final
newline) so most editors match these checks automatically.

## Branching

RigForge uses a two-branch model (same as [Pithead](https://github.com/p2pool-starter-stack/pithead)):

- **`develop`** — the default, integration branch. All PRs target `develop`.
- **`main`** — the release branch. `develop` is merged into `main` at each release, and version tags
  are cut from `main`.

## Submitting a pull request

1. Fork the repo and create a topic branch off `develop`.
2. Make your change and confirm `shellcheck` passes.
3. Open a PR against `develop` and fill out the template.
4. **All PRs require review** before merging — a code owner will take a look.

Keep PRs focused and the description clear about *what* changed and *why*. Small,
reviewable changes get merged faster.

Thanks again for contributing! 🔥
