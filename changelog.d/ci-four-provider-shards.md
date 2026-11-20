### Provider CI: the provider suite runs in four shards

- Provider Unit Tests runs in 4 shards instead of 2, each running 3 selections at the same time (12 in all). The planned longest selection of a shard drops from about 399 s to about 199 s.
- Shard 1 keeps the parallel class and Prompt Parity, and the last shard keeps the isolated processes and native gates. The new shards use the lanes `test-provider-3` and `test-provider-4` (4x24), so a full run asks for 17 macOS jobs instead of 15.
