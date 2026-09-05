.DEFAULT_GOAL := help
.PHONY: help \
        coordinator-test coordinator-build coordinator-build-linux coordinator \
        prompt-sidecar-format prompt-sidecar-check prompt-sidecar-test prompt-sidecar-build prompt-sidecar \
        provider-build provider-test provider benchmark-gemma-contbatch benchmark-wrapper-test \
        ui-install ui-build ui-lint ui-test ui \
        e2e-integration e2e-benchmark e2e \
        graph graph-frontend graph-check graph-test \
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
# Requires Postgres + Swift provider binary + MLX model downloaded.

e2e-integration: ## go test ./e2e/... -run TestIntegration
	go test ./e2e/... -run TestIntegration -v

e2e-benchmark: ## go test ./e2e/... -run TestBenchmark (load benchmarks)
	go test ./e2e/... -run TestBenchmark -v

e2e: e2e-integration ## Run the integration suite

# ---- System map (tools/systemmap) -------------------------------------------
# tools/systemmap is its own Go module, so go/packages never becomes a
# coordinator dependency; these targets hide the extra `cd`. `graph` writes the
# whole map — a self-contained system-map.html plus inventory.json and
# report.md — into $(GRAPH_OUT), which is git-ignored: CI builds it per pull
# request and publishes it to Pages from master, so the artifact is always
# regenerated and never committed. `graph-frontend` serves what `graph` wrote.

GRAPH_OUT ?= docs/reference/api-map
GRAPH_PAGE ?= system-map.html
GRAPH_PORT ?= 8765

# GRAPH_OUT is passed through rather than left to the generator's own default, so the
# directory `graph` writes and the one `graph-frontend` serves cannot drift apart. The
# generator resolves it against the repository root, not the working directory.
graph: ## Generate the system map into $(GRAPH_OUT) (git-ignored)
	$(MAKE) -C tools/systemmap ARGS="-out $(GRAPH_OUT) $(GRAPH_ARGS)"

graph-frontend: graph ## Generate the map and serve it (GRAPH_PORT=8765) locally
	@command -v python3 >/dev/null 2>&1 || { \
	    echo "graph-frontend needs python3; the page is self-contained, so you can also just open $(GRAPH_OUT)/$(GRAPH_PAGE)" >&2; \
	    exit 1; \
	}
	@echo "system map: http://127.0.0.1:$(GRAPH_PORT)/$(GRAPH_PAGE)  (ctrl-c to stop)"
	@command -v open >/dev/null 2>&1 && \
	    { (sleep 1; open "http://127.0.0.1:$(GRAPH_PORT)/$(GRAPH_PAGE)") >/dev/null 2>&1 & } || true
	cd $(GRAPH_OUT) && python3 -m http.server $(GRAPH_PORT) --bind 127.0.0.1

graph-check: ## Fail if source has outgrown the curated system-map overlay
	$(MAKE) -C tools/systemmap check

graph-test: ## Test the map generator and drive the generated page in a DOM
	$(MAKE) -C tools/systemmap test

# ---- Aggregates ------------------------------------------------------------

test: coordinator-test prompt-sidecar-test provider-test ui-test benchmark-wrapper-test graph-test ## Run all unit tests

build: coordinator-build prompt-sidecar-build provider-build ui-build ## Build all components

all: test build ## Test + build everything

clean: ## Remove built artifacts
	rm -f coordinator/coordinator coordinator/coordinator-linux
	rm -rf coordinator/promptsidecar/target provider-swift/.build console-ui/.next console-ui/node_modules
