# Dense Qwen layer split candidates

> Last updated: 2026-09-14 · commit `e4df336bc`

`QwenLayerStageCandidates.enumerate` produces legal two-stage plans and declared
parameter/state ownership from configuration bytes and canonical tensor names.
It is a metadata API for exploring splits before loading a model. Compute costs
remain `unknown`; candidates do not grant execution admission or select devices.

```swift
let candidates = try QwenLayerStageCandidates.enumerate(
    configuration: configurationData,
    canonicalSourceNames: canonicalNames)
```

Every candidate passes the existing [plan validator](Sources/ClusterInference/QwenLayerStagePlan.swift).
Both stage starts retain the attention/recurrent interval phase, and each stage
contains at least one complete interval. The final end need not align: a ten-layer
model with interval four has a legal 4+6 split. `structuralCuts` returns positions
only; the full enumerator rejects an empty candidate set or any validation error.

Each text parameter has one stage and a compact local name. Embeddings belong to
stage 0; the final norm and output head belong to stage 1. Recurrent layers declare
convolution and SSM state; full-attention layers declare keys, values and position
offsets. Vision and inactive MTP names remain explicit exclusions. The API preserves
original configuration bytes and delegates quantization remapping to the plan.
Name coverage alone does not validate tensor shapes, dtypes, payloads or state bytes.

Compiled metadata checks against retained registered configurations and canonical
name inventories produced these results, without reading model payloads:

| Retained model metadata | Layers | Legal cuts | Text tensors | Declared state components |
| --- | ---: | --- | ---: | ---: |
| Qwen3.5 9B | 32 | 4, 8, 12, 16, 20, 24, 28 | 927 | 72 |
| Qwen3.8 27B | 64 | Every four layers from 4 through 60 | 1,847 | 144 |

The [metadata validator](Sources/ClusterInference/QwenLayerStageMetadata.swift)
accepts an absent `output_gate_type`, or exactly `swish`/`silu`; other strings,
types and explicit null are rejected. It retains the declared spelling. The
registered 27B `swish` value agrees with the GDN SiLU operation in the pinned
[primary model implementation](https://github.com/huggingface/transformers/blob/049d2bf1220747b6d39e2a978b9f5fe0defa1dca/src/transformers/models/qwen3_5/modeling_qwen3_5.py)
and the existing [Swift gated norm](../../../libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen3Next.swift).
The provider decoder still ignores this optional field; this change adds only
experimental validation. GDN math and the separate full-attention sigmoid gate
are unchanged. Operator correspondence does not prove numerical parity.

Run `Tests/LayerStageCandidates/run.sh` for the [public Foundation fixtures](Tests/LayerStageCandidates/README.md).
They test inverse parameter mappings, state ownership, quantization remapping,
configuration preservation, non-half splits and rejection cases without MLX or
model downloads. The native `adapter-check` remains a separate integration check.
For a short numerical comparison, `qwen-layer-stage-compare --stage-cut LAYER`
uses the selected legal plan and a fresh full-model baseline. The option is
also supported by the short `qwen-layer-stage-rank-check`; omission preserves
equal halves. Both retain the existing 128-token prompt, 32-token chunk,
four-output and resource limits. CLI/admission checks passed. The
[unequal-stage correctness checks](QWEN_UNEQUAL_STAGE_VALIDATION.md)
passed for a tiny 4+8 fixture and the registered 9B 12+20 split, each against a
fresh full-model baseline. These are one-process correctness results.
The [public short-rank launcher](../runtime/stage_checks/README.md) forwards
`--stage-cut` and checks the selected parameter/state ranges. Its new CPU tests
passed. A private two-process 12+20 run on one GPU also passed against the
retained full-model reference; the public Python model entry remains unqualified.
The native registered 8K reference, pair and rank commands also accept
`--stage-cut`. They admit cuts 4, 8, 12, 16, 20, 24 and 28 while preserving the
8192/512/1 workload and all resource limits. Omission binds exactly 16+16,
including direct calls with a retained plan. Each runner rejects a mismatched
plan before model or collective work. The selected plan determines compact
layer counts and exact state ownership; final global state coverage stays
complete. See [QwenLongPrefillStageCut.swift](Sources/ClusterInference/QwenLongPrefillStageCut.swift).

A different cut needs a fresh full-model reference carrying that same plan
identity. The [one-process 8K 12+20 comparison](QWEN_LONG_PREFILL_UNEQUAL_VALIDATION.md)
passed; unequal 8K rank execution remains unqualified. The public Python long commands and
all solo commands reject the cut. 27B artifact loading, resource/hardware
eligibility, numerical checks and the
[M3 Ultra throughput target](../../../docs/design/distributed-inference-goal.md)
remain separate work.
