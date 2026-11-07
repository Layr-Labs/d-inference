### Provider CI: shorter cluster runtime shards

- Cluster Runtime Tests runs in 5 shards instead of 3. The batch-session suite (672 s in one process) runs in two processes: its warm and SSD prefix tier tests in `base-batch-session-prefix-tiers`, its other tests in `base-batch-session`. Each runs beside one half of the Qwen GPU chain, on shards 2 and 3. The Gemma 4 base suites (610 s) run in two processes, each alone on its own shard: `Gemma4TensorParallelTests` on shard 4 and the other Gemma suites on shard 5. Every test still runs in exactly one selection.
- The two new shards ask for no new lane: shards 2 and 3 share the lane `test-cluster-2`, and shards 4 and 5 share `test-cluster-3`, each requested for 2 jobs. A run that tests every component asks Darkbloom for 9 macOS jobs while job sizes are off (7 before).
- The cluster plan audit checks that each Gemma suite runs whole in exactly one base selection of Gemma suites, and that each test of a split suite runs in exactly one of its selections.
- The CI plan checks run in their own job, Check the CI plans, beside the test jobs. The `Provider Tests` gate requires that job and no longer runs the checks after the last test job.
