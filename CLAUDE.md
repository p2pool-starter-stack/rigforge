# RigForge — Claude Code context

Everything is portable Bash (`rigforge.sh` + `util/` + `tests/`): must run on Ubuntu/Debian AND
macOS under Apple's bash 3.2 — no bash-4-only syntax, no GNU-only flags on shared paths.

## Commands

- `make test` — lint + the dependency-free suite (`bash tests/run.sh`, ~2.5 min, any host, no Docker)
- `make lint` — shellcheck --severity=warning + shfmt -i 4 -d over the Makefile's `SHELL_FILES`;
  new `tests/*.sh` are picked up via `git ls-files` (must be tracked). `make fmt` auto-formats.
- `make lint-all` — adds yamllint --strict, markdownlint (npx), actionlint. All gate in CI.
- `make test-e2e` — container e2e, needs Docker. `make test-e2e-macos` — real-Mac e2e (CI runs it).
- `make coverage` — kcov in Docker, Linux/CI only (does not run on this Mac). Two CI gates:
  committed floor (tests/coverage-floor.txt) + 90% patch coverage on changed lines (diff-cover).
- `make smoke` / `make e2e-real` / `make e2e-pithead` — manual real-hardware release gates
  (miner-0), never in CI. They take `/var/lock/rig-e2e.lock`; see RELEASING.md.

## Testing

See @tests/README.md for the layer model. Boundary: if hardware/OS can be simulated with PATH
stubs it belongs in `tests/run.sh` (the default home); real-`/etc` effects → `e2e/in-container.sh`;
BSD/launchd behaviour → `e2e/macos.sh`; only-provable-on-real-hardware → `e2e-real.sh`.
`run.sh` is dependency-free (no bats): drive behaviour through `STUB_*` env vars and PATH stubs,
never read the host's real `/sys` or `/proc`. Must pass under Apple's bash 3.2.

## Constraints

- No real credentials, pool passwords, wallets, or tokens anywhere — gitleaks (built-in ruleset,
  pinned 8.30.1, no custom .toml) scans the FULL history on every push; a leaked secret stays leaked.
- `config.json` keys are lowercase snake_case; the three SCREAMING legacy keys (`ACCESS_TOKEN`,
  `DONATION`, `HOME_DIR`) are frozen — never rename a shipped key.
- No telemetry, nothing phones home. Public repo, MIT; XMRig is compiled from source, never bundled.

## Etiquette

- Branches: `develop` = default/integration (all PRs target it); `main` = release-only, promoted
  via PR. Commits: `type(scope): summary (#issue)` — feat/fix/test/docs/chore/perf, `release: vX.Y.Z`.
- CHANGELOG.md entry under `## [Unreleased]` (Keep a Changelog) for every user-visible change.
- Open PRs for review; do not merge them. Update docs/ when behaviour changes.
