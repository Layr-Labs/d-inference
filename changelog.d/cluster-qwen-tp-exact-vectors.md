### Qwen tensor-parallel decode with batch-invariant projections

Every Qwen tensor-parallel plain decode step, verify window and batched row
(the 9B, the 27B and the dense projections of both 35B A3B rows) now projects
through the SDK's batch-invariant affine kernel. Each position of a speculative
verify window therefore has the bits of the plain decode step that computes the
same token, and each concurrent row the bits it has alone, at any cohort width.
This changes the rounding of every decode projection relative to MLX's own
kernels, so recorded tensor-parallel references must be regenerated once.

A row-parallel projection reads its bf16 activation directly and writes its
FP32 partial (no separate widening launch and no FP32 copy of its scales), and
its rounded all-sum feeds the fused residual step, so a step runs far fewer GPU
launches. Each rank logs the arithmetic it resolved once per load
(`darkbloom-aqv-kernel-v1`: exact vectors, the kernel's arithmetic and words
per lane on that GPU family, its layouts), and the pair binds whether exact
vectors are on into its load agreement, so two ranks that resolved it
differently refuse to load. `DARKBLOOM_QWEN_TP_EXACT_VECTORS=0` (diagnostic
only, never forwarded to an installed rank) keeps MLX's kernels.
