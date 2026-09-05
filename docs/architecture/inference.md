# Provider inference engine

> Last updated: 2026-09-05 · commit `7b6afb181`

How a chat-completion request is served inside the `darkbloom` provider
process in v0.8.16: one in-process engine (`mlx-swift-lm`
ContinuousBatchingV2, "CBv2"), one `EngineV2Bridge` per resident model, no
legacy engine and no subprocess. For the memory model see
[`hardware-support.md`](hardware-support.md); for KV/prefix caching see
[`prefix-cache.md`](prefix-cache.md).

## Context

Every advertised model is served through CBv2. A model family is one
*runner* in the fork (`libs/mlx-swift-lm/Libraries/MLXRunners`), with a static
manifest that declares the `model_type`s it claims, and
`RunnerRegistry.contains(modelType:)` is the advertise gate: a `model_type`
no runner claims is dropped from the advertised set at scan time and never
loads
(`provider-swift/Sources/ProviderCore/Inference/EngineV2SupportedModels.swift`,
`isSupported`).

Every slot is built the same way, for every family: resolve the runner from
the checkpoint's `model_type`, hand it the module the slot already has
resident (`Runner.adopt` — it reads no tensors, so nothing is loaded twice),
then build the engine with `runner.makeEngine(EngineBuild(...))`. The
provider names no model family on that path. The path is HTTP/WebSocket → `ProviderLoop` /
`StandaloneServer` → `MultiModelBatchSchedulerEngine` → `EngineV2Bridge` →
`EngineV2` → Metal.

| Component | Role | Code |
|---|---|---|
| `ProviderLoop` / `StandaloneServer` | Coordinator WebSocket and local HTTP ingress; model load/unload; heartbeat | `provider-swift/Sources/ProviderCore/ProviderLoop.swift`, `provider-swift/Sources/ProviderCore/Server/StandaloneServer.swift` |
| `MultiModelBatchSchedulerEngine` | Implements the upstream `MLXServerEngine` contract: OpenAI translation, chat-template render, tool-parser and tool-choice resolution, model acquire, dispatch by `request.model` | `provider-swift/Sources/ProviderCore/Inference/MultiModelBatchSchedulerEngine.swift` |
| `EngineV2Bridge` (one per model) | Provider↔CBv2 boundary: request-id normalisation, `CBv2Request` translation, SSD staging, shared-KV reservation, deadline projection, `engine.submit`, event pump, telemetry | `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift` (+ `+Translation`, `+Profile`, `+Liveness`, `+MTP`, `+PrefixCache`) |
| `EngineV2SlotFactory` | Builds one slot: model prep, MTP assistant, KV-backend selection and vetoes, paged preflight, SSD prefix-cache construction gate | `provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift` |
| `EngineV2Factory` (production) | `prepareProductionBackend`, `productionSchedulerConfig`, engine assembly | `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift` |
| Runner boundary (provider side) | Resolves a checkpoint through `RunnerRegistry`, adopts the resident module with `Runner.adopt`, injects load-time resources, selects the decoder from `loadedDecoders`, and hands the slot's policy to `runner.makeEngine` on `EngineBuild` | `provider-swift/Sources/ProviderCore/Inference/EngineV2RunnerBuild.swift` |
| Runner package | One runner per family: manifest, serving model, layer kinds, per-layer caches, drafter, engine and one-row stepper. The provider's only family-aware dependency | `libs/mlx-swift-lm/Libraries/MLXRunners/Runner.swift`, `RunnerRegistry.swift` |
| `EngineV2SlotFactory+MTP` | Adopts the runner over the resident container, and loads the family's drafter through `Runner.loadDrafter` | `provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory+MTP.swift` |
| `EngineV2Runtime` | Process-wide registry of bridges; capacity summary for heartbeats; cancellation fan-out | `provider-swift/Sources/ProviderCore/Inference/EngineV2Runtime.swift` |
| CBv2 engine loop | Admission, KV allocation, chunked prefill, batched decode, detokenisation, leases | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift`, `SchedulerV2.swift` |
| promptsidecar boundary | Coordinator-side Rust process that computes the same `prompt_contract_id` and block chain ([`prefix-cache.md#block-hashing`](prefix-cache.md#block-hashing)) the provider derives with `PromptContractIdentity.compute(modelDirectory:)`; the provider never calls it | `coordinator/promptsidecar/`, `provider-swift/Sources/ProviderCoreFoundation/PromptContractIdentity.swift` — see [`prompt-contract-sidecar.md`](prompt-contract-sidecar.md) |

## Mechanism

### One request through the engine

```mermaid
sequenceDiagram
    participant C as Coordinator / local client
    participant S as MultiModelBatchSchedulerEngine
    participant B as EngineV2Bridge
    participant K as SSDPrefixCache + GlobalKVCacheBudget
    participant E as EngineV2 (CBv2)
    C->>S: OpenAI ChatCompletionRequest
    S->>S: render chat template, resolve tool parser / tool-choice, build CBv2TokenConstraint
    S->>B: submitTokenized(tokens, request)
    B->>B: normalise request id; FirstContentDeadline.check(); samplingParams
    B->>K: stage(prefix) [text-only, SSD cache present]; reserve prompt+maxTokens [contiguous slots]
    B->>E: submit(CBv2Request, firstTokenDeadlineAdmission?)
    E->>E: admit → ensureKVState → prefill chunks → decode steps
    E-->>B: token events … terminal CBv2Usage(CBv2RequestTiming)
    B-->>S: detokenised GenerationEvent stream
    S-->>C: SSE chunks / final response
```

Bridge-side order (`EngineV2Bridge.submitTokenized`): request-id
normalisation (`maxRequestIdLength = 256`; duplicates rejected) → first
deadline check → translation (`maxTokens = request.max_tokens ??
defaultMaxTokens`, 4096) → SSD stage → shared-KV reservation (contiguous slots
only; paged pools are committed whole at first admission) → final deadline
check → engine request-id mint → `engine.submit`. The terminal `CBv2Usage`
carries `CBv2RequestTiming`, copied verbatim onto the wire and folded into
`EngineProfile` (`EngineV2Bridge+Profile.swift`).

### `CBv2RequestTiming`

Stamped by the engine thread only; instants are nanoseconds from the enqueue
instant (`0` = not observed, observed values clamped ≥ 1); durations are
elapsed nanoseconds. Numerics only — never tokens, text or hashes
(`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift`,
`CBv2RequestTiming`).

| Field | Meaning |
|---|---|
| `admittedNanos` | First step whose plan included the row (queue wait) |
| `kvAllocatedNanos` | Per-layer KV state allocated (`ensureKVState`) |
| `prefillFirstLaunchNanos` | First step that launched one of the row's prefill chunks |
| `promptComputedNanos` | Finalize of the step where `numComputedTokens >= promptTokens` |
| `firstTokenNanos` | Finalize of the step that confirmed the first generated token (excludes detokenisation) |
| `finishedNanos` | `finishRequest` instant |
| `readmissions`, `preemptions`, `capacityRequeues` | Waiting→running crossings after the first admission; preemptions; capacity requeues |
| `prefillChunks`, `packedPrefillChunks`, `visionChunks`, `soloStripeChunks` | Prefill chunk forwards: all; in a rectangular `[B, chunk]` cohort; carrying image spans; solo chunks wider than `prefillChunkSize` |
| `prefillChunkTokensMax` | Widest prefill chunk |
| `decodeSteps`, `chainedDecodeSteps` | Finalized steps confirming a token beyond the first (an MTP round with ≥ 1 confirmed token counts once); of those, chained-decode launches |
| `batchRowsSum`, `batchRowsMin`, `batchRowsMax` | Token-producing rows per participated step |
| `stepLatencyNanosSum`, `stepLatencyNanosMax` | Readback-done − `wallStartedNanos`, summed and max |
| `mtpRounds`, `mtpProposed`, `mtpAccepted` | MTP verify rounds, drafted tokens, accepted tokens |
| `pausedNanos`, `pauseCount` | Backpressure pause time and transitions |
| `detokDelayFirstNanos` | First token only: engine confirm → detokenised emit |
| `prefixLookupNanos`, `prefixAdoptionNanos` | Submit-thread prefix lookup (hash + lookup + plan); `applyAdoption` on the engine thread |

### Scheduler and loop configuration

| Setting | Value in production | Code |
|---|---|---|
| `maxConcurrentRequests` | `engine_v2_max_concurrent` (default and clamp: [`../provider/cli-reference.md#providertoml-keys-read-by-the-cli`](../provider/cli-reference.md#providertoml-keys-read-by-the-cli); per-model map `engine_v2_max_concurrent_by_model`) | `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`, `productionSchedulerConfig` |
| `maxBatchedTokensPerStep` / `prefillChunkSize` / `maxWaiting` | 2048 / 512 / 64 (`CBv2SchedulerConfig` init defaults) | `CBv2Contracts.swift`, `CBv2SchedulerConfig` |
| `soloPrefillStripeTokens` | 2048 (`defaultSoloPrefillStripeTokens`); 4096 for dense Qwen3.5/3.8 (`Qwen35Model`, not `Qwen35MoEModel`); `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE` | `EngineV2Factory+Production.swift` |
| `maxConcurrentPartialPrefills` | 1; `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` | `EngineV2Factory+Production.swift`, `maxPartialPrefillsKey` |
| `enablePrefixCache` | true only when an SSD cache object was constructed for the slot | `EngineV2SlotFactory.swift` |
| `requestTimeout` | 120 s legacy total wall, used only when `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT` is affirmative | `EngineLoopV2.swift`, `CBv2EngineLoopConfig`; `EngineV2Factory+Production.swift` |
| `stepTimeout` | 30 s | `CBv2EngineLoopConfig` |
| `admissionLease`, `prefillProgressLease`, `decodeProgressLease`, `backpressureLease` | 120 s each | `CBv2EngineLoopConfig` |
| `safetyCeilingDecodeFloorTPS` | 5 | `CBv2EngineLoopConfig` |

Environment variables are named here, never defaulted; defaults live in
[`../reference/configuration.md`](../reference/configuration.md).

### Deadlines

The coordinator's relative first-content budget is anchored once at frame
receipt (`FirstContentDeadline(relativeBudgetMilliseconds:)`,
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientTypes.swift`)
and checked at every pre-content boundary. `prefill_deadline_mode` ∈ {`off`,
`enforce`}; when the config key is absent, `DARKBLOOM_PREFILL_DEADLINE_MODE`
exactly `off` disables, anything else enforces
(`provider-swift/Sources/ProviderCore/Inference/PrefillDeadlineMode.swift`).
Under `enforce` the bridge builds `CBv2FirstTokenDeadlineAdmission` only when
`maxConcurrentPartialPrefills == 1`, the request is not multimodal, and the
isolated cold-prefill EWMA is initialised; prefill and decode rates are haircut
by `deadlineProjectionRateHaircut = 0.5`. `WedgeMonitor.suspectStallSeconds =
10` flags a stalled slot
(`provider-swift/Sources/ProviderCore/Inference/WedgeMonitor.swift`).

### Multi-token prediction

| Target | Drafter | Activation |
|---|---|---|
| Qwen3.5 family (`qwen3_5`, `qwen3_5_moe`) | Embedded head (`Qwen35InlineMTPAssistant`, request-stateful) | `mtp_mode = "auto"` (default) when the checkpoint declares the embedded artifact |
| Qwen 3.8 Flash-Next (`qwen4_exp`, `qwen4_exp_text`) | Embedded head (`Qwen4ExpInlineMTPAssistant`, request-stateful, depth 1…3) | The head is a block of the target checkpoint (`mtp.*`); a checkpoint without it serves serial. On the runner path the mode is `EngineBuild.decoder` and is selected only when `runner.loadedDecoders` reports it |
| Gemma 4 | Separate assistant checkpoint (`Gemma4AssistantDraftModel`, stateless) | `mtp_mode = "on"` or a catalog-declared `spec_dec` artifact resolved by `SpecDecArtifactFunnel`; `mtp_drafter_path` overrides the directory |

`MTPAutomaticVerificationPolicy`: `initialDraftTokens = 1`;
`fixedDraftTokens = nil` for request-stateful drafters (engine controller, 0…4)
and `1` for the stateless Gemma drafter; `maxRectangularTokens = 8` on
M3/M4/M5 and `4` on M1/M2/unknown, lowered only by
`DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS`
(`provider-swift/Sources/ProviderCore/Inference/MTPAutomaticVerificationPolicy.swift`).
Engine contract: `CBv2MTPConfig` with `testedMaxDraftTokens` (≤ 7) and
`testedMaxSpeculativeBatch = 8`
(`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/MTPContractsV2.swift`).
The process-wide kill switch is `DARKBLOOM_CBV2_MTP` (`CBv2MTPConfig.envEnabled`;
see [`../reference/configuration.md`](../reference/configuration.md)).

### Sampling parameters

`EngineV2Translation.samplingParams(from:)`
(`provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge+Translation.swift`):

| OpenAI field | Honoured as | Default |
|---|---|---|
| `temperature` | `temperature` | `0.0` (greedy) |
| `top_p` | `topP` | `1.0` |
| `top_k` | `topK` | `0` |
| `repetition_penalty` | `repetitionPenalty` | `1.0` |
| `frequency_penalty` / `presence_penalty` | `frequencyPenalty` / `presencePenalty` | `0` |
| `seed` | `seed`; also keys a stable engine request id | nil |
| `logit_bias` | `logitBias` — string keys parsed to non-negative `Int`; invalid keys dropped and counted | `[:]` |
| `logprobs` + `top_logprobs` | `topLogprobs = logprobs ? min(20, max(1, top_logprobs ?? 0)) : 0` | `0` |
| `max_tokens` | `maxTokens = max_tokens ?? 4096` | 4096 |
| `stop` | `stopStrings`, matched on held-back detokenised text (`EngineV2Bridge+StopSequence.swift`) | `[]` |
| `min_p`, `priority` | **Ignored**: always `0` | — |
| `n`, `best_of` | **Not represented**: one alternative | — |

### Streaming reasoning state

`ReasoningPromptProbe.streamingPrefix` in
`provider-swift/Sources/ProviderCore/Inference/ReasoningPromptProbe.swift`
decodes only the final eight prompt tokens to initialize Qwen/DeepSeek
streaming parsing. A prompt ending in `<think>` receives an opening marker;
a prompt ending in `</think>` receives an empty closed block. The downstream
think parser consumes these prefixes as state transitions, so reasoning or
ordinary answer text streams immediately. The prefix bypasses tool parsing
and does not add output frames or token usage.

Both text and media paths in `MultiModelBatchSchedulerEngine` apply the
probe before forwarding model output. This matters for media because
`templateAdditionalContext` defaults `enable_thinking` to false unless the
caller supplied a thinking control: the template already closes the block,
and generated answers need not emit another marker. Explicit `.none`, other
parser families, non-streaming requests, and unrecognized prompt tails receive
no prefix. Unknown tails preserve legacy close-only reasoning parsing.

### Tool-call parsers

`ServerToolParser.resolve(requested:modelType:)` honours an explicit
`tool_call_parser`, else `ToolCallFormat.infer(from:configData:)`
(`libs/mlx-swift-lm/Libraries/MLXLMServer/Parsing/ServerToolParser.swift`,
`libs/mlx-swift-lm/Libraries/MLXLMCommon/Tool/ToolCallFormat.swift`).
Resolution happens before submit so a bad parser name never orphans a request.

| `model_type` rule | Format | Parser |
|---|---|---|
| `gpt_oss` | `.harmony` | `HarmonyToolCallParser` |
| prefix `gemma` (`gemma4`, `gemma4_text`) | `.gemma` | `GemmaFunctionParser` |
| prefix `qwen3_5` | `.qwen35` | `Qwen35ToolCallParser` (XML first, framed-JSON fallback) |
| prefix `qwen3_next`, prefix `nemotron` | `.xmlFunction` | `XMLFunctionParser` |
| `llama` with `vocab_size ≥ 128000` or `rope_scaling.rope_type == "llama3"` | `.llama3` | `Llama3ToolCallParser` |
| prefix `lfm2` / `glm4` / `mistral3` | `.lfm2` / `.glm4` / `.mistral` | `PythonicToolCallParser` / `GLM4ToolCallParser` / `MistralToolCallParser` |
| anything else, including `qwen3_vl_moe` | `nil` → `.json` | `JSONToolCallParser` (`<tool_call>…</tool_call>`) |

`.kimiK2` and `.minimaxM2` exist but are selectable only explicitly.

### Chat-template render check

At scan time `TemplateRenderCheck.renderOK(at:)` compiles every template
source in runtime precedence (`chat_template.jinja`, `chat_template.json`,
`tokenizer_config.json`) with swift-jinja `lstripBlocks: true, trimBlocks:
true` and renders canonical fixtures; multimodal fixtures run only when
`config.json` declares `vision_config`. The result is advertised per model as
`template_render_ok` (`nil` = no template, key omitted); the model stays
advertised, but the provider's capacity quotes reject it with reason `template`
and the coordinator can refuse to route
(`provider-swift/Sources/ProviderCoreFoundation/TemplateRenderCheck.swift`,
`provider-swift/Sources/ProviderCore/Coordinator/CapacityQuoteEngine.swift`).

### Vision constraints

- **One image per tower pass.** `EngineV2VisionTowerRun` drives the Qwen
  tower one image per call and evaluates final + DeepStack features before the
  next; peak attention memory falls from `(Σᵢ nᵢ)²` to `maxᵢ nᵢ²`. Gemma 4's
  SigLIP tower is one image per forward pass already. Each image is checked
  with `MLX.withError` right after `eval`
  (`provider-swift/Sources/ProviderCore/Inference/EngineV2VisionTowerRun.swift`).
- **N² budget.** `N_max = floor(sqrt(maxBufferLength / (headFactor ×
  attentionElementBytes)))` with `attentionElementBytes = 2`,
  `fusedAttentionHeadDims = {64, 80, 128}` (`headFactor = 1` when fused-eligible,
  else `numHeads`); `DARKBLOOM_VISION_MAX_TOWER_PATCHES` is a lower-only ceiling
  (`provider-swift/Sources/ProviderCore/Inference/VisionTowerBudget.swift`).
- **Media caps** (`provider-swift/Sources/ProviderCore/Inference/MediaIngest.swift`):
  `maxImagePixels` 100 Mpx, `maxRequestImagePixels` 384 Mpx,
  `maxMediaDecodedBytes` 25 MiB, `maxVideoDurationSeconds` 600,
  `maxImagesPerRequest` 16, `maxVideosPerRequest` 8,
  `maxRequestVideoFramePixels` 384 Mpx; `decodeOverheadFactor = 4`.
- Vision requests never stage SSD blocks and get no deadline projection; VLM
  slots are vetoed to the contiguous KV backend ([`prefix-cache.md`](prefix-cache.md)).
  `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK` gates the load-time parity prefill
  between MLXVLM's inline text model and the extracted MLXLLM target
  (`libs/mlx-swift-lm/Libraries/MLXRunners/QwenVLMTextExtraction.swift`, which
  the family's runner applies while adopting the wrapper).

### Supported `model_type`s and quantization

| `model_type` | Family | Notes |
|---|---|---|
| `gpt_oss` | GPT-OSS | Harmony tool format; measured activation floor ([`hardware-support.md`](hardware-support.md)) |
| `gemma4` | Gemma 4 VLM wrapper | Served through its text tower + vision prefill |
| `gemma4_text` | Gemma 4 text target | Assistant checkpoints share the prefix; never advertised |
| `qwen3_5` | Dense Qwen 3.5/3.8, recurrent state | Embedded MTP head; no prefix reuse |
| `qwen3_5_moe` | Qwen 3.5/3.6 MoE, recurrent state | Embedded MTP head; no prefix reuse |
| `qwen3_vl`, `qwen3_vl_moe` | Qwen3-VL wrapper | Served via CBv2 adapter + vision prefill; `cbv2Capabilities` all `false` (no prefix reuse, paged, compiled decode, packed prefill or MTP) |
| `qwen3_5_text` | Qwen 3.5 text target | Claimed by the Qwen 3.5 runner |
| `qwen4_exp`, `qwen4_exp_text` | Qwen 3.8 Flash-Next 125B-A6B | Hybrid trunk, QSA keep mask, recurrent state. Contiguous KV only; MTP is the one engine capability the manifest sets. The n-gram PLE table is never model parameters: it is read from the checkpoint's shard directory through a load-time resource (`Qwen4ExpRunner.ngramRowSourceResource`) |

This table restates no capability. The authority is each runner's manifest
(`libs/mlx-swift-lm/Libraries/MLXRunners/*Runner.swift`), which the registry
and the engine both read.

Quantization is detected by name, in order: `4bit`|`q4`|`int4` → `4bit`;
`8bit`|`q8`|`int8` → `8bit`; `3bit`|`q3` → `3bit`; `bf16`; `fp16`|`f16`; else
`quantize_config.json` `bits`; else `nil`
(`provider-swift/Sources/ProviderCore/Models/ModelScanner+Discovery.swift`,
`detectQuantization`). KV quantization was retired in v0.8.0. Memory sizing
(the `1.2` padded estimate and the load gate) is in
[`hardware-support.md`](hardware-support.md).

## Invariants

1. A `model_type` is advertised if and only if a runner claims it. The gate
   is `RunnerRegistry.contains(modelType:)` behind
   `EngineV2SupportedModels.isSupported`; an unsupported load request fails
   the advertised-set guard (404) — `EngineV2SupportedModels.swift`.
2. A request is admitted to a contiguous slot only after
   `prompt + maxTokens` bytes are reserved in `GlobalKVCacheBudget`; a second
   reservation failure rejects with `token_budget_exhausted` —
   `EngineV2Bridge.swift` (`submitTokenized`).
3. Every request carries a first-content deadline anchored at frame receipt and
   checked before submit; the budget value is the coordinator's, not a provider
   constant — `CoordinatorClientTypes.swift` (`FirstContentDeadline`).
4. No request outlives its leases: 120 s admission / prefill-progress /
   decode-progress / backpressure leases and a 30 s step timeout —
   `EngineLoopV2.swift` (`CBv2EngineLoopConfig`).
5. Tool parser and tool-choice strategy are resolved before submit —
   `MultiModelBatchSchedulerEngine.swift` (`ServerToolParser.resolve`).
6. `CBv2RequestTiming` contains numerics only — `CBv2Contracts.swift`.
7. MTP is fail-open to target-only decode: artifact resolution failure or
   `DARKBLOOM_CBV2_MTP` off never refuses a load — `EngineV2SlotFactory+MTP.swift`,
   `MTPContractsV2.swift` (`envEnabled`).

## Failure modes

| Symptom | Cause | Where |
|---|---|---|
| `token_budget_exhausted: duplicate request ID` | Request id already live on the bridge | `EngineV2Bridge.swift` |
| `token_budget_exhausted: … shared KV budget has no headroom` | Two failed `GlobalKVCacheBudget` reservations | `EngineV2Bridge.swift` |
| `PreContentDeadlineFailure.deadlineUnreachable` | First-content budget spent before submit or during prefill projection | `CoordinatorClientTypes.swift`, `EngineV2Bridge.swift` |
| Request cancelled by lease | No admission/prefill/decode progress within 120 s, or a step over 30 s | `EngineLoopV2.swift` |
| Model dropped from advertised set | Unsupported `model_type` | `EngineV2SupportedModels.swift` |
| Model advertised, capacity quotes rejected with reason `template` | Scan-time render check failed (`template_render_ok = false`) | `TemplateRenderCheck.swift`, `provider-swift/Sources/ProviderCore/Coordinator/CapacityQuoteEngine.swift` (`reject(.template)`) |
| Image rejected | Over `MediaIngest` caps or over the N² tower budget | `MediaIngest.swift`, `VisionTowerBudget.swift` |
| Load refused: `pagedUnavailable` (503) | Explicit `engine_v2_kv_backend = paged` and the paged pool/kernels failed | `EngineV2Factory+Production.swift` — see [`prefix-cache.md`](prefix-cache.md) |
| Slot flagged wedged | No engine progress for `suspectStallSeconds = 10` | `WedgeMonitor.swift` |

## Code map

| Concern | File / symbol |
|---|---|
| Bridge submit path | `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift` (`submitTokenized`) |
| Sampling translation | `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge+Translation.swift` (`samplingParams`) |
| Slot construction | `provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift` |
| Scheduler config, backend prep | `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift` (`productionSchedulerConfig`, `prepareProductionBackend`) |
| Refusal taxonomy, retired env knobs | `provider-swift/Sources/ProviderCore/Inference/EngineV2Config.swift` (`EngineV2RefusalReason`) |
| Deadlines | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientTypes.swift`, `provider-swift/Sources/ProviderCore/Inference/PrefillDeadlineMode.swift`, `provider-swift/Sources/ProviderCore/Inference/WedgeMonitor.swift` |
| MTP | `provider-swift/Sources/ProviderCore/Inference/MTPAutomaticVerificationPolicy.swift`, `provider-swift/Sources/ProviderCore/Inference/EngineV2MTPAssistant.swift`, `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/MTPContractsV2.swift` |
| Vision | `provider-swift/Sources/ProviderCore/Inference/MediaIngest.swift`, `provider-swift/Sources/ProviderCore/Inference/VisionTowerBudget.swift`, `provider-swift/Sources/ProviderCore/Inference/EngineV2VisionTowerRun.swift`, `provider-swift/Sources/ProviderCore/Inference/EngineV2VisionPrefill.swift` |
| Tool constraints, reasoning probe | `provider-swift/Sources/ProviderCore/Inference/ToolConstraintFactory.swift`, `provider-swift/Sources/ProviderCore/Inference/ReasoningPromptProbe.swift` |
| Engine contracts, timing, scheduler, loop | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift`, `SchedulerV2.swift`, `EngineLoopV2.swift`, `CBv2RequestTiming+Stamps.swift` |

## Related

- [`prefix-cache.md`](prefix-cache.md) — KV layouts, prefix reuse, SSD tier
- [`hardware-support.md`](hardware-support.md) — memory model and load gate
- [`components/provider.md`](components/provider.md), [`components/mlx-swift.md`](components/mlx-swift.md) — process components and pinned submodules
- [`prompt-contract-sidecar.md`](prompt-contract-sidecar.md) — coordinator-side contract identity
- [`../reference/configuration.md`](../reference/configuration.md) — every `DARKBLOOM_*` variable and config key with its default
- [`../reference/protocol-messages.md`](../reference/protocol-messages.md) — wire shape of capacity, timing and status fields
