### GLM tensor-parallel decode command buffers and sum fences

- GLM tensor-parallel decode steps, MTP rounds and lane rounds encode up to 100 operations a Metal command buffer instead of the rank guard's 16, which prefill keeps; each further buffer cost about 10 µs of GPU time (13.24 to 12.56 ms a decode step on two M5 Ultra, tokens identical).
- GLM tensor-parallel workers turn on the fused all-sum fence update and let the hyper-connection site wait for the sum itself (`MLX_METAL_FUSED_FENCE_UPDATE`, `MLX_METAL_FENCED_INPUTS`; a launcher value is kept): 12.58 to 12.43 ms a decode step, tokens identical.
