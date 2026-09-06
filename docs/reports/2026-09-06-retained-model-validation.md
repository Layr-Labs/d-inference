# Current candidate: Qwen3.8, GPT-OSS and Gemma QAT retained checks

> Last updated: 2026-09-06 · commit `2eebb5412`

Qwen3.8 passes B1/B2/B4 backend and SSD comparisons on the combined candidate. GPT-OSS passes all three cache-off backend comparisons. Gemma QAT completes both ordinary B1 runs with intact request state, but their strict token comparison fails; its B2/B4 cells remain unrun in this stopped plan. This is bounded model evidence, not release-wide acceptance.

All runs use immutable runtime104, engine SHA256 `cc86a3328be98a498ea0dad077c7a6fd64add25aabe5ac7d9cba78bc93a11568` and source manifest `e7b769e2713e48c53fb62fbe74e449bb409c8fc1b7e5f036b14e808a7c3da3f5`. The [review and exact file identities](evidence/retained-model-validation-2026-09-06/evidence.json), [selected original reports](evidence/retained-model-validation-2026-09-06/evidence.tar.gz) and [archive identity](evidence/retained-model-validation-2026-09-06/archive.json) retain successful and failed evidence together.

| Exact model | Completed cells | Observed result |
|---|---:|---|
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | 9 | Contiguous/off, paged/off and paged/SSD at B1, B2 and B4; all six comparisons pass with embedded MTP active. |
| `gpt-oss-20b` | 6 | Ordinary contiguous/off and paged/off at B1, B2 and B4; all three backend comparisons pass. |
| `gemma-4-26b-qat-4bit` | 2 | Ordinary B1 contiguous/off and paged/off each pass cell integrity; cross-backend token equality fails. |

Every completed cell passes actual forward-width, production-grant, request completion, isolation and retirement checks. The root reviewer independently verified all 17 full source/model/runtime before-and-after audits against the sealed manifest and confirmed each before/after pair is identical. Successful comparisons include the completed tenant and cancellation-recovery trajectories, not only the first answer. No resident prefix bank is enabled. GPT-OSS and QAT keep SSD and MTP off, as in their shipping defaults.

Qwen3.8 long requests produce 74 tokens in each compared arm. Its B1 warm row restores 4,096 tokens. At B2 both warm rows restore 5,120 tokens each; at B4 all four warm rows restore 5,120 each. Those rows report authenticated SSD hits and preserve the corresponding cache-off output. Actual widths two and four are verified from native forward telemetry; merely queuing concurrent requests is insufficient.

Gemma QAT emits 61 tokens and a normal stop on both backends. Each backend repeats its own answer exactly. The prompt asks for three sentences summarizing proposed infrastructure work. The contiguous answer says acoustic leak detection methods “have been suggested”; the paged answer says they “will be implemented.” Both are coherent, but the latter overstates certainty relative to the proposal. Preserve that fidelity caveat. The difference alone does not isolate a numerical regression, establish broad quality, or prove cache corruption; SSD is disabled in both runs. The retained tenant/donor/recovery mismatch flags also compare outputs across these two backends, rather than reporting an isolation failure within one run.

The original 21-cell controller stops on that strict comparison: its final accepted flag remains false, with 17 completed cells and four QAT B2/B4 cells unrun. The [release acceptance decision](../design/release-090-acceptance.md) treats cross-backend wording as diagnostic while requiring numerical soundness, substantive quality and cache/request integrity. Remaining QAT widths require a separately reviewed continuation; this report does not rewrite the original failure.

The original sealed archive is 7,151,820,829 bytes, SHA256 `d8d44d097470579145f99d4a7875960fc8c3d7d7ef0de2d9f555564d0418ab69`, retained on the test host. A compact local collection verifies 344 files against original manifest `3315da07bc6a52fba80668d9dc615fbaa23263391c97f9f436a8b4d62c96c26e`, excluding only 19 encrypted prefix-cache payload files. The linked publication capsule selects original model reports, inputs, metadata, final verdict and cleanup receipts; full per-step audits remain in the verified local collection and remote archive. This is a declared projection, not a replacement execution.

All owned process groups retired and the fresh host observation found no owned or unexpected jobs before releasing the M5 lane. No performance median, default HTTP, connected routing, persistent restart, representative quality, sustained-context or whole-release pass is claimed by this retained matrix. The tested executable still reports 0.8.16; the separate version-only build must validate 0.9.0 before release.
