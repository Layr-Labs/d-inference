# Qwen whole-layer stage correctness

> Last updated: 2026-09-13 · commit `e4df336bc`

An eight-layer dense Qwen fixture split into two full-width four-layer stages
matched the independent full-model CBv2 baseline byte-for-byte in all tested
logits and committed cache/recurrent state. Three weight-format cases passed
on one M4 Max. This is a sequential local correctness result; it does not
measure a speedup, transport, the registered 27B model or M3 Ultra hardware.

## Execution and ownership

The phase-aligned stage plan keeps every projection at its original width.
The first stage owns the embedding and layers 0–3; the second owns layers 4–7,
final norm and output head. The actual attention layers are global 3 and 7.
The first stage exports the residual before the final norm, through Qwen's
existing noncaptured CBv2 hidden-state method. The second consumes that residual
through the existing CBv2 embedding-input interface.

The verified loader checks both compact inventories against the original
configuration and canonical source tensors, remaps quantization overrides,
and materializes only the selected stage's full tensors. The inactive first
stage norm keeps its immutable module with an explicit H-element parameter;
inactive head/embedding modules have bounded parameters. The second stage
rejects missing residual input before its inactive embedding can be called.

Both stages independently own their attention KV, convolution and SSM state.
Every forward evaluates output plus all state roots, validates shapes/dtypes
and token offsets, then commits. The sequential pair makes a byte-preserving
owned copy of each residual; it has no network transfer or compute overlap.

## Initial native result

Run `qwen-layer-stage-runtime-20260913` completed on 2026-09-14 at
06:38:44 UTC (September 13 locally), native and driver exit 0. The host was an
M4 Max with 36 GiB unified memory and 32 GPU cores, using the repository's
pinned MLX dependencies, Xcode 26.5 and native arithmetic.

Each fixture used seed 7, hidden size 128, vocabulary 512, affine W4/G64
quantization, a deterministic 65-token prompt in chunks 32/32/1, and three
teacher-forced decode inputs producing four total output rows. MTP was disabled.

| Fixture | Source bytes | First-stage active bytes | Second-stage active bytes | Inactive bytes, first/second |
|---|---:|---:|---:|---:|
| Float32, direct text configuration | 1,440,224 | 719,856 | 720,368 | 1,024 / 512 |
| BF16, wrapped text configuration | 1,261,552 | 630,648 | 630,904 | 512 / 256 |
| BF16, wrapped, 124 stored FP16 metadata tensors | 1,261,552 | 630,648 | 630,904 | 512 / 256 |

For every fixture the loader checks all 237 active tensors: 118 owned by the
first stage and 119 by the second. Names, full shapes, dtypes and logical bytes
match the ordinary saved-checkpoint loader. Actual active buffers have compact,
unique, zero-offset allocations before forwarding; inactive parameters are
checked separately. Both stage loaders reject an incorrect aggregate and a
corrupted owned source file. Existing loaded parameter handles remain unchanged.

The test deletes its generated checkpoint and checks every active tensor again
before any transformer forward. Native GDN fusion may subsequently replace
named parameter arrays with views, so unique allocation is specifically a
load-time observation. Later inference uses resident weights after source deletion.

At frontiers 32, 64, 65, 66, 67 and 68, the native test compares all 18 state
components: six convolution/SSM pairs and two attention key/value/device-offset
triplets. Global layer identity, shape, dtype, count and bytes match exactly.
The final prefill and three decode steps also compare every native logit byte
in each complete 512-value row. Intermediate evaluation handles are checked
for shape/dtype only. All successful request owners retire cleanly.

The three cases therefore cover 12 exact output rows and 324 exact state-entry
comparisons. This statement describes the native checks in the archived source.
The JSONL retains candidate logit values/hashes and state fingerprints; it does
not include separate baseline logits or individual raw state arrays for a CPU
replay of every pairwise equality comparison.

## Evidence and limits

The initial run archives 182 source/dependency files and a frozen executable
bundle. Private run storage is outside the repository; no checkpoint payloads,
machine credentials or private addresses are published here.

| Identity | SHA-256 |
|---|---|
| Initial native executable | `1e249820b3f5bdddbdf5835d3201935de0ee93a30711cfb8321875d01c2196e9` |
| Initial source manifest | `bb26717bb425ccfabf36bc454b1e15447eabbf9530122b6f3444e4ecdb634403` |
| Initial driver | `9299c54ea84fa09ab4b9917984b6ad168794995639941f8ca8e6d6468d842bfa` |
| Initial six native JSONL records | `3b8d9b2c32361ce6ba9795314e991e803dbd5d996fd13de1cb86fa0f5454bd58` |

The process supervisor retained the conservative real-9B solo admission
estimate even for these small fixtures. Sampled owned-process RSS peaked at
73,777,152 bytes; memory pressure stayed at level 2 and there was no new swap.
RSS sampling is not an exact device or process memory peak. The owned native
process exited and was reaped; no process cleanup failure occurred.

The first integration build exposed a Swift nonescaping callback restriction
in the pair's error wrapper. Each stage and residual-copy operation now owns
its native error scope; the subsequent build and pure admissions passed.

The registered 9B configuration/header-only check separately maps 927 text
tensors into 463/464 stage owners, excluding 364 vision/MTP tensors. That result
does not establish actual registered-model stage execution. Real-model state
and logits, a two-process boundary, failure/reconnection over the physical
link, overlap, and target-hardware latency remain to be qualified.

## Code map

| Concern | Source |
|---|---|
| Pure stage plan and policy remapping | `Sources/ClusterInference/QwenLayerStagePlan.swift`, `QwenLayerStageMetadata.swift` |
| Original metadata and compact inventory | `Sources/ClusterInference/PreparedQwenLayerSource.swift`, `PreparedQwenLayerStage.swift` |
| Verified payload loading and inactive parameters | `Sources/ClusterInference/VerifiedQwenLayerStageLoading.swift`, `QwenLayerStageInert.swift` |
| Request schedule, residual and sequential execution | `Sources/ClusterInference/QwenLayerStageSchedule.swift`, `QwenLayerStageSession.swift`, `QwenSequentialStagePair.swift` |
| State ownership and CPU snapshots | `Sources/ClusterInference/CBv2OwnedRequestState.swift`, `CBv2OwnedStateSnapshot.swift` |
| Fixture, independent loader oracle and parity | `Sources/ClusterInference/QwenLayerStageFixture.swift`, `QwenLayerStageLoaderOracle.swift`, `QwenLayerStageParityCheck.swift` |

The reproduction command is in [the inference probe README](README.md#whole-layer-stages).
The [distributed inference goal](../../../docs/design/distributed-inference-goal.md)
defines the separate prefill and release acceptance criteria.
