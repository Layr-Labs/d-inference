# Two-Mac Qwen9B resident prefill baseline

> Last updated: 2026-09-15 · commit `605651bb9`

A resident Qwen3.5 9B 4-bit cohort completed on the 24 GB and 48 GB M4 Pro Macs
with JACCL and the selected Thunderbolt RDMA devices. The serial 4/28 layer
split produced **426.98 prompt tokens/s median**, with all four final-logit and
state digest comparisons passing. This establishes the first completed
two-machine prefill runtime check, not a distributed speedup or serving release.

## Workload and timing

Both Macs have 14 CPU and 20 GPU cores and run macOS 27.0 build 26A428. The
24 GB member owns layers 0–3 and the input embedding; the 48 GB member owns
layers 4–31 and the final norm/output projection. Active checkpoint storage is
1,058,851,136 and 3,979,190,464 logical bytes respectively, before native fusion
and request temporaries. The split preserves all 927 active source tensors.

The artifact, diagnostic prompt and arithmetic match the retained
[solo baseline](2026-09-15-cluster-resident-solo-baseline.md). Each fresh request
uses 8,192 prompt tokens, B1, 512-token chunks, one output token and MTP off.
Weights load once per member; one warmup is excluded from the three measurements.

| Request | Rank-zero engine interval (seconds) | Prompt tokens/s |
|---|---:|---:|
| Excluded warmup | 19.647162459 | 416.96 |
| Measured 1 | 19.185990083 | 426.98 |
| Measured 2 | 19.191527083 | 426.86 |
| Measured 3 | 19.170158042 | 427.33 |
| Measured median | 19.185990083 | 426.98 |

The interval uses only rank zero's monotonic clock. It starts before the start
message and fresh state construction and ends after the final consumed
acknowledgment and returned token validation. It includes native compute,
boundary copies/validation, communication, scalar tracing and resource checks.
It excludes loading, readiness, tokenization, final diagnostic capture and
retirement. See `QwenLongPrefillRankTiming` in
`experiments/cluster/inference/Sources/ClusterInference/QwenLongPrefillRankResult.swift`.

The median is 3.44% longer than the retained solo interval of 18.547385417 seconds.
The binaries and allocator cache policies differ, so this is context rather than
an isolated measurement of distribution overhead. The first split was selected
to fit the smaller member's available memory. It does not balance compute.

The 8K TTFT allowance is 18.192 seconds; this internal interval alone exceeds it
by 0.994 seconds. No external streaming TTFT was measured. The repeated-prose
diagnostic, three measurements and one-output requests cannot establish an SLA
percentile, representative performance, decode throughput or active MTP.

## Correctness, memory and cleanup

All four requests selected token 271 and matched the frozen full-reference
BF16 logit digest. Each rank's committed-state digests matched its global-layer
slice, with disjoint 9/63 component ownership covering all 72 components and
319,946,784 logical state bytes. The reference's full BF16 row and eight integer
offsets were independently reconstructed; the other reference state components
and candidate numerical bytes remain opaque digests.

The parent validated fourteen events: readiness, four results, release and stop
on each member. Both native processes exited zero, both model owners released
their weights, and no cleanup or postflight error occurred. All 36 returned
event/evidence files were rehashed. The temporary IPv4 alias was removed, with
the bridge membership and management route preserved.

Each member has 312 retained resource samples. Minimum actual free memory was
6.667 GiB on the 24 GB Mac and 11.747 GiB on the 48 GB Mac. Every sample reported
AC power, pressure level 1 and zero swap. Native gates also check low-power and
thermal state. Sampling does not prove a continuous peak bound.

Earlier 12/20 and 8/24 attempts reached both loaded-ready events but crossed the
unchanged 6 GiB actual-free floor during their first requests. They produced no
timing result. The successful build uses aligned selected-payload reads and
disables freed-buffer caching only in the dedicated rank processes; it does not
lower a memory floor or change active allocation limits. The solo default is
unchanged. Finer chunk sizing and balanced overlap remain later experiments.

JACCL rank/backend/device configuration is bound to the actual workers. The
experiment retains `physicalTransferQualified: false`: there is no separate
RDMA data-path counter qualification or production transport attestation.

## Retained identities and next work

Raw evidence remains with the private machine records. No credentials or private
host addresses are included here.

| Artifact | SHA-256 |
|---|---|
| Executed native | `d9041bf50a008ca15b7d560b1871859e9c3e582afb860d01e9f23ec1e67ab774` |
| Source snapshot, 430 members | `55fd6433f0cfbf22dc573d807113a9405cfc26b510af72f72ce6a30d6462900b` |
| Frozen cut4 launcher manifest | `3c933bc999b50f3911cf8e90c2e9672664f40dd4f6d62fe234f0e26e0851662c` |
| Parent receipt | `d4330f9ea03b4728b15c7fffac3bbf477ac7d4ccbb5ebdae21b1dcca1f7e2e50` |
| Alias cleanup receipt | `5f177d71d4fc9c4a2eee8c3fe38683210844d97940bffb9c3f61bf31132a4534` |

The [execution plan](../design/distributed-cluster-execution-plan.md) still
requires multi-token continuation, cancellation/recovery on actual peers,
provider startup and external streaming measurements before performance
selection. Qwen27B, Gemma26B, active MTP and M3 Ultra projections remain open.
