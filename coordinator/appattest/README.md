# App Attest

Start here for coordinator App Attest verification, session orchestration and tests.

```text
appattest/
  verify.go, authenticator.go       Apple certificate, nonce, key and assertion checks
  receipt.go, authorization.go     Receipt verification and pure authorization policy
  code_measurement.go              Apple-signed executable measurement parsing
  *_test.go                       Unit tests for those private verification helpers
  testdata/                       Recorded, sanitized proof fixtures
  service/
    service.go                    Constructor, dependencies, lifetime and public entry points
    config.go, rollout.go          Configuration and supported-client/account cohort rules
    session.go, exchange.go        Bounded connection worker and proof exchanges
    retry.go, key_rotation.go      Bounded retries, dead-key rotation and its short retry
    ready_diagnostics.go           Ready-reply diagnostics carried through an attempt; derived reboot/restart fields
    enrollment_backoff.go          Six-hour wait after repeated fresh-key invalid-key enrollments
    archive.go, storage.go         Durable evidence recording and shared storage limits
    receipt*.go, maintenance.go    Receipt renewal and evidence recovery
    inventory*.go                 Identity/OS observations and reconciliation workers
    build_qualifications.go         Durable approval snapshots, expiry and revocation fencing
    authorizer.go, policy.go       Current serving authorization and revocation refresh
    authorization*.go             Identity association, readiness and operator status
    *_test.go                     Feature unit tests beside the code under test
```

The root package is pure verification: it does not import the API, registry or store. The service consumes explicit store/registry dependencies and callbacks for telemetry, status delivery and an immutable release-policy snapshot. It never imports the API server.

## Integration boundaries

| Package | What remains there and why |
|---|---|
| `coordinator/api` | `app_attest.go` wires the feature; `app_attest_release.go` adapts the shared signed-release catalog; `app_attest_revocation.go` authenticates HTTP requests. HTTP/WebSocket and real encrypted-inference tests stay with these adapters. |
| `coordinator/registry` | Live provider/connection state, scheduler and final-writer locks, credential fences and reservation checks. These methods must stay with the registry that owns those invariants. |
| `coordinator/store` | PostgreSQL/memory implementations and atomic transactions for credentials, proofs, receipts and canonical identities. Storage contracts are tested against both backends there. |
| `coordinator/protocol` | Canonical shared message types and transcript encoding, mirrored by the Swift provider. |

## Why tests are beside the code

In Go, a directory is a package. Tests named `*_test.go` in that package can exercise private parsers, state machines and helpers without exporting them for testing. They are compiled by `go test`, not into the coordinator executable. Test data belongs in `testdata/`; cross-component tests belong with their integration boundary. A separate unit-test directory would require a different package and would lose private access.

From the repository root:

```sh
mise exec -- go test ./coordinator/appattest/...
mise exec -- go test -race ./coordinator/appattest/...
mise exec -- go test ./coordinator/api -run AppAttest
mise exec -- go test ./coordinator/...
```

Runtime controls and guarantees: [authorization reference](../../docs/reference/provider-authorization.md). Physical signed-Mac qualification and rollout: [runbook](../../docs/operations/mdm-optional-rollout.md).
