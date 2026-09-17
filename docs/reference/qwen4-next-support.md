# Qwen 3.8 Next (Flash-Next) native support reference

> Last updated: 2026-09-17 · commit `43c7b1c32`

Reference for the native Qwen4 support candidate and its remaining qualification gates. These source defaults do not publish a model, approve a catalog entry, qualify a hardware tier or establish a production release. The composed SDK's `libs/mlx-swift-lm/docs/qwen4/composition.md` records source selection and excluded experiments.

## Identity and serving policy

| Concern | Current candidate contract | Source |
|---|---|---|
| Architecture | `qwen4_exp` / `qwen4_exp_text` use native QSA, GDN, hyper-connections, MoE, PLE and embedded MTP. Architecture recognition is separate from default artifact eligibility | `provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2SupportedModels.swift` (`isSupported`); `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+ModelAdapter.swift` (`ProductionModelAdapter`) |
| Qualified serving identifiers | Registry ID `qwen3.8-flash-next` and legacy ID `DarkBloom/Qwen3.8-Flash-Next-Q4-mtp` share native defaults. Matching is exact and case-sensitive; upstream HF IDs, download repositories, substrings and reference artifacts are not runtime aliases | `provider-swift/Sources/ProviderCoreFoundation/Qwen4ModelIdentity.swift` (`isQualified`); `coordinator/promptsidecar/src/qwen4_identity.rs` (`is_qualified`) |
| Mixed fleet | All requests for the registry ID require provider `0.9.5` or newer. Legacy/other IDs retain their existing floors; an older binary must not silently serve the new ID without its native policies | `coordinator/registry/qwen4_model_policy.go` (`providerMeetsQwen4CatalogPolicyLocked`); `coordinator/registry/request_traits.go` (`providerEligibleForTraitsLocked`) |
| Concurrent generation | Native Qwen4 defaults to one active generation row; other requests may queue. `DARKBLOOM_QWEN4_BATCHED_QSA=1` exposes an opt-in candidate bounded by the installed native row capability, not a production concurrency qualification. The reported speed results are single-request measurements; generic scheduler/packed-fixture tests do not establish full Qwen4 multi-request serving | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift` (`nativeConcurrentRequestLimit`, `configureNativeQwen4Batching`) |
| Original checkpoint | Conversion tools pin `Qwen/Qwen3.8-Flash-Next` at `de4b8e4d43b917e7706784d8bb445c9af86a3540`. The resulting affine Q4 artifact is not oQ4e and is not numerically identical to BF16 | [Conversion contract](../../scripts/qwen38_conversion/README.md); `scripts/qwen38_conversion/qwen38_provenance.py` |
| Media | Either qualified ID may select the VLM factory only with the full 48-layer/2560 text and 27-layer/1152 vision declaration, no DeepStack, and explicit `language_model_only=false`. Unqualified IDs, bare text types, missing/true overlays and wrong tower geometry remain text-only. The shared Qwen vision seam preserves causal spans, native media IDs and request-owned positions; real-model restoration qualification is separate | `provider-swift/Sources/ProviderCoreFoundation/ModelMediaPolicy.swift` (`advertisesMedia`); `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/ModelContainerLoading.swift` (`factorySelection`); `provider-swift/Sources/ProviderCore/Inference/Vision/EngineV2VisionPrefill.swift` (`buildQwenSubmission`) |
| Context | Listing and runtime use positive native configuration, with a `262_144` metadata-only fallback for the two qualified IDs and a lower-only explicit operator override. There is no additional 82K clamp. Prompt plus resolved output reservation must fit: 229376 prompt + 32768 output fits 262144; one more token does not. Coordinator SLA/routing policy and physical memory admission remain separate | [Context configuration](configuration.md#native-flash-next-candidate); `provider-swift/Sources/ProviderCore/Inference/Qwen4SupportPolicy.swift` (`contextLimit`); `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Submission.swift` (`submitTokenized`) |
| Paging and cache defaults | Both qualified IDs select paging under `auto` and enable complete SSD prefix-cache eligibility. Loaded native dtype/layout, authenticated identity, keys and actual cache construction remain required; resident memory is separately opt-in | `provider-swift/Sources/ProviderCore/Inference/Engine/EngineV2KVBackendPolicy.swift` (`preferredBackend`); `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` (`isEnabled`); [cache mechanism](../architecture/prefix-cache.md#flash-next-complete-state) |
| Embedded MTP | A native architecture/head declaration and indexed `mtp.` or `language_model.mtp.` tensors select the trained head. `InlineWeightIndex` decodes `weight_map` without assuming all metadata values are integers: numeric `total_size` and string `format` can coexist. The complete config/index bytes remain hashed and revalidated | `provider-swift/Sources/ProviderCore/SpecDec/SpecDecStore.swift` (`declaresNativeQwen4MTP`, `inspectInlineArtifact`, `InlineWeightIndex`, `revalidateForLoad`); `provider-swift/Tests/ProviderCoreTests/Qwen4EmbeddedMTPTests.swift` |
| Capacity and errors | Model offload reduces only validated native weight-allocation estimates, not artifact size or actual OS page residency. The context rejection maps to bounded HTTP 400 / `invalid_request` / `client_error`; catalog and fleet-level capacity policy remain independent | [Offloaded-weight admission](../architecture/routing.md#ssd-offloaded-model-weights); `provider-swift/Sources/ProviderCore/ProviderLoop+ErrorMapping.swift` (`sanitizedInferenceFailure`) |

## State and resource ownership

The SDK's paired default candidate bounds MTP catch-up, initializes cold and
restored unprimed heads from the same trusted carry and uses grouped selected-page reads where the
existing sparse geometry permits. Frozen/shared/unsupported layouts retain
their safe fallback. Default activation, actual dispatch and completed
model/state qualification are distinct; see
`libs/mlx-swift-lm/docs/qwen4/qualification.md` for controls and rollback.

The loading allowance for eligible native non-FP16, SSD-offloaded checkpoints
is derived from complete safetensor headers, with all MTP/vision bytes retained.
It is not bare steady residency. Provider and coordinator share that explicit
allowance; unknown layouts retain generic padding. A recent owned Qwen4 unload
allows a bounded real-headroom recheck, never speculative reclaim credit. See
the [memory contract](../architecture/hardware-support.md#mechanism); original
failed requirements and new physical qualification evidence remain distinct.

| Boundary | Required behavior | Source |
|---|---|---|
| Learned PLE weights | Keep the packed table SSD-backed. Filter its arrays before shard evaluation, retain a directory lease with the model, validate external tables before serving and release them on failed load/unload | `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/ModelContainerLoading.swift` (`loadContainer`, `releaseExternalResources`); `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4Exp.swift` (`Qwen4ExpPLEResidency`); [hardware reference](../provider/hardware-requirements.md#qwen4-learned-table-offload) |
| Native attention | Paged storage retains observed native types. Qwen decode gathers visible native page contents and uses the canonical attention terminal; a paged-storage label is not proof that a direct paged Metal decode kernel ran | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4ExpQSA.swift`; `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+BackendPreparation.swift` (`prepareProductionBackend`) |
| Mixed position provenance | Rectangular text/media batches preserve each request's absent versus explicit positions through ordinary and direct hidden-returning MTP forwards. Equal media planes remain explicit. Host-only scope lifetime does not change cache/tensor ownership; scoped regression evidence does not qualify longer-prefix batching | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2+Qwen4Positions.swift` (`withQwen4PositionScope`); `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4ExpBatchedQSA.swift` (`positions`) |
| Complete checkpoint | Restore target KV, QSA index/positions, GDN state, request PLE history and compatible MTP history at a committed boundary. Learned PLE weights are separate; ordinary attention-only prefix reuse is insufficient | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CompleteCheckpointQwen4.swift`; `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen4ExpMTP+PrefixCheckpoint.swift` |
| Local request lifecycle | Cache usage belongs to one request and reaches Chat/Responses serialization from engine accounting. Complete connection closure cancels the owned upstream row and removes its registration when forwarding ends. Legal half-close has a bounded release-binary pass; quiet cancellation and full loaded retirement require separate evidence | `provider-swift/Sources/ProviderCore/Inference/Engine/Scheduler/MultiModelBatchSchedulerEngine.swift` (`streamChatCompletion`, `makeEventStream`); `provider-swift/Sources/ProviderCore/Server/LocalRequestCancellation.swift`; `provider-swift/Sources/ProviderCore/Server/LocalHTTPConnectionCancellation.swift` |

## Validation status and next gates

The [loading/MTP memory review](../reports/2026-09-17-qwen38-memory-mtp-review.md)
records the M5 follow-up, exact publication inputs, passing API/state checks
and the still-open repeated-request cache qualification failure.

The [native API/cache qualification](../reports/2026-09-15-qwen38-native-api-qualification.md)
records the latest source-bound tests and remaining deployment gates. The
[earlier performance/stability update](../reports/2026-09-15-qwen38-performance-stability.md)
retains its original-checkpoint measurements and historical evidence scope.
Required/named native Qwen4 text requests preserve the original messages and
trained template. Named choice still filters the tool declarations; native
framing and final validation enforce names, schema and allowed parallelism.
Other model/media prompt policies keep their prior parallel-aware wording.
The normalization contract is v6; see the
[prompt-contract mechanism](../architecture/prompt-contract-sidecar.md#contract-identity).
Source: `provider-swift/Sources/ProviderCore/Inference/Prompting/ToolChoicePromptPolicy.swift`
(`prepare`, `parallelCallsInstruction`).

The registry-ID/native-context follow-up remains a draft until actual artifact
serving, full-context resource behavior and local API gates are qualified.
Boundary/policy unit tests do not certify a 262K workload on 128 GiB hardware.
The SDK pin, weights, quantization, embedded MTP and native arithmetic are
unchanged by this policy update.

The owned artifact supports reasoning ON with its default `xhigh`, or explicit
`low`, `medium`, `xhigh`. Chat supports `reasoning.enabled=false`; Chat and
Responses both support `reasoning.effort=none`. The local Responses schema
does not model `reasoning.enabled`; do not substitute that extension for its
supported OFF form. Existing Chat Boolean precedence is preserved.
Unsupported active efforts such as `high` or `minimal` are rejected before
template rendering with a typed HTTP 400, not coerced to another effort.
Disabled thinking retains its existing precedence. Other artifact templates
are unaffected. Source: `provider-swift/Sources/ProviderCore/Inference/Qwen4SupportPolicy.swift`
(`validateReasoningContext`) and `provider-swift/Sources/ProviderCore/Inference/Prompting/ProviderPromptContractPipeline.swift`
(`tokenize`). Hosted OpenRouter routing, adapter control mappings, exclusion,
reasoning-token budgets and opaque reasoning-history extensions require
separate qualification; localhost success does not establish them.

The standalone Responses endpoint uses the SDK's Responses event writer and
accepts function-call/output history. `response.created`, item/content/tool
deltas and one completed/incomplete/failed terminal replace Chat-style frames
on that endpoint. Native parsed channels are not parsed twice. Chat SSE stays
unchanged. Source: `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/ResponsesStreamWriter.swift`
(`ResponsesStreamWriter`) and `libs/mlx-swift-lm/Libraries/MLXLMServer/Protocol/OpenAIResponseInputMessage.swift`
(`OpenAIResponseInputMessage`). Previous-response reconstruction, hosted tools,
encrypted reasoning-state replay and Responses `text.format` are outside this
local implementation; the coordinator has its separate endpoint contract.

`Qwen4StandaloneAdmissionTests` exercises `StandaloneServer.ensureModelLoaded`
through its existing pre-weight hook, with no resident engine. It checks owned
identity defaults, other native IDs, missing/invalid artifacts and reservation
cleanup. Real model generation and transport are separate test cells.

Responses reasoning effort is carried through the typed chat request and into
the provider's template context. Typed effort takes precedence over raw effort
aliases; explicit thinking booleans retain their precedence over effort-based
disable shorthands. The native Responses `effort=none` regression is recorded
separately from model-state/cache tests; changed prompt controls require a new
prompt, not reuse of a cached answer.

The provider's `/metrics` also reports observed
`kv_backend_info`, `kv_active_requests`, `kv_waiting_requests`,
`paged_kv_page_size`, allocator-reported `paged_kv_*_bytes`,
`prefix_cache_status` and `complete_prefix_key_persistent`.
Missing geometry/storage/key facts are omitted, not invented as zeros.
Ready status and a persistent key alone are not a proven cache hit.
Source: `provider-swift/Sources/ProviderCore/Server/LocalServingPosture.swift`
(`LocalServingPostureRenderer`, `localMetricsSample`).

## Native tool and reasoning boundaries

| Boundary | Contract | Source |
|---|---|---|
| Reasoning examples | The canonical native Qwen4 target preserves balanced inner reasoning examples as reasoning. Delimiters are not removed from argument data; malformed or excessively nested spans fail closed. Other families retain their routing | `provider-swift/Sources/ProviderCore/Inference/Streaming/NativeChannelSplitter.swift`; `provider-swift/Sources/ProviderCore/Inference/Streaming/NativeToolStreamRouter.swift` |
| Required/named text tools | Native framing follows the actual rendered reasoning boundary and requires a completed tool frame before EOS. Each frame starts with whitespace then a declared native function header or framed JSON, not free-form prose. Named XML headers are restricted to the selected name. Argument values remain opaque. Final function, schema and cardinality validation is mandatory, including for framed JSON; budget exhaustion and semantic-copy failures are not repaired | `provider-swift/Sources/ProviderCore/Inference/Qwen4NativeToolConstraint.swift`; `provider-swift/Sources/ProviderCore/Inference/Tools/ToolConstraintFactory.swift` |
| MTP eligibility | Constrained required/named text requests remain target-only under the engine's safety gate. Ordinary text and auto-tool requests retain their existing eligibility. Slot-level head activation alone does not prove a request speculated | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/EngineLoopV2+MTPPlanning.swift` |
| Multimodal tools | Auto/none choice and tool history are supported; required/named multimodal forcing is rejected by the shared media path. Media remains target-only | `provider-swift/Sources/ProviderCore/Inference/Engine/Scheduler/MultiModelBatchSchedulerEngine.swift` |

## Qualification boundaries

Use the [qualification record](../reports/2026-09-14-qwen38-next-qualification.md)
and the [reproducible harnesses](../../scripts/qwen38_validation/README.md).
Keep native exactness, API framing, semantic answer quality, cache equivalence,
resource retirement and hardware/trust qualification separate. A skipped test
is not a pass; a cache hit that reproduces an incorrect answer does not improve
answer quality.

The shared codec's historical Qwen35 name describes serialization grammar,
not model architecture. The native Qwen4 template and immutable config are the
authority for this model; do not substitute a Qwen3.5 model implementation.

Publication, model distribution, registry activation, licensing decisions,
signing and deployment are separately authorized operations. Source support
does not imply hosted routing, every physical RAM tier or universal quality.

## Related

- [Configuration](configuration.md#native-flash-next-candidate)
- [Consumer model contracts](../consumer/models.md#native-flash-next-candidate)
- [Build](../developer/build.md#native-flash-next-candidate) and [test procedure](../developer/test.md#native-flash-next-candidate)
- [Model registry format](model-registry-format.md), [release procedure](../operations/provider-release.md)
