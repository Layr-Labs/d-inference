### Interim CI job sizes (CI only)

- While `DARKBLOOM_JOB_SHAPES` is `on`, the macOS CI lanes ask only for sizes that production signs, 8x16 and 12x32. Production does not sign 4x16 and 4x24 yet. Every test lane asks for 8x16, except GPU shard 2, which asks for 12x32. The build jobs and Cluster Release Build Checks keep their sizes. Runtime shard 2, Provider Unit Tests shard 2 and GPU shards 1 and 3 run on 16 GiB with less than the usual 1.25 memory margin. When 4x16 and 4x24 are signed, the lanes go back to their measured sizes (`docs/developer/build.md`, Job sizes). No provider change.
