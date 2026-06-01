.DEFAULT_GOAL := help
.PHONY: help \
        coordinator-test coordinator-build coordinator-build-linux coordinator \
        provider-build provider-test provider \
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

# ---- Provider (Swift, Apple Silicon) --------------------------------------

provider-build: ## swift build for the Swift provider CLI
	cd provider-swift && swift build

provider-test: ## swift test for the Swift provider CLI
	cd provider-swift && swift test

provider: provider-build provider-test ## Build + test provider

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

# ---- Aggregates ------------------------------------------------------------

test: coordinator-test provider-test ui-test ## Run all unit tests

build: coordinator-build provider-build ui-build ## Build all components

all: test build ## Test + build everything

clean: ## Remove built artifacts
	rm -f coordinator/coordinator coordinator/coordinator-linux
	rm -rf provider-swift/.build console-ui/.next console-ui/node_modules