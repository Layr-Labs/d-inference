.DEFAULT_GOAL := help
.PHONY: help provider-build provider-test provider \
        benchmark-gemma-contbatch benchmark-wrapper-test \
        landing-install landing-build landing-lint landing-test landing \
        docs-check docs-impact-check docs-stamp changelog-check changelog-preview \
        test build all clean

help:
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- Provider (Swift, Apple Silicon) --------------------------------------

provider-build: ## Build the Swift provider CLI with its source-matched metallib
	cd provider-swift && swift build
	@set -eu; \
	    bin_path="$$(cd provider-swift && swift build --show-bin-path)"; \
	    ./scripts/fetch-metallib.sh "$$bin_path"

provider-test: ## Build and run Swift provider tests with source-matched metallibs
	python3 provider-swift/Tests/test_protocol_fixture_resources.py
	python3 scripts/test-stage-test-metallib.py
	python3 scripts/test-stage-swiftpm-resource-bundles.py
	cd provider-swift && swift build --build-tests
	@set -eu; \
	    bin_path="$$(cd provider-swift && swift build --show-bin-path)"; \
	    ./scripts/stage-test-metallib.sh "$$bin_path"
	cd provider-swift && ../scripts/run-provider-tests.sh

provider: provider-build provider-test ## Build + test provider

benchmark-wrapper-test: ## Unit-test benchmark wrappers (no GPU or weights)
	cd scripts && python3 -m unittest discover -s gemma_contbatch/tests -t .
	cd scripts && python3 -m unittest discover -s serving_performance -t . -p 'test_*.py'
	python3 -m unittest discover -s scripts/benchmarks -p test_radix_forward_shapes.py
	python3 reports/runtime-kv-path-2026-10-09/qualification/test_curate_runs.py
	python3 reports/runtime-kv-path-2026-10-09/qualification/test_run_suite.py

benchmark-gemma-contbatch: ## Build and benchmark Gemma 4 26B continuous batching
	python3 scripts/benchmark-gemma-contbatch.py $(GEMMA_BENCHMARK_ARGS)

# ---- Desktop frontend ------------------------------------------------------
.PHONY: desktop-install desktop-build desktop-test desktop-package desktop-api-test

desktop-install: ## Install Electron app dependencies
	cd desktop-app && npm ci

desktop-build: ## Build the Electron frontend and native bridge
	cd desktop-app && npm run build

desktop-test: ## Test desktop user journeys and IPC boundaries
	cd desktop-app && npm test

desktop-package: ## Create a macOS app for review without publishing
	cd desktop-app && npm run package

desktop-api-test: ## Test the real Swift desktop API with isolated local fixtures
	python3 scripts/test-desktop-api.py provider-swift/.build/debug/darkbloom

# ---- Marketing site (Next.js 16) ------------------------------------------

landing-install: ## npm ci for landing
	cd landing && npm ci

landing-build: ## next build for landing
	cd landing && npm run build

landing-lint: ## eslint check for landing sources
	cd landing && npm run lint

landing-test: landing-build ## Test landing routes against its production server
	cd landing && npm test

landing: landing-install landing-lint landing-test ## Install, lint, build and test landing

# ---- Docs ----------------------------------------------------------------

docs-check: ## Lint docs/: freshness stamps, relative links, cited code paths, orphans
	./scripts/docs-check.sh

docs-impact-check: ## Check source changes have their mapped canonical docs (BASE=origin/master)
	python3 scripts/docs-impact-check.py --base "$(if $(BASE),$(BASE),origin/master)"

docs-stamp: ## Refresh the freshness stamp on changed docs (FILES=... to target specific files)
	./scripts/docs-stamp.sh $(FILES)

changelog-check: ## Validate independent pending changelog fragments
	python3 scripts/changelog.py check

changelog-preview: ## Preview pending release notes without changing files
	python3 scripts/changelog.py preview

# ---- Aggregates ------------------------------------------------------------

test: provider-test landing-test benchmark-wrapper-test changelog-check docs-check ## Run provider and landing tests + docs lint

build: provider-build landing-build ## Build provider and landing

all: test build ## Test + build everything

clean: ## Remove built artifacts
	rm -rf provider-swift/.build
	rm -rf landing/.next landing/node_modules
