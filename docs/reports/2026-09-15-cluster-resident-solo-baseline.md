# Cluster resident Qwen9B solo baseline

> Last updated: 2026-09-15 · commit `605651bb9`

One real resident Qwen3.5 9B 4-bit cohort completed on the 48 GB M4 Pro:
**441.68 prompt tokens/s median** for the retained diagnostic 8,192-token input.
All four fresh requests matched the retained reference hashes, then the model
was released and the native worker exited successfully. This closes the first
solo runtime check in the [cluster execution plan](../design/distributed-cluster-execution-plan.md).

## Workload and timing

The device has 14 CPU and 20 GPU cores. The artifact aggregate is
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`;
the diagnostic prompt SHA is
`ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997`.
The worker uses B1, 512-token chunks, one generated token, MTP off, and one
weight load across one excluded warmup plus three measured requests.

| Request | Engine interval (seconds) | Prompt tokens/s |
|---|---:|---:|
| Excluded warmup | 20.463068042 | 400.33 |
| Measured 1 | 18.547385417 | 441.68 |
| Measured 2 | 18.546285208 | 441.71 |
| Measured 3 | 18.559176250 | 441.40 |
| Measured median | 18.547385417 | 441.68 |

The native monotonic interval starts at fresh CBv2 request-state creation and
ends after finite argmax/scalar readback. It excludes model loading, readiness,
final diagnostic capture and retirement. Parent resource polling runs during
the interval. This is not an isolated GPU-kernel timer or external-client TTFT.

The user-specified 8K TTFT allowance is 18.192 seconds. The measured median
engine interval alone exceeds it by 0.355 seconds; a serving-path measurement
is still required. This single repeated-prose input does not establish a
representative throughput, SLA percentile, fastest eligible solo control,
distributed speedup or M3 Ultra projection.

## Correctness and lifecycle

All four results matched the same-input reference's final BF16 row digest,
selected token and committed-state fingerprints. The reference's complete
BF16 row and eight integer state offsets were independently reconstructed;
64 other state components and candidate tensor bytes remain opaque hashes.
The reference was captured on the other M4 Pro on September 14; its oracle
was frozen after that reference execution, before this candidate execution.

The parent validated seven native events, four numerical results, one model
load, four request retirements, explicit release and shutdown. The native
process was reaped with exit code zero and empty stderr. Final MLX cached
memory was zero; active allocator memory was 4,016 bytes. There were no cleanup
or postflight errors. The 301 parent resource samples observed a minimum of
8.638 GiB actual free memory, zero reported swap, acceptable pressure and AC
power. Native checks additionally covered low-power and thermal state before
and after requests. These observations do not prove continuous peak memory or
thermal behavior.

## Retained evidence

Evidence is retained privately with the machine access records; no credentials
or private host addresses are included here. Returned streams and original
event files were rehashed successfully.

| Artifact | SHA-256 |
|---|---|
| Executed native | `aa7d205de4d2b5b7ac26842e0fd0fa42c96774b5ed1b229f418d726636da279a` |
| Source snapshot, 422 members | `89b0245e2f7ce823d56aa9e4a37b8d7dbfffe5742edb0682886d485b443ae613` |
| Frozen solo launcher manifest | `78d9781a9c8ea967dc4bc204a1019c80af3e655aef88aef3dd4100546766ed89` |
| Parent receipt | `4cfefe9101a3f264d30b66750f26968670f1344f3a00e9cc820796f1a713b81e` |
| Native stdout | `21c5b56acbad089cd705d71a6b6a8ab388e668ce629eab6f24bfd307efd2b15a` |

The historical aa7d build remains unchanged after the master refresh. Physical
two-machine model execution, multi-token continuation, active MTP and the
Darkbloom provider integration remain separate unfinished milestones.
