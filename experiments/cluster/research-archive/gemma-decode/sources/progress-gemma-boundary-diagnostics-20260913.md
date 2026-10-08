# Gemma boundary diagnostics checkpoint — 2026-09-13

Goal remains active. The primary requirement is at least 800 uncached prefill TPS (1000 stretch) on the registered dense Qwen3.8 27B 4-bit artifact using two M3 Ultra 256 GB machines, batch one / 8192 prompt tokens, correct continuation and improvement over eligible solo. No target-hardware throughput is qualified.

The boundary diagnostic milestone is complete: native binary d39cf2ec2e8c75d1af31532f593458e7894750d2e2d272e0bdaf536622ac8635, immutable runs/gemma-boundaries-final-20260913. All 24 runs pass; all eight schedule/capture/archived control groups have exact outputs. The public record is ../d-inference/experiments/cluster/inference/GEMMA_BOUNDARY_DIAGNOSTICS.md.

CPU analysis verifies 384 Float32 partial sums and 860160 BF16 casts plus 221184 Float32 identity casts, with zero failures. Replayed expert sets/order do not change. W8 BF16 seed101 demonstrates 1.49e-8 reduced-output difference becoming 0.0009765625 at casting, surviving branch normalization. This establishes local cast amplification, not a sole cause for final error or a quality fix. Mixed seed31 intermediate differences reconverge at final output.

Both native rank-mismatch cases fail before inference. Eight invalid CLI settings fail before model construction. Persistent regression has two cohorts/six requests/two fresh controls with exact outputs. Full Python suite:148 tests. Comparator:7 tests. Source and immutable bundle verification is saved in gemma-boundaries-final-source-verification-20260913.json; only two READMEs differed from the captured source at that checkpoint. docs-check:280 files; pinned submodules unchanged.

Read-only SSH probe of darkbloom-48 still timed out after five seconds. No network mutations, service restart, or real-model benchmark was attempted. Power/hang/network cause remains unknown; two-machine RDMA and M3 Ultra hardware are unavailable.

Next bounded experiment started after this checkpoint: separate float32-through-norm policy, retaining each FFN reduction in Float32 through its separate RMSNorm before BF16 cast and branch combination. Native default and prior float32 semantics stay unchanged. This tests a principled rounding boundary, with paired policies, held-out seeds, and ordinary-native output comparisons. No tolerance relaxation or forced routing.
