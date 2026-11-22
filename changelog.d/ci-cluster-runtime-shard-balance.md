### Provider CI: a lighter Cluster Runtime Tests shard 1

- Three base suites of the cluster runtime tests (`CBv2PagedGrowthSyntheticTests`, `CBv2PagedQuantizedStageTests` and `PrefixDiskEncodingTests`, synthetic models only) run in a new `base-shard-5` selection after shard 5's first group instead of in shard 1's `base`. The same tests run, each once.
- Shard 1 runs its selections one after another and was the longest runtime shard in both runs after the build database fix (411 and 469 s). The move takes 72 to 89 s from it; shard 5's first group had about 100 s to spare before its second group ended.
