### GLM tensor-parallel decode command buffers and sum fences

- GLM tensor-parallel decode steps, MTP rounds and lane rounds encode up to 100 operations a Metal command buffer instead of the rank guard's 16, which prefill keeps; each further buffer cost about 10 µs of GPU time (13.24 to 12.56 ms a decode step on two M5 Ultra, tokens identical).
- GLM tensor-parallel workers let the hyper-connection site wait for each all-sum in-kernel (`MLX_METAL_FENCED_INPUTS`; a launcher value is kept). The fused fence update (`MLX_METAL_FUSED_FENCE_UPDATE`) stays a launcher's choice: its multi-threadgroup path (partials above 32 KB) never signals the CPU, which stalled batched lanes about 0.7 s a round.
