.PHONY: help test test-suite test-e2e test-e2e-macos smoke coverage e2e-real e2e-pithead e2e-docs-replay lint lint-topology lint-file-budget lint-env-docs fmt lint-yaml lint-md lint-links lint-all lint-actions dev-setup ci check rust-check rust-goldens rust-mutants rust-fmt rust-clippy rust-test rust-deny rust-musl rust-version rust-msrv

MUSL_TARGET ?= x86_64-unknown-linux-musl

SHELL_FILES = $(shell git ls-files '*.sh')

YAML_FILES = $(shell git ls-files '*.yml' '*.yaml')
MD_FILES = $(shell git ls-files '*.md')

.DEFAULT_GOAL := test

help: ## List the available targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

test: lint test-suite ## Lint + the dependency-free suite (runs on macOS or Linux, no Docker)

test-suite: ## rigforge test suite: unit + black-box, every CPU/OS profile simulated
	bash tests/run.sh
	bash tests/test-doctor-json.sh
	bash tests/test-contract-credentials.sh
	bash tests/test-access-token-readiness.sh
	bash tests/test-docs-clone-pin.sh
	bash tests/test-staged-rebuild.sh
	bash tests/test-package-upgrade.sh
	bash tests/test-dependabot-coverage.sh
	bash tests/test-codeql-workflow.sh
	bash tests/test-tool-pin-watch.sh
	bash tests/test-xmrig-bump.sh
	bash tests/test-osv-file-issue.sh
	bash tests/test-file-security-issue.sh
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test-docs-replay.py
	bash tests/test-api-allowlist-probe.sh
	bash tests/test-e2e-docs-guest.sh
	python3 tests/test-control-readiness.py
	python3 tests/test-worker-proof.py
	python3 tests/test-serve-poll.py
	bash tests/test-worker-proof.sh
	bash tests/test-coverage-cache.sh
	bash tests/test-revision-key.sh
	bash tests/test-state-lib.sh
	bash tests/test-homebrew-formula.sh
	bash tests/test-release-bundle.sh

test-e2e: ## Full end-to-end run in disposable Linux containers (needs Docker)
	bash tests/e2e/linux.sh

e2e-docs-replay: ## Replay documented setup and two reboots in an explicitly supplied disposable KVM guest
	python3 tests/docs_replay.py

test-e2e-macos: ## Native macOS e2e: real rigforge.sh (brew/git/cmake stubbed) — BSD sed, launchd, nohup (macOS only, best effort, not run in CI)
	bash tests/e2e/macos.sh

smoke: ## Release pre-tag gate (quick): real xmrig --bench proves the built worker hashes (manual, Linux-only)
	bash tests/smoke.sh

coverage: ## Measure product Bash coverage via kcov and enforce the committed floor (needs Docker)
	bash tests/coverage.sh

e2e-real: ## Release pre-tag gate (full): real build+tune+bench+doctor+uninstall on a rig (root; see RELEASING.md)
	bash tests/e2e-real.sh all

e2e-pithead: ## Release gate (worker↔stack): real worker vs a live Pithead stack (root; PITHEAD_URL=host:3333; see RELEASING.md)
	bash tests/e2e-pithead.sh all

lint: lint-topology lint-file-budget lint-env-docs ## shellcheck + shfmt (check) the script, utilities, and test scripts, plus the topology, file-budget and env-docs gates
	shellcheck --severity=warning $(SHELL_FILES)
	shfmt -i 4 -d $(SHELL_FILES)

lint-topology: ## fail if a real-looking IPv6/IPv4/hostname/path/user@host literal leaks in (generic classes only)
	bash scripts/lint-topology-classes.sh --self-test
	bash scripts/lint-topology-classes.sh

lint-file-budget: ## fail if a file crosses the 800-line hard ceiling, or an existing offender grows past its docs/dev/file-budget.tsv ceiling (#407)
	bash scripts/lint-file-budget.sh --self-test
	bash scripts/lint-file-budget.sh

lint-env-docs: ## fail if a TUNE_/AUTOTUNE_ setting read with a default in rigforge.sh or util/ is mentioned nowhere under docs/
	bash scripts/lint-env-docs.sh --self-test
	bash scripts/lint-env-docs.sh

fmt: ## auto-format all shell scripts with shfmt (resolves shfmt lint failures)
	shfmt -i 4 -w $(SHELL_FILES)

lint-yaml: ## yamllint the YAML (workflows, dependabot, configs) — uses .yamllint, strict
	yamllint --strict $(YAML_FILES)

lint-md: ## markdownlint the docs — uses .markdownlint-cli2.yaml + package-lock.json (needs Node 22+)
	npm ci --silent
	npx markdownlint-cli2 $(MD_FILES)

lint-actions: ## actionlint the GitHub workflows for correctness (zizmor covers security; make dev-setup installs it)
	actionlint

dev-setup: ## One-time local toolchain: linters + git hooks (brew or apt; versions pinned in ci.yml)
	@if command -v brew >/dev/null 2>&1; then brew install shellcheck shfmt jq yamllint actionlint pre-commit; \
	elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y shellcheck jq yamllint && echo "apt shfmt/actionlint lag — install those two per their READMEs"; \
	else echo "no brew/apt found — install shellcheck, shfmt, jq, yamllint, actionlint, pre-commit manually"; fi
	@if command -v npm >/dev/null 2>&1; then npm ci || echo "npm ci failed — make lint-md needs a network or a warm npm cache"; else echo "no npm found — make lint-md (markdownlint) needs Node 22+"; fi
	pre-commit install
	@echo "Hooks installed. CI-pinned versions to match (source of truth per tool):"
	@echo "  curl binaries in ci.yml/security.yml · Python tools in tools/requirements-ci.txt · markdownlint-cli2 in package.json"

ci: lint-all test-suite ## Everything CI runs that can run locally (adds the container e2e when Docker is up)
	@if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then $(MAKE) test-e2e; else echo "docker unavailable — skipped the container e2e (CI runs it)"; fi

lint-links: ## lychee link-check the docs — uses .lychee.toml (needs lychee; hits external links)
	lychee --config .lychee.toml $(MD_FILES)

lint-all: lint lint-yaml lint-md lint-actions ## run every fast linter (shell + yaml + markdown + workflows; not the link check)

check: lint-all test-suite ## Everything: lint-all, the suite, and the Rust gates (loud skip where cargo is missing)
	@if command -v cargo >/dev/null 2>&1; then $(MAKE) rust-check; else echo "cargo unavailable — skipped the Rust gates (CI runs them)"; fi

rust-check: rust-fmt rust-clippy rust-test rust-deny rust-musl rust-msrv ## Every Rust gate (needs the pinned toolchain from rust-toolchain.toml and cargo-deny)

rust-goldens: ## regenerate the jq 1.7.1 goldens and fail on any difference (needs jq 1.7.1; loud skip otherwise)
	@if [ "$$(jq --version 2>/dev/null)" = jq-1.7.1 ]; then bash scripts/make-goldens.sh jq && git diff --exit-code -- crates/rigforge-core/tests/golden && test -z "$$(git ls-files --others --exclude-standard crates/rigforge-core/tests/golden)"; else echo "jq 1.7.1 unavailable — skipped the golden regeneration check (CI runs it)"; fi

rust-mutants: ## apply every row of tests/rust/mutants.tsv to a scratch copy and require a red run (slow; needs cargo)
	@if command -v cargo >/dev/null 2>&1; then bash scripts/rust-mutants.sh tests/rust/mutants.tsv; else echo "cargo unavailable — skipped the mutation check"; fi

rust-fmt: ## cargo fmt --all -- --check
	cargo fmt --all -- --check

rust-clippy: ## clippy over every target, warnings are errors
	cargo clippy --workspace --all-targets --locked -- -D warnings

rust-test: ## cargo test --workspace --locked
	cargo test --workspace --locked

rust-deny: ## cargo deny check (advisories, licenses, bans, sources) from deny.toml (needs cargo-deny)
	@command -v cargo-deny >/dev/null 2>&1 || { echo "cargo-deny is not installed (see rust.yml for the pinned version)" >&2; exit 1; }
	cargo deny check advisories licenses bans sources

rust-musl: ## --locked release build for MUSL_TARGET (default x86_64) and assert the binary is statically linked and stripped
	cargo build --release --locked --target $(MUSL_TARGET) -p rigforge-rs
	@command -v readelf >/dev/null 2>&1 || { echo "readelf is not installed (binutils)" >&2; exit 1; }
	@bin=target/$(MUSL_TARGET)/release/rigforge-rs; readelf -h "$$bin" >/dev/null || exit 1; \
	if readelf -lW "$$bin" | grep -q INTERP || readelf -dW "$$bin" | grep -q NEEDED; then echo "$$bin is not statically linked" >&2; exit 1; fi; \
	if readelf -SW "$$bin" | grep -q '\.symtab'; then echo "$$bin is not stripped" >&2; exit 1; fi; \
	echo "$$bin is statically linked and stripped"

rust-version: ## assert the musl binary for MUSL_TARGET (default x86_64) reports the repository VERSION
	@bin=target/$(MUSL_TARGET)/release/rigforge-rs; want="rigforge-rs $$(tr -d '[:space:]' <VERSION)"; \
	if [ ! -x "$$bin" ]; then echo "$$bin missing; run make rust-musl first" >&2; exit 1; fi; \
	got="$$($$bin --version)"; \
	if [ "$$got" != "$$want" ]; then echo "$$bin reports '$$got'; expected '$$want'" >&2; exit 1; fi; \
	echo "$$bin reports $$got"

rust-msrv: ## rust-version in Cargo.toml must equal the pinned toolchain's major.minor, and the workspace must build with it
	@want=$$(sed -n 's/^rust-version = "\(.*\)"$$/\1/p' Cargo.toml); have=$$(sed -n 's/^channel = "\([0-9]*\.[0-9]*\)\.[0-9]*"$$/\1/p' rust-toolchain.toml); \
	if [ -z "$$want" ] || [ "$$want" != "$$have" ]; then echo "rust-version [$$want] does not match the rust-toolchain.toml channel [$$have]" >&2; exit 1; fi
	cargo build --workspace --locked
