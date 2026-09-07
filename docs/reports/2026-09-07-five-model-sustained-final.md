# Final five-model sustained generation checks

> Last updated: 2026-09-07 · commit `f8086ef1e`

The three Qwen models and GPT-OSS meet the required long-context and sustained decode scope on the verified 0.9.0 runtime. Gemma QAT refuses the long checklist request and stops after 70 and 62 tokens, so the five-model run fails its complete-workload gate.

## Measured workload

Every main request must actually emit 2,048 tokens and finish at the configured length limit, with at least ten seconds of decode. The run uses batch width one and paged attention. The three Qwens enable normal embedded MTP and SSD caching; GPT-OSS and Gemma QAT keep MTP and SSD disabled.

| Model | Prompt tokens | First / repeat decode seconds | Repeat saved prefix tokens | Cell state |
| --- | ---: | ---: | ---: | --- |
| Qwen 3.5 | 22,043 | 19.73 / 19.01 | 20,480 | Passed |
| Qwen 3.6 | 22,043 | 21.15 / 19.97 | 20,480 | Passed |
| Qwen 3.8 | 22,043 | 47.63 / 49.40 | 8,192 | Passed |
| GPT-OSS 20B | 21,669 | 20.81 / 20.80 | 0; disabled | Passed |
| Gemma 4 26B QAT | 21,621 | Below one second in both rows | 0; disabled | Failed: 70 / 62 tokens, natural stop |

Decode duration excludes the first output delta, using the retained decode-token count divided by the measured decode rate. These are individual functional workload observations, not benchmark medians or cross-machine performance claims.

## Output review

The prompt requests 160 numbered implementation-checklist entries. The fixed 2,048-token budget deliberately provides a bounded sustained workload; none of the reviewed Qwen or GPT responses completes all 160 entries. Completion quality remains inconclusive at that cap.

All six main Qwen outputs remain coherent and relevant to the infrastructure program. Qwen 3.5 often separates an action and its verification into alternating entries rather than placing both in every entry. Qwen 3.6 and 3.8 generally use separate action and verification sentences. These format limitations remain recorded. The Qwen responses reach entries 57–98 before truncation.

Both GPT main outputs are identical analysis-channel planning and drafted checklist items, with explicit word counting through partial item 23. They do not reach the final answer channel. The sustained workload passes independently of the separate GPT code/prose quality-control investigation.

Generated-token comparisons use explicit record mode. Strict generated equality is not claimed; prompt/cache identity, authentication, isolation, cancellation, accounting and actual execution scope remain required. Earlier failed strict experiments retain their original results.

Gemma QAT explicitly refuses the requested 160 entries because of their output length and formatting constraints. Its repeat response also identifies the highly repetitive input as a possible attempt to bypass constraints. Independent reconstruction and comparison verify that both actual 21,621-token prompts contain the complete checklist instruction. The short output is not explained by a missing suffix or a cache hit; SSD is disabled. It does not by itself establish a Paged Attention numerical defect.

A separate QAT experiment is being prepared: the exact original prompt on contiguous attention to investigate causality, plus a nonrepetitive long-context writing task on both backends with the same required 2,048-token completion and minimum decode duration. The failed experiment is not relabeled, and no new result is claimed here.

## Evidence

All five source/runtime/model audits are identical before and after execution. All owned process groups retire, and a fresh host observation confirms no remaining test jobs. No binding or process-order error is present. The only final workload errors are the two short QAT main rows and their missing sustained-decode exposure. The original overall verdict remains false.

Collection independently verifies 231 original files against the full manifest. Twenty-seven encrypted cache files remain in the original 10.43 GB remote archive. Its owner-recorded hash is retained; the selected local projection does not claim to rehash that full archive or preserve original file modes.

The [result summary](evidence/five-model-sustained-final-2026-09-07/evidence.json) retains measured rows, the workload failure, output reviews and exact collection identities. The [publication capsule](evidence/five-model-sustained-final-2026-09-07/evidence.tar.gz) includes original reports, inputs, metadata, final verdict and cleanup records, bound by its [manifest](evidence/five-model-sustained-final-2026-09-07/manifest.json). Root verifies that the provisional main outputs reviewed during execution match the final collected reports exactly.

Related: [final build](2026-09-07-release090-final-build.md), [quality follow-up](2026-09-07-five-model-quality-followup.md), [earlier strict sustained diagnosis](2026-09-06-qwen36-sustained-diagnosis.md), [acceptance criteria](../design/release-090-acceptance.md).
