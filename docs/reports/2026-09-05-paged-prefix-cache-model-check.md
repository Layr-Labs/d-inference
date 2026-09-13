# Paged resident prefix cache: GPT-OSS model check

> Last updated: 2026-09-05 · commit `da7303d42`

Explicit paged serving reused 3,920 prefill tokens on the measured long GPT-OSS
repeat, reducing time to first token from 1.578716708 to 0.854751458 seconds
(45.86%). Four long-request comparisons matched the baseline's generated token
IDs, counts and finish reasons; tenant isolation and cancellation recovery also
passed. These are single observations from one ordered group, not repeated-run
medians or a fleet latency result.

## Artifact and model provenance

Both arms ran the same direct production-factory harness on the 128 GiB M5 Max
used by the [baseline measurements](2026-09-05-radix-prefix-cache-baseline.md),
with explicit `paged` KV, cache requested, a 16 GiB KV grant, greedy sampling,
64 output tokens, and **MTP off**. Both resolved to paged without fallback.
Neither arm supplied an SSD cache. The baseline compile omits the candidate's
resident-cache construction API, so its actual prefix outcome is `disabled`
even though the shared harness records `cache_requested = true`. The candidate
uses the engine-owned paged cache; the generic report's hybrid-budget fields do
not imply a GPT-OSS recurrent bank.

The baseline is clean parent `e928d395fa4f97e736552a6de89b37876b2bc56b`, compiled
with `RADIX_CANDIDATE_BUILD=0`. The immutable candidate is `candidate-mtp-build3`,
compiled with `RADIX_CANDIDATE_BUILD=1`: parent
`5477b6e32abc1c296f77931e65a015033e79fbe3` and LM
`713d2cf4bfb244ac1c8eef7e6a5e8c6fc99091f0` plus the retained source patches.
The artifact label does not enable MTP; the run metadata records it off.
This report does not attribute these results to the later combined refactor or
recurrent-cache compaction candidate.

| Artifact | SHA-256 |
|---|---|
| Baseline engine | `740ce1b31783509f7e545712aa5002e5c6918aaf0160393ad7cec169a17add21` |
| Immutable build3 engine | `13712390cec5e5af9d6ebad8c87e1ef358d28f17545366442a81d7a22e399d93` |
| Shared Metal library | `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0` |

The [baseline build manifest](evidence/2026-09-05-radix-prefix-cache/baseline-mtp-build2-artifact.json)
and [build3 manifest](evidence/2026-09-05-radix-prefix-cache/candidate-mtp-artifact.json.gz)
contain identical hashes for all four Swift harness/package files and for the
runner scripts. The engine binaries and Metal libraries were rehashed against
those manifests; the retained
[provider patch](evidence/2026-09-05-radix-prefix-cache/candidate-mtp-provider.patch.gz)
and [LM patch](evidence/2026-09-05-radix-prefix-cache/candidate-mtp-mlx.patch.gz)
also match the compiled manifest's digests.

The model is `gpt-oss-20b` from a local snapshot, not an immutable Hugging Face
revision. The [model manifest](evidence/2026-09-05-radix-prefix-cache/gpt-oss-model-manifest.json)
pins all ten configuration, template, tokenizer and weight files. All ten file
sizes and SHA-256 digests were rechecked, including the three safetensors shards
(total 12,076,207,568 bytes). This identifies the measured local model without
claiming a registry attestation or a remote revision. The
[verification record](evidence/2026-09-05-radix-prefix-cache/paged-model-check-verification.json)
also records raw-result checks and retained evidence hashes.

## Short prompts: a match that correctly saves no work

The original/repeat input has 1,439 actual tokens; branch inputs have 1,436.
The model has 12 sliding-attention layers with 128-token windows, so its
conservative replay bound is 1,536 tokens. The candidate finds a 1,424-token
page-aligned match, but that is shorter than the bound. Adoption returns
`skippedPolicy`, with zero saved tokens and no replay performed. It does not
report a useful hit merely because the index matched.

`CBv2PrefixReuseCapability.plan` in
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/PrefixReusePlan.swift`
requires a positive saved span for this frozen replay layout. The
[short-policy verdict](evidence/2026-09-05-radix-prefix-cache/paged-short-policy-verdict.json)
passes all four main prompt/generated-ID, count and finish comparisons.

| Request, one observation each | Prompt tokens | Baseline TTFT, s | Candidate TTFT, s | Saved tokens |
|---|---:|---:|---:|---:|
| First | 1,439 | 1.504816458 | 0.847678209 | 0 |
| Exact repeat | 1,439 | 0.419654791 | 0.422155750 | 0 |
| Shared-prefix branch | 1,436 | 0.422560875 | 0.424192625 | 0 |
| Branch repeat | 1,436 | 0.419548000 | 0.419493667 | 0 |

The faster candidate first row is not credited to prefix reuse: it saved no
tokens. Subsequent short rows are nearly equal; first-shape warmup and run order
limit interpretation of the first-row difference.

## Long prompts: useful frozen replay

The original/repeat input has 5,472 actual tokens; branches have 5,469. The three
warm rows match 5,456 tokens, replay 1,536 with `frozenFullReplay`, and save
`5,456 - 1,536 = 3,920` tokens. The
[long verdict](evidence/2026-09-05-radix-prefix-cache/paged-long-verdict.json)
passes all four main raw token-ID, count and finish comparisons. The request IDs
contain the workload label `p8192`; it is not the actual tokenized prompt length.

| Request, one observation each | Prompt tokens | Baseline TTFT, s | Candidate TTFT, s | Saved tokens |
|---|---:|---:|---:|---:|
| First | 5,472 | 2.075151250 | 1.817950292 | 0 |
| Exact repeat | 5,472 | 1.578716708 | 0.854751458 | 3,920 |
| Shared-prefix branch | 5,469 | 1.582734417 | 0.658183875 | 3,920 |
| Branch repeat | 5,469 | 1.581932334 | 0.532338958 | 3,920 |

The warm reductions are 45.86%, 58.41%, and 66.35%, respectively. Each value is
computed from its paired raw `ttft_s`, verified against the first emitted
chunk's timestamp. They are distinct positions in one ordered sequence;
additional shape warmup can affect the first warm row. They are not three
independent estimates of a common median speedup. No dedicated decode control
was included, and both verdicts correctly report aggregate decode TPS as null.

## Tenant, cancellation, and run conditions

Each length has four main rows, three tenant-control requests, one decode
cancellation, one recovery request, and an excluded eight-token warmup in each
arm. The long candidate's two tenant-A controls save 3,920 tokens; the otherwise
identical tenant-B request misses and saves zero. All three control outputs
match their baseline counterparts. The short candidate has a matching-but-skipped
tenant-A control and a genuine tenant-B miss, consistent with the replay bound.

The long cancellation completes prefill, emits four decode tokens, and then
finishes `cancelled`. A later request in the same isolated `cancel-probe` scope
reuses 3,920 tokens and produces the baseline's full 64-token output. This is
valid for the paged cache: `publishFinalizedResidentBlocks` publishes confirmed
prompt pages before decode cancellation, and page-generation/ownership checks
remain in force (`Paged/PrefixBlocks/EngineLoopV2+PagedPrefix.swift`). The hybrid
recurrent bank has a stricter donor policy: it publishes only after natural
`stop`/`length` completion. The corrected paged verdict records this distinction;
it does not treat a cancelled decode as permission to publish unfinished pages.

All four runs exited successfully and recorded no ranked job at the final
check. Telemetry includes loading/warmup and is not a per-request allocator
trace. At GPU utilization of at least 90%, median GPU clock is 1,620 MHz in all
four runs; active sample counts are 44/44 for short baseline/candidate and
99/64 for long baseline/candidate. Sampled swap usage stays at 1,310,720 bytes.
The runs were sequential, not randomized or thermally identical: long active
GPU temperature ranges are 34.50–72.19°C for baseline and 31.79–63.79°C for
candidate. These traces do not establish a cache memory-peak improvement or
eliminate order effects.

## Retained runs and limits

| Run | Raw requests and output IDs | Thermal/memory telemetry | Launch metadata |
|---|---|---|---|
| Short baseline | [report](evidence/2026-09-05-radix-prefix-cache/baseline-engine-paged-gpt-oss-report.json.gz) | [telemetry](evidence/2026-09-05-radix-prefix-cache/baseline-engine-paged-gpt-oss-telemetry.jsonl.gz) | [metadata](evidence/2026-09-05-radix-prefix-cache/baseline-engine-paged-gpt-oss-metadata.json) |
| Short candidate | [report](evidence/2026-09-05-radix-prefix-cache/candidate-engine-paged-gpt-oss-report.json.gz) | [telemetry](evidence/2026-09-05-radix-prefix-cache/candidate-engine-paged-gpt-oss-telemetry.jsonl.gz) | [metadata](evidence/2026-09-05-radix-prefix-cache/candidate-engine-paged-gpt-oss-metadata.json) |
| Long baseline | [report](evidence/2026-09-05-radix-prefix-cache/baseline-engine-paged-gpt-oss-long-report.json.gz) | [telemetry](evidence/2026-09-05-radix-prefix-cache/baseline-engine-paged-gpt-oss-long-telemetry.jsonl.gz) | [metadata](evidence/2026-09-05-radix-prefix-cache/baseline-engine-paged-gpt-oss-long-metadata.json) |
| Long candidate | [report](evidence/2026-09-05-radix-prefix-cache/candidate-engine-paged-gpt-oss-long-report.json.gz) | [telemetry](evidence/2026-09-05-radix-prefix-cache/candidate-engine-paged-gpt-oss-long-telemetry.jsonl.gz) | [metadata](evidence/2026-09-05-radix-prefix-cache/candidate-engine-paged-gpt-oss-long-metadata.json) |

This check covers one model snapshot, serial engine requests and explicit paged
storage. It does not exercise provider HTTP, live coordinator routing, a
multi-machine request path, simultaneous tenants, restart persistence, or the
combined optimization/refactor artifact. The production backend default was not
changed. Provider local cache enablement and the coordinator's default-off
cache-routing switch remain separate controls.
