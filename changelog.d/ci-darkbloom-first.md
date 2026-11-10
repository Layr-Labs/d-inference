### CI: the build jobs and GPU shards 1 and 3 ask Darkbloom first

- Build provider test products, Build cluster test products and Cluster Release Build Checks now ask the Darkbloom plane for a sandbox on every run. Their lanes (`build-provider`, `build-cluster`, `cluster-release-checks`) are no longer `required`, so they no longer wait for `DARKBLOOM_JOB_SHAPES`: while sizes are off they ask without a size, as the test lanes do.
- Cluster GPU Tests shards 1 and 3 ask too, each on a lane of its own (`test-cluster-gpu-1`, `test-cluster-gpu-3`, 4x24 while sizes are on: 14.33 and 14.72 GiB used in run 42737118357). Shard 2 still runs on `blacksmith-12vcpu-macos-27` without asking: it uses 42 GiB, which no signed size holds.
- Release runs are unchanged: every job of a release keeps its Blacksmith runner.
- A full CI run now asks for 14 macOS jobs instead of 9. Every lane still falls back to its Blacksmith runner, alone, when the plane does not grant it; a lane the plane's approval does not name falls back as `lane_not_enabled`.
