# Final tool and vision capability checks

> Last updated: 2026-09-07 · commit `dbf2b73cf`

Qwen 3.5, Qwen 3.6, GPT-OSS 20B and Gemma 4 26B QAT pass seven connected HTTP capability requests on the verified 0.9.0 runtime. All four tool calls select the requested function and arguments; all three vision responses finish naturally and correctly describe the test image. Qwen 3.8's final capability check remains part of the separate routing successor.

## Results

| Model | Tool call | Vision response |
| --- | --- | --- |
| Qwen 3.5 | Pass | Pass; 31 tokens, natural stop |
| Qwen 3.6 | Pass | Pass; 28 tokens, natural stop |
| GPT-OSS 20B | Pass | Outside its text-only scope |
| Gemma 4 26B QAT | Pass | Pass; 23 tokens, natural stop |

Each tool response emits exactly one `record_color` call whose parsed arguments are `{"color":"blue","count":2}`, with finish reason `tool_calls`. Each vision response describes the central cluster of white/gray cubes against a black background. Root and the executing reviewer inspect both the original image and the returned text; an HTTP 200 alone is not the semantic criterion. Streaming completion and prompt/completion/total usage accounting also pass.

The fixture selects automatic backend and MTP policy. Actual slot snapshots confirm paged attention and the expected model aggregates. Qwen SSD capability is enabled; GPT and QAT SSD is disabled. These short requests establish capability behavior, not a measured long-prefix restoration or durable restart.

## Scope and cleanup

Each cell uses one local provider connected to the real test coordinator. It does not establish two-provider cache selection, cross-host performance, production attestation or general tool/vision benchmark quality. The failed two-provider registration experiment remains separate from these successful one-provider cells.

All four workers complete and their owned process groups retire. Immutable dependency checks pass; the temporary Qwen model-discovery aliases are removed using their ownership journals. The native runtime remains the [verified final build](2026-09-07-release090-final-build.md); it is not rebuilt for this experiment.

## Evidence

Root independently verifies all 332 original files across the four collected manifests and checks every reported request against the original HTTP report. The [result summary](evidence/final-capabilities-2026-09-07/evidence.json) preserves exact runtime, model, response and archive identities. The [selected evidence capsule](evidence/final-capabilities-2026-09-07/evidence.tar.gz) includes original reports, audit and retirement records, the test image and attributed reviews; its [manifest](evidence/final-capabilities-2026-09-07/manifest.json) binds every member. Full per-cell archives remain retained; the publication projection does not claim original file modes.

Related: [acceptance criteria](../design/release-090-acceptance.md), [quality follow-up](2026-09-07-five-model-quality-followup.md), [sustained workload results](2026-09-07-five-model-sustained-final.md).
