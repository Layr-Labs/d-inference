### Provider CI: a shard's concurrent test processes start together

- The three `swift test` processes of each Provider Unit Tests shard start together instead of 15 s apart, and the planner no longer gives each later process 15 s less work (`START_GAP_SECONDS` and `PROVIDER_TEST_START_GAP` are gone). Replaying the measured seconds of four dev runs through both plans, the longest shard ends 15 to 35 s sooner.
- The gap was added for SwiftPM's build database lock. Since the processes plan the build in memory, none opens that database, so starting together waits for nothing. The cluster runtime shards' groups keep their 15 s gap.
- `UnreclaimableLoadMemoryFixture` empties MLX's buffer cache and the retained KV segments before each test. The refusal's "reclaimable" figure counts both, and an earlier suite in the same process could leave some behind: with the new plan, `UnevictableResidentReportTests` reported 17.7 GB instead of the scripted 16.8 GB.
