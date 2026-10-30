### MLX core updated to upstream MLX main (2026-10-30)

The provider and cluster worker now build on upstream MLX main `1ba7f969`, merged into the Layr-Labs MLX fork.

- `libs/mlx` and the copy nested in `libs/mlx-swift` that Cmlx compiles move from `72dffa2d` to `70245518`. `libs/mlx-swift` moves from `c633d221` to `19b72070` (nested mlx-c `2ac897e3` to `db5cb211`), and `libs/mlx-swift-lm` stays at `d5bd32b8`.
- Release builds compile MLX with `NDEBUG`, so they no longer run its asserts or Metal shader logging, nor the graph check on every dispatch and the allocation tracking that upstream added in this update, which cost about 10% of decode speed when left on.
- From upstream, a stalled JACCL collective checks its Thunderbolt RDMA queue pair about every 100 ms and fails once the queue pair is in an error state.
- On two M5 Ultra serving Qwen3.8 27B and GLM-5.3-Flash tensor-parallel, decode speed is unchanged within run-to-run noise, the answers to 12 fixed greedy prompts per model are byte-identical to the previous build's, and concurrent requests still decode the same tokens as alone.
