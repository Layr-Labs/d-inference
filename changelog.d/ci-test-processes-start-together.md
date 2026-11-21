### Provider CI: a shard's concurrent test processes start together

- The three `swift test` processes of each Provider Unit Tests shard start together instead of 15 s apart, and the planner no longer gives each later process 15 s less work (`START_GAP_SECONDS` and `PROVIDER_TEST_START_GAP` are gone). Replaying the measured seconds of four dev runs through both plans, the longest shard ends 15 to 35 s sooner.
- The two groups of Cluster Runtime Tests shards 2 to 5 start together too (`CLUSTER_TEST_START_GAP` is gone). A shard whose second group runs longest ends up to 15 s sooner.
- The gaps were added for SwiftPM's build database lock. Since the processes plan the build in memory, none opens that database, so starting together waits for nothing.
