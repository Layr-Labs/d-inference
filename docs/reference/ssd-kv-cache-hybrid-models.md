# SSD KV Cache for Hybrid Models

Interleaved sliding/full models use frozen-full tail replay on the contiguous,
unquantized native-floating-point backend. Gemma 4 QAT and GPT-OSS can therefore advertise exact reusable
prefix capability after their SSD scan is ready. Paged and quantized hybrid
rows remain cold-only.

## Root cause and invariant

The v0.7.5 algorithm restored every owning full-attention row only through a
replay start C, then appended projected K/V while rebuilding omitted sliding
state. Early replay activations were computed without their true finite-window
history. A downstream full layer stored those divergent projections
permanently, so decode continued attending polluted K/V after the sliding error
itself had flushed.

The exact invariant is:

- M is the whole-block matched boundary.
- R is the conservative finite-window dependency span:
  `windowed-layer count × largest window`, clamped to M.
- C is `M - R`.
- Sliding rows start empty at C and rebuild normally through M.
- Every storage-owning full row keeps exact cached K/V immutable through M.
- During replay, a full row has a logical read cursor beginning at C and a
  separate immutable storage high-water M. It exposes only `[0, chunkEnd)` to
  attention and ignores replay-generated K/V.
- At M, the full row transitions exactly once to ordinary append mode.

This removes the persistence path for replay error. Once R has flushed every
finite-window dependency, the state at M is identical to cold prefill without
storing any sliding layer on SSD.

## Typed capability and fail-cold policy

`CBv2PrefixReuseCapability` derives support from the exact layer layout and KV
backend before cache construction. Each hit produces a
`CBv2PrefixReusePlan` carrying M, C, R, strategy, saved tokens, restored tokens,
capacity-reservation tokens, and full-KV byte facts.

Supported paths:

- contiguous unquantized native-float, interleaved hybrid: `frozen_full_replay`;
- contiguous native-float or paged FP16, structurally safe layout: existing direct or
  ordinary tail replay.

Rejected paths:

- paged interleaved hybrid: requires a separately proved dual-cursor paged row;
- quantized rows: snapshots are lossy and cannot be adopted exactly;
- unknown/invalid layouts or backend implementations.

An explicit paged selection derives cache capability from the resolved serving
backend. A slot that remains paged keeps interleaved hybrid reuse cold. A kernel,
physical-capacity, or pool-construction fallback resolves contiguous before SSD
construction and enables frozen-full reuse in the same build
(`provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift`
`makeProductionBundle`).

Any failed invariant or capacity check falls back to cold prefill before KV
state is published. The coordinator protocol schema is unchanged.

The generic saved-token floor is 1,024. Long frozen hybrids with
`R >= 25,600` configure a 1,536-token minimum because the final real Gemma
matrix found the 1,024-saved boundary noisy/negative while 1,536 and 7,168 were
beneficial. Durable donation is deliberately strict and block-rounded:
`prefixTokens > R + minimum`. With 256-token blocks and `R = 25,600`, the exact
27,136 boundary is discarded and 27,392 is the first persisted boundary, so
the first durable entry saves 1,792 tokens
(`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift`
`donate`).

## Accounting and lifecycle

SSD staging reconciles encrypted file estimates to exact rehydrated MLX bytes.
Frozen adoption transfers those arrays directly into full rows instead of
copying them. Engine and process-wide admission reserve native-width owning
full rows through the request's maximum sequence length before publication;
replay work below M consumes that existing reservation and is not
double-charged. Sliding rings retain their ordinary window-capped allocation.

Cancellation, preemption, shutdown, corruption, capacity refusal, and unload
release every staging ticket, cache pin, backend row, and reservation. A
preempted request discards the plan and restarts cold.

## Layout epoch

DBK3 remains the file format. Snapshot semantics changed, so the layout identity
is `cbv2-frozen-full-3|native-fp|<blockSize>|<layerDigest>`. An existing
`cbv2-snap-2` binding rotates the durable cache epoch and deletes old blocks
before protocol-v2 readiness can be advertised.

## Code locations

- Planner: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/PrefixReusePlan.swift`
- Frozen row: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SequenceKV/FrozenReplayFullSequenceKV.swift`
- Backend adoption: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SequenceKV/ContiguousKVBackend.swift`
- Scheduler boundaries/accounting: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SchedulerV2.swift`
- Provider policy: `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift`
- SSD construction: `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift`
- Proof suites: `CBv2FrozenReplayTests.swift`, `CBv2FrozenReplayModelTests.swift`,
  and `FrozenReplayRealModelTests.swift`
