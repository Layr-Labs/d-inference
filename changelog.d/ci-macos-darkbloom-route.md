### CI's macOS jobs ask for Darkbloom Sandboxes again

- The macOS jobs of `ci.yml` read the Darkbloom route again, as they did before they moved to Blacksmith only. Each provider shard (`test-provider-1` to `test-provider-3`), the shard summary (`test-provider-summary`), the SDK lane (`test-provider-sdk`), the cluster metadata checks (`test-cluster-checks`), each cluster runtime and GPU shard (`test-cluster-1` to `test-cluster-3`, `test-cluster-gpu-1`, `test-cluster-gpu-2`) and the cluster focused checks (`test-cluster-focused`) run on a Darkbloom Mac when the plane grants their lane, and on `blacksmith-12vcpu-macos-27` otherwise.
- A lane is requested only when its job runs: the provider lanes when provider inputs change, the SDK lane on pushes and SDK-lane changes, and the cluster lanes when cluster inputs change.
- The provider shard count, the cache-save rules and the `.git` and SwiftPM caches are unchanged.
- Limitation: a lane the plane's approval does not name keeps Blacksmith, as do all lanes while `DARKBLOOM_ROUTING` is not `on` and for pull requests from forks.
