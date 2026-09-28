# Explicit long-prefill profile

> Last updated: 2026-09-14 · commit `e4df336bc`

`long_prefill_8k_v1` adds an explicit request namespace for up to 8,192 prompt
tokens and 512-token chunks. The integrated foundation and single-process tiny
full-model/stage comparison passed the [dated validation](QWEN_LAYER_STAGE_LONG_PREFILL_VALIDATION.md).
This qualifies the tested tiny arithmetic and request ownership. A separate
[registered 9B 8K reference](QWEN_LONG_PREFILL_REFERENCE_VALIDATION.md) also passed.
The [two-process loopback path](QWEN_LONG_PREFILL_RANK_VALIDATION.md) and
[matched solo control](QWEN_LONG_PREFILL_SOLO_VALIDATION.md) also passed their
guarded native checks. Physical transport and cluster performance remain unqualified.

## Admission and identity

The profile describes geometry; it does not itself authorize a model, memory
budget, native execution mode or wire flow.

| Property | `long_prefill_8k_v1` |
|---|---|
| Batch | Exactly one |
| Prompt | 1–8,192 tokens |
| Chunk | 1–512 tokens |
| Frames | `ceil(prompt/chunk)`, at most 128 |
| Output | Exactly one selected token; no decode forward or teacher tokens |
| Reserved sequence capacity | Prompt count plus one |
| Declared hidden/vocabulary limits | 8,192 / 262,144; actual model admission is separate |

[QwenLayerStagePrefillProfile.swift](Sources/ClusterInference/QwenLayerStagePrefillProfile.swift)
checks arithmetic before admitting a request. For example, 8,192/512 has 16
frames and 1,025/512 has three frames, ending in a one-token tail. An otherwise
in-range prompt/chunk pair requiring more than 128 frames is rejected.

[QwenLayerStageProfiledPrefillRequestSpec.swift](Sources/ClusterInference/QwenLayerStageProfiledPrefillRequestSpec.swift)
requires the profile explicitly. Its `decode(_:)` entry accepts at most 2 KiB,
scans the original JSON for duplicate fields and strict integer syntax, requires
the exact six-field schema, then invokes the throwing constructor. Direct
`JSONDecoder` entry is rejected. Profile, request and recorded-history hashes
have distinct domains; incoming integers never create an unchecked schedule.

[QwenLayerStageProfiledPrefillRecordedRequest.swift](Sources/ClusterInference/QwenLayerStageProfiledPrefillRecordedRequest.swift)
binds the actual in-vocabulary prompt slices to every frame and frontier. The
final frame alone requests logits. A request UUID identifies one request; it
does not replace the source artifact, configuration, plan or history identities.

The legacy request initializer, Codable representation, fingerprints, 128/32
caps and decode semantics remain unchanged. Existing v1/v2/v3 wire flows retain
their bounds. [QwenLayerStageAdmittedRequest.swift](Sources/ClusterInference/QwenLayerStageAdmittedRequest.swift)
is a closed internal enum over already admitted legacy or profiled requests.
[QwenLayerStageAdmittedSchedule.swift](Sources/ClusterInference/QwenLayerStageAdmittedSchedule.swift)
delegates legacy work to its original schedule and rejects decode work for the
new profile. Failed frame admission or commit leaves its frontier unchanged.

## Shared native arithmetic and ownership

[QwenLayerStageSession.swift](Sources/ClusterInference/QwenLayerStageSession.swift)
has an explicit `profiledRequest:` initializer sharing the existing owned
state and forward implementation. Whole layers retain their full widths and
original global positions. The plan still divides layers into two contiguous
ranges at a full-attention phase boundary; it does not slice tensor dimensions.

Stage zero produces the full residual before final normalization. Stage one
consumes an owned, validated boundary and owns the final norm/head. Each stage
evaluates its output and all recurrent/KV state roots before committing the
same prompt frontier. Existing boundary copying, hashing, shape/dtype checks,
state validation and cancellation remain in the path.

The guarded `qwen-layer-stage-profiled-check` mode is a fixed synthetic matrix:
eight layers split 4+4, full width 128, vocabulary 512, seed 7, native CBv2,
both Float32 and BFloat16, and prompts 1,025 and 8,192 with chunk 512. The
fixture explicitly reserves 8,193 context positions; the default legacy fixture
configuration is unchanged. Source files are removed after loader ownership
proof and before the first transformer forward.

The check compares each committed state component and the complete final native
logit row with a same-chunk full-model baseline. It also injects failure after
stage zero's first 512-token commit, requires both requests to retire, rejects
retired-owner reuse, then runs fresh requests on the same resident stage models.
See [QwenLayerStageProfiledParityCheck.swift](Sources/ClusterInference/QwenLayerStageProfiledParityCheck.swift)
and [QwenLayerStageProfiledLifecycleCheck.swift](Sources/ClusterInference/QwenLayerStageProfiledLifecycleCheck.swift).
This lifecycle result does not qualify persistent production serving.

## Arithmetic and resource gates

[QwenLongPrefillArithmeticEnvironment.swift](Sources/ClusterInference/QwenLongPrefillArithmeticEnvironment.swift)
admits the actual environment before MLX initialization: explicit
`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128`, `DARKBLOOM_BF16_WEIGHTS=1` and
`MLX_ENABLE_TF32=1`, with `MLX_METAL_GPU_ARCH` and `MLX_SDPA_BLOCKS` absent.
A full 512-token chunk uses four query blocks. Chunk size can change numerical
dispatch, so a 32-token reference cannot qualify this 512-token path. The
environment receipt also does not substitute for binary, Metal-library,
hardware and source provenance.

[QwenLongPrefillTensorBudget.swift](Sources/ClusterInference/QwenLongPrefillTensorBudget.swift)
computes checked named state/boundary terms. The separate
[QwenRegistered9BLongPrefillAdmission.swift](Sources/ClusterInference/QwenRegistered9BLongPrefillAdmission.swift)
admits only the pinned registered-9B configuration/artifact, BF16 and exact
8,192/512/1 workload under a 768 MiB named-tensor ceiling. Its estimate is
745,345,056 bytes. The legacy 512 MiB ceiling is unchanged.

That estimate includes conservative state generations, capacity and boundary
arrays. It excludes weights, native workspaces, allocator/driver costs and
other process/OS memory; it is not whole-process memory safety or permission
to launch the registered model. Independent OS resource gates and verified
loading remain required. The registered reference passed separate resource,
verified-loading and native checks; see its dated validation linked above.

There is no public long-profile launch command. The dated tiny validation used
a separately reviewed guarded launcher with a pinned bundle, source archive,
resource monitoring, bounded output and an owned-process deadline. The public
short-prefill launcher does not admit this profile. Future registered-model
and transport qualification must preserve these separate gates. Related:
[inference checks](README.md), [distributed goal](../../../docs/design/distributed-inference-goal.md).
