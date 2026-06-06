# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: test test-stack test-e2e lint

test: lint test-stack ## Lint + the dependency-free suite (runs on macOS or Linux, no Docker)

test-stack: ## rigforge test suite: unit + black-box, every CPU/OS profile simulated
	bash tests/run.sh

test-e2e: ## Full end-to-end run in disposable Linux containers (needs Docker)
	bash tests/e2e/run.sh

lint: ## shellcheck the script, utilities, and test scripts
	shellcheck --severity=warning rigforge.sh util/proposed-grub.sh tests/run.sh tests/e2e/run.sh tests/e2e/in-container.sh
