# Distributed inference progress — generation and MoE primitives

The [canonical goal](../d-inference/docs/design/distributed-inference-goal.md)
remains active: opt-in clustering, initially two 256 GB M3 Ultras, primary dense
27B acceptance of 800 uncached prefill TPS at batch one / 8192 input tokens,
1000 TPS stretch, reusable support for the two named MoE families and safe
product setup/recovery. No target-performance or release milestone is complete.

Final evidence is in
[receipt.json](runs/generation-moe-validation-20260913-verified/receipt.json).
Executable SHA-256:
`73b3a63b7e7984b749d27b09d9b07db87ae490ade43df4cae311f1f040106e9c`.
Runtime bundle manifest SHA-256:
`c6b0e9640036fe6c78db283db901414783415ab109452aece830a4a7a489f091`.

Implemented and checked:

- Coordinated rank-zero greedy output selection, per-run sequence reset,
  sequence/step/vocabulary/count validation in the token collective, separate
  selected/local-argmax/input histories, and native report schema 3.
- Synthetic BF16 profile with all floating parameters, including A_log, checked
  against requested dtype. Packed weights remain U32. Actual 9B A_log metadata
  is F32; actual 27B A_log is BF16. This tiny fixture follows the latter policy.
- Six dense solo/full-loopback executions: F32 greedy, BF16 teacher-forced and
  BF16 greedy, each paired, warmup one, repetitions two, prompt 65, chunks 32,
  outputs eight. Every measured repetition's output and input history matches
  the solo baseline. Saved last-repetition logits cover all 8×512 values/rank.
- F32 maximum absolute logit error 1.6e-6. BF16 observed maximum absolute error
  0.0234375 and maximum per-row relative RMS 0.0138524, with all greedy choices
  matching. These are bounded synthetic observations, not artifact quality gates.
- Forced different rank-local choices still feed the same continuation history;
  fourteen malformed-frame checks and invalid rank-zero selection rejected.
  Mixed F32/BF16 native ranks both reject before model inference/report emission.
- Shared expert inner-width partition primitive with per-projection affine
  W4/W8 G64, SiLU/tanh-GELU, split/fused gate-up, unequal aligned cuts, global
  expert IDs and preserved routing scores. Six primitive cases pass.
- Four actual tiny Qwen MoE block and two actual tiny Gemma decoder checks pass
  in F32/W4. Routing logits are captured; private final IDs/scores remain
  independently derived CPU oracles. Gemma reduces each branch before its own
  normalization; whole-model distributed MoE execution remains unimplemented.
- Copy-helper fix: pinned MLX copy shares storage, interior-axis take may be
  transposed, and GPU completion handlers can temporarily retain Data after
  eval. Fresh gather plus row-major contiguous materialization and load-time
  GPU synchronization preserve strict uniqueness/footprint checks. Twenty-four
  selections and twenty-four owned oracle copies pass, including rank-three
  U32 geometry, source overwrite/deletion, and forty-five rejected bad ranges.
- Both Qwen loader plans pass F32 and FP16-to-BF16 metadata fixtures. Four
  attention and six GDN operator cases still pass. Eighty Python tests and
  docs-check (280 files) pass; submodules remain unchanged.

The first two new ownership-check failures are retained in the adjacent
generation-moe-validation-20260913 and generation-moe-validation-20260913-final
directories; the final successful evidence is the `-verified` directory above.

Next useful offline work: exercise whole-model synthetic attention/GDN geometry
closer to 9B/27B, extend actual MoE boundary checks to BF16, and compose verified
MoE tensor loading/model plans. The current tiny dense model has hidden width
128, four layers, Q/KV heads 4/2 at dimension 64, and GDN key/value heads 2/2 at
dimension 128. It cannot establish long-context real-artifact quality.

The development 48 GB peer still reports offline, last seen
2026-09-13T23:40:00.1Z. Continue read-only recovery checks periodically; no further
network mutations or sustained real-model benchmarks while it is unavailable.
No successful two-machine RDMA transfer or target M3 Ultra run has occurred.
