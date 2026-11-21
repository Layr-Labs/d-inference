### Provider CI: wider provider and cluster runtime test fan-out

- Provider Unit Tests runs in 5 shards instead of 4 (15 selections). The new shard reads lane `test-provider-5` (4x24). The shard holding `BootSecurityServeLoopTests` (170 s, never split) plans 170 s and every other shard 139 s, against 177 s each on 4 shards.
- Cluster Runtime Tests runs in 7 shards instead of 5. Shards 6 and 7 share lane `test-cluster-2` (4x24, now a count of 4) with shards 2 and 3. `qwen-tp-mtp-gpu`, the batch GPU switch's prefix depth test, the GLM paged-KV selection, the SSD prefix tier test and two batch-session history tests move to the new shards. Each moved test runs in a process of its own. On 5 shards, shards 2 and 3 ran 439 to 571 s on Darkbloom.
- Provider Gates fetches the MiMo audio codec before the provider products download, while the build runs. After the products, that fetch took 21 to 137 s.
- Every planned test still runs exactly once. A full run asks for 21 macOS jobs instead of 18.
