### Faster prompts on Macs without neural accelerators

- MLX's steel affine quantized matmul computes prompt-sized products (256 rows
  or more, 64-aligned outputs) in 64-row x 32-column tiles for 16-bit inputs and
  32 x 64 for FP32 partials instead of 32 x 32 on GPUs without neural
  accelerators (M1-M4, and the M3 Ultra rank of a pair). On the M3 Ultra alone a
  4,096-token prompt took 2.5% less time (27B 12.37 -> 12.06 s, 9B 3.55 -> 3.46 s)
  with the same tokens. `MLX_QMM_STEEL_TILE=32` restores the previous tile.
- Qwen tensor-parallel prompt frames are submitted to the GPU every four layers
  while they are built (`DARKBLOOM_QWEN_TP_PREFILL_STRIDE=0` restores whole-frame
  evaluation). With both changes the 27B pair at 1:1 reached its first token
  1.4-3.1% sooner (4K 8.22 -> 8.08 s, 16K 36.7 -> 35.5 s, 32K 81.8 -> 80.0 s) and
  the 9B pair 1.1-2.3% sooner (4K 2.63 -> 2.60 s, 32K 27.5 -> 26.9 s), with the
  same tokens.
- Diagnostics: `darkbloom-cluster-tp-check qwen-prefill` (one rank's prompt
  frames, layers and projections), `DARKBLOOM_QWEN_TP_PREFILL_FRAME_TIMING=1`
  and `pair-check --worker-environment`.
