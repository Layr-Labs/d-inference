### GLM tensor-parallel decode command buffers and sum fences

- GLM tensor-parallel decode steps, MTP rounds and lane rounds encode up to 100 operations a Metal command buffer instead of the rank guard's 16, which prefill keeps; each further buffer cost about 10 µs of GPU time (13.24 to 12.56 ms a decode step on two M5 Ultra, tokens identical).
- The fused all-sum fence update and in-kernel sum waits (`MLX_METAL_FUSED_FENCE_UPDATE`, `MLX_METAL_FENCED_INPUTS`) stay a launcher's opt-in for GLM tensor-parallel workers, kept and logged: 12.58 to 12.43 ms a decode step alone, but with batched lanes every round stalled about 0.7 s, so no worker sets them itself.
