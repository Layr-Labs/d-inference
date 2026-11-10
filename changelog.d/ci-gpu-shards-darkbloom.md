### CI: Cluster GPU Tests shards 1 and 3 ask Darkbloom first

- Cluster GPU Tests shards 1 and 3 now ask the Darkbloom plane for a sandbox, each on a lane of its own (`test-cluster-gpu-1`, `test-cluster-gpu-3`; 4x24 while sizes are on: 14.33 and 14.72 GiB used in run 42737118357). Each falls back alone to `blacksmith-12vcpu-macos-27` when the plane does not grant it.
- Shard 2 still runs on `blacksmith-12vcpu-macos-27` without asking: it uses 42 GiB, which no signed size holds.
- A full CI run now asks for 14 macOS jobs instead of 12. The two GPU lanes come last in the lane table, so the `DARKBLOOM_MACOS_LANES` cap drops them first.
