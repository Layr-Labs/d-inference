.DEFAULT_GOAL := help
.PHONY: help \
        coordinator-test coordinator-build coordinator-build-linux coordinator \
        prompt-sidecar-format prompt-sidecar-check prompt-sidecar-test prompt-sidecar-probe prompt-sidecar-build prompt-sidecar \
        provider-build provider-test provider benchmark-gemma-contbatch benchmark-wrapper-test \
        ui-install ui-build ui-lint ui-test ui \
        e2e-integration e2e-benchmark e2e \
        test build all clean

help:
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- Coordinator (Go) ------------------------------------------------------

coordinator-test: ## Run Go unit tests for the coordinator
	cd coordinator && go test ./...

coordinator-build: ## Build the coordinator binary for the host platform
	cd coordinator && go build ./cmd/coordinator

coordinator-build-linux: ## Cross-compile coordinator for linux/amd64 (EigenCloud)
	cd coordinator && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
	    go build -o coordinator-linux ./cmd/coordinator

coordinator: coordinator-test coordinator-build ## Test + build coordinator

# ---- Prompt-contract sidecar (Rust) ---------------------------------------

prompt-sidecar-format: ## Check Rust sidecar formatting
	cd coordinator/promptsidecar && cargo fmt --all -- --check

prompt-sidecar-check: ## Check and lint all Rust sidecar targets
	cd coordinator/promptsidecar && cargo check --locked --all-targets
	cd coordinator/promptsidecar && cargo clippy --locked --all-targets -- -D warnings

prompt-sidecar-test: ## Run Rust sidecar tests
	cd coordinator/promptsidecar && cargo test --locked --all-targets

prompt-sidecar-probe: ## Run explicit Rust sidecar workstation probes
	cd coordinator/promptsidecar && cargo test --locked --test planner_fixture measure_fixture_planning_latency -- --exact --ignored --nocapture
	cd coordinator/promptsidecar && cargo test --locked --test planner_fixture measure_fixture_unix_http_latency -- --exact --ignored --nocapture
	cd coordinator/promptsidecar && cargo test --locked --test planner_fixture health_remains_fast_while_planner_is_busy_and_overloaded -- --exact --ignored --nocapture

prompt-sidecar-build: ## Build the Rust sidecar for the host platform
	cd coordinator/promptsidecar && cargo build --locked --release --bin promptsidecar

prompt-sidecar: prompt-sidecar-format prompt-sidecar-check prompt-sidecar-test prompt-sidecar-build ## Format + lint + test + build Rust sidecar

# ---- Provider (Swift, Apple Silicon) --------------------------------------

provider-build: ## Build the Swift provider CLI with its source-matched metallib
	cd provider-swift && swift build
	@set -eu; \
	    bin_path="$$(cd provider-swift && swift build --show-bin-path)"; \
	    ./scripts/fetch-metallib.sh "$$bin_path"

provider-test: ## Build and run Swift provider tests with source-matched metallibs
	cd provider-swift && swift build --build-tests
	@set -eu; \
	    bin_path="$$(cd provider-swift && swift build --show-bin-path)"; \
	    ./scripts/fetch-metallib.sh "$$bin_path"; \
	    runner_tmp=""; \
	    trap 'test -z "$$runner_tmp" || rm -f "$$runner_tmp"' EXIT; \
	    trap 'exit 143' HUP INT TERM; \
	    found=0; \
	    for bundle in "$$bin_path"/*PackageTests.xctest; do \
	        [ -d "$$bundle" ] || continue; \
	        runner_dir="$$bundle/Contents/MacOS"; \
	        mkdir -p "$$runner_dir"; \
	        runner_tmp="$$runner_dir/.mlx.metallib.$$$$"; \
	        cp "$$bin_path/mlx.metallib" "$$runner_tmp"; \
	        mv -f "$$runner_tmp" "$$runner_dir/mlx.metallib"; \
	        runner_tmp=""; \
	        found=1; \
	    done; \
	    [ "$$found" -eq 1 ] || { echo "provider test runner bundle not found in $$bin_path" >&2; exit 1; }; \
	    trap - EXIT HUP INT TERM
	cd provider-swift && swift test --skip-build

provider: provider-build provider-test ## Build + test provider

benchmark-wrapper-test: ## Unit-test the Gemma benchmark wrapper (no GPU or weights)
	cd scripts && python3 -m unittest discover -s gemma_contbatch/tests -t .

benchmark-gemma-contbatch: ## Build and benchmark Gemma 4 26B continuous batching
	python3 scripts/benchmark-gemma-contbatch.py $(GEMMA_BENCHMARK_ARGS)

# ---- Console UI (Next.js 16) ----------------------------------------------

ui-install: ## npm install for console-ui
	cd console-ui && npm install

ui-build: ## next build for console-ui
	cd console-ui && npm run build

ui-lint: ## eslint check for console-ui sources
	cd console-ui && npx eslint src/

ui-test: ## vitest for console-ui
	cd console-ui && npm test

ui: ui-install ui-lint ui-test ui-build ## Install, lint, test, build console-ui

# ---- E2E integration tests -------------------------------------------------
# The harness starts ephemeral Postgres, builds/stages the provider unless
# DARKBLOOM_PROVIDER_BINARY is supplied, and never downloads model weights.
# Full-network and benchmark lanes require both production checkpoints.

e2e-integration: ## Run local TestIntegration tests (local model prerequisites)
	go test ./e2e/... -count=1 -v -timeout 25m -p=1 -run '^TestIntegration'

e2e-benchmark: ## Run local TestBenchmark tests (local two-model prerequisites)
	go test ./e2e/... -count=1 -v -timeout 25m -p=1 -run '^TestBenchmark_'

e2e: e2e-integration ## Run the integration suite

# ---- Aggregates ------------------------------------------------------------

test: coordinator-test prompt-sidecar-test provider-test ui-test benchmark-wrapper-test ## Run all unit tests

build: coordinator-build prompt-sidecar-build provider-build ui-build ## Build all components

all: test build ## Test + build everything

clean: ## Remove built artifacts
	rm -f coordinator/coordinator coordinator/coordinator-linux
	rm -rf coordinator/promptsidecar/target provider-swift/.build console-ui/.next console-ui/node_modules
