### CI: every Cluster GPU Tests shard asks Darkbloom first

- Each of the 3 Cluster GPU Tests shards now asks the Darkbloom plane for a sandbox on a lane of its own (`test-cluster-gpu-1`, `test-cluster-gpu-2`, `test-cluster-gpu-3`; 4x24 while sizes are on). Each falls back alone to `blacksmith-12vcpu-macos-27` when the plane does not grant it. A lane routes only after the operator adds it to the approval's `lanes`.
- Shard 2 no longer needs 42 GiB. The paged verify/prefill attention bench (`paged-verify-bench`) bounds MLX's freed-buffer cache to 1 GiB, as a ready Qwen tensor-parallel rank does. Before, the cache kept every prompt chunk's attention temporaries, and the bench's process reached 34.26 GiB. The bench also prints its peak active memory and cache size for each run.
- A full CI run now asks for 15 macOS jobs instead of 14. The GPU lanes come last in the lane table, so the `DARKBLOOM_MACOS_LANES` cap drops them first.
