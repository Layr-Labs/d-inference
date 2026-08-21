# Qwen Prefill Retained Optimizations on Current Master

**Date:** 2026-08-21  
**Base:** `origin/master` at `937a8a1d1` (through PR #650)  
**Branch:** `perf/qwen-prefill-retained`

## Purpose

The earlier `perf/splitd-megakernel-prefill` branch combined confirmed wins,
insufficiently isolated candidates, and rejected experiments on top of the
pre-merge PR #646 history. This branch is rebuilt from current master and keeps
only the post-#646 optimizations with positive speed evidence.

## Retained

### GDN 4-in-1 input projection fusion

The 30 GDN layers replace four quantized input projections:

```text
2048 -> 8192  qkv
2048 -> 4096  z
2048 -> 32    beta
2048 -> 32    decay
```

with one `2048 -> 12,352` quantized projection followed by views.

Measured progression on the earlier qualification branch:

| Prompt | Before | After | TTFT reduction |
|---|---:|---:|---:|
| 8K | 5,171.09 ms | 4,645.78 ms | 10.2% |
| 16K | 11,416.72 ms | 10,729.91 ms | 6.0% |
| 32K | 28,529.06 ms | 26,681.86 ms | 6.5% |

The dedicated packed-W4 parity test measured zero difference for QKV/Z and
approximately `3.1e-6` for the small A/B projections.

### Direct weighted expert unsort reduction

Qwen's sorted expert output is reduced through the inverse permutation directly
into `[tokens, hidden]`, avoiding the `[tokens, topK, hidden]` assignment-order
intermediate. This remains behind `MLX_QWEN_DIRECT_EXPERT_REDUCTION` while full-model
qualification is completed. A paired 25-sample primitive benchmark at the exact
2048-token stripe geometry (`16,384 x 8 x 2,048` assignment tensor) measured:

| Reduction | Median |
|---|---:|
| Legacy assignment tensor multiply + top-8 sum | 0.6389 ms |
| Direct inverse-permutation weighted reduction | 0.3564 ms |
| Primitive speedup | **1.793x (44.2% lower latency)** |

This isolates a real local win. The expected full-model delta is smaller because
expert projections dominate the MoE layer.

## Reverted / excluded

### D=256 Steel attention

Excluded from this branch. Numerical correctness was established, but speed was
not isolated in an adjacent, stable-power A/B. Earlier D=256 fused experiments
also showed that bounded memory does not imply a speed win. It may be
requalified separately.

### Router + shared-expert gate fusion

Excluded. Its measured step was a wash: about 1.8% slower at 8K and only
0.7-0.8% faster at 16K/32K. That does not meet the bar for an always-on change.

### MoE Mega-Kernel and GateUp+SwiGLU fusions

All source experiments were reverted. The full one-threadgroup kernel destroyed
Down output-column parallelism. The two correctly wired GateUp+SwiGLU candidates
also regressed in paired microbenchmarks:

| Candidate | Discrete | Fused | Result |
|---|---:|---:|---:|
| Two FP32 accumulators | 1.7977 ms | 3.0785 ms | 71.2% slower |
| BF16-staged Gate tile | 1.8257 ms | 2.9847 ms | 63.5% slower |

No Mega-Kernel code is present in the retained branch.

## PR scope

This master-based branch is intended to produce focused PRs:

1. `mlx-swift-lm`: GDN 4-in-1 fusion and parity test.
2. `mlx-swift-lm`: direct expert reduction behind an isolated qualification
   gate, retained only if the new A/B is positive.
3. Superproject: pin the qualified `mlx-swift-lm` commit and add production
   benchmark evidence.

The PR description must include before/after Mermaid diagrams for both behavior
and code flow.
