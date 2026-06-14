# Test

## Coordinator unit tests

```bash
make coordinator-test
```

Run with `-race` for race detection:

```bash
cd coordinator && go test -race ./...
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
