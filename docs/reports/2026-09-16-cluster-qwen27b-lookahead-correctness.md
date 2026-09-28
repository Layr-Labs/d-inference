# Qwen27B 8K prefill lookahead correctness

> Last updated: 2026-09-16 · commit `605651bb9`

The 24 GB and 48 GB M4 Pro Macs completed registered Qwen3.8 27B 4-bit
generation with one-chunk prefill lookahead over Thunderbolt RDMA. All 128
output IDs, the complete final BF16 logits row and exported state records match
the full-model reference. This extends the
[serial 8K correctness result](2026-09-15-cluster-qwen27b-8k-correctness.md);
it does not establish a throughput gain.

The workload has 8,192 prompt tokens, 512-token chunks, 128 greedy output
tokens, no stop tokens and MTP off. Rank 0 owns 16 layers; rank 1 owns 48.
The same native executable runs on both members. Rank 0 prepares the next
prompt chunk while rank 1 consumes the previous chunk, with at most one
prepared boundary and the existing consumption acknowledgments retained.

| Check | Result |
|---|---|
| Output sequence | All 128 IDs equal the reference |
| Final vocabulary row | All 496,640 BF16 bytes reconstructed and equal |
| Exported state union | 144 ordered records; ownership 36/108 |
| State comparison | 16 offsets reconstructed; 128 other digests equal |
| Completed schedule | 143 frames; committed frontier 8,319 |
| Lookahead | 15 preparations on rank 0; maximum one outstanding boundary |
| Final transport state | No pending consumed acknowledgment or decode prefetch |

Both native workers exit zero with empty diagnostic tails. Native cleanup,
owner release acknowledgments, diagnostic drain and transport termination all
complete. Independent postflight and collection find no native workers and
empty canonical journals; the temporary Thunderbolt alias is restored.

All 284 rank-0 and 287 rank-1 resource samples report AC power, normal pressure
and zero swap. Minimum actual free memory is 7,071,547,392 bytes on rank 0 and
19,167,215,616 bytes on rank 1. These are sampled observations, not continuous
peak bounds. The 82.674-second parent duration includes loading and diagnostic
work and must not be converted into prefill TPS.

The numerical check reconstructs the final row and position offsets; it compares
other state digests without reconstructing their bytes. It does not compare
every intermediate logits row or independently attest the executable. The
physical review separately verifies resources and retirement.

Evidence is retained under `/Users/developer/DarkbloomDev/cluster-research/` in
`qwen27b-8k-lookahead-owner-qualification-20260915` and
`qwen27b-8k-lookahead-collection-20260915`:

- Native SHA-256: `c35c585cfcd31e54e9635253e74a74fac35e704d83619b50aff007bac1f3f830`.
- Numerical comparison: `92ca67004e239583109a9ec6c8140b53ae940bb705c3cd56d6bebd4626897142`.
- Physical review: `68ef9d4015d307501da9846aa4fdd4a513b3241be48955b7bdc8a53f75ce9ca8`.

This private plaintext-RDMA case does not change installed defaults. Matched
performance runs, encrypted transfer, broader placement, real MTP and product
integration remain work in the [delivery plan](../design/distributed-cluster-delivery.md).
