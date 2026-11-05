### CI's macOS jobs ask for Darkbloom Sandboxes again

- The macOS CI jobs read the Darkbloom route again, as they did before they moved to Blacksmith only. Each provider and cluster test job runs on a Darkbloom Mac when the plane grants its lane, and on `blacksmith-12vcpu-macos-27` otherwise. The job list and shard counts are those of the entry "Provider CI: fewer Mac jobs per run" below.
- A lane is requested only when its job runs: the provider lanes when provider inputs change, and the cluster lanes when cluster inputs change.
- Limitation: a lane the plane's approval does not name keeps Blacksmith, as do all lanes while `DARKBLOOM_ROUTING` is not `on` and for pull requests from forks.
