The accepted Gemma v7 cut7 cohort spends about **45.0 ms per decode token on each pipeline rank versus 22.3 ms solo**. The largest measured software overhead category is the live guard: **17.15–17.28 ms/token on the pair versus 2.09 ms solo**. Guard time is inclusive and is partly inside the owner and transport intervals below; the columns must not be summed.

All values below are means over **45 continuation tokens per role: three measured requests × 15 tokens**, excluding the warmup. Workload is P4096/C64/O16, greedy, MTP off. Pair prefill used lookahead; decode remains serial. These are same-process native timings, not external TTFT or GPU kernel durations.

| Local interval, ms/token | Solo, 30 layers | Rank0, layers 0–6 | Rank1, layers 7–29 |
|---|---:|---:|---:|
| First-to-last agreement / 15 | 22.289 | 45.020 | 44.998 |
| Owner span | 20.609 | 7.843 | 15.770 |
| Graph construction | 1.564 | 0.248 | 0.841 |
| Root staging | 0.017 | 0.004 | 0.011 |
| Evaluation, including existing post-eval check | 18.742 | 7.398 | 14.698 |
| Validation and commit | 0.285 | 0.192 | 0.220 |
| Before owner, within frame | 0.451 | 0.329 | 18.306 |
| After owner, within frame | 0.771 | 36.522 | 10.579 |
| Between frames | 0.458 | 0.327 | 0.344 |

Rank1's pre-owner interval contains receive, peer preparation, checks and synchronization. Rank0's post-owner interval includes sending the residual, awaiting committed consumption, receiving the selected token and acknowledging it. Neither interval isolates network cost. Summing stage-local owner durations is also not a measured cross-host critical path.

| Guard / transport observation | Solo | Rank0 | Rank1 |
|---|---:|---:|---:|
| Logical guard calls per token | 8 | 105 | 103 |
| Fresh OS snapshots per token | 8 | 105 | 103 |
| Entry / owner / environment calls per token | 16 / 8 / 24 | 210 / 105 / 315 | 206 / 103 / 309 |
| Outer native fault checks per token | 64 | 840 | 824 |
| Logical guard, ms/token | 2.091 | 17.147 | 17.278 |
| OS snapshot subinterval, ms/token | 0.956 | 8.677 | 8.986 |
| Completed native sends / receives per token | 0 / 0 | 5 / 6 | 6 / 5 |
| Completed send + receive wall time, ms/token | 0 | 32.925 | 25.182 |
| Logical guard nested inside that wire time | 0 | 13.323 | 13.802 |
| Wire time after subtracting its nested guard | 0 | 19.603 | 11.380 |

The final row still includes peer model work, CPU/GPU completion fences, backend and scheduling time. It is not a bandwidth or latency measurement. Guard categories such as entry, environment and OS snapshot overlap; subtracting all categories would double-count. Native fault-check overhead itself is only about 0.009 ms/token on the pair.

The strongest source-level optimization lead is the **high-frequency guard path**, while retaining its fresh observations and inequalities. Existing invocation-local sharing works: entry→owner→entry uses exactly one OS snapshot. In the actual v7 source, every snapshot nevertheless constructs an `ISO8601DateFormatter` and formats a UTC string, although admission uses the monotonic timestamps and numeric resource fields. The total snapshot bucket is measured above; the formatter's individual share is not. Root's newer timestamp implementation is outside this audit and cannot inherit these results. It is a small first experiment because it can retain every observation, native error/deadline check, power/thermal check and 6/4/2 GiB requirement.

A second, larger change is control framing. Each decode token exchanges five bounded control messages (frame header, payload-ready, frame-consumed, selected token, token-accepted). Each control currently uses separate completed prefix and body transfers, plus one residual transfer: **11 completed native operations per rank/token**. Each completion invokes checks after construction, evaluation and CPU/GPU fences. A separately qualified fixed-size bounded control record could remove five prefix operations per token without removing the semantic acknowledgements. This requires an explicit resource/codec/deadline proof and exact numerical/retirement comparison; no such change or speedup is claimed here. The original fences must not simply be deleted.

The [JSON audit](profile.json) contains per-request aggregates, full category counts, interval distributions, exact workload/layer ownership and file hashes. The [read-only extraction source](audit.py) checks the accepted comparison→terminal→raw stdout/job joins, natural exit0/complete output/retirement flags, exact frame/phase frontiers and chronology, the source/build chain and unchanged input hashes. It clips the last frame's completion marker to the final token-agreement boundary. It does not reread gigabytes of numerical sidecars or repeat physical resource qualification.

Evidence is retained at:

- [Accepted solo/serial comparison](/Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/cases/p4096-cut7-c64-serial-v7/comparison-v2.json).
- [Accepted matched overlap comparison](/Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/cases/p4096-cut7-c64-overlap-v7/comparison-overlap.json).
- [Actual v7 build](/Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/GemmaResidentBenchmark-build-6.json), native `6115f51db204f8afe59b1e6b68d47074c7cad14bfde11e5acda477c290305034`, source composition `8ec41c24385edfa16b66864ffbf4161de470dbb5b5c559d8a134243b102288a6`.
- [Exact v7 OS-reader source](/Users/developer/DarkbloomDev/cluster-research/gemma4-benchmark-guard-metrics-20260920/Runtime/QwenDenseStageLoadResources.swift:8), `a1ddaab9f875569542b4e17999a55e9afb928b83128d537379d922ab3b9b7bf4`, preserved separately from the newer workspace optimization.

Only retained evidence was read. No build, native/model execution, SSH or existing-source mutation occurred. These measurements identify a bounded optimization target; they do not supply isolated communication/encryption costs or activate a placement planner.
