# Qwen3.8 27B: larger two-Mac prefill projections

2026-09-13. Planning estimates, not measured Darkbloom cluster performance.

Assume the same dense Qwen3.8 27B family, approximately 4-bit weights, BF16 activations, one uncached text request, 4K–8K prompt, model already loaded, 512-token chunks, no swapping, and a working optimized two-rank tensor-parallel runtime over one TB5/RDMA link. Current production M5/NAX eligibility is unchanged.

| Pair | Initial planning prefill TPS | Working target | 8192-token prefill at target |
|---|---:|---:|---:|
| M4 Max 48GB each, 40 GPU cores each | 350–550 | 450 | 18.2s |
| M3 Ultra 256GB each, 60 GPU cores each | 450–700 | 600 | 13.7s |
| M3 Ultra 256GB each, 80 GPU cores each | 600–900 | 750 | 10.9s |

Ranges are engineering priors, not statistical confidence intervals or guarantees. The 60-core Ultra range is a rough reduction from the 80-core compute prior; memory bandwidth does not fall proportionally. Larger prompts require a new estimate because full attention grows with context. Aggregate independent-replica throughput is a different objective.

## Evidence

- Apple official Mac Studio specifications: https://support.apple.com/en-us/122211 . M4 Max40GPU has546GB/s memory bandwidth; M3Ultra60/80GPU has819GB/s. RAM capacity alone does not predict prefill.
- https://github.com/Weschera/Qwen3.8-27B-oMLX-MTP-Mac and its raw ane-mtp3-results.json report274TPS at4096tokens on an M4Max128GB, oQ4e mixed4/5bit, oMLX with ANE prefill. This is a different artifact/runtime, not our baseline. Raw baseline.json gives roughly220–264 prompttokens/HTTP-TTFT at2.1–2.4K with no cached tokens; not a pure GPU kernel timer.
- https://github.com/jundot/omlx/discussions/2811 reports single-M3Ultra512GB oQ4e prefill443TPS at8K withANEoff,496TPS at8K withANE0.53+GDN,398/468 at32K respectively. Self-reported, not independently reproduced; do not transfer its512GBcapacity into a speed multiplier.
- Darkbloom repo docs/reports/2026-08-28-qwen35-9b-validation-and-mtp.md reports731TPS at2K on M4Max40GPU for9Bdense. Dividing by~3x dense model work gives a rough240TPS27B prior. This is not an exact27Bbenchmark.
- Repo's exact27B M5Max results (~843TPS at5523tokens /6.5541sHTTP-TTFT) use another GPU generation/NAX; excluded from directM4/M3scaling.

## Cost model

For fullTP2 use t/token=[f+(1-f)/(2*eta)]/P1+1310720/B+128*alpha/512. Central assumptionsf=.1, eta=.9 givecompute multiplier.6. Effectivebandwidth B=3.5–7GB/s and fixedcollectivealpha=30–100us remain unmeasured hypotheses. These add~0.20–0.40ms/token, or~1.6–3.3s across8192tokens, without overlap. The assumedsolo envelope is roughly250–350TPS forM4Max and450–650TPS for80GPU M3Ultra; rounding plusimplementation uncertainty yields table ranges.

FullTP BF16 sends1.25MiB/token/rank,10GiB/rank at8192tokens. Faster GPUs encounter the same external link, so speedup cannot be assumed2x. A plan with more overlap or fewer collectives may improve this; a poor implementation can regress. The initial implemented FFN-only prototype does not establish the fullTP estimates.

## Architecture implications

Use extra Ultra memory for alternate prefill weight layouts, cache capacity, larger batches or more resident models; do not model it as extra FLOPs. Compare an optimized BF16 prefill path, GPU/ANE division where a supported backend exists, better Gated DeltaNet kernels, and overlap of communication with independent work. Their gains must be measured separately before multiplying them by cluster scaling. Both48GBnodes can hold the quantized27B target individually; compare independentreplicas for aggregate throughput, and tensorparallelism for single-request latency.

## Current experiment state

The isolated Swift harness builds with realJACCL compiled (availabilityAPItrue), and local synthetic hybrid-model FFN partition parity passed. No successful two-node RDMA data transfer or model TPS measurement exists yet. The48GB M4Pro node went offline during temporaryThunderbolt interface setup; user is away and asked to continue analysis and check later. No further network configuration will be attempted while it is unreachable.
