### Provider CI: per-job macOS sizes for Darkbloom Sandboxes

- Each macOS CI lane can ask the Darkbloom plane for a size, `<vCPUs>x<GiB>`. The route job checks each size against this grammar and fails on a bad value before it sends a request.
- Sizes are sent only when the repository variable `DARKBLOOM_JOB_SHAPES` is exactly `on`. While it is off, the route request is byte for byte the request without sizes, and every job keeps the runner it has today.
- While sizes are on, the 7 blocking test jobs ask for 4x24. The build jobs, Cluster Release Build Checks and the 2 Cluster GPU Tests shards also ask, for 12x32, on the lanes `build-cluster`, `build-provider`, `cluster-release-checks` and `test-cluster-gpu` (count 2). A run that tests every component then asks for 12 macOS jobs. While sizes are off, these jobs use `blacksmith-12vcpu-macos-27` without asking.
- A sized lane uses a grant only when its labels end in the qualified label, such as `darkbloom-macos-arm64-4x24`. Otherwise it keeps `blacksmith-12vcpu-macos-27`.
- For each lane, the route job's log and summary show the size asked, the runner, and the decision with its reason, such as `shape_not_signed`, `unsupported_runner_class`, `image_not_available` or `lane_not_enabled`.
- The `DARKBLOOM_MACOS_LANES` cap still keeps the critical-path test lanes first. The 12x32 lanes come after them.
