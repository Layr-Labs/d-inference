# Find and organize code

> Last updated: 2026-10-04

Use this guide to find the code behind a behavior and place new files beside
their owners. Start from the subsystem, then search for the request, command,
type, or test name you are investigating.

## Prerequisites

Run the commands below from the repository root with `rg` installed.
Build and test prerequisites are in [build.md](build.md) and [test.md](test.md).

## Steps

### 1. Choose the owning subsystem

| Behavior | Start here |
|---|---|
| Process assembly and shutdown | `coordinator/app/`; command parsing stays in `coordinator/cmd/coordinator/` |
| HTTP composition | `coordinator/api/`; `NewServer` binds domain owners to the real router |
| Authentication, principals, keys and device login | `coordinator/api/access/`, `access/keys/`, `access/device/` |
| Request admission, dispatch and settlement | `coordinator/api/inference/`; request/response codecs in its `request/` and `response/` packages |
| Provider sessions and trust | `coordinator/api/provider/` and `provider/trust/`; terminal inference events return to the shared inference owner |
| Catalog publication and release policy | `coordinator/api/catalog/` and `coordinator/api/releases/` |
| Accounts, billing HTTP and payouts | `coordinator/api/accounts/`, `coordinator/api/billing/`, `billing/payouts/` |
| Public projections and operational endpoints | `coordinator/api/reporting/` and `coordinator/api/operations/` |
| Profiles, request outcomes and route sinks | `coordinator/api/observation/`; separate bounded queues retain their own loss/flush rules |
| Prompt accounting and planning | `coordinator/api/promptwork/` and the inference owner |
| Pure deadline calibration | `coordinator/registry/firstcontent/`; runtime adapters remain in `coordinator/registry/` |
| Provider selection, admission, queueing | `coordinator/registry/`; pure calculations in `registry/admission/` and `registry/selection/`, atomic transitions in the registry parent |
| Autopilot admin HTTP contract | `coordinator/api/autopilot/`; parent API adapter supplies authorization and dependencies |
| Autopilot demand, placement and donor coverage | `coordinator/registry/autopilot/`; the registry adapter owns live sessions, reservations and transport |
| Accounting and durable state | `coordinator/billing/`, `coordinator/payments/`; contracts/decorator in `coordinator/store/`, implementations in `store/memory/` and `store/postgres/` |
| Open Sales Program | `coordinator/api/billing/referrals.go` for account-scoped HTTP; `coordinator/billing/referral.go` for registration, attribution and stats; `coordinator/store/consumer_settlement.go` for the atomic charge contract |
| Coordinator tests and fixtures | `coordinator/tests/` mirrors production owners; public API contracts use `tests/api/<domain>/contracts/`, shared helpers use `tests/internal/` |
| Provider inference, downloads, security, local serving | `provider-swift/Sources/ProviderCore/`; entrypoints in `provider-swift/Sources/darkbloom/` |
| Autopilot runtime and operator controls | `ProviderCore/Autopilot/`, `ProviderCore/Protocol/Autopilot/`, and `darkbloom/Autopilot/` under `provider-swift/Sources/`; startup is in `darkbloom/Start/` |
| Portable model manifests and hashing | `provider-swift/Sources/ProviderCoreFoundation/`; target defined in `provider-swift/Package.swift` (`package`) |
| Console, operations dashboard, landing page | `console-ui/src/`, `admin-ui/src/`, `landing/` |
| System tests and shared inputs | `e2e/`, `fixtures/`; lifecycle harness in `e2e/testbed/` |
| Build, install, release, deploy | `Makefile`, `scripts/`, `.github/workflows/`, `deploy/` |

The dependency repositories are Git submodules under `libs/`, declared in
`.gitmodules`. The [docs index](../README.md) separates current instructions
from historical designs and reports.

Production-consumed internal boundaries are not a second application or a test
facade. Start from the API/service owner for orchestration, then follow these
components for the specific invariant:

| Concern | Internal owner |
|---|---|
| Middleware, projections and reporting calculations | `coordinator/internal/api/` |
| Media, provider-body memo/sealing, relay, cancellation, promotions/reservations and outcomes | `coordinator/internal/inference/` |
| Uncertain consumer-charge settlement | `coordinator/internal/inference/consumercharge/settlement.go` (`Engine`); the inference owner supplies completion callbacks and `coordinator/app/services.go` runs maintenance |
| Session/inventory/heartbeat, challenge, identity, MDM and trust authority | `coordinator/internal/provider/` |
| Apple transcript, exchange/evidence/storage, recovery, qualification and authorization | `coordinator/internal/appattest/`; `coordinator/appattest/service/` binds the live session lifecycle and collaborators |
| Independent route/profile/outcome pipelines | `coordinator/internal/observation/` |
| Writer lanes/watchdog, drain authority, identity gates, queue-drain coalescing, bounded demand and detached residency/capacity/forecast/deadline policy | `coordinator/internal/registry/` |
| Connection age/order and eviction grace | `coordinator/internal/registry/connectiontime/origin.go` (`Origin`), `coordinator/internal/registry/eviction/grace.go` (`Grace`); `coordinator/registry/connection_lifecycle.go` binds maintenance to the live registry |
| Live connection membership and advertisement counts | `coordinator/registry/provider_directory.go` (`ProviderDirectory`) shares `Registry.mu`; `coordinator/internal/registry/modelindex/counts.go` (`Counts`) owns live-advertisement counts |
| Restore publication and pending service charges | `coordinator/registry/provider_persistence.go` (`ProviderPersistence`), `coordinator/registry/service_reservations.go` (`ServiceReservations`); both retain the provider's existing lock boundaries |
| Cache restore, maintenance and capability publication | `coordinator/registry/cache_restoration.go`, `coordinator/registry/cache_maintenance.go`, `coordinator/registry/cache_snapshot.go`; factories in `coordinator/registry/cache_dependencies.go` retain the actual tracker/registry |
| Autopilot session authority, bounded control and pending durable phases | `coordinator/internal/registry/autopilotstate/`, `autopilotcontrol/`, `autopilotledger/`; pure placement and demand contracts remain under `coordinator/registry/autopilot/` |
| Routing scan candidate storage | `coordinator/internal/registry/candidatearena/arena.go` (`Arena`, `ChunkSize`); the chunk is sized against `Candidate` (`coordinator/registry/scheduler.go`) and guarded by `coordinator/tests/registry/candidate_arena_test.go` |
| Cache generations, memory history, shared records and SQL helpers | `coordinator/internal/store/` |
| Consumer referral accounting shared by both backends | `coordinator/internal/store/consumersettlement/settlement.go` owns validation, replay, collected-cost and promotion-record rules; `coordinator/store/memory/consumer_settlement.go` and `coordinator/store/postgres/consumer_settlement.go` own atomic writes |
| Sidecar identity, protocol, artifacts, catalog/preload and endpoint lowering | `coordinator/internal/promptcontract/` |
| Remote media policy, read budgets and reference grouping | `coordinator/internal/mediafetch/` |
| Frame scanning and decoding | `coordinator/internal/wire/` |

Application assembly supplies the same registry/store/ledger/read-cache instances
through `api.RuntimeDependencies` (`coordinator/api/server.go`, `NewRuntime`).
See [coordinator assembly](../architecture/components/coordinator.md#startup-sequence)
for startup ordering and cross-owner callback binding.

### 2. Search filenames, then symbols

Find likely files before searching their contents:

```bash
rg --files coordinator/api coordinator/internal coordinator/tests -g '*attest*'
rg --files provider-swift/Sources provider-swift/Tests -g '*PrefixCache*'
rg --files console-ui/src -g '*Auth*' -g '*auth*'
```

Then find the implementation and its callers or tests:

```bash
rg -n 'RecordRequestOutcome|ClassifyOutcomeByCode' coordinator/api coordinator/internal coordinator/tests
rg -n 'StatusCanonical' provider-swift/Sources provider-swift/Tests coordinator/attestation
```

Scope runtime searches to source and test directories. Search `docs/reports/`
separately when you need measurements or the state at a historical commit.

### 3. Name and place files by responsibility

Group a feature's independent logic in its own directory and mirror that owner
under `coordinator/tests/`. For example, `coordinator/api/autopilot/` owns HTTP
validation, with tests in `coordinator/tests/api/autopilot/`.
`coordinator/registry/autopilot/` owns pure policy and demand logic; it imports no registry
or live-provider types. The registry captures detached values and retains session
identity beside them before revalidating a plan. Go methods that need registry,
HTTP-server or store receivers stay in their owning package as integration files.
Swift sources and tests use matching `Autopilot/` feature folders within their
existing targets; the CLI entry point delegates to enrollment, policy, status and
configuration files.

Use the feature followed by the behavior: `code_attest_reuse_policy_test.go`
groups the attestation reuse policy cases, and `stripe_transfer_reversal_test.go`
groups transfer reversal cases. A shared fixture belongs in a domain-specific
helper file, such as `coordinator/tests/api/provider/contracts/helpers_test.go`
(`setupTestServer`).

Split unrelated test collections by the contracts they verify. Work-wave,
priority, and ticket labels belong in commit history. Meaningful protocol,
engine, model, and fixture-version identifiers belong in names when they
distinguish supported behavior.

Keep every coordinator `_test.go` under `coordinator/tests/`. Pure request
normalization and response emitter tests belong in
`coordinator/tests/api/inference/request/` and `coordinator/tests/api/inference/response/`.
Public HTTP/WebSocket contracts belong under `coordinator/tests/api/<domain>/contracts/`
and use the real composed router fixture in
`coordinator/tests/internal/testkit/server.go` (`NewServer`); authenticated
fixtures use locally signed JWTs via `auth.go` (`NewSessions`). `coordinator/tests/api/`
retains composition and global-middleware coverage, not moved domain tests.
Backend conformance lives under `coordinator/tests/store/contracts/`. See
[the test-boundary map](test.md#2-coordinator-go) for fixture and execution rules.
Do not export implementation state merely to move a test. A new directory
creates a new Go package. Retain injected dependencies in test fixtures and
extract cohesive production-consumed components under `coordinator/internal/`
where an invariant crosses a real package boundary. Do not use test-only
production facades, copied implementations, overlays, reflection or `go:linkname`.
Within a SwiftPM target or UI
feature, use folders for cohesive subsystems. Keep small, already focused
targets flat. Put a fixture beside its users; use a shared helper location when
several subsystems actually need it.

### 4. Check consumers before moving a file

Search the old full path and basename across tracked source, scripts, CI,
and current docs. Check relative imports, source-relative fixture lookups,
symlink destinations, build source lists, generated entrypoints, and command
paths. Preserve exported APIs and test names when only changing organization.

Historical reports, release notes, and frozen design bodies retain the paths
from their original source snapshots; follow [the docs rules](../AGENTS.md).
Public script entrypoints and release lookup paths need a compatibility plan
before renaming.

## Verify

Compare the original and moved files, account for every declaration, and
confirm that test discovery still includes the same cases. Run the affected
tests, build or typecheck where imports or source membership changed, and run
`make docs-check` after updating current links. A path move must still load
the same fixture bytes and preserve the same test selection.

Remove obsolete source and test shells rather than leaving package-only files.
`coordinator/tests/api/source_layout_test.go` (`TestAPISourceFilesHaveDeclarations`)
checks Go AST declarations in the API, extracted components and API tests,
excluding `testdata` and allowing `doc.go`. `coordinator/tests/layout_test.go`
enforces the separate test tree and rejects production test imports. Run
`go test ./coordinator/tests/api/...` for API suites; `go test ./coordinator/api`
does not select the tests. The complete `./coordinator/...` selector still does.

The coordinator runner instruments the selected production packages and the
owners of external contract suites before merging atomic coverage profiles.
Do not use a contract package's own statement percentage as coverage of the
implementation it imports. Store test processes allocate separate disposable
databases before running backend fixtures; package parallelism must never make
one suite truncate another suite's tables. The shared administrative-database
advisory lock also protects the server connection budget; see
[store fixture isolation](test.md#2-coordinator-go).

## Related

- [Build](build.md)
- [Test](test.md)
- [Repository structure and contribution rules](../../AGENTS.md)
