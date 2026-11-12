# Minimum implementation slice

The Python candidate is executable metadata logic. The following Swift interfaces are proposed edits, not existing APIs. Preserve the original Qwen paths and fingerprints until a separately reviewed migration; add typed variant cases rather than weakening Qwen checks.

## 1. Shared metadata destinations and source identity

The existing [QwenLayerStagePlan.Parameter](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenLayerStagePlan.swift:35) has one destination, and the [storage commitment](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/VerifiedQwenLayerStageLoading.swift:30) requires summed destination count/bytes to equal source count/bytes. Introduce a small model-neutral descriptor used by the new Gemma mapper:

```swift
struct LayerStageTensorMapping {
    let canonicalSourceName: String
    let sourceDescriptorIdentity: String
    let destinations: [Destination] // bounded: exactly one, or tied replica exactly two
    let replication: Replication?  // closed tiedEmbedding case, same source on rank0+rank1
}
struct StageConstructionDescriptor {
    let originalConfiguration: Data
    let sourceLayerRange: Range<Int>
    let globalLayerIndices: [Int]
    let localQuantizationPolicy: Data
    let responsibility: StageResponsibility // ingressResidual / finalLogits
}
```

Conservation becomes: each admitted text source appears once in unique source coverage; every destination name is unique within its rank; only the exact embedding triplet may appear twice; sum(destination bytes)=uniqueSourceBytes+explicitReplicaBytes. Excluded components must equal the captured vision set, with no unknown text leaves. Commit original config hash, ranges/global mapping, full quantization policy, local relocation and replica roles. Use a new typed Gemma Plan identity; do not reuse a Qwen fingerprint for this topology.

`geometry.expected_text_tensors()` and `partition.make_partition()` provide the concrete shape/destination/policy rules to port. `artifact.validate_inventory()` supplies exact descriptor coverage. They do not provide payload authentication. Keep descriptor-backed file checks and actual selected array ownership from `VerifiedQwenLayerStageLoading` as the materialization mechanism, refactored only where model/Plan types require it.

## 2. Ranged actual Gemma module

Add a narrow `Gemma4LayerStage` inside MLXLLM with a factory accepting only the validated original config and descriptor. Build only the selected `Gemma4DecoderLayer(fullConfig, layerIdx: global)` objects. Use small module wrappers to preserve `language_model.model.layers.<local>` names, plus the active embedding and optional final norm. Do not construct a full `Gemma4TextModelInner` and prune it, or synthesize compact full-model geometry.

Reuse the public decoder's call and existing GeGLU/router/attention implementation. Lift the existing full-trunk schedule policy into one internal helper callable by both ordinary and ranged trunks: global final-layer test, tail policy, last-query capability, scheduled-prefill weighted reduction and global submission cadence. Keep the ordinary full-model caller's behavior byte-for-byte equivalent. Do not duplicate these policies in Runtime or expose process-global forced kernel selection.

Expose three guarded operations through the shared stage execution interface: ingress token lookup, residual layer forward, final norm/tied head. The final projection must reuse the rank1 embedding object, not allocate a separate `Linear(vocab)` or a second rank1 embedding. For rank1, that object is never used for residual ingress. Preserve source BF16 parameters and loaded local policy; do not enable expert gate/up fusion.

Add narrow loaded-KV-dtype introspection in MLXLLM, using the actual quantized embedding scales/biases and attention projection/normalization policy. Gemma's private attention internals mean this belongs beside the existing implementation, not a Runtime reflection cast. Until actual checks establish the dtype, refuse admission rather than blindly copying Qwen's BF16 declaration.

## 3. Shared owned state, with a Gemma geometry branch

Add a closed Gemma branch to [CBv2RequestGeometry](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/CBv2RequestGeometry.swift:17), after factoring common cache ownership/capacity checks. It supplies selected local kinds from the original global list and an explicit local→global map. Set each kind's `modelLayerIndex` to its local model index; Gemma's ordinary kinds historically use nil for identity mapping. Keep global layer identity in the stage descriptor and snapshot join, not in cache-bank array indexing. All sharesKVWithLayer are nil; queryHeads/kvHeads divisibility and actual full/sliding head dimensions remain validated.

Use `CBv2RecurrentStateSpec(layers: [])` without a fabricated recurrent model. Retain the existing bind/evaluate/commit ordering; its empty generation is valid and allocates no recurrent arrays. The forwarding closure chooses the existing Gemma stage method without requiring a `CBv2PositionedRecurrentLanguageModelForwardable` cast.

In [CBv2OwnedRequestState.validateState](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/CBv2OwnedRequestState.swift:120), derive retained length by kind for the admitted ordinary path: fullF/slidingmin(F,window). Always enforce absolute/device frontierF, row identity, exact native dtype and actual shapes. Charge full-row maximum capacity and fixed sliding ring capacity. Keep existing failure poisoning and retirement intact.

In [CBv2OwnedStateSnapshot](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/CBv2OwnedStateSnapshot.swift:44), accept nil confirmed recurrent state only when the admitted recurrent spec is empty. Read the existing chronological ring snapshots and absolute offset; compare/snapshot shapes by actual kind. Retain explicit global index and retained span in Gemma's state descriptor so a future comparator cannot interpret a1024-token window as a prefix. Existing Qwen snapshot behavior must remain identical.

Do not create a separate Gemma state owner, row rollback system, request sequence or transport. The existing native retirement proof remains necessary even if host state descriptors are empty or a client disconnected.

## 4. Registered source/resource/profile binding

Add a model-bound Gemma specification and source descriptor plan. Keep it planning-only until the native constructor and resource ledger are qualified. The current [QwenResidentSource](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentSource.swift:17) full-model metadata constructor cannot be selected for Gemma: it casts dense Qwen, expects GDN fusion and invokes model construction. Use this package's closed descriptor mapping to avoid full30-layer materialization just to discover names; later compare the selected actual module inventory against those expectations before any selected tensor read.

Factor only the descriptor/materialization plumbing needed by both adapters. Retain `VerifiedCheckpoint`, pre-read hooks, aligned no-cache reads, evaluated independent compact buffers, exact update, weak model retirement and source-file closure. Separate source unique coverage from replicated destinations in the storage commitment. New Gemma resource code derives full/windowed KV and MoE scratch; it cannot call `QwenDenseStateBudget` or claim a zero GDN charge proves a complete bound.

After these pass, dispatch `QwenLayerStageSession`'s reusable schedule/boundary/state work through a small typed stage backend while preserving its current Qwen constructor as one sealed case. `QwenResidentAdapterDefinition`, source admission, worker metadata, registered model/profile catalog and installed configuration capability matching then need explicit Gemma branches with exact model/geometry identities. Existing frame width bounds already contain2816; there is no need to widen the transport envelope. Use the same owner/JACCL setup, duration translation, canonical gate, resource guards and request accounting. Do not advertise a capability until actual descriptor loading, numerical and cleanup qualification establishes it.

## Smallest next patch set

1. Port the pure map and multi-destination storage conservation; test all29 cuts and refusal mutations without constructing a model.
2. Add the ranged MLXLLM module and shared policy helper, actual dtype seam, and selected descriptor inventory under a fixture-only/native qualification entry.
3. Add the narrow per-kind/empty-recurrent changes in the existing state owner and snapshots; prove unchanged Qwen controls and actual tiny Gemma whole-versus-split parity.
4. Complete model-specific MoE/resource bounds and selected payload authentication, then add unadvertised registered Gemma admission for guarded qualification.

No step here alters ordinary solo M5/NAX policy or installed product eligibility. Native execution and physical qualification remain root-owned follow-up work.
