# Local test entry points (mirror the GitHub Actions CI jobs).
.PHONY: help test test-suite test-e2e test-e2e-macos smoke coverage e2e-real e2e-pithead lint fmt lint-yaml lint-md lint-links lint-all lint-actions dev-setup ci

SHELL_FILES = $(shell git ls-files '*.sh')

# Config/docs lint file sets, derived from what's tracked so CI and local stay in sync (like SHELL_FILES).
YAML_FILES = $(shell git ls-files '*.yml' '*.yaml')
MD_FILES = $(shell git ls-files '*.md')
MARKDOWNLINT_VERSION = 0.22.1

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

e2e-pithead: ## Release gate (worker↔stack): real worker vs a live Pithead stack (root; PITHEAD_URL=host:3333; see RELEASING.md)
	bash tests/e2e-pithead.sh all

lint: ## shellcheck + shfmt (check) the script, utilities, and test scripts
	shellcheck --severity=warning $(SHELL_FILES)
	shfmt -i 4 -d $(SHELL_FILES)

fmt: ## auto-format all shell scripts with shfmt (resolves shfmt lint failures)
	shfmt -i 4 -w $(SHELL_FILES)

lint-yaml: ## yamllint the YAML (workflows, dependabot, configs) — uses .yamllint, strict
	yamllint --strict $(YAML_FILES)

lint-md: ## markdownlint the docs — uses .markdownlint-cli2.yaml (needs node/npx)
	npx --yes markdownlint-cli2@$(MARKDOWNLINT_VERSION) $(MD_FILES)

lint-actions: ## actionlint the GitHub workflows for correctness (zizmor covers security; make dev-setup installs it)
	actionlint

dev-setup: ## One-time local toolchain: linters + git hooks (brew or apt; versions pinned in ci.yml)
	@if command -v brew >/dev/null 2>&1; then brew install shellcheck shfmt jq yamllint actionlint pre-commit; \
	elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y shellcheck jq yamllint && echo "apt shfmt/actionlint lag — install those two per their READMEs"; \
	else echo "no brew/apt found — install shellcheck, shfmt, jq, yamllint, actionlint, pre-commit manually"; fi
	pre-commit install
	@echo "Hooks installed. CI-pinned versions to match (ci.yml/security.yml are the source of truth):"
	@echo "  shellcheck 0.11.0 · yamllint 1.38.0 · actionlint 1.7.7 · markdownlint-cli2 $(MARKDOWNLINT_VERSION) · gitleaks 8.30.1"

ci: lint-all test-suite ## Everything CI runs that can run locally (adds the container e2e when Docker is up)
	@if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then $(MAKE) test-e2e; else echo "docker unavailable — skipped the container e2e (CI runs it)"; fi

lint-links: ## lychee link-check the docs — uses .lychee.toml (needs lychee; hits external links)
	lychee $(MD_FILES)

lint-all: lint lint-yaml lint-md lint-actions ## run every fast linter (shell + yaml + markdown + workflows; not the link check)
