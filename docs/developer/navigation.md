# Find and organize code

> Last updated: 2026-09-14 · commit `93daffe4b`

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
| Process startup, configuration binding and shutdown | `coordinator/cmd/coordinator/main.go` (`main`); follow each named setup function to its subsystem file in the same command package. [Startup source map](../architecture/components/coordinator.md#startup-sequence) |
| API request handling, auth, attestation, dispatch | `coordinator/api/`; server construction in `server.go` (`NewServer`) |
| HTTP response caching and refresh coalescing | `coordinator/api/readcache/`; catalog fill fences in `generation.go` (`SetIfCurrent`, `SetValueIfCurrent`) |
| Chat/Responses/Completions/Messages formatting and relays | `coordinator/inference/response/` (`Writer`, `ChatSink`, `EndpointSink`); lifecycle and accepted-write binding in `coordinator/api/response_writer.go` |
| Attempt cancellation, terminal correlation and provider feedback | `coordinator/inference/attempt/` (`Service`, private `Tracker` state); `coordinator/api/inference_attempt.go` binds current services and the shared tracker |
| Inference reservations, refunds and completion accounting | `coordinator/inference/settlement/` (`Service`, `ServiceHolds`, `Holder`); live dependencies in `coordinator/api/inference_settlement.go`, terminal lifecycle in `coordinator/api/provider.go` |
| Tool schemas, tool-choice policy and tool-call history | `coordinator/inference/toolpolicy/`; `NormalizeParsed` and `ValidateParsed` preserve validation of the original schemas |
| Metrics and asynchronous observation writes | `coordinator/telemetry/metrics/`, `coordinator/telemetry/routequeue/`, `coordinator/telemetry/profilequeue/`, `coordinator/telemetry/outcomequeue/`; API adapters supply request context and persistence dependencies |
| Operator telemetry reads and exports | `coordinator/api/operations/` (`Controller`); `routes.go`, `rejections.go`, `profiles.go`, `snapshots.go`, `request_outcomes.go`, `metrics.go`, `utilization.go`; current owner bindings in `coordinator/api/operations.go` (`newOperations`) |
| Profile construction, provider diagnostics and sampling | `coordinator/telemetry/profiler/` (`Builder`, `Profiler`); request/terminal lifecycle wiring remains in `coordinator/api/profiler.go` |
| Durable device evidence, revocation and reconnect continuity | `coordinator/providercontrol/trustreuse/` (`Manager`); HTTP lifecycle integration remains in `coordinator/api/` |
| Provider challenge nonces, replies and verification | `coordinator/providercontrol/challenge/` (`Session`, `Verifier`); `coordinator/api/provider_challenge.go` binds current dependencies and `providerReadLoop` owns the connection lifecycle |
| Registration, reconnect state and device verification | `coordinator/providercontrol/verification/` (`Verifier`, `Attempt`); `coordinator/api/provider_verification.go` binds current resources; durable scheduling and command ownership live in `coordinator/providercontrol/mdmscheduler/` (`Scheduler`) |
| Code-identity proof, APNs budgets and encrypted resume | `coordinator/providercontrol/codeidentity/` (`Manager`); the API adapter binds the release snapshot, startup proof store and live coverage store |
| Readiness, admin draining and graceful shutdown | `coordinator/api/readiness/` (`Controller.Gate`, `Ready`, `Drain`, `WaitForInflightZero`); `coordinator/api/drain.go` binds one owner for routes and public shutdown methods |
| Downloading a coordinator state archive | `coordinator/api/statearchive/` (`Controller.Download`, root selection, streamed byte accounting); `coordinator/stateexport/` (`Archiver.Stage`, `Write`, `EncryptWriter`) |
| Release HTTP, artifact validation, discovery and deactivation | `coordinator/api/releases/` (`Controller`); `coordinator/api/releases.go` binds current inventory, cache and policy dependencies; `coordinator/api/admin_auth.go` retains admin authorization and OTP |
| Active releases, binary allowlists, runtime verification and evidence generations | `coordinator/providercontrol/releasepolicy/` (`Manager`, `Snapshot`); `coordinator/api/release_policy.go` binds inventory and fleet |
| HTTP credentials and API-key cache | `coordinator/api/requestauth/` (`Authenticator`); current Server bindings in `coordinator/api/authentication.go`; Privy cryptographic verification in `coordinator/auth/` |
| Account keys, per-key policy, device login and invites | `coordinator/api/accounts/` (`Controller`); `account_controller.go` binds current store/configuration and the shared authenticator; `authorization.go` owns the in-handler admin check |
| Public stats, geography, earnings totals and leaderboards | `coordinator/api/network/`; `controller.go` (`Controller`) owns refresh state, `stats_snapshot.go` owns fleet aggregation, and `totals_refresh.go` bounds concurrent earnings queries |
| Account provider dashboard and offline-machine removal | `coordinator/api/accountfleet/`; `merge.go` reconciles persisted and live machines, `summary_cache.go` coalesces account earnings, and `removal.go` preserves ownership checks |
| Provider selection and live reservations | `coordinator/registry/`; request eligibility in `request_traits.go` (`providerEligibleForTraitsLocked`) |
| Token/KV and memory admission calculations | `coordinator/registry/admission/` (`Policy`); immutable field adapter in `coordinator/registry/admission_policy.go` |
| Cache receipt proofs, holder indexes and lifecycle | `coordinator/registry/cachedirectory/` (`Directory`); live capability/connection prerequisites in `coordinator/registry/cache_receipts_v2.go` |
| Cache preparation, queued-frame revocation and terminal lifetime | `coordinator/registry/cacheattempt/` (`State`, `Snapshot`); live connection/capability publication adapter in `coordinator/registry/cache_attempt_ownership.go` |
| Provider-version comparison and slot layout | `coordinator/registry/providerversion/` (`Policy`); shared interpreter binding in `coordinator/registry/provider_version.go` |
| Pending model commands and heartbeat plan timing | `coordinator/registry/modelloads/` (`Commands`, `PlanGate`); live selection in `coordinator/registry/model_load_plan.go`, command adapters in `coordinator/registry/model_load_state.go` |
| Warm-pool control loop, pressure and latest observations | `coordinator/registry/warmpool/` (`Controller`, `State`, `Snapshot`); live fleet/eligibility adapters in `coordinator/registry/warm_pool_fleet.go` and `coordinator/registry/warm_pool_eligibility.go` |
| Provider socket writes, cancellation and watchdog | `coordinator/registry/providerwriter/` (`Writer`); current provider binding in `coordinator/registry/provider_writer.go`; handoff transaction in `handoff.go`, priority/serve in `run.go`, socket fragments in `frames.go` |
| Identity fault histories and session migration | `coordinator/registry/faultstate/`; registry bindings in `coordinator/registry/fault_binding.go` and `coordinator/registry/fault_capacity.go` |
| Provider wire records and decoding | `coordinator/protocol/doc.go` maps message families; `coordinator/protocol/messages.go` (`DecodeProviderMessage`) owns dispatch by `type`; [protocol reference](../reference/protocol-messages.md#source-files) maps records to files. |
| Routing latency and reservation | `coordinator/registry/routingcost/` owns shared calibration and startup tuning; `coordinator/registry/reservation.go`, `coordinator/registry/reservation_commit.go`, `coordinator/registry/routing_scan.go` retain live registry transactions; `coordinator/registry/candidate_cost.go` composes cost over the same snapshot. |
| Retained dispatch plans and capacity probes | `coordinator/registry/dispatchplan/plan.go` (`Plan`), `coordinator/registry/dispatchplan/quotes.go` (`Probes`); private wrapper in `coordinator/registry/dispatch_plan.go`; live identity/admission in `coordinator/registry/plan_reservation.go`, refresh in `coordinator/registry/plan_refresh.go` and transport in `coordinator/registry/capacity_quotes.go` |
| Queue storage and throughput | `coordinator/registry/requestqueue/`, `coordinator/registry/throughput/`; live provider state and reservation orchestration stay in `coordinator/registry/` |
| Billing, pricing, referrals and payout endpoints | `coordinator/api/billing/` (`Controller`); route and shared-dependency binding in `coordinator/api/billing_controller.go` |
| Model publishing, discovery and aliases | `coordinator/api/catalog/` (`Controller`); shared bindings in `coordinator/api/catalog_controller.go`; runtime publication stays in `server.go` (`SyncModelCatalog`) |
| Financial services and durable state | `coordinator/billing/`, `coordinator/payments/`, `coordinator/store/contracts/`, `coordinator/store/postgres/`, `coordinator/store/memory/`, `coordinator/store/cache/` |
| Provider inference, downloads, security, local serving | `provider-swift/Sources/ProviderCore/`; entrypoints in `provider-swift/Sources/darkbloom/` |
| Portable model manifests and hashing | `provider-swift/Sources/ProviderCoreFoundation/`; target defined in `provider-swift/Package.swift` (`package`) |
| Console, operations dashboard, landing page | `console-ui/src/`, `admin-ui/src/`, `landing/` |
| System tests and shared inputs | `e2e/`, `fixtures/`; lifecycle harness in `e2e/testbed/` |
| Build, install, release, deploy | `Makefile`, `scripts/`, `.github/workflows/`, `deploy/` |

The dependency repositories are Git submodules under `libs/`, declared in
`.gitmodules`. The [docs index](../README.md) separates current instructions
from historical designs and reports.

### 2. Search filenames, then symbols

Find likely files before searching their contents:

```bash
rg --files coordinator/api -g '*attest*'
rg --files provider-swift/Sources provider-swift/Tests -g '*PrefixCache*'
rg --files console-ui/src -g '*Auth*' -g '*auth*'
```

Then find the implementation and its callers or tests:

```bash
rg -n 'recordRequestOutcome|classifyOutcomeByCode' coordinator/api
rg -n 'StatusCanonical' provider-swift/Sources provider-swift/Tests coordinator/attestation
```

Scope runtime searches to source and test directories. Search `docs/reports/`
separately when you need measurements or the state at a historical commit.

### 3. Name and place files by responsibility

Use the feature followed by the behavior: `code_attest_reuse_policy_test.go`
groups the attestation reuse policy cases, and `coordinator/api/billing/connect_transfer_reversal_test.go`
groups transfer reversal cases. A shared fixture belongs in a domain-specific
helper file, such as `coordinator/api/attestation_helpers_test.go`
(`testStatusSignature`).

Split unrelated test collections by the contracts they verify. Work-wave,
priority, and ticket labels belong in commit history. Meaningful protocol,
engine, model, and fixture-version identifiers belong in names when they
distinguish supported behavior.

Keep Go tests beside their owning package: a new directory creates a new Go
package and may change access to unexported code. Within a SwiftPM target or UI
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

## Related

- [Build](build.md)
- [Test](test.md)
- [Repository structure and contribution rules](../../AGENTS.md)
