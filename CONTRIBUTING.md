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
- Run **ShellCheck** before you push and fix any warnings:

  ```bash
  shellcheck rigforge.sh util/proposed-grub.sh
  ```

  CI runs the same check, so a clean local run keeps your PR green.
- Update the README or other docs when you change behaviour or add options.

## Submitting a pull request

1. Fork the repo and create a topic branch off `main`.
2. Make your change and confirm `shellcheck` passes.
3. Open a PR against `main` and fill out the template.
4. **All PRs require review** before merging — a code owner will take a look.

Keep PRs focused and the description clear about *what* changed and *why*. Small,
reviewable changes get merged faster.

Thanks again for contributing! 🔥
