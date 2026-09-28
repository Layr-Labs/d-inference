# Gemma 4 26B QAT: default prefix cache and MTP validation

> Last updated: 2026-09-08 · commit `4ae34f033`

Report date: 2026-09-08. Review checkout: `4ae34f033472f2b2b3d69cce0f9f0b0c85f31f39`. Scope: `gemma-4-26b-qat-4bit`; Gemma 8-bit is excluded.

**Implementation and model validation are ready for review.** Candidate5 builds and focused suites pass. Two reversed-order greedy pairs and one sampled pair show useful MTP gains for code and extraction, with a small prose cost. B2/B4 branched-prefix checks, final default-auto HTTP activation and same-process vision/tool checks have completed. The repeated generated code defect below remains a quality caveat. External CI/benchmark resolution and actual catalog/release publication remain; this is not a claim that the release has been published. [Candidate5 build/test status](evidence/2026-09-08-gemma-qat-defaults/candidate5/status.json), [final HTTP result](evidence/2026-09-08-gemma-qat-defaults/candidate5/http/report.json)

## Implemented behavior

The exact QAT model defaults to paged attention, complete encrypted SSD prefix caching and `mtp_mode=auto`. Cache identity includes target bytes, prompt contract, native/metallib identity, layout and numerics. Authenticated restore and tenant isolation remain required. Enabling the assistant changes the complete-cache numerics identity; an earlier target-only checkpoint can intentionally miss after activation.

Network and standalone providers resolve the catalog assistant asynchronously while the target continues serving. Verified assistant preparation shares the existing target container and reserves separate assistant/KV resources. The staged engine is published only at an idle admission boundary, with arriving requests waiting through the existing load gate. Busy requests and reservations prevent replacement. Fetch, verification, cancellation, stale-owner and insufficient-memory failures retain the original target; candidate resources are discarded. Optional upgrades do not evict models to make room. Serving telemetry starts after publication, and closed samplers cannot emit stale posture.

Automatic Gemma MTP selects ordinary decode or one draft token. Its profitability baseline measures steady chained ordinary decoding. Positive samples measure actual committed output against wall time, including paired seed work. A bounded window of at most eight verified rounds lets the controller observe sustained carry reuse; the first shape warmup consumes a window slot but is excluded from the paired cost/output estimate. Unprofitable work returns to ordinary decoding with bounded exploration after cooldown. Cohort changes, invalid samples and tail constraints abort the learning window; per-round stop, cancellation and eligibility checks still apply. This policy is restricted to adaptive stateless drafting; explicit off/kill controls, fixed diagnostics and Qwen's stateful policy retain their behavior.

## Candidate identity and completed tests

The report checkout includes a test-only amendment after the runtime artifacts were built. It is not the runtime build revision. The amendment changes only the native tail-clamp fixture: it enables the intended rectangular cap and asserts the actual depth-one plan before testing the clamp. Runtime sources and the measured binaries are unchanged. [Amendment provenance](evidence/2026-09-08-gemma-qat-defaults/candidate5/test-amendment.json)

| Identity | Value |
|---|---|
| Candidate5 provider runtime | `22a9ad7acf03d25bb95f402066d76502ff56605d` |
| Candidate5 native runtime | `3e2e137ea2be8a0be36935ff2cfd91e53ba39705` |
| Test/report provider checkout | `4ae34f033472f2b2b3d69cce0f9f0b0c85f31f39` |
| Test-only native checkout | `b87e2ee1b2a4624aadc73210e066f2a6a8854736` |
| `radix-engine` SHA256 | `816b64f6b8614f35dde3cf062e36a2f5f40ee02c51d6afc58dc87243e5f8128a` |
| `darkbloom` SHA256 | `463729f9f48e0739c7708646e2548b1347558eae6741d8d2418e1233ee21bfb6` |
| Loaded benchmark metallib SHA256 | `20972c37e53fe6db3b3191a0434f6604c4ffc4f5ac62b370574f9922585b0fdb` |

Strict dependency pins and 7,725 source files were verified. Both production products built. Recorded passing suites comprise 270 provider Swift Testing tests; 31 benchmark Swift Testing and 2 XCTest tests; and 172 native Swift Testing and 25 XCTest tests. The native counts include the documented fixture amendment. These are focused suites, not a claim that every repository test ran. [Build/test status](evidence/2026-09-08-gemma-qat-defaults/candidate5/status.json)

Lifecycle fixtures exercise busy-slot replacement, cancellation, failed preparation, pending-load memory refusal, ownership and cleanup. Simultaneous upgrades were simulated with 2 and 16 independent provider fixtures, including busy originals and failed-preparation subsets. They do not represent 16 physical machines or a production fleet rollout.

## Matched decode pairs

Both arms use the same candidate5 binary, prompt token IDs, paged backend and SSD cache. The first pair ran adaptive-on then off; the second ran off then adaptive-on, completing an ABBA order check. Each row emits 1,024 completion tokens, with 1,023 tokens included in post-first-delta decode timing. [Pair measurements](evidence/2026-09-08-gemma-qat-defaults/candidate5/speed-pair1.json)

| Task | Pair1 off tok/s | Pair1 adaptive tok/s | Pair1 change | Pair2 change |
|---|---:|---:|---:|---:|
| Code, first | 115.23 | 127.21 | +10.40% | +10.48% |
| Code, repeat | 115.06 | 128.63 | +11.80% | +11.39% |
| Prose, first | 119.09 | 117.79 | −1.09% | −0.92% |
| Prose, repeat | 118.90 | 118.17 | −0.61% | −0.72% |
| Extraction, first | 116.14 | 136.12 | +17.20% | +17.23% |
| Extraction, repeat | 116.16 | 136.74 | +17.72% | +17.75% |

The second pair confirms the first pair's performance pattern on the same runtime. Its paired prompt tokens match, and extraction again follows identical generated token sequences; code/prose differ. The run owner reports zero structural-check errors. All 24 greedy outputs have now been reviewed, directly or through exact text identity to reviewed outputs; the repeated coding defect is retained below. [Reversed-order pair](evidence/2026-09-08-gemma-qat-defaults/candidate5/speed-pair2.json)

In pair1, MTP actually ran: code used 525/519 rectangular verification rounds and extraction 511/511, with only 3/4 and 1/1 seed steps respectively. Prose used 120/136 rounds and mostly ordinary decoding thereafter, with 820/792 depth-zero selections. All off rows recorded zero MTP rounds. These observations show sustained carry reuse and adaptive fallback; fallback does not eliminate the exploration cost.

In pair1, both modes restored the same repeated prefixes: 8,192 code tokens, 4,096 prose tokens and 6,144 extraction tokens, with zero replay. Adaptive repeat TTFTs were 199.84/256.92/176.84 ms, compared with 203.01/258.00/181.86 ms off. Code and prose follow different generated trajectories, so those speed comparisons concern matched input tasks. Extraction is an identical-token comparison. These are one-M5, B1, synthetic-input measurements with a local assistant directory, not public download or fleet throughput measurements. [Semantic and measurement review](evidence/2026-09-08-gemma-qat-defaults/candidate5/greedy-two-pair-semantic-review.md)

## Production sampling

A matched B1 off/on pair used the production sampling translator with temperature 0.7, top-p 0.9, top-k 40 and seed 4242. Recorded Float32 values match these settings; penalties, repetition penalty and logit bias match between arms. Every row has more than three seconds and 256 tokens of decode exposure. Both structural verdicts passed. This is one sampled pair; the reversed-order confirmation above concerns the separate greedy pairs. [Sampled measurements](evidence/2026-09-08-gemma-qat-defaults/candidate5/sampling-pair1.json)

| Task | Off tok/s | Adaptive tok/s | Change | Adaptive MTP rounds |
|---|---:|---:|---:|---:|
| Code, first | 110.66 | 117.69 | +6.35% | 396 |
| Code, repeat | 110.49 | 120.96 | +9.47% | 502 |
| Prose, first | 114.19 | 112.14 | −1.80% | 104 |
| Prose, repeat | 114.17 | 112.69 | −1.30% | 144 |
| Extraction, first | 111.44 | 130.15 | +16.79% | 511 |
| Extraction, repeat | 111.46 | 131.02 | +17.55% | 511 |

All sampled MTP rounds are rectangular; all off rows have zero MTP rounds. Code/prose use different generated trajectories, while all four sampled extraction outputs are identical. Repeated prefixes restore 8,192/4,096/6,144 tokens with zero replay. All 12 sampled outputs hit the 1,024-token cap. These measurements demonstrate nonzero-temperature MTP and workload-specific speed behavior, not sampling-distribution equivalence. [Sampled review](evidence/2026-09-08-gemma-qat-defaults/candidate5/sampling-semantic-review.md), [sampling and executable evidence](evidence/2026-09-08-gemma-qat-defaults/candidate5/sampling-semantic-evidence.json)

## Correctness and answer quality

Correctness evidence covers cache ownership/identity, authenticated restore, tenant boundaries, cancellation and request lifecycle separately from generated answer quality. Exact generated-token comparisons remain recorded, including differences; coherent wording alone does not verify cache state. Conversely, a changed answer is not by itself evidence of cache corruption.

Across the two greedy pairs, three of four adaptive code variants contain a concrete task failure: insertion must be keyed by `(source,event_id)`, but the generated implementation rejects the same event ID from a second source. Executing the completed code produces aggregate 10 instead of 20. All four matched off variants and the first pair's adaptive repeat accept both sources. These are repeated generations of one coding prompt, not independent tasks or a broad quality-rate estimate. The failing logic occurs before the output cap and cannot be dismissed as truncated tests. Both modes also accept naive timestamps despite the timezone-aware requirement; the off implementation additionally fails to distinguish several conflicting payload fields as its own documentation promises. [Combined executable findings and exact assertion](evidence/2026-09-08-gemma-qat-defaults/candidate5/greedy-two-pair-semantic-evidence.json)

Reviewed prose preserves the source's priorities and distinction between proposed work and approved funding, with some unsupported attribution details. All eight greedy extraction answers are text-identical, and their eight completed objects match all 72 source fields/types; they retain the baseline Markdown-fence defect and truncate within the ninth object. All speed rows hit the explicit length cap, so they do not demonstrate natural stopping or complete JSON. These results establish neither overall semantic equivalence nor a cache/state fault. The completed two-pair review retains the repeated source-isolation defect. [Combined greedy answer review](evidence/2026-09-08-gemma-qat-defaults/candidate5/greedy-two-pair-semantic-review.md)

Both sampled adaptive code variants pass the same source-isolation probe, accepting both records and producing 20. This contrasting result does not erase the greedy defect. Sampled code still accepts naive datetimes, and one variant raises KeyError where it documents ValueError for malformed input. Sampled prose retains the source priorities but adds some unsupported attribution details; sampled extraction retains the fence and truncation limitations. The sampled and greedy reviews make no overall answer-quality equivalence claim. [Sampled answer review](evidence/2026-09-08-gemma-qat-defaults/candidate5/sampling-semantic-review.md)

## Concurrent branched-prefix validation

Candidate5 B2 and B4 completed eight and sixteen rows respectively. Every row naturally stopped. Initial summaries missed the SSD cache; every repeated summary, changed-question branch and repeated branch restored 3,072 tokens. Reviewed summaries include pumping-station upgrades, canal maintenance and acoustic leak detection. Every changed-question answer correctly lists costs, schedules and downstream construction risks; one restored summary per width changes wording without contradiction. Structural verdicts passed with zero errors. [B2 verdict](evidence/2026-09-08-gemma-qat-defaults/candidate5/b2-branches/structural-verdict.json), [B2 answer/shape review](evidence/2026-09-08-gemma-qat-defaults/candidate5/b2-branches/review.json), [B4 verdict](evidence/2026-09-08-gemma-qat-defaults/candidate5/b4-branches/structural-verdict.json), [B4 answer/shape review](evidence/2026-09-08-gemma-qat-defaults/candidate5/b4-branches/review.json)

Actual target-forward observations confirm concurrent verification, not merely a configured request limit: B2 reaches two active requests and batch width two; B4 reaches four active requests and width four, with sequence width two during MTP verification. B4 records 16/16/8/8 completed width-four verification calls across initial/repeat/branch/branch-repeat batches. These are target-call observations, not GPU kernel counts. Outputs are short (25–60 tokens), so these cases establish bounded concurrent restore/branch behavior rather than sustained batched speed gains. Native text retains a terminal marker; the final HTTP check below validates shaping separately. [B2 runtime provenance](evidence/2026-09-08-gemma-qat-defaults/candidate5/b2-branches/metadata.json), [B4 runtime provenance](evidence/2026-09-08-gemma-qat-defaults/candidate5/b4-branches/metadata.json)

## Final-candidate default-auto HTTP and capabilities

The final candidate5 provider completed **47/47 valid text streams**, with zero interrupted streams, non-2xx responses or serving failures. Two requests completed while metadata was blocked and two while assistant weights were blocked. The provider served target-only, downloaded/prepared the assistant, then activated MTP without restarting; 12 requests began after activation and the observed verification counter reached 802 rounds including the subsequent capability requests. The test omitted MTP mode, drafter path and KV backend overrides. All 47 text requests naturally stopped. [HTTP result](evidence/2026-09-08-gemma-qat-defaults/candidate5/http/report.json), [runtime and fixture provenance](evidence/2026-09-08-gemma-qat-defaults/candidate5/http/metadata.json), [independent stream/content review](evidence/2026-09-08-gemma-qat-defaults/candidate5/http/independent-review.md)

Request34 overlapped first activation and the first positive verification-counter interval. Its maximum streamed-content gap was **16.224 ms**, with **176.6 ms TTFT** and **1.692 s total latency**. The warm target maximum gap was 18.937 ms; later active requests peaked at 17.521 ms. Initial target loading and terminal drain are excluded from these gap comparisons. This run shows no activation-associated gap or TTFT spike relative to its observed warm serving range. It does not establish zero latency cost, a causal explanation for earlier pauses, or a fleet-wide latency bound. [Gap analysis](evidence/2026-09-08-gemma-qat-defaults/candidate5/http/content-gap-analysis.md), [exact per-request timings](evidence/2026-09-08-gemma-qat-defaults/candidate5/http/content-gap-analysis.json)

The same provider then completed two image requests with MTP active. Each naturally stopped after 107 output tokens and 27 verification rounds; both returned the same coherent description of the supplied gray/white cube interface. The quoted label “Camera Settings” paraphrases actual “Camera Position”/“Camera Target” controls; the review retains this imprecision. The tool request produced exactly `record_color({"color":"blue","count":2})`, finished with `tool_calls` and used six MTP rounds. These are capability smoke tests, not broad vision/tool quality evaluations. HTTP usage omits `cached_tokens`, so this trace does **not** prove zero cache hits for images. Multimodal lookup/staging is disabled by the source gate; file inventories and the faster second response cannot independently establish whether reads occurred. [Capability summary](evidence/2026-09-08-gemma-qat-defaults/candidate5/http/capabilities-summary.json)

## Earlier restart and live rollout evidence

Candidate4 passed the real-model fresh-engine checkpoint fixture: a 6,846-token prompt restored 6,144 tokens, read 335,646,082 bytes and returned `ALDER-427`, matching the cold control. The donor engine was closed before the fresh engine restored using the same injected key. This is fresh-engine persistence evidence, not an OS-process restart with a signed persistent Keychain identity. Candidate4 used provider `5d1c905826205e24a05092043761943217444eee` and native `31c454165b750cedeee2e246f5d6bd1fa9ff29f0`; its focused suites also passed. [Status](evidence/2026-09-08-gemma-qat-defaults/candidate4/status.json), [restart log](evidence/2026-09-08-gemma-qat-defaults/candidate4/checkpoint-restart.log.gz)

Candidate3's real default-auto HTTP success cell completed 38/38 streams, including two during blocked metadata and two during blocked weights. It observed target-only→MTP activation, actual verification rounds and 12 requests begun after activation. All streams naturally stopped below the cap, with no observed special-token leakage or serving errors. The separate failed-download cell completed 22/22 streams and stayed target-only, with no published artifact or staging residue. These cells use the candidate3 provider/native revisions and hashes recorded in their metadata. [Success](evidence/2026-09-08-gemma-qat-defaults/candidate3-http-success/report.json), [success provenance](evidence/2026-09-08-gemma-qat-defaults/candidate3-http-success/metadata.json), [independent review](evidence/2026-09-08-gemma-qat-defaults/candidate3-http-success/independent-review.md), [failure](evidence/2026-09-08-gemma-qat-defaults/candidate3-http-failure/report.json)

There was no observed warm TTFT spike, but there was a measurable streamed-content pause. Request25 overlapped first activation despite its stale `waiting_weights` start label. It had a **78.533 ms** maximum content-to-content gap, **180.8 ms TTFT** and **2.036 s total latency**. Warm target requests peaked at an 18.744 ms content gap; later active requests peaked at 17.108 ms. Initial target loading and terminal drain are excluded from those gap comparisons. Successful streams therefore do not establish zero latency cost. The trace cannot causally attribute the pause to JIT, and response-length differences prevent a matched total-latency comparison. [Gap analysis](evidence/2026-09-08-gemma-qat-defaults/candidate3-http-success/content-gap-analysis.md), [exact per-request evidence](evidence/2026-09-08-gemma-qat-defaults/candidate3-http-success/content-gap-analysis.json)

## Artifact delivery and rollout limits

The assistant is pinned to HF repository `mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit`, immutable revision `bb94eae1b70a80dac16cbf959bb4b7d56bd1fb8c`. Full config and weight bytes match the published R2 manifest, whose SHA256 is `8b7c00b7f131345156f5f20fa9c94a895c5340f16d9331bafb9e59628bf45bf2`. The resolver supports pinned HF-first transfer with verified R2 fallback. **The prepared HF catalog patch has not been applied.** Byte verification does not prove public catalog propagation or end-to-end HF-first runtime activation. [Artifact verification](evidence/2026-09-08-gemma-qat-defaults/hf-assistant-identity-verification.json), [prepared catalog patch](../operations/artifacts/gemma-qat-assistant-hugging-face.patch.json)

Live rollout tests use one real M5 with controlled localhost catalog/CDN endpoints, unique artifact namespaces and the pinned assistant bytes. They deliberately omit the HF hint to control download delays. They validate that local serving lifecycle, not public HF transport, coordinator routing across real machines, fleet download pressure or low-memory physical devices. Persistent signing/package deployment work remains separate from these ephemeral-key tests.

## Review, CI and publication status

The latest review snapshot for provider checkout `4ae34f033472f2b2b3d69cce0f9f0b0c85f31f39` reports Provider Tests and E2E Integration passing. E2E Benchmarks is waiting on its environment. Threat Model Review encountered HTTP 401 from an invalid Anthropic API key; this external check needs resolution and re-verification. Native checkout `b87e2ee1b2a4624aadc73210e066f2a6a8854736` has all three CodeQL checks passing. The reviewed snapshot contains no PR reviews or inline comments. E2E Benchmarks is a separate manual cost-control job; waiting is not a test failure. These statuses should be refreshed before merge; the benchmark queue and failed external check are not represented as passing.

Remaining work is to resolve the external review check, decide whether to run the separately approved benchmark job, merge the native dependency before the provider PR, and perform the actual catalog and release publication. The prepared HF catalog patch has not been applied. Model validation is complete for the documented scope; answer-quality limitations, one-host coverage and the separate persistent-key/deployment scope remain explicit.

## Evidence inventory

The [evidence index](evidence/2026-09-08-gemma-qat-defaults/README.md) includes compressed raw native reports, source verification, original and amended test logs, and the [checksummed inventory](evidence/2026-09-08-gemma-qat-defaults/INVENTORY.json).
