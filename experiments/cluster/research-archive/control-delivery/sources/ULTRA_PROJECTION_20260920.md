# M3 Ultra target calculation — 2026-09-20

These are requirements and sensitivity calculations, not measured Ultra results
or a hardware performance forecast. We have only the two M4 Pro hosts.

The accepted 27B 4-bit baseline at8,192 prompt tokens is126.6253prefill TPS on
one M4 Pro20-GPU-core/48GB host. The current unequal16/48 layer pipeline reaches
164.8962TPS; it does not establish balanced-pair or TP efficiency. One warmup plus
one measured request is not a statistical hardware characterization.

For identical larger hosts, the simple capacity sensitivity is
`pairTPS = 2 × measuredSoloTPS_on_target_hardware × pairEfficiency`.
Pair efficiency here includes fill/drain, communication, scheduling and repeated
work. It is an explicit unknown, not a measured0.90 constant. This relation is
a sizing model; workload-dependent pipeline partitions and fixed endpoint costs
still need component calibration.

| Assumed pair efficiency | Pair targetTPS | Required target-host soloTPS | Multiple of measured M4 Pro solo |
|---:|---:|---:|---:|
| 85% | 800 | 470.6 | 3.72× |
| 85% | 1000 | 588.2 | 4.65× |
| 90% | 800 | 444.4 | 3.51× |
| 90% | 1000 | 555.6 | 4.39× |
| 95% | 800 | 421.1 | 3.33× |
| 95% | 1000 | 526.3 | 4.16× |

At90% pair efficiency,800TPS needs444TPS from each target Mac;1,000TPS needs
556TPS. This is a useful acceptance gate for the first real Ultra owner trial.
It does not follow from installed RAM, nominal core count or memory bandwidth
alone. Larger RAM should permit testing a balanced32/32 layer cut without the
24GB host's current constraint; actual baseline-free and live-memory checks must
still pass.

Apple's2025 Studio specification lists60- and80-core M3 Ultra GPUs, both with
819GB/s memory bandwidth. The40-core M4 Max has546GB/s; the32-core version410GB/s.
These facts distinguish the target configurations but are not inference scaling
factors. Sources checked2026-09-20:
[Mac Studio2025 specifications](https://support.apple.com/en-us/122211) and
[M4 MacBook Pro specifications](https://support.apple.com/en-us/121554).

At8,192 prompt tokens the external deadline is18.192s. Pure prefill requires
450.31TPS if every other cost were zero; with1s reserved for routing/queueing/
first-token delivery,476.50TPS. At800TPS pure prefill takes10.24s, leaving7.952s
for those other costs; at1,000TPS it takes8.192s, leaving10s. This budget is for
request-send to first token and must be checked externally. Cold load, queueing,
network, encryption and output serialization cannot be dropped from the SLA.

## Independent measured reference, not a Darkbloom result

Rapid-MLX reports330.8prefillTPS for Qwen3.8-27B4bit at8,156 prompt tokens on
one256GB M3Ultra with28CPUcores. Its method uses three requests, clears the
prefix cache each time, and divides prompt tokens by client first-delta latency.
The candidate uses automaticMTP; its model artifact and runtime differ from our
testbed. The published result is a useful independent reference, not a matched
Darkbloom comparison. [Author's methodology and results](https://github.com/raullenchai/Rapid-MLX/blob/main/docs/benchmarks/recent-large-models-m3-ultra.md).

Apple associates the28CPU-core M3Ultra configuration with60GPUcores. The80GPU
variant has32CPUcores, with the same819GB/s memory bandwidth;256GB does not by
itself identify the compute configuration. [Apple specifications](https://support.apple.com/en-us/122211).

Using330.8 solely as a sensitivity input, two identical hosts at assumed85–95%
efficiency produce562–629TPS. At90%, reaching800 requires34% more solo
throughput; reaching1,000 requires68% more. These are arithmetic scenarios,
not cluster forecasts or confidence intervals. The80-core variant and kernel/
scheduling improvements may change the baseline, but linear scaling from its
core count has not been established.800 remains a development target and1,000
a stretch target until actual target-host calibration is available.
