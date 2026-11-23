### Provider CI: the four provider shards end together again

- The provider shard weights are refreshed from a green run of the current `dev` tree (run 44711129396). The old weights predated the 4-vCPU lanes, so shard 2 carried `BootSecurityServeLoopTests` at 26 s while it ran 167 to 181 s, and in most runs of 2026-11-20 shard 2 ended 1 to 3.5 minutes after the next shard.
- The planner counts each process slot's 15 s start gap and the measured 12 s of the parallel process (was 31 s), so every shard is planned at about 232 s of tests and fixed work.
- Each shard's audit prints, per selection, its suites' seconds against their weights and warns when they differ by more than 60 s, so stale weights show in the run that measures them. `weights --prune` no longer reads the weights file, so its output can replace that file directly.
