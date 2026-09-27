# Qwen3.6 sustained exposure stops on strict token comparison

> Last updated: 2026-09-06 · commit `2eebb5412`

The five-model sustained run stops in its first Qwen3.6 cell because cancellation recovery generates different tokens from its completed donor. The strict failure remains recorded. Source analysis shows that normal MTP selects verification depth using measured execution time and retained history; this run does not isolate an SSD corruption defect.

## Observed exposure

Run `117-sustained-shipping-five1` uses the [reviewed candidate](2026-09-06-release090-candidate-build.md), version `0.8.16`, on the 128 GiB M5. The exact `qwen3.6-35b-a3b-vl-mtp-mxfp8` artifact runs paged B1, normal embedded MTP, SSD caching and production-derived grants. First/repeat requests have identical 22,043-token prompts, temperature zero and a 2,048-token output cap.

| Observation | Cache evidence | Generated output |
|---|---|---|
| First | Cold miss | 2,048 tokens, `length`; 19.92 s decode |
| Repeat | Staged 20,480-token restore | 2,048 tokens, `length`; 19.30 s decode |
| Cancellation donor | Fresh-scope cold miss | 2,048 tokens, `length` |
| Cancellation | Staged 20,480-token restore | Five tokens, `cancelled` |
| Recovery | Staged 20,480-token restore | 2,048 tokens, `length` |

Three tenant controls also complete at the output cap, with cold/warm/cold behavior across two isolated scopes. Restored requests have actual disk-read increments, one 1,563-token suffix prefill and zero replay tokens. Cold prefill uses eleven chunks with a maximum of 2,048 tokens. All recorded stream chunks match their output arrays. Shutdown records zero active/waiting requests, KV reservations, live pages and committed paged storage; the owned process group retires cleanly.

The native benchmark throws `cancellation recovery differs from completed donor tokens`, producing exit `-5` through the top-level Swift error. This is the recorded benchmark assertion, not a lease termination or demonstrated GPU kernel crash. No cell is accepted, and Qwen3.5, Qwen3.8, GPT-OSS and Gemma QAT sustained cells remain unrun in this attempt.

## What the divergence establishes

First/repeat tokens diverge at zero-based position 199. Cold first versus cold donor also diverges at 199, despite identical cold prefill geometry. Donor/recovery first diverge at 220. Restoration and cancellation are therefore not necessary for the observed variation.

The archived candidate source proves the timing dependency: `EngineLoopV2.swift:3693–3701` measures elapsed step time; `CBv2MTPRoundDriver.swift:758–805` records shared costs, retained across request completion; `CBv2MTPDepthController.swift:325–347,389–391` selects depth using measured goodput and hysteresis. `EngineLoopV2+MTPPlanning.swift:181–204` applies that depth to verification geometry. First/repeat actually use different mixtures of verification widths 2–5. These aggregate counters do not capture the exact geometry or logit margins at positions 199/220. Timing-dependent geometry and finite precision are a plausible explanation, not an isolated causal proof or proof that every cache path is correct.

The four inspected full-length texts remain coherent infrastructure action/verification checklists, with differing relevant wording, actions and ordering. They stop after roughly 58–65 entries, before the requested 160: task completion is **inconclusive under the output cap**, and engineering validity was not certified.

## Preserved evidence and continuation

The [summary](evidence/qwen36-sustained-diagnosis-2026-09-06/evidence.json) binds the failed report, comparisons, full projection and cleanup. All 108 collected original files verify against the original manifest; nine encrypted cache payloads remain excluded. The source/runtime/full-model before/after audits are byte-identical. The [capsule](evidence/qwen36-sustained-diagnosis-2026-09-06/evidence.tar.gz) contains 13 original result/control/retirement files plus provenance, CPU diagnosis and exact candidate source proofs; the [archive receipt](evidence/qwen36-sustained-diagnosis-2026-09-06/archive.json) verifies its 34 members. Complete audits and the 108-file projection remain separately retained.

A separately reviewed [benchmark comparison policy](../developer/test.md#prefix-cache-benchmark-validation) can retain token differences while continuing structural checks and explicit quality review. That is a validation-policy change, not a production inference fix. It was not used in this run and does not convert this strict failure into a pass. Sustained qualification of the remaining models and broader release acceptance remain separate.
