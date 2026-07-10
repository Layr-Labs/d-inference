# Test

## Coordinator unit tests

```bash
make coordinator-test
```

Run with `-race` for race detection:

```bash
cd coordinator && go test -race ./...
```

## Rust coordinator tests

```bash
make coordinator-rs-test
make coordinator-rs-lint
```

`coordinator-rs/crates/server/tests/postgres.rs` uses a real PostgreSQL
instance only when `DARKBLOOM_TEST_DATABASE_URL` is set. CI supplies an
isolated PostgreSQL 16 service. Tests never fall back to the runtime database
URL and never point at production. The suite covers schema compatibility,
Rust/Go advisory-lock contention, irreversible ownership activation, fencing
transactions, lock-connection loss, readiness, and runtime shutdown. Each test
creates and drops its own UUID-named database; the supplied database remains
read-only and is schema/checksum-snapshotted around the test. The configured
role therefore needs `CREATEDB` (required in CI; local tests skip clearly when
it is unavailable).

Cross-language migration contracts are committed under `tests/contracts/`:

```bash
make contracts-check           # fail if generated contracts drift
make contracts-update          # explicit regeneration for reviewed changes
```

The Go and Swift suites consume the same protocol/crypto fixtures. The
Go-to-Rust NaCl reference test is:

```bash
go test ./coordinator/internal/e2e -run '^TestCrossLanguageEncryption$'
```

## Provider tests

```bash
make provider-test
```

Full `swift test` requires the MLX metallib. Some suites pass without it.

## Console UI tests

```bash
make ui-test
```

Uses vitest.

## E2E integration tests

Requires Postgres + a Swift provider binary + a downloaded MLX model.

```bash
make e2e-integration          # go test ./e2e/... -run TestIntegration -v
make e2e-benchmark            # go test ./e2e/... -run TestBenchmark -v
```

The E2E harness lives in `e2e/testbed/`:

- `coordinator.go` — coordinator lifecycle.
- `provider.go` — provider lifecycle.
- `suite.go` — suite orchestration.
- `load.go` — load generator.

## Key integration tests

- Streaming chat completions.
- Billing and ledger integrity.
- Request encryption (NaCl Box).
- Attestation challenge-response.
- Model alias migration.

## Running a local coordinator

```bash
cd coordinator
go run ./cmd/coordinator
```

By default it uses the in-memory store. Set `EIGENINFERENCE_DATABASE_URL` to
use Postgres.
