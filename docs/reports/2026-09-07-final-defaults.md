# Final five-model serving defaults

> Last updated: 2026-09-07 · commit `4805797ff`

All five release artifacts select paged attention automatically on the verified 0.9.0 runtime. The three Qwens use their normal automatic MTP policy and restore an SSD prefix on the repeated request. GPT-OSS and Gemma QAT keep SSD and automatic MTP off. All ten connected HTTP requests pass completion and usage accounting.

## Results

| Model | Actual backend | MTP active | Repeated-request SSD tokens saved |
| --- | --- | --- | --- |
| Qwen 3.5 35B A3B | Paged | Yes | 4,096 |
| Qwen 3.6 35B A3B | Paged | Yes | 4,096 |
| Qwen 3.8 27B | Paged | Yes | 4,096 |
| GPT-OSS 20B | Paged | No | Disabled |
| Gemma 4 26B QAT | Paged | No | Disabled |

The fixture requests automatic backend and MTP selection and the release cohort's SSD setting. Actual capacity snapshots confirm the paged backend and exact model aggregate. Completion profiles confirm MTP activity. The three repeated Qwen requests report an SSD hit saving 4,096 prefill tokens each; the cold requests have no hit. Cold and repeat requests are otherwise identical.

Every response reaches its 64-token cap. The Qwen and GPT responses contain reasoning without a final answer, so they establish configuration and cache behavior rather than answer-quality acceptance. Both QAT responses give the same coherent three-sentence summary, correctly describing infrastructure work as proposed. This observation does not erase the earlier QAT proposal-certainty caveat or establish broader model quality.

## Evidence and scope

Root independently verifies 425 original file identities, all ten HTTP completion and usage records, slot identities, MTP profiles and cache lookup records. Immutable dependency checks and owned process retirement pass for all five cells. Temporary Qwen discovery aliases are removed, and the final clean host observation hands the GPU to the separate GPT baseline control.

The [result summary](evidence/final-defaults-2026-09-07/evidence.json), [selected evidence capsule](evidence/final-defaults-2026-09-07/evidence.tar.gz) and [member manifest](evidence/final-defaults-2026-09-07/manifest.json) preserve the exact source, runtime, model, request and cleanup records. The publication projection does not claim original filesystem modes. Full original per-cell archives remain retained.

This is a one-provider connected test with ephemeral cache keys. It does not establish two-provider selection, durable production-key restart or cross-machine performance. See the [final build](2026-09-07-release090-final-build.md), [tool and vision checks](2026-09-07-final-capabilities.md), [quality follow-up](2026-09-07-five-model-quality-followup.md) and [acceptance criteria](../design/release-090-acceptance.md).
