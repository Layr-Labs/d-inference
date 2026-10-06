# App Attest

Start here for coordinator App Attest verification, session orchestration and tests.

```text
coordinator/
  appattest/
    verify.go, receipt.go, authorization.go  Public verification and policy entry points
    service/                                Session orchestration and dependency adapters
  internal/appattest/
    proof/, receipt/, transcript/           Cryptographic verification and binding
    exchange/, recovery/, storage/          Proof exchange and durable recovery
    authorization/, qualification/          Serving and release-approval fences
    cohort/, eligibility/, input/           Enrollment policy and bounded inputs
    diagnostics/, evidence/                 Operational evidence and ready diagnostics
    inventory/, observation/                Identity observations and reconciliation
  tests/appattest/
    *_test.go                               Verification and policy tests
    testdata/                               Recorded, sanitized proof fixtures
    service/                                Mirrored component and service tests
  tests/api/                                HTTP, WebSocket and inference contracts
```

The root package is pure verification: it does not import the API, registry or store. The service consumes explicit store/registry dependencies and callbacks for telemetry, status delivery and an immutable release-policy snapshot. It never imports the API server.

## Integration boundaries

| Package | What remains there and why |
|---|---|
| `coordinator/api/provider/trust` | App Attest adapters wire the feature, adapt the shared signed-release catalog and authenticate revocation requests. HTTP/WebSocket tests live under `coordinator/tests/api/provider/`; encrypted-inference tests live under `coordinator/tests/api/inference/`. |
| `coordinator/registry` | Live provider/connection state, scheduler and final-writer locks, credential fences and reservation checks. These methods must stay with the registry that owns those invariants. |
| `coordinator/store` | PostgreSQL/memory implementations and atomic transactions for credentials, proofs, receipts and canonical identities. Storage contracts under `coordinator/tests/store/` exercise both backends. |
| `coordinator/protocol` | Canonical shared message types and transcript encoding, mirrored by the Swift provider. |

## Isolated tests

All coordinator `*_test.go` files live under `coordinator/tests/`. App Attest
tests exercise the same production-consumed components under
`coordinator/internal/appattest/` that the public verification and service
adapters use. Production packages do not import test infrastructure. Cross-component
tests mirror their API or storage boundary; standard `go test` discovers them.

From the repository root:

```sh
mise exec -- go test ./coordinator/tests/appattest/...
mise exec -- go test -race ./coordinator/tests/appattest/...
mise exec -- go test ./coordinator/tests/api/... -run AppAttest
mise exec -- go test ./coordinator/...
```

Runtime controls and guarantees: [authorization reference](../../docs/reference/provider-authorization.md). Physical signed-Mac qualification and rollout: [runbook](../../docs/operations/mdm-optional-rollout.md).
