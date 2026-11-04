# Public cluster models: GLM-5.3-Flash, Qwen3.8-27B, MiMo-V2.6-Flash and Gemma 4 26B QAT

> Last updated: 2026-11-03

This record is the evidence document of the provider's public cluster model
declaration (`ClusterPublicModels`): the declaration's `evidenceSHA256` is the
SHA-256 of this file, and every release's cluster runtime facts name it. It
records the owner's decisions and the checks they rest on. It contains no
endpoint, credential, machine identifier or personal workspace location. It is
not a hosted-provider certification or a production deployment approval.

## Decision

The owner (jonathan308) decided on 2026-10-31:

- "public traffic should not be manual"
- "only glm 5.3 flash should be serving public & qwen 3.8 27b they are both good
  to go they should be approved for serving"
- on the mode families: "It should be tensor or pipeline obviously but that
  shouldn't matter for the coordinator"

The owner approved both modes, pipeline and tensor parallel, for both models,
and the public qualification of both models is done.

On 2026-11-03 the owner added two models. Of the cluster-validated models
that served their owner only, the owner said "Mark them all approved for public
traffic", then "If you did just add Mimo and Gemma to start". MiMo-V2.6-Flash
and Gemma 4 26B QAT are declared in the same two families, pipeline and tensor
parallel, as the 2026-10-31 ruling on families reads. MiMo-V2.6-Flash also
keeps its speculative pipeline, the split it plans by default. A declared
model's grant replaces the families its records grant, and a coordinator never
forms a pair planned in a family its grant omits, so without it a MiMo pair
planned that way would not form through Darkbloom at all. No other model serves
public cluster traffic: a cluster of any other model serves its owner only.

## Declared models

| Runtime model | Catalog model | Artifact | Mode families | Schedules |
|---|---|---|---|---|
| `registered_glm53_flash` | `glm-5.3-flash` | `3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac` | `pipeline`, `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |
| `registered_qwen38_27b` | `EigenLabs/Qwen3.8-27B-4bit-mtp` | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` | `pipeline`, `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |
| `registered_mimo_v26_flash_mopd` | `mimo-v2.6-flash-mopd` | `2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034` | `pipeline`, `pipeline_speculative`, `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |
| `registered_gemma4_26b_qat_4bit` | `gemma-4-26b-qat-4bit` | `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785` | `pipeline`, `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |

The artifacts are the ones the cluster runtime registers for the four models.
Each family is qualified on 2 ranks, each an Apple M5 Ultra (GPU architecture
`applegpu_g17d`, NAX on) on macOS 27.0, at 2026-11-03T00:00:00Z, the date of the latest declaration:

| Family | Mode | Cuts | Shares |
|---|---|---|---|
| `pipeline` | `pipeline_v1` | `[num_hidden_layers / 2]` (integer division): `[22]` for GLM-5.3-Flash (45 layers), `[32]` for Qwen3.8-27B (64 layers), `[24]` for MiMo-V2.6-Flash (48 layers), `[15]` for Gemma 4 26B QAT (30 layers) | not applicable |
| `pipeline_speculative` (MiMo-V2.6-Flash only) | `pipeline_mtp_v1` | `[num_hidden_layers / 2]`: `[24]` | not applicable |
| `tensor_parallel` | `tensor_parallel_v1` | `[]` | equal |

GLM-5.3-Flash's, Qwen3.8-27B's and Gemma 4 26B QAT's `config.json` give the
layer count as `text_config.num_hidden_layers`; MiMo-V2.6-Flash's gives it at the
top level.

## What was run

Recorded by the owner's team on DevNet; this record restates the results and
does not re-run them.

- GLM-5.3-Flash and Qwen3.8-27B served in tensor parallel on two Apple M5 Ultra
  Macs with 256 GB each, connected over Thunderbolt 5, on DevNet builds
  0.10.5-dev.branch.14 to 0.10.5-dev.branch.16. The guided setup's test request
  "Name three colors." was answered "Red, blue, and green."; GLM-5.3-Flash
  decoded at 120 to 128 tokens per second in that test.
- The fixed greedy answers of both models were identical across the build
  changes of 2026-10-30 (12 of 12).
- `ClusterAPIParityTests`
  (`provider-swift/Tests/ProviderCoreTests/Server/Distributed/ClusterAPIParityTests.swift`:
  the cluster endpoint answers the same requests as the single-Mac endpoint)
  passed 12 of 12 local runs.
- Best measured speeds:

| Model | Decode, one request | Decode, 8 concurrent requests | Prefill |
|---|---|---|---|
| GLM-5.3-Flash | about 118 tok/s | about 150 tok/s | about 4,100 tok/s |
| Qwen3.8-27B | about 82 tok/s | about 98 tok/s | about 1,465 tok/s |

This record holds no pipeline run on two Apple M5 Ultras.

For MiMo-V2.6-Flash and Gemma 4 26B QAT this record holds no run on two Apple
M5 Ultras. Their pipeline rests on the bundled records below and the owner's
decision of 2026-11-03. Their tensor parallel rests on the owner's decision
alone: its code is in open PRs (#1706 and #1707, with #1715 and #1716), and no
cross-cable record of it exists yet. MiMo-V2.6-Flash's speculative pipeline
(`pipeline_mtp_v1`, family `pipeline_speculative`) rests on its 2 passing
records below.

## Bundled cross-cable records

The qualification records the build bundles
(`ClusterPairQualificationRecordsBundled`) for these artifacts:

- Qwen3.8-27B, `tensor_parallel_v1`: 15 passing records over `jaccl`, 13 with
  the `one_chunk_lookahead_v1` schedule (prompts up to 32,768 tokens) and 2 with
  `serial_v1`, run on an Apple M3 Ultra with an Apple M5 Max (13) or with an
  Apple M5 Ultra (2).
- Qwen3.8-27B, `pipeline_v1`: 6 passing records over `jaccl`, all with the
  `one_chunk_lookahead_v1` schedule (prompts up to 30,720 tokens): 5 on an
  Apple M3 Ultra with an Apple M5 Max (cuts 16, 32, 48 and 60) and 1 with an
  Apple M5 Ultra (cut 8). The `pipeline` family also has 6 passing
  `pipeline_compact_decode_v1` records.
- GLM-5.3-Flash: 1 passing `pipeline_v1` record (an Apple M3 Ultra with an
  Apple M5 Max, cut 39, `serial_v1`) and no `tensor_parallel_v1` record. Its
  pipeline rests on that run and the owner's ruling; its tensor parallel rests
  on the owner's decision and the DevNet serving results above.
- MiMo-V2.6-Flash: 19 passing records over `jaccl`, all on an Apple M5 Ultra
  with an Apple M3 Ultra, from 2026-10-14, with prompts up to 16,384 tokens. The
  `pipeline` family has 8 `pipeline_v1` records (cuts 14 and 47; 7 `serial_v1`
  and 1 `one_chunk_lookahead_v1`) and 3 `pipeline_compact_decode_v1` records
  (cut 47, `serial_v1`). The others are 2 `pipeline_mtp_v1` and 6 `phase_split_v1`
  records. None diverged.
- Gemma 4 26B QAT: 7 `pipeline_v1` records over `jaccl`, from 2026-10-09 and
  2026-10-12, on an Apple M3 Ultra with an Apple M5 Max or an Apple M5 Ultra.
  4 passed and 3 diverged. A pass that a divergence of the same placement
  contradicts counts for nothing, so its records grant rests on 2 passes, both
  on an Apple M3 Ultra with an Apple M5 Ultra: cut 5 with `one_chunk_lookahead_v1`
  and cut 15 with `serial_v1`. The planner refuses the diverged placements (cut 2
  on that pair, and cuts 12 and 18 on the Apple M5 Max pair).

## Pair-serving grants

A pair member reports only hardware capabilities
(`DistributedServingEligibility.memberCapabilities`, called from
`provider-swift/Sources/darkbloom/StartCommand+ClusterMember.swift`): `apple_m5`
on an M5, never `mlx_nax` or `glm5_next_v1`. A coordinator holds each member of
a pair without a pair-serving grant to the model's single-Mac requirements
([`providerMeetsServingRequirementsLocked`](https://github.com/Layr-Labs/darkbloom-platform/blob/2847f27dda8e4caf9e2441d554067f42a88c9e1f/coordinator/registry/cluster_pair_serving_grant.go)),
which no member meets for GLM-5.3-Flash (`mlx_nax`, `glm5_next_v1`) or
Qwen3.8-27B (`mlx_nax`). Without a grant no pair of either model forms, for its
owner or the public (David's finding, 2026-10-31).

A release's cluster runtime facts therefore carry a pair-serving grant for each
model. A declared model's grant names its declared families, with this file as
its evidence. Any other model's grant is the one the build's bundled records
give its artifact (`ClusterPairServingGrants.grant`), with the SHA-256 of those
records as its evidence; a model the records grant nothing has none.

## Request envelope

Every declared model, both families: sampling and tool calls are allowed, and
`max_prompt_tokens` and `max_output_tokens` are 1,048,576 (the coordinator's
maximum, so only the model's own limits apply). Media follows what the
placement serves (`ClusterModelFeaturePolicy.mediaContract`). In tensor
parallel both models take media as the single-Mac product does
(`ClusterGLMMedia`, `ClusterQwenMedia`): `vision` holds when the model's
catalog entry in the release's environment lists `image` in
`input_modalities`, and `video` when it also lists `video`. A pipeline serves
text only, so its envelope admits neither. GLM-5.3-Flash's DevNet catalog entry
lists `text`, `image` and `video`; Qwen3.8-27B's lists `text` and `image`.
MiMo-V2.6-Flash's and Gemma 4 26B QAT's media in tensor parallel follow the same
contract, once their tensor-parallel code serves.

## Where it is used

`provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterPublicModels.swift`
declares the four models with this file's SHA-256. A release's cluster runtime
facts (`cluster_runtime`) carry, for a declared model, the grant of its declared
families and one parity qualification for each declared family and schedule:
`pipeline` first, then `tensor_parallel`. A coordinator that derives approvals
from releases derives their grants and parity qualifications from them
([provider release](../operations/provider-release.md#cluster-runtime-facts)).
