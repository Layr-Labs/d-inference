.PHONY: build build-coordinator build-provider build-console build-enclave build-app \
       test test-coordinator test-provider test-console test-enclave test-app test-python \
       lint lint-go lint-rust lint-console fmt fmt-go fmt-rust fmt-console \
       check clean

# ── Build ────────────────────────────────────────────────────────────────────

build: build-coordinator build-provider build-console build-enclave build-app

build-coordinator:
	go build ./cmd/coordinator

build-provider:
	PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo build --release
	@echo "For distributable bundles (no embedded Python):"
	@echo "  cd provider && cargo build --release --no-default-features"

build-console:
	cd console-ui && npm ci && npm run build

build-enclave:
	cd enclave && swift build -c release

build-app:
	cd app/EigenInference && swift build -c release

# ── Test ─────────────────────────────────────────────────────────────────────

test: test-coordinator test-provider test-console test-enclave test-app test-python

test-coordinator:
	go test -race ./...

test-provider:
	PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo test -- --skip proxy::tests --skip server::tests

test-console:
	cd console-ui && npm test

test-enclave:
	cd enclave && swift test

test-app:
	cd app/EigenInference && swift test

test-python:
	python3 -m pytest tests/test_crypto_interop.py

# ── Lint ─────────────────────────────────────────────────────────────────────

lint: lint-go lint-rust lint-console

lint-go:
	gofmt -l .
	golangci-lint run

lint-rust:
	cargo fmt --check --manifest-path provider/Cargo.toml
	cargo clippy --manifest-path provider/Cargo.toml -- -D warnings

lint-console:
	cd console-ui && npx eslint src/

# ── Format ───────────────────────────────────────────────────────────────────

fmt: fmt-go fmt-rust fmt-console

fmt-go:
	gofmt -w .

fmt-rust:
	cargo fmt --manifest-path provider/Cargo.toml

fmt-console:
	cd console-ui && npx eslint src/ --fix

# ── Combined check (lint + test) ─────────────────────────────────────────────

check: lint test

# ── Clean ────────────────────────────────────────────────────────────────────

clean:
	go clean -testcache
	cd provider && cargo clean
	cd console-ui && rm -rf .next node_modules
	cd enclave && swift package clean
	cd app/EigenInference && swift package clean
