### Widened Qwen tensor-parallel owners keep fast fences

Qwen tensor-parallel owners with more than one lane (Qwen3.8 27B, and the Qwen3.5 9B and both 35B A3B rows) keep MLX's fast fence waits instead of the slower event path. The stall that once stopped a widened pair right after a request finished is fixed at its cause: MLX kept a batched step on one GPU stream, and batched rows no longer convert their scales each step.
