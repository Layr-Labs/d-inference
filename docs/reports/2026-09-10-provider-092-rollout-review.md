# Provider 0.9.2: compatibility and rollout review

> Last updated: 2026-09-10 · commit `5f021ba4d`

**The provider can use the current 0.9.1 coordinator, but the combined 0.9.2
runtime is not yet fully qualified for fleet publication.** No direct interface
conflict was found in this review. This is a source/compatibility review with
local fixture tests and read-only production inspection, not a new live-model
or signed-bundle qualification.

## Scope and observed production

The candidate is `5f021ba4d4219b75f45de72af7c221395ec6594e`, based on master
`c09499b5e`. The release range is `v0.9.1..5f021ba4d`: provider changes from
#885, #892 and #872; coordinator warm-pool changes from #807; console changes
from #888 and #887; and the synchronized version bump in #893.

On September 10 PDT / September 11 UTC, `/health` reported coordinator
`73093957b8f2f7058f9eabab3ab004c3d758ec16`, version 0.9.1. This is exactly
`v0.9.1`. `/v1/releases/latest?platform=macos-arm64` returned active release
0.9.1, registered September 9. These independent observations establish the
coordinator source and published provider baseline. [Captured public state](evidence/2026-09-10-provider-092-review/live-snapshot.json).

Read-only inspection of the running container's
`EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` found only
`EigenLabs/Qwen3.8-27B-4bit-mtp`, `qwen3.5-35b-a3b` and
`qwen3.6-35b-a3b-vl-mtp-mxfp8`. Public cache status reported routing on, 100%
activation and an allowlist count of three. Gemma local SSD reuse therefore
does not imply Gemma holder-directed routing. No environment or traffic
setting was changed.

The live catalog already declares the Gemma QAT assistant at revision
`bb94eae1b70a80dac16cbf959bb4b7d56bd1fb8c`, through R2-only metadata. A default
0.9.2 provider can fetch and activate it; leaving the coordinator unchanged
does not keep Gemma MTP disabled. The optional HF-first metadata patch is
absent. No Nemotron entry appeared in the public catalog snapshot; binary
support alone does not publish a catalog model.

## Interactions reviewed

| Boundary | Finding and evidence |
|---|---|
| Provider protocol and admission | No changes to either protocol tree, the release-registration payload, installer or release workflow since v0.9.1. The new assistant drain uses existing `reloading`, capacity quotes and `slot_state` rejection semantics. The old coordinator excludes only the affected model. Source: `ProviderLoop+MTPDrain.swift`, `CoordinatorClientState.swift`, `ProviderLoop+Capacity.swift`; old `scheduler_queue_drain_test.go` and `tool_constraints_test.go`. |
| Registration and mixed provider versions | The old `handleRegisterRelease` validates the bundle, commits the release row, refreshes active binary/metallib trust and invalidates discovery caches. Existing active releases remain trusted. `LatestProviderVersion` is a fallback, not a requirement to restart the coordinator for each provider release. Source: `coordinator/api/release_handlers.go`, `server.go` (`SyncBinaryHashes`, `SyncRuntimeManifest`) and runtime-manifest union tests. |
| Gemma, Qwen and Nemotron MTP | Gemma automatic external-assistant activation is scoped to exact QAT model ID; its adaptive depth is at most one. Nemotron admission is scoped to three Lightning identities. Qwen keeps its drafter cap of four even though the shared SDK maximum becomes seven. The driver selects Gemma committed-output learning only for stateless target-prefix drafters; it does not apply that controller mode to Qwen/Nemotron stateful drafters. Source: `ProviderConfig.swift`, `MTPAutomaticVerificationPolicy.swift`, SDK `CBv2MTPRoundDriver.swift` and `Qwen35MTP.swift`. |
| Shared memory and assistant replacement | Target retention precedes catalog suspension; retained targets are excluded from optional-upgrade eviction. A pending-load lease and staging charge cover the replacement. Generation checks reject stale capacity snapshots. Accepted work retains the original engine; timeout/cancellation discards staging and restores admission/KV grants. Source: `MTPStagingReservations.swift`, `ProviderLoop+MTPUpgrade.swift`, `ProviderLoop+ModelLoading.swift`, standalone counterparts and lifecycle tests. This reduces identified race risks; it does not establish zero fleet capacity loss. |
| Cache identities | Complete checkpoints bind model, prompt, binary, metallib, MTP configuration and storage/numerical identity. Nemotron controls join that fingerprint. Upgrading the binary or activating MTP therefore invalidates incompatible checkpoints instead of restoring them across identities. Expect cold-cache warmup after the release. Source: `PrefixCachePolicy+CheckpointIdentity.swift`. |
| Tool streams | Native reasoning classification is selected only for qualified Nemotron targets; Gemma retains its grammar path. Calls are validated before publication. Existing explicit capability advertisements work on the old coordinator, including revocation and broken-template/runtime gates. Source: `ToolChoiceEnforcementPolicy.swift`, `NativeToolStreamRouter.swift`, `MultiModelBatchSchedulerEngine.swift`. Shared parser/stream code still merits cross-model live smoke tests. |
| Dependency composition | A fresh recursive checkout resolves SDK `ce446cc5`, Swift `6d6796d7`, core `3fa8f25e`, and C `02cf6f4d` consistently. The SDK package pins the same Swift revision, whose nested core matches the root core. SDK tree `6d03d43e` is identical to previously reviewed `753f8a3`; final provider source includes subsequent Nemotron and bounded-drain amendments, so earlier provider measurements are not treated as exact-candidate results. |

## Checks completed in this review

An isolated checkout at the production commit was used for compatibility
tests. The candidate's `native_tool_advertisement_test.go` was copied into
that checkout with the advertised provider version changed from 0.9.0 to
0.9.2. No production source or service was modified.

- Five registry test functions pass, with no skips: new Nemotron advertisement
  activation/revocation, preserving still-approved release evidence, skipping
  reloading/crashed slots, model-specific slot state and queued tool requests
  during reload. [Raw registry log](evidence/2026-09-10-provider-092-review/coordinator-compatibility.log.gz).
- Thirty API test functions pass, with no skips: release registration and
  artifact verification, immediate cache invalidation, runtime-manifest unions,
  deactivation and retaining older providers' runtime verification when a new
  release registers. [Raw API log](evidence/2026-09-10-provider-092-review/release-compatibility.log.gz).
- Source version integrity, four release-resolution tests, installer parity
  and the two version synchronization/format tests passed on the candidate.
- Recursive dependency checkout and SDK tree identity were verified locally.

Commands used repository-pinned Go 1.25.0. Exact filters and source identifiers
are retained in [the evidence manifest](evidence/2026-09-10-provider-092-review/manifest.json).

The final merged #872 description links passing [provider CI](https://github.com/Layr-Labs/d-inference/actions/runs/34550904534/job/103113418227)
and [integration CI](https://github.com/Layr-Labs/d-inference/actions/runs/34550904539/job/103113418358),
including released-coordinator compatibility and paged concurrency-eight
integration. It records 2,792 Swift Testing passes, 98 XCTest passes and 46
explicit live/environment skips. These are prior CI results, not tests rerun
locally here, and skipped model tests are not qualification.

At review time, #893 head `5f021ba4d` had passing release integrity,
coordinator, prompt-sidecar, console, docs and CodeQL checks; provider and
integration jobs were still running and E2E Benchmarks awaited its protected
environment. [Threat Model Review](https://github.com/Layr-Labs/d-inference/actions/runs/34564254131/job/103153015257)
failed with the external service's HTTP 401 / invalid API key. This is an
unresolved CI failure, not evidence of a code defect. Refresh checks on the
final documentation amendment before merging.

## Release concerns that remain open

1. **Combined-artifact qualification is incomplete.** The final amended Gemma
   download/drain/swap path lacks an uninterrupted optimized build plus matched
   B1 MTP-on/off, B4 repeated/branched-prefix and real HTTP success/failure
   qualification on the final provider artifact. The earlier 47/47 HTTP success
   and 22/22 failure-fallback results used natural-idle activation, before the
   bounded admission drain. They do not validate this final transition.
2. **There is a concrete Gemma answer-quality concern.** Earlier greedy MTP
   coding outputs repeatedly enforce global event-ID uniqueness where the prompt
   requires `(source,event_id)` identity; ordinary-decode controls on that prompt
   pass. The September 10 MTP arm repeats this defect. The sampled pair differs,
   and one prompt does not establish a general quality rate or prove a cache bug.
   It does prevent an unqualified claim of output equivalence. Preserve and
   rerun this probe in the matched final-candidate comparison.
3. **Nemotron component coverage is not connected fleet qualification.**
   [#885](https://github.com/Layr-Labs/d-inference/pull/885) leaves published-chain
   connected serving/restart open; [#892](https://github.com/Layr-Labs/d-inference/pull/892)
   proves standalone admission reaches the memory gate, not that a small-memory
   Mac can serve it. Qualify on a machine with sufficient memory before model
   activation.

The [final #872 review](https://github.com/Layr-Labs/d-inference/pull/872) and
[September 10 report](2026-09-10-gemma-qat-review-sync.md) retain the model
evidence and its limitations. No newly demonstrated cross-feature code defect
was found in this scoped review; the open concerns are substantive release
evidence gaps and the recorded answer-quality result.

## Rollout recommendation

Keep the coordinator at its observed revision for a provider-only rollout
after the remaining gates pass. A coordinator upgrade is not required for the
new protocol behavior and would add unrelated warm-pool changes to the same
rollout. Its absence means #807's proactive headroom policy is not deployed.

First qualify the exact signed candidate on a small authorized provider set
against the existing coordinator, including ordinary Qwen/GPT-OSS requests,
Gemma tools/vision, repeated/branched cache use, sustained concurrency,
assistant download failure, admission drain and restart. Check mixed-version
attestation, capacity, 503s, TTFT and stream completion. Resolve the quality
probe and final CI status before broad publication; if qualification cannot
be completed, postpone the release or separately review a candidate that
retains Gemma's prior opt-in defaults.

Registering an active stable release exposes it to auto-update; it is not a
canary by itself. Provider auto-update starts checking after five minutes and
then every thirty minutes, with configured jitter. The new binary and MTP
identity also require cache warmup. Once authorized for broad publication,
verify release discovery, mixed-version trust and actual inference separately;
the coordinator `/health` build commit should remain unchanged. Follow the
[provider release runbook](../operations/provider-release.md). This review
performs no merge, tag, publication, catalog mutation or deployment.
