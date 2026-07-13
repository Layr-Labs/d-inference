.DEFAULT_GOAL := help
.PHONY: help \
        contracts-check contracts-update \
        coordinator-test coordinator-build coordinator-build-linux coordinator-migrate-build coordinator-migration-test coordinator \
        coordinator-rs-fmt coordinator-rs-lint coordinator-rs-test coordinator-rs-fault-test coordinator-rs-build coordinator-rs-sqlx coordinator-rs-deps coordinator-rs \
        cutover-readiness-test \
        provider-build provider-test provider \
        ui-install ui-build ui-lint ui-test ui \
        e2e-integration e2e-benchmark e2e \
        test build all clean

help:
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} \
	     /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- Cross-language contracts ---------------------------------------------

contracts-check: ## Verify committed HTTP, protocol, crypto, and routing contracts
	go run ./coordinator/cmd/contract-fixtures

contracts-update: ## Regenerate committed cross-language contracts
	go run ./coordinator/cmd/contract-fixtures -update

# ---- Coordinator (Go) ------------------------------------------------------

coordinator-test: ## Run Go unit tests for the coordinator
	cd coordinator && go test ./...

coordinator-build: ## Build the coordinator binary for the host platform
	cd coordinator && go build ./cmd/coordinator

coordinator-build-linux: ## Cross-compile coordinator for linux/amd64 (EigenCloud)
	cd coordinator && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
	    go build -o coordinator-linux ./cmd/coordinator

coordinator-migrate-build: ## Build the external PostgreSQL migration command
	mkdir -p coordinator/bin
	go build -o coordinator/bin/coordinator-migrate ./coordinator/cmd/migrate

coordinator-migration-test: ## Test migration catalog, compatibility, and runner
	go test ./coordinator/store ./coordinator/cmd/migrate -run 'Migration|Migrate_|Schema'

coordinator: coordinator-test coordinator-build ## Test + build coordinator

# ---- Coordinator (Rust replacement) ---------------------------------------

coordinator-rs-fmt: ## Check Rust coordinator formatting
	cd coordinator-rs && cargo fmt --all -- --check

coordinator-rs-lint: ## Run Clippy for the Rust coordinator
	cd coordinator-rs && cargo clippy --workspace --all-targets --all-features --locked -- -D warnings

coordinator-rs-test: ## Run Rust coordinator tests
	cd coordinator-rs && cargo test --workspace --all-features --locked

coordinator-rs-fault-test: ## Run deterministic Rust fault-recovery validation
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	umask 077; \
	openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
	    -out "$$tmp/fault-matrix.pem"; \
	openssl pkey -in "$$tmp/fault-matrix.pem" -pubout \
	    -out "$$tmp/fault-matrix.pub.pem"; \
	scripts/run-fault-matrix.sh \
	    --output "$$tmp/fault-matrix.json" \
	    --signing-key "$$tmp/fault-matrix.pem" \
	    --trusted-key "$$tmp/fault-matrix.pub.pem"

coordinator-rs-build: ## Build the Rust coordinator
	cd coordinator-rs && cargo build --workspace --all-targets --all-features --locked

coordinator-rs-sqlx: ## Verify checked SQLx query metadata (requires cargo-sqlx)
	cd coordinator-rs && cargo sqlx prepare --workspace --check -- --all-targets --all-features

coordinator-rs-deps: ## Check Rust advisories, bans, licenses, and sources
	cd coordinator-rs && cargo deny check advisories bans licenses sources

coordinator-rs: coordinator-rs-fmt coordinator-rs-lint coordinator-rs-test coordinator-rs-build coordinator-rs-deps ## Check, test, and build Rust coordinator

# ---- Coordinator cutover evidence -----------------------------------------

cutover-readiness-test: ## Validate offline cutover gates, evidence, and shell safety
	scripts/tests/test_cutover_readiness.sh

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

test: coordinator-test coordinator-rs-test cutover-readiness-test provider-test ui-test ## Run all unit tests

build: coordinator-build coordinator-rs-build provider-build ui-build ## Build all components

all: test build ## Test + build everything

clean: ## Remove built artifacts
	rm -f coordinator/coordinator coordinator/coordinator-linux
	rm -rf target coordinator-rs/target provider-swift/.build console-ui/.next console-ui/node_modules