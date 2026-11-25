### Provider CI: BootSecurityServeLoopTests in a process of its own on the 12x32 shard

- `BootSecurityServeLoopTests` runs in a fourth process beside provider shard 1's three selections, on that shard's 12x32 lane, instead of alone in a selection of shard 2 (4x24). Each of its 25 tests verifies the test host's real code signature. On 4x24 it ran 167 to 250 s, and its shard was the last provider job in 16 of the 35 green pull-request rounds of 2026-11-23; on 12x32 it ran 117 s in one process.
- The process runs the command line the suite's selection ran (`--no-parallel`, the suite's `--filter`, the isolated-process `--skip`) with its own `TMPDIR` and state files. The 15 numbered selections now plan 130 s each (before: 14 at 139.6 s and the suite's at 170 s).
- Shard 1's Prompt Parity now starts after this process. Modelled on the rounds of 2026-11-23 (not measured), the last provider shard ends about 11 s sooner at the median, and shard 1 becomes the last provider job in about 10 of 35 rounds.
- Shard 1's audit checks that process like a selection (`shard-own.json`: its executed count must equal its plan), and the last shard checks that all plans, that process's included, list every test once. Every planned test still runs exactly once.
- The release qualification lane runs one process per shard and plans as before.
