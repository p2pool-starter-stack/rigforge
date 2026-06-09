# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: test test-stack test-e2e smoke coverage e2e-real lint fmt

SHELL_FILES = rigforge.sh util/proposed-grub.sh tests/run.sh tests/e2e/run.sh tests/e2e/in-container.sh tests/smoke.sh tests/coverage.sh tests/e2e-real.sh

test: lint test-stack ## Lint + the dependency-free suite (runs on macOS or Linux, no Docker)

test-stack: ## rigforge test suite: unit + black-box, every CPU/OS profile simulated
	bash tests/run.sh

test-e2e: ## Full end-to-end run in disposable Linux containers (needs Docker)
	bash tests/e2e/run.sh

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
