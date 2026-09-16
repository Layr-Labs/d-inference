# Codebase operation boundaries and refactor decisions

> Last updated: 2026-09-11 · commit `bbb46b21f`

This record maps the objectives of Darkbloom's major operations and explains the
four parallel refactors based on the GPT-OSS prefix-cache branch. The common
base contains 4,160 tracked entries, including three dependency gitlinks. The
inventory covers the repository surface; detailed control-flow review targets
the changed operations. It is not a claim that every line was individually
audited or that the entire repository was rewritten.

## Responsibilities used to choose changes

| Surface | Objective and ownership | Decision |
| --- | --- | --- |
| Coordinator consumer API | Authenticate, lower endpoint requests, dispatch, stream results, settle usage and record outcomes | Share provider-channel arbitration and translated endpoint lifecycle; preserve endpoint-specific completion policy and wire emitters. |
| Coordinator management API | Account, key, device, model, provider and billing operations | Keep authority and resource-specific checks at their existing boundaries. Console duplication is removed on the forwarding side. |
| Registry and routing simulation | Own provider connections, trust/capacity views, queues, reservations, cache routing and model placement | Preserve overlapping authoritative/fallback state views and lock boundaries. Similar-looking reads have different admission meanings. |
| Store, payments and billing | Persist facts; own transactions, integer accounting, idempotency, settlement and external payment products | Preserve transactional differences and invalidation rules. A universal store/payment wrapper would obscure those contracts. |
| Prompt contracts, protocol, media and trust | Canonicalize inputs, bind artifact identity, encrypt messages, bound media reads and verify device/code evidence | Preserve wire compatibility, trust authorities and bounded IO. |
| Provider commands, loop and model operations | Resolve configuration; register, load, serve, download/drain/swap assistants and stop | Simplify shared slot assembly after tracing its callers; preserve load order, assistant policy and process lifecycle. |
| Provider engine and cache | Prepare compatible resources, admit requests, own KV state, settle usage and report cache outcomes | Separate attention-cache preparation, complete-state precedence, request usage synchronization and sampled telemetry. |
| Provider platform services | Discovery, hashing, publishing, diagnostics, updates, signing and fan control | Retain distinct process and platform boundaries; no dependency, model, version or numerical changes. |
| Console server routes | Forward account/billing operations while preserving authentication and browser-facing responses | Two focused adapters replace repeated account and Stripe handlers. Their different auth/status/body rules remain explicit. |
| Console UI and chat | Own session/view state, forms, withdrawal recovery, encrypted streaming and rendering | Keep existing feature hooks and streaming boundaries. Correct stale payout test initialization without changing payout behavior. |
| Admin and landing | SELECT-only operational views; independent static pages/calculator/public stats | Existing query, server/client and pure-calculation boundaries are useful; no cross-application abstraction introduced. |
| Testbed | Create isolated dependencies and users, launch owned providers, admit wire evidence, drive requests and clean up | Keep `Suite` as the lifecycle coordinator. Give coordinator/store setup, provider launch and registration admission focused owners. |
| Scripts, workflows and deployment | Build exact artifacts; measure controlled runs; install, register or deploy through operation-specific gates | Keep launch ownership, provenance, receipt validation and deployment authority distinct. No workflow or deployment mutation is included. |
| Dependencies, fixtures, reports and legal/static assets | Supply pinned runtime implementations, reproducible inputs and historical records | Preserve pins and frozen evidence. Relocation is not a reason to rewrite third-party code or historical receipts. |

## Concrete implementation

The provider workstream is [PR #897](https://github.com/Layr-Labs/d-inference/pull/897).
`EngineV2SlotFactory.makeProductionBundle` delegates ordered attention-cache
gates to `prepareAttentionPrefixCache`, retaining complete-checkpoint precedence
even when that store is disabled or unavailable. Model preparation has one
call, Gemma diagnostics have one owner, and cache telemetry shares one builder.
The lock-protected request usage signal moves unchanged. Production code is
88 lines smaller across all changed and new files; the slot factory drops from
827 to 509 lines and the bridge cache surface from 411 to 59.

The coordinator workstream is [PR #898](https://github.com/Layr-Labs/d-inference/pull/898).
`relayProviderStream` replaces three select/drain/flush loops.
`handleEndpointStreamingResponse` replaces duplicated translated-endpoint
orchestration; `streamCompletionPolicy` names the existing Responses versus
Messages/Completions completion differences. Chat keeps its authoritative
usage, held finish frames and metadata. Production code is 127 lines smaller.

The web workstream is [PR #899](https://github.com/Layr-Labs/d-inference/pull/899).
Fifteen operations in twelve route files become declarations over
`proxyAccount` and `proxyStripe`. Authentication before body/parameter work,
opaque resource IDs, one-time secrets, raw account passthrough and Stripe JSON
normalization remain unchanged. Production code is 135 lines smaller. Tests
add verification code rather than being removed to improve the line count.

The testbed workstream keeps `suite.go` focused on startup/cleanup sequencing
(723 to 186 lines). `coordinator.go` owns the store, users and HTTP coordinator;
`suite_providers.go` owns launch credentials and attempts;
`suite_registration.go` owns admission; and `provider_capabilities.go` validates
original signed claims with ordered early returns. The one-use listener and
command wrappers are removed. This decomposition reduces nesting and the
largest file rather than promising a total line reduction after module headers
and new tests are included.

## Validation and review boundaries

The testbed passes `go test -race -short ./e2e/testbed/...` and targeted E2E
CPU tests for connected fixtures, release defaults and benchmark configuration.
New cases cover missing/invalid signatures, chip/library/capability mismatch,
first-error precedence, order/duplicate-insensitive capability sets, original
privacy snapshots, account fallback and refusal before hardware-trust promotion.
An independent agent compared startup, cleanup and admission ordering to the base.

The console passes 730 tests in 90 files, lint and a Node 22 production build.
Thirty-six added route-contract cases pass against both base and refactor.
Three existing payout tests needed the current initialization guard respected;
their original failures were reproduced first. Repository-wide TypeScript
checking has thirteen pre-existing diagnostics, identical before and after;
focused changed-file type checking passes and the existing Next build setting
still skips global type checking. This refactor does not represent a clean
repository-wide type check.

Coordinator verification targets SSE golden/burst/coalescing/usage behavior,
completion policy, refunds and cancellation. Provider verification targets
optimized slot/cache/bridge/MTP/Gemma tests on the dedicated M5. Source commits,
final test receipts and current CI/Codex review states are recorded in each PR,
so this dated inventory does not stand in for a green final-head check.

All four branches start at `bbb46b21f` and have separate source ownership. They
can be reviewed independently after their common GPT-OSS dependency. Existing
GPT-OSS performance measurements remain base evidence, not new measurements of
the refactor. No release, merge, catalog update or deployment is part of this work.
