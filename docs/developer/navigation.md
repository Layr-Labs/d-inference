# Find and organize code

> Last updated: 2026-09-14 · commit `5f2c53f32`

Use this guide to find the code behind a behavior and place new files beside
their owners. Start from the subsystem, then search for the request, command,
type, or test name you are investigating.

## Prerequisites

Run the commands below from the repository root with `rg` installed.
Build and test prerequisites are in [build.md](build.md) and [test.md](test.md).

## Steps

### 1. Choose the owning subsystem

#### HTTP composition

| Behavior | Start here |
|---|---|
| Process startup, configuration binding and shutdown | `coordinator/cmd/coordinator/main.go` (`main`); follow each named setup function to its subsystem file in the same command package. [Startup source map](../architecture/components/coordinator.md#startup-sequence) |
| Server construction and HTTP route registration | `coordinator/api/server.go` (`NewServer`); `coordinator/api/routes.go` (`routes`) |
| HTTP body caps, CORS, panic recovery and request logging | `coordinator/api/http_middleware.go` (`Handler`); `coordinator/api/http_logging.go` (`loggingMiddleware`) |
| Per-account/per-key rate limits and token admission | `coordinator/api/request_rate_limits.go` (`rateLimitWithTier`); `coordinator/inference/ingress/tokens.go` (`applyTokenRateLimitWithAdmission`, `ReconcileOutputAdmission`); `coordinator/api/token_admission.go` (`SetTokenLimiters`) |
| Installer URL rendering | `coordinator/api/installer.go` (`resolveBaseURL`, `installScript`) |
| HTTP response caching and refresh coalescing | `coordinator/api/readcache/cache.go` (`Cache`); `coordinator/api/readcache/refresher.go` (`Refresher`); catalog fill fences in `coordinator/api/readcache/generation.go` (`SetIfCurrent`, `SetValueIfCurrent`) |
| Readiness, admin draining and graceful shutdown | `coordinator/api/readiness/gate.go` (`Gate`); `coordinator/api/readiness/probe.go` (`Ready`); `coordinator/api/readiness/drain.go` (`Drain`); `coordinator/api/readiness/shutdown.go` (`WaitForInflightZero`); route and shutdown binding in `coordinator/api/drain.go` (`readinessController`) |
| HTTP credentials and API-key cache | `coordinator/api/requestauth/authenticator.go` (`Authenticator`); current Server bindings in `coordinator/api/authentication.go` (`authenticationSettings`, `authenticationStore`); Privy verification in `coordinator/auth/privy.go` (`PrivyAuth`) |

#### Consumer inference

| Behavior | Start here |
|---|---|
| Consumer request parsing, media and admission | `coordinator/inference/ingress/chat.go` (`ChatCompletions`), `coordinator/inference/ingress/endpoints.go` (`Completions`, `Messages`); current dependency bindings in `coordinator/api/inference_ingress.go` (`inferenceIngress`). [Request stages and code map](../architecture/components/consumer.md#the-request-pipeline) |
| Inference dispatch, queue handoff, hedging and failover | `coordinator/inference/dispatch/request.go` (`Run`); current-service and observation bindings in `coordinator/api/inference_dispatch.go` (`inferenceDispatch`) |
| Chat/Responses/Completions/Messages formatting and relays | `coordinator/inference/response/writer.go` (`Writer`), `coordinator/inference/response/provider_stream.go` (`relayProviderStream`), `coordinator/inference/response/endpoint_stream.go` (`finishEndpointStream`); lifecycle and accepted-write binding in `coordinator/api/response_writer.go` (`responseWriter`) |
| Attempt cancellation, terminal correlation and provider feedback | `coordinator/inference/attempt/service.go` (`Service`); `coordinator/inference/attempt/cancel_tracker.go` (`Tracker`); current services and shared tracker in `coordinator/api/inference_attempt.go` (`inferenceAttempts`) |
| Provider acceptance, encrypted chunks and terminal ownership | `coordinator/inference/providerframe/service.go` (`Service`); current services and shared observations in `coordinator/api/provider_frames.go` (`inferenceFrames`) |
| Inference reservations, refunds and completion accounting | `coordinator/inference/settlement/service.go` (`Service`); `coordinator/inference/settlement/service_holds.go` (`ServiceHolds`); `coordinator/inference/settlement/holder.go` (`Holder`); live dependencies in `coordinator/api/inference_settlement.go` (`inferenceSettlement`); terminal lifecycle in `coordinator/inference/providerframe/complete.go` (`CompleteAt`) |
| Tool schemas, tool-choice policy and tool-call history | `coordinator/inference/toolpolicy/normalize.go` (`NormalizeParsed`); `coordinator/inference/toolpolicy/validate.go` (`ValidateParsed`, `ValidateBytes`) preserve validation of the original schemas |

#### Provider trust and wire protocol

| Behavior | Start here |
|---|---|
| Durable device evidence, revocation and reconnect continuity | `coordinator/providercontrol/trustreuse/manager.go` (`Manager`); HTTP lifecycle integration in `coordinator/api/trust_reuse.go` (`trustReuseDependencies`) |
| Provider connection, registration publication, heartbeat and teardown | `coordinator/providercontrol/session/read.go` (`Run`); `coordinator/api/provider_session.go` (`providerSessionDependencies`) binds current resources and the four inference-frame callbacks |
| Provider challenge nonces, replies and verification | `coordinator/providercontrol/challenge/session.go` (`Session`); `coordinator/providercontrol/challenge/dependencies.go` (`Verifier`); current dependencies in `coordinator/api/provider_challenge.go` (`newProviderChallengeVerifier`); connection lifecycle in `coordinator/providercontrol/session/read.go` (`Run`) |
| Registration, reconnect state and device verification | `coordinator/providercontrol/verification/dependencies.go` (`Verifier`); `coordinator/providercontrol/verification/attempt.go` (`Attempt`); current resources in `coordinator/api/provider_verification.go` (`newProviderVerifier`); durable scheduling and commands in `coordinator/providercontrol/mdmscheduler/scheduler.go` (`Scheduler`) |
| Code-identity proof, APNs budgets and encrypted resume | `coordinator/providercontrol/codeidentity/manager.go` (`Manager`); `coordinator/api/provider_codeattest.go` (`codeIdentityDependencies`) binds release policy, the startup proof store and live coverage |
| Active releases, binary allowlists, runtime verification and evidence generations | `coordinator/providercontrol/releasepolicy/manager.go` (`Manager`); `coordinator/providercontrol/releasepolicy/snapshot.go` (`Snapshot`); inventory and fleet bindings in `coordinator/api/release_policy.go` (`releasePolicyDependencies`) |
| MicroMDM device evidence | `coordinator/mdm/doc.go` maps the exchange; `coordinator/mdm/command_policy.go` (`assertReadOnlyCommand`) restricts outbound requests; `coordinator/mdm/webhook.go` (`HandleWebhook`) correlates and delivers replies. |
| Provider wire records and decoding | `coordinator/protocol/doc.go` maps message families; `coordinator/protocol/provider_message.go` (`DecodeProviderMessage`) owns dispatch by `type`; [protocol reference](../reference/protocol-messages.md#source-files) maps records to files. |

#### Public, account and admin APIs

| Behavior | Start here |
|---|---|
| Operator telemetry reads and exports | `coordinator/api/operations/controller.go` (`Controller`); route records in `coordinator/api/operations/routes.go` (`Routes`, `RoutesExport`); current owner bindings in `coordinator/api/operations.go` (`newOperations`) |
| Downloading a coordinator state archive | `coordinator/api/statearchive/handler.go` (`Download`) selects roots and counts streamed bytes; `coordinator/stateexport/archive.go` (`Stage`, `Write`); `coordinator/stateexport/encrypt.go` (`EncryptWriter`) |
| Release HTTP, artifact validation, discovery and deactivation | `coordinator/api/releases/controller.go` (`Controller`); `coordinator/api/releases.go` (`newReleaseAPI`) binds current inventory, cache and policy dependencies; `coordinator/api/admin_auth.go` (`isAdminAuthorized`, `handleAdminAuthInit`, `handleAdminAuthVerify`) retains admin authorization and OTP |
| Account keys, per-key policy, device login and invites | `coordinator/api/accounts/controller.go` (`Controller`); `coordinator/api/account_controller.go` (`accountController`) binds the current store, configuration and shared authenticator; in-handler admin check in `coordinator/api/authorization.go` (`requireAdminKey`) |
| Public stats, geography, earnings totals and leaderboards | `coordinator/api/network/controller.go` (`Controller`) owns refresh state; `coordinator/api/network/stats_snapshot.go` (`computeStats`) aggregates the fleet; `coordinator/api/network/totals_refresh.go` (`refreshNetworkTotals`) bounds concurrent earnings queries |
| Account provider dashboard and offline-machine removal | `coordinator/api/accountfleet/merge.go` (`mergeFleet`) reconciles persisted and live machines; `coordinator/api/accountfleet/summary_cache.go` (`accountEarningsWindows`) coalesces account earnings; `coordinator/api/accountfleet/removal.go` (`DeleteProvider`) preserves ownership checks |
| Billing, pricing, referrals and payout endpoints | `coordinator/api/billing/controller.go` (`Controller`); route and shared-dependency binding in `coordinator/api/billing_controller.go` (`billingController`) |
| Model publishing, discovery and aliases | `coordinator/api/catalog/controller.go` (`Controller`); shared bindings and runtime publication in `coordinator/api/catalog_controller.go` (`catalogController`, `SyncModelCatalog`) |

#### Registry capacity and routing

| Behavior | Start here |
|---|---|
| Provider selection and live reservations | `coordinator/registry/reservation.go` (`ReserveProviderEx`); request eligibility in `coordinator/registry/request_traits.go` (`providerEligibleForTraitsLocked`) |
| Token/KV and memory admission calculations | `coordinator/registry/admission/snapshot.go` (`Policy`); immutable field adapter in `coordinator/registry/admission_policy.go` (`admissionPolicy`, `admissionSnapshot`) |
| Cache receipt proofs, holder indexes and lifecycle | `coordinator/registry/cachedirectory/directory.go` (`Directory`); live capability and connection prerequisites in `coordinator/registry/cache_receipts_v2.go` (`ApplyPrefixCacheReadyV2Result`, `ApplyPrefixCacheLookupV2Result`, `PreparePrefixCacheV2Attempt`) |
| Cache preparation, queued-frame revocation and terminal lifetime | `coordinator/registry/cacheattempt/state.go` (`State`); `coordinator/registry/cacheattempt/snapshot.go` (`Snapshot`); live connection and capability publication in `coordinator/registry/cache_attempt_ownership.go` (`publishCacheAttempt`) |
| Provider-version comparison and slot layout | `coordinator/registry/providerversion/policy.go` (`Policy`); shared interpreter binding in `coordinator/registry/provider_version.go` (`CompareVersions`, `slotBudgetLayoutForVersion`) |
| Pending model commands and heartbeat plan timing | `coordinator/registry/modelloads/commands.go` (`Commands`); `coordinator/registry/modelloads/plan_gate.go` (`PlanGate`); live selection in `coordinator/registry/model_load_plan.go` (`planModelLoadActions`); command adapters in `coordinator/registry/model_load_state.go` (`ClearIneligiblePendingModelLoads`, `HasPendingModelLoad`) |
| Warm-pool control loop, pressure and latest observations | `coordinator/registry/warmpool/owner.go` (`Controller`); `coordinator/registry/warmpool/state.go` (`State`); `coordinator/registry/warmpool/snapshots.go` (`Snapshot`); live adapters in `coordinator/registry/warm_pool_fleet.go` (`warmPoolFleetSnapshot`) and `coordinator/registry/warm_pool_eligibility.go` (`warmPoolCandidateLocked`) |
| Routing latency and reservation | `coordinator/registry/routingcost/policy.go` (`Policy`) owns shared calibration and startup tuning; live transactions in `coordinator/registry/reservation.go` (`ReserveProviderEx`), `coordinator/registry/reservation_commit.go` (`commitProviderReservation`) and `coordinator/registry/routing_scan.go` (`scanCandidatesLocked`); snapshot cost in `coordinator/registry/candidate_cost.go` (`buildCandidateInto`) |
| Retained dispatch plans and capacity probes | `coordinator/registry/dispatchplan/plan.go` (`Plan`); `coordinator/registry/dispatchplan/quotes.go` (`Probes`); private wrapper in `coordinator/registry/dispatch_plan.go` (`DispatchPlan`); live admission in `coordinator/registry/plan_reservation.go` (`ReserveProviderWithPlan`, `ReserveNextFromPlan`); refresh in `coordinator/registry/plan_refresh.go` (`RefreshDispatchPlan`); transport in `coordinator/registry/capacity_quotes.go` (`ProbePlanCandidates`) |

#### Registry lifecycle and state

| Behavior | Start here |
|---|---|
| Provider socket writes, cancellation and watchdog | `coordinator/registry/providerwriter/writer.go` (`Writer`); current provider binding in `coordinator/registry/provider_writer.go` (`newProviderWriter`, `WriteText`); handoff in `coordinator/registry/providerwriter/handoff.go` (`writeRequest`); priority and serving in `coordinator/registry/providerwriter/run.go` (`run`, `serve`); socket fragments in `coordinator/registry/providerwriter/frames.go` (`writeFrame`) |
| Registry connection lifecycle | `coordinator/registry/provider_registration.go` (`Register`), `coordinator/registry/provider_disconnect.go` (`disconnectProvider`), `coordinator/registry/provider_eviction.go` (`evictStale`); shared record in `coordinator/registry/provider.go` (`Provider`) |
| Heartbeat state and snapshots | `coordinator/registry/heartbeat.go` (`Heartbeat`); `coordinator/registry/heartbeat_snapshot.go` (`canonicalHeartbeatModelState`, `BackendCapacitySnapshot`), `coordinator/registry/capacity_report.go` (`clampBackendCapacity`) and `coordinator/registry/heartbeat_stats.go` (`applyHeartbeatStatsDelta`) |
| Live evidence and trust transitions | `coordinator/registry/device_evidence.go` (`GrantHardwareEvidenceAtEpochIfNotUntrusted`), `coordinator/registry/application_evidence.go` (`GrantApplicationEvidenceIfNotUntrusted`), `coordinator/registry/code_evidence.go` (`GrantProcessCodeAttested`), `coordinator/registry/provider_trust.go` (`markUntrusted`) and `coordinator/registry/provider_challenges.go` (`RecordChallengeSuccess`) |
| Reconnect restoration and persistence | `coordinator/registry/provider_restore.go` (`RestoreProviderStateContext`), `coordinator/registry/persistence.go` (`persistProviderNow`) and `coordinator/registry/reputation_persistence.go` (`persistReputationNow`) |
| Identity fault histories and session migration | `coordinator/registry/faultstate/manager.go` (`Manager`, `Session`); `coordinator/registry/faultstate/capacity_accept.go` (`CapacityAccept`); registry bindings in `coordinator/registry/fault_binding.go` (`bindStableFaultKey`) and `coordinator/registry/fault_capacity.go` (`RecordCapacityAcceptObserved`) |
| Queue storage and throughput | `coordinator/registry/requestqueue/queue.go` (`Queue`); `coordinator/registry/throughput/observations.go` (`Observations`); `coordinator/registry/throughput/policy.go` (`Policy`); live provider state and reservation orchestration stay in the registry package |

#### Persistence and observability

| Behavior | Start here |
|---|---|
| Metrics and asynchronous observation writes | `coordinator/telemetry/metrics/registry.go` (`Registry`); `coordinator/telemetry/routequeue/queue.go` (`Sink`); `coordinator/telemetry/profilequeue/queue.go` (`Sink`); `coordinator/telemetry/outcomequeue/queue.go` (`Sink`); API adapters supply request context and persistence dependencies |
| Profile construction, provider diagnostics and sampling | `coordinator/telemetry/profiler/record.go` (`Builder`); `coordinator/telemetry/profiler/profiler.go` (`Profiler`); request and terminal lifecycle in `coordinator/api/profiler.go` (`newRequestProfile`, `finalizeAttemptProfile`) |
| Stripe Connect accounts, payouts and webhooks | `coordinator/billing/stripe_connect.go` (`StripeConnect`) maps the client files; `coordinator/billing/stripe_connect_accounts.go` (`CreateExpressAccount`), `coordinator/billing/stripe_connect_transport.go` (`do`), `coordinator/billing/stripe_connect_errors.go` (`APIError`) and `coordinator/billing/stripe_connect_webhooks.go` (`VerifyConnectWebhookSignature`) own the operations |
| Financial services and durable state | `coordinator/billing/billing.go` (`Service`); `coordinator/payments/payments.go` (`Ledger`); `coordinator/store/contracts/store.go` (`Store`); `coordinator/store/postgres/store.go` (`Store`); `coordinator/store/memory/store.go` (`Store`); `coordinator/store/cache/store.go` (`Store`) |

#### Other repository areas

| Behavior | Start here |
|---|---|
| Provider inference, downloads, security, local serving | `provider-swift/Sources/darkbloom/Darkbloom.swift`; `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient.swift`; `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`; `provider-swift/Sources/ProviderCore/Security/SecureEnclaveIdentity.swift`; `provider-swift/Sources/ProviderCore/Server/StandaloneServer.swift` |
| Portable model manifests and hashing | `provider-swift/Sources/ProviderCoreFoundation/Manifest.swift`; `provider-swift/Sources/ProviderCoreFoundation/ManifestBuilder.swift`; `provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift`; `provider-swift/Sources/ProviderCoreFoundation/WeightHasher.swift`; target defined in `provider-swift/Package.swift` |
| Console, operations dashboard, landing page | `console-ui/src/app/page.tsx`; `admin-ui/src/app/page.tsx`; `landing/index.html` |
| System tests and shared inputs | `e2e/integration_test.go`; lifecycle harness in `e2e/testbed/coordinator.go`; shared prompt inputs in `fixtures/prompt-contract/v1/corpus.json` |
| Build, install, release, deploy | `Makefile`; `scripts/install.sh`; `.github/workflows/release-swift.yml`; `deploy/environments/prod.env` |

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
rg -n 'recordRequestOutcome|ClassifyOutcomeByCode' coordinator/api coordinator/inference/dispatch
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
