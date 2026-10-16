# Native GLM-5.3-Flash integration

> Last updated: 2026-10-14

Status: In progress — not release-qualified.

This design records the native implementation boundary for `glm5_next`. An
existing four-bit artifact retaining the trained prediction layer is the initial
target; BF16 conversion is deferred. Neither a configuration decoder nor a
successful artifact download establishes serving support.

## Required execution contract

The release requires all three paths together on qualified requests: native
sparse paged attention, complete-state prefix reuse, and trained native MTP.
Keep `glm5_next` excluded from `EngineV2SupportedModels` until the production
adapter and these paths pass their acceptance gates. Do not substitute an older
GLM/Qwen model, dense attention, or a different inference runtime.

The official source is pinned to
[`zai-org/GLM-5.3-Flash@91b69215804f2d2036a8867f6ce44848e278dcda`](https://huggingface.co/zai-org/GLM-5.3-Flash/tree/91b69215804f2d2036a8867f6ce44848e278dcda).
Artifact identity, license, tensor coverage and numerical equivalence are
separate gates. A community quantization name does not prove either its source
revision or the presence of usable MTP tensors.

## Initial artifact selection

The local candidate is
[`Vontra/GLM-5.3-Flash-MLX-4bit-MTP@76add2a341a1cd90ad0e86bb69839ea9c35827c6`](https://huggingface.co/Vontra/GLM-5.3-Flash-MLX-4bit-MTP/tree/76add2a341a1cd90ad0e86bb69839ea9c35827c6).
Its 43 shard headers account for 181,709,451,790 bytes, 114,160 stored tensors
and 2,641 prediction-layer tensors. Logical name/shape coverage matches the
official source; this is header evidence, not payload hashing or numerical
quality evidence. The complete metadata contract is
`fixtures/models/glm53-flash/architecture.json`.

The raw candidate template differs from the official revision, and its embedding
and output matrices are Q4 despite its card's BF16 description. Preserve these
discrepancies in intake evidence; do not repair the raw snapshot in place. Our
own `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp` artifact ships a separately identified
template: the official source with numeric attribute access written as `[0]`
subscripts, which the pinned Swift-Jinja can parse. Its identity, derivation and
golden equivalence are recorded in `fixtures/prompt-contract/glm53-flash/`. No
BF16 weight conversion is part of this pass.

The larger mixed 4/5/6-bit `mlx-community` candidate exceeds this Mac's current
generic load allowance. The selected smaller Q4 candidate does not require
lowering the allowance, but actual loaded memory and safe context/concurrency
still require measurement. Neither artifact has a qualified hardware tier.

## Existing owners and missing implementation

| Concern | Existing owner | GLM-specific work required |
|---|---|---|
| Native dispatch | `EngineV2SupportedModels`, `EngineV2Factory.ProductionModelAdapter` | Exact architecture implementation and adapter, without permissive family matching |
| Target state | `CBv2RecurrentRequestState`, `CBv2RecurrentStateEvaluation` | Correct recurrence/convolution layout and transactional forward |
| Sparse attention | Native paged sequence ownership and selected-row kernels | Exact sparse selection, positions, index state and paging; existing model-specific indices are not a GLM codec |
| Prediction layer | `SpecDecArtifactFunnel`, `ProductionProviderMTPAssistantLoader` | Exact weight inventory, trained hidden boundary, request-owned draft state and verification |
| Memory prefix reuse | `HybridPrefixCache`, `EngineV2+HybridPrefix` | Paged complete-state resident ownership; the current recurrent RAM bank requires contiguous KV |
| Durable prefix reuse | `SSDHybridCheckpointStore`, complete checkpoint import/adoption | GLM sparse, recurrent, convolution and MTP codecs with exact accepted-prefix alignment |
| Routing evidence | Resident/durable prefix evidence and receipts | Publish only committed, actually restorable complete prefixes |
| Admission | `CBv2TargetAuxiliaryAllocationProviding`, recurrent and MTP allocation contracts | Charge weights, vision, prediction layer, sparse history, captures and retained aliases before allocation |
| Platform | Sibling `darkbloom-platform` | Catalog/capability and API qualification; no new centralized code in this repository |

The relevant provider entry points are
`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/ModelContainerLoading.swift`,
`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory+MTP.swift`
and
`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory+CompletePrefixCache.swift`.
Native transactional and checkpoint contracts live in
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2`.

## State invariants

1. Attention pages, sparse indices, recurrence, convolution history, positions
   and draft history describe the same accepted token prefix.
2. Prefix capture reads confirmed state, never an in-flight speculative suffix.
   Each adopter receives independent mutable state; shared immutable pages remain
   pinned and use copy-on-write.
3. Rejection, partial acceptance, cancellation and teardown retire every state
   component and allocation through the existing native fences.
4. Cache identity binds artifact and quantization, tokenizer/template/processor,
   layout, numerical options, media and the existing authenticated cache scope.
   Preserve [cache encryption and storage protections](../architecture/security/encryption.md#provider-cache-storage).
5. Capacity uses the full resident/load working set, not the activated expert
   count. Unmeasured hardware and vision shapes retain conservative reserves.
6. Operator overrides and visible recovery reasons remain supported. Disabling
   a required default is recovery, not a qualified default-path result.

## Acceptance order

1. Pin and inspect the unchanged four-bit artifact, all MTP tensors and source
   license. Validate every tensor name, shape, dtype and shard against its index.
2. Establish a native reference baseline: tokenizer/template, intermediates,
   routes, logits, masks and short/long/chunked/batched execution.
3. Validate transactional sparse/recurrent state, then trained MTP including
   greedy equivalence and separate stochastic-distribution checks.
4. Validate complete-state RAM and encrypted SSD restore, restart, corruption,
   incompatible identities, tenant isolation and pressure/eviction.
5. Exercise the actual provider and platform APIs: streaming, usage, stops,
   tools, reasoning, constrained output, media, lifecycle and cancellation.
   Advertise only independently passing capabilities.
6. Use the [serving qualification procedure](../developer/serving-performance-qualification.md)
   on an exclusive test host. Compare interleaved target-only and full-default
   requests at identical precision, context and output lengths. Record actual
   paged execution, positive saved prefill work and active MTP rounds, not flags.

No hardware tier, context limit, MTP depth or performance improvement is qualified
by this design. Hosted CI, signed publication, catalog activation and deployed
OpenRouter qualification remain distinct, approval-gated steps.

## Proposed rollout and recovery

| Stage | Entry gate | Exposure |
|---|---|---|
| Native development | Pinned source/artifact inventory and isolated tests | Keep provider advertisement closed; no live catalog mutation |
| Composed local qualification | Real target, MTP and complete-cache paths; API/lifecycle/security tests; measured memory and performance | Dedicated local provider and isolated platform only |
| Approved dev canary | Required reviews, signed source/build identity and artifact hashes | Owner-approved dev registration; no automatic production promotion |
| Approved production canary | Dev evidence plus hosted CI, release and public routing qualification | Explicitly approved catalog/alias operation and bounded monitored cohort |

Use existing diagnostics to record the effective backend, cache restore work,
MTP proposals/acceptance, failures, cancellation recovery, latency and memory.
Never add prompts, token IDs, media or tool arguments to telemetry. A missing
required path or incompatible cache identity blocks qualification rather than
silently changing the default profile.

Use the existing [model migration and rollback procedure](../operations/model-migration.md)
for any later approved alias change. Pre-position a verified previous build;
drain/cancel through the normal provider lifecycle before unloading, and fence
incompatible checkpoints by their identity. Operator target-only/cache-off
recovery must expose its reason and cannot count as a passing full-default cell.
No rollout or recovery operation is authorized by this design.
