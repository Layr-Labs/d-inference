# Public cluster models: GLM-5.3-Flash and Qwen3.8-27B

> Last updated: 2026-10-31

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
and the public qualification of both models is done. No other model serves
public cluster traffic: a cluster of any other model serves its owner only.

## Declared models

| Runtime model | Catalog model | Artifact | Mode families | Schedules |
|---|---|---|---|---|
| `registered_glm53_flash` | `glm-5.3-flash` | `3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac` | `pipeline`, `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |
| `registered_qwen38_27b` | `EigenLabs/Qwen3.8-27B-4bit-mtp` | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` | `pipeline`, `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |

The artifacts are the ones the cluster runtime registers for the two models.
Each family is qualified on 2 ranks, each an Apple M5 Ultra (GPU architecture
`applegpu_g17d`, NAX on) on macOS 27.0, at 2026-10-31T00:00:00Z:

| Family | Mode | Cuts | Shares |
|---|---|---|---|
| `pipeline` | `pipeline_v1` | `[num_hidden_layers / 2]` (integer division): `[22]` for GLM-5.3-Flash (45 layers), `[32]` for Qwen3.8-27B (64 layers) | not applicable |
| `tensor_parallel` | `tensor_parallel_v1` | `[]` | equal |

Both models' `config.json` give the layer count as `text_config.num_hidden_layers`;
neither has a top-level `num_hidden_layers`.

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

Both models, both families: sampling and tool calls are allowed, and
`max_prompt_tokens` and `max_output_tokens` are 1,048,576 (the coordinator's
maximum, so only the model's own limits apply). Media follows what the
placement serves (`ClusterModelFeaturePolicy.mediaContract`). In tensor
parallel both models take media as the single-Mac product does
(`ClusterGLMMedia`, `ClusterQwenMedia`): `vision` holds when the model's
catalog entry in the release's environment lists `image` in
`input_modalities`, and `video` when it also lists `video`. A pipeline serves
text only, so its envelope admits neither. GLM-5.3-Flash's DevNet catalog entry
lists `text`, `image` and `video`; Qwen3.8-27B's lists `text` and `image`.

## Where it is used

`provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterPublicModels.swift`
declares the two models with this file's SHA-256. A release's cluster runtime
facts (`cluster_runtime`) carry, for a declared model, the grant of its declared
families and one parity qualification for each declared family and schedule:
`pipeline` first, then `tensor_parallel`. A coordinator that derives approvals
from releases derives their grants and parity qualifications from them
([provider release](../operations/provider-release.md#cluster-runtime-facts)).
