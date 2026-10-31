# Public cluster models: GLM-5.3-Flash and Qwen3.8-27B in tensor parallel

> Last updated: 2026-10-31

This record is the evidence document of the provider's public cluster model
declaration (`ClusterPublicModels`): the declaration's `evidenceSHA256` is the
SHA-256 of this file, and every release's cluster runtime facts name it. It
records the owner's decision and the checks the decision rests on. It contains
no endpoint, credential, machine identifier or personal workspace location. It
is not a hosted-provider certification or a production deployment approval.

## Decision

The owner (jonathan308) decided on 2026-10-31:

- "public traffic should not be manual"
- "only glm 5.3 flash should be serving public & qwen 3.8 27b they are both good
  to go they should be approved for serving"

The public qualification of both models is done. No other model serves public
cluster traffic: a cluster of any other model serves its owner only.

## Declared models

| Runtime model | Catalog model | Artifact | Mode family | Schedules |
|---|---|---|---|---|
| `registered_glm53_flash` | `glm-5.3-flash` | `3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac` | `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |
| `registered_qwen38_27b` | `EigenLabs/Qwen3.8-27B-4bit-mtp` | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` | `tensor_parallel` | 1 (serial), 2 (one-chunk lookahead) |

The artifacts are the ones the cluster runtime registers for the two models.
The evidence placement of both: 2 ranks, each an Apple M5 Ultra (GPU
architecture `applegpu_g17d`, NAX on) on macOS 27.0, cuts `[]`, mode
`tensor_parallel_v1`, equal shares. Qualified at 2026-10-31T00:00:00Z.

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

## Bundled cross-cable records

The qualification records the build bundles
(`ClusterPairQualificationRecordsBundled`) for these artifacts:

- Qwen3.8-27B, `tensor_parallel_v1`: 15 passing records over `jaccl`, 13 with
  the `one_chunk_lookahead_v1` schedule (prompts up to 32,768 tokens) and 2 with
  `serial_v1`, run on an Apple M3 Ultra with an Apple M5 Max (13) or with an
  Apple M5 Ultra (2).
- GLM-5.3-Flash: 1 passing `pipeline_v1` record and no `tensor_parallel_v1`
  record. Its tensor-parallel public qualification is the owner's decision, on
  the runs above.

The records still decide the provider's own pair-serving grants and the shapes
the planner avoids. The declaration adds the public qualification of the two
declared models and of nothing else. A release derives no pair-serving grant
from the records: a coordinator grant restricts its approval to the families it
names, so a grant from GLM-5.3-Flash's pipeline record alone would stop its
tensor-parallel pairs.

## Request envelope

Both models: sampling and tool calls are allowed, and `max_prompt_tokens` and
`max_output_tokens` are 1,048,576 (the coordinator's maximum, so only the
model's own limits apply). `vision` holds when the model's catalog entry in the
release's environment lists `image` in `input_modalities`, and `video` when it
also lists `video`. Both models' tensor-parallel cluster paths take media as the
single-Mac product does (`ClusterGLMMedia`, `ClusterQwenMedia`). GLM-5.3-Flash's
DevNet catalog entry lists `text`, `image` and `video`.

## Where it is used

`provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterPublicModels.swift`
declares the two models with this file's SHA-256. A release's cluster runtime
facts (`cluster_runtime`) carry one parity qualification for each declared
family and schedule of a declared model, and a coordinator that derives
approvals from releases derives their parity qualifications from them
([provider release](../operations/provider-release.md#cluster-runtime-facts)).
