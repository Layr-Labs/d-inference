.DEFAULT_GOAL := help
.PHONY: help provider-build provider-test provider \
        benchmark-gemma-contbatch benchmark-wrapper-test \
        ui-install ui-build ui-lint ui-test ui \
        landing-install landing-build landing-lint landing-test landing \
        docs-check docs-impact-check docs-stamp test build all clean

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
	cd provider-swift && swift build --build-tests
	@set -eu; \
	    bin_path="$$(cd provider-swift && swift build --show-bin-path)"; \
	    ./scripts/stage-test-metallib.sh "$$bin_path"
	cd provider-swift && ../scripts/run-provider-tests.sh

provider: provider-build provider-test ## Build + test provider

benchmark-wrapper-test: ## Unit-test the Gemma benchmark wrapper (no GPU or weights)
	cd scripts && python3 -m unittest discover -s gemma_contbatch/tests -t .
	cd scripts && python3 -m unittest discover -s serving_performance -t . -p 'test_*.py'

benchmark-gemma-contbatch: ## Build and benchmark Gemma 4 26B continuous batching
	python3 scripts/benchmark-gemma-contbatch.py $(GEMMA_BENCHMARK_ARGS)

# ---- Retained Console UI (Next.js 16) --------------------------------------

ui-install: ## npm install for console-ui
	cd console-ui && npm install

ui-build: ## next build for console-ui
	cd console-ui && npm run build

ui-lint: ## eslint check for console-ui sources
	cd console-ui && npx eslint src/

ui-test: ## vitest for console-ui
	cd console-ui && npm test

ui: ui-install ui-lint ui-test ui-build ## Install, lint, test, build retained console-ui

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

# ---- Aggregates ----------------------------------------------------------

test: provider-test ui-test landing-test benchmark-wrapper-test docs-check ## Run provider, retained console and landing tests + docs lint

build: provider-build ui-build landing-build ## Build provider, retained console and landing

all: test build ## Test + build everything

clean: ## Remove built artifacts
	rm -rf provider-swift/.build
	rm -rf console-ui/.next console-ui/node_modules
	rm -rf landing/.next landing/node_modules
