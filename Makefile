# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: help test test-suite test-e2e test-e2e-macos smoke coverage e2e-real lint fmt

SHELL_FILES = rigforge.sh util/proposed-grub.sh tests/run.sh tests/e2e/linux.sh tests/e2e/in-container.sh tests/e2e/macos.sh tests/smoke.sh tests/coverage.sh tests/e2e-real.sh

# Keep `make` (no target) running the default dev check; `make help` lists every target.
.DEFAULT_GOAL := test

help: ## List the available targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

test: lint test-suite ## Lint + the dependency-free suite (runs on macOS or Linux, no Docker)

test-suite: ## rigforge test suite: unit + black-box, every CPU/OS profile simulated
	bash tests/run.sh

test-e2e: ## Full end-to-end run in disposable Linux containers (needs Docker)
	bash tests/e2e/linux.sh

test-e2e-macos: ## Native macOS e2e: real rigforge.sh (brew/git/cmake stubbed) — BSD sed, launchd, nohup (macOS only)
	bash tests/e2e/macos.sh

smoke: ## Release pre-tag gate (quick): real xmrig --bench proves the built worker hashes (manual, Linux-only)
	bash tests/smoke.sh

coverage: ## Measure rigforge.sh + util coverage via kcov and enforce the committed floor (needs Docker)
	bash tests/coverage.sh

e2e-real: ## Release pre-tag gate (full): real build+tune+bench+doctor+uninstall on a rig (root; see RELEASING.md)
	bash tests/e2e-real.sh all

lint: ## shellcheck + shfmt (check) the script, utilities, and test scripts
	shellcheck --severity=warning $(SHELL_FILES)
	shfmt -i 4 -d $(SHELL_FILES)

fmt: ## auto-format all shell scripts with shfmt (resolves shfmt lint failures)
	shfmt -i 4 -w $(SHELL_FILES)
