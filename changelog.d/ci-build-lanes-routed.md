### Provider CI: build lanes route to Darkbloom while job sizes are off

- Build cluster test products, Build provider test products and Cluster Release Build Checks no longer keep `blacksmith-12vcpu-macos-27` without asking while `DARKBLOOM_JOB_SHAPES` is off. Their lanes `build-cluster`, `build-provider` and `cluster-release-checks` now ask without a size, as the test lanes do, and get the approval's pinned macOS size (12 vCPU / 32 GiB on 2026-11-05). If the approval pins a smaller macOS size, they get that size.
- While sizes are on, they still ask for 8x16 (build-cluster, cluster-release-checks) and 12x32 (build-provider).
- A run that tests every component asks for 12 macOS jobs.
