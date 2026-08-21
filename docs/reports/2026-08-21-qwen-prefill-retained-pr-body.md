## Summary

Rebases the retained Qwen prefill improvements onto current master after PRs
#646-#650. It intentionally excludes the unqualified D=256 attention path,
router fusion, and the rejected MoE Mega-Kernel experiments.

Retained:

- fuse the four GDN input projections into one quantized QMM;
- enable Qwen direct sorted-expert weighted reduction by default with an explicit rollback flag;
- include parity and isolated performance tests.

## Before

```mermaid
flowchart LR
  subgraph Behavior_before[Behavior]
    P1[Prompt chunk] --> G1[30 GDN layers]
    G1 --> A1[4 input QMMs per GDN layer]
    P1 --> M1[40 MoE layers]
    M1 --> U1[Unsort to tokens x topK x hidden]
    U1 --> R1[Multiply routing weights and reduce]
  end
  subgraph Code_before[Code]
    Q1[Qwen35GatedDeltaNet] --> QKV[inProjQKV]
    Q1 --> Z[inProjZ]
    Q1 --> B[inProjB]
    Q1 --> A[inProjA]
    S1[SwitchGLU.callAndWeightedReduce] --> Legacy[scatterUnsort + weightedExpertSum]
  end
```

## After

```mermaid
flowchart LR
  subgraph Behavior_after[Behavior]
    P2[Prompt chunk] --> G2[30 GDN layers]
    G2 --> A2[1 fused 2048-to-12352 QMM per GDN layer]
    P2 --> M2[40 MoE layers]
    M2 --> R2[Optional direct inverse-permutation weighted reduction]
    R2 --> O2[tokens x hidden]
  end
  subgraph Code_after[Code]
    Q2[Qwen35GatedDeltaNet.projectInputs] --> Fused[QuantizedLinear fused weights/scales/biases]
    Fused --> Views[QKV / Z / beta / decay views]
    S2[SwitchGLU.callAndWeightedReduce] --> Gate{Exact Qwen production shape}
    Gate -->|on and exact production shape| Direct[weightedExpertUnsort]
    Gate -->|otherwise| Legacy2[legacy fallback]
  end
```

## Canonical implementation

- GDN fusion: `mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift:306-391`
- Batched MoE flattening/caller: `mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift:1190-1261`
- Direct-reduction default/rollback: `mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift:261-266`
- Eligibility/fallback: `mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift:493-581`

## Evidence

- GDN fusion parity: QKV/Z exact; A/B max difference approximately `4.1e-6`.
- Historical GDN step A/B: 10.2% lower TTFT at 8K, 6.0% at 16K, 6.5% at 32K.
- Direct expert reduction isolated primitive benchmark: 0.6389 ms -> 0.3564 ms,
  1.793x speedup at 2,048-token stripe geometry.

## Excluded

- D=256 Steel attention: correctness passed, speed not isolated under stable posture.
- Router/shared-gate fusion: wash/regression at 8K.
- MoE Mega-Kernel/GateUp+SwiGLU fusion: 63.5-71.2% slower in paired tests.
