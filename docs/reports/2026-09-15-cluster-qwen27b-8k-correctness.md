# Qwen27B 8K generation across two Macs

> Last updated: 2026-09-15 · commit `605651bb9`

Registered Qwen3.8 27B 4-bit completes an 8,192-token prompt and 128-token
generation across the 24 GB and 48 GB M4 Pro Macs over RDMA. All output IDs,
the complete final BF16 logits row and all exported state records match the
separately executed full-model reference. This qualifies one long-context
correctness case; it does not measure prefill throughput or external TTFT.

## Workload and result

The request uses 512-token prefill chunks, greedy generation, an empty stop
set, serial prefill and MTP off. Placement remains 16 layers on the 24 GB Mac
and 48 layers on the 48 GB Mac, with the same native binary and unchanged
memory guards as the [short correctness run](2026-09-15-cluster-qwen27b-generation-correctness.md).
This is a manually selected feasible partition. It is not a tensor-parallel
run or a measured optimum.

| Comparison | Observed result |
|---|---|
| Output sequence | All 128 IDs agree across both ranks and the full reference |
| Completed schedule | 143 frames; committed frontier 8,319 |
| Final vocabulary row | All 496,640 BF16 bytes reconstructed and equal |
| Final CPU argmax | Token 13; unique maximum |
| Complete exported state union | 144 ordered records, owned 36/108 by rank |
| State details | 16 position offsets reconstructed; 128 other state digests agree |

The unchanged numerical comparator checks exported values and state digests.
It does not reconstruct non-offset state payloads, compare every intermediate
logits row, attest native execution or audit loaded weight values. Separate
physical observations establish process retirement and sampled resources.

## Resources and retirement

| Run and host | Raw samples | Minimum actual free bytes |
|---|---:|---:|
| Full reference, 48 GB | 340 | 9,551,134,720 |
| Distributed rank 0, 24 GB | 338 | 7,414,693,888 |
| Distributed rank 1, 48 GB | 341 | 18,837,028,864 |

Every retained sample reports AC power, normal memory pressure and zero swap.
Samples do not prove a continuous memory peak. Both distributed native
workers exit zero with empty stderr. Their owners report native cleanup,
release acknowledgments, diagnostic EOF and clean transport termination.
Independent postflight and sidecar collection find no native processes and
empty canonical journals. The temporary Thunderbolt alias is restored.

The full-reference parent takes 91.945 seconds; the distributed parent takes
98.681 seconds. Both include loading, diagnostic work and retirement, so
dividing prompt length by these durations would not give prefill TPS. No
compiler, bulk transfer or competing remote job overlaps either run.

## Evidence and limits

Evidence is under `/Users/developer/DarkbloomDev/cluster-research/`:

- `qwen27b-8k-full-reference-20260915`: reference output, collection, numerical
  recheck and independent raw-resource review.
- `qwen27b-8k-serial-owner-qualification-20260915`: source and artifact checks,
  preflights, physical execution and independent resource/retirement review.
- `qwen27b-8k-collection-comparison-20260915`: separate sidecars, pinned
  comparison packet and final comparison.

Reference SHA-256:
`1922793ab2f252d52b3729efd4222220935bd1d046c6649fc71afded1ad70305`.
Final comparison SHA-256:
`3ac9e69846b375dd7968fc288d1ea9161cb419c81048a8149e0fb12f69847adf`.
Distributed physical review SHA-256:
`8b0282bb0d63868ef8689b2d9c116537dda32e7407c34f521a603a212530fa4b`.

This private development case uses plaintext RDMA and does not change the
installed 9B default. Optimized solo/distributed timing, 27B lookahead, actual
MTP, encrypted RDMA, coordinator routing and M3 Ultra performance remain
separate work in the [delivery plan](../design/distributed-cluster-delivery.md).
