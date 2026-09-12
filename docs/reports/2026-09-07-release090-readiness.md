# 0.9.0 implementation and validation readiness

> Last updated: 2026-09-07 · commit `32a756317`

The Paged Attention migration, three-Qwen SSD defaults and cache-routing implementation are ready for code review. The model and functional validation described below is complete. This does not authorize or claim a published release: production-key cache reuse across restart still requires the signed candidate from the separate signing work, followed by normal review, merge and release checks.

## Shipping configuration

| Artifact | Automatic attention | Automatic MTP | SSD prefix caching |
| --- | --- | --- | --- |
| Qwen 3.5 35B A3B | Paged | Enabled | Enabled |
| Qwen 3.6 35B A3B | Paged | Enabled | Enabled |
| Qwen 3.8 27B | Paged | Enabled | Enabled |
| GPT-OSS 20B | Paged | Disabled | Disabled |
| Gemma 4 26B QAT | Paged | Disabled | Disabled |

Gemma 8-bit is excluded. Explicit Gemma QAT MTP uses serial target verification. Coordinator cache routing remains a separate operational activation, initially restricted to the three verified Qwen artifact tuples; shipping these provider defaults does not enable production routing.

## Completed evidence

| Area | Result |
| --- | --- |
| Runtime and dependencies | Both optimized products build and report 0.9.0. Exact source, compiled dependency closures and runtime artifacts are verified. Latest merged MLX and mlx-c pins have the tested source trees. [Build](2026-09-07-release090-final-build.md), [dependency pins](2026-09-07-release090-merged-dependency-pins.md). |
| Numerical correctness | Retained combined-candidate evidence passes 93 focused functions, including 50 analytic SDPA cases, and 13 D256 cases with unchanged tolerances. The final runtime preserves that inference implementation; original runtime identities remain recorded. [D256 validation](2026-09-06-qwen36-candidate-d256.md). |
| B1/B2/B4 and memory lifecycle | All five artifacts have bounded concurrency coverage. Final Qwen 3.5/3.6 B2/B4 has 12 passing cells, 72 coherent main responses and 12 restored prefixes. Qwen generation also continues through GPT/QAT loads, grant shrink and cancellation/recovery. [Qwen concurrency](2026-09-07-qwen-concurrency-final.md), [retained models](2026-09-06-retained-model-validation.md), [QAT concurrency](2026-09-06-qat-concurrency-validation.md), [memory lifecycle](2026-09-06-coresidency-lifecycle.md). |
| Defaults and capabilities | Ten final default requests verify all five automatic paged backends and normal MTP policy; each Qwen repeat restores 4,096 SSD tokens. Four models pass seven tool/vision requests; Qwen 3.8 passes its final tool/vision cases in routing. [Defaults](2026-09-07-final-defaults.md), [capabilities](2026-09-07-final-capabilities.md). |
| Answer-quality investigation | All 12 arithmetic observations complete correctly. Contiguous controls reproduce the observed code concerns; all eight GPT code/prose outputs match their paged counterparts exactly. These bounded investigations find no migration-specific cause for those concerns. Failed or capped answers remain recorded. [Quality follow-up](2026-09-07-five-model-quality-followup.md), [GPT control](2026-09-07-gpt-contiguous-quality-control.md). |
| Sustained generation | The three Qwens and GPT pass the 2,048-token long-workload gate. QAT's combined evidence establishes sustained paged exposure and actual B1 geometry, while both exact-main-target failures remain preserved. [Five-model workload](2026-09-07-five-model-sustained-final.md), [QAT combined assessment](2026-09-07-qat-sustained-followup.md). |
| Functional cache routing | Both cache-off and SSD phases pass all ten cases with two isolated providers: donor/repeat, tenant isolation, continuation/original branch, tools, vision, cancellation/recovery and unavailable-sidecar fallback. Separate coordinator tests cover stale, expired, disconnected and revoked cache evidence. [Final routing](2026-09-07-final-cache-routing.md). |

Generated-token equality is diagnostic, not universal acceptance. The original strict failures, QAT B1 proposal-certainty caveat, generated-code errors and literary inaccuracies remain visible. These tests establish bounded inference, cache and lifecycle behavior; they do not establish universal model quality or cross-machine routing performance.

## Review and release dependencies

The parent change is [d-inference #851](https://github.com/Layr-Labs/d-inference/pull/851). Its dependency PRs [mlx-swift #21](https://github.com/Layr-Labs/mlx-swift/pull/21) and [mlx-swift-lm #141](https://github.com/Layr-Labs/mlx-swift-lm/pull/141) are ready for review. The MLX and mlx-c changes are merged; pins are `6005bca7a3ee99f81c043299b1f73327d3755c9c` and `9aaf7ff4fb0c2f13b7894d1f7c556850e891559b`. All existing review threads on the three open PRs were resolved at the final review check.

The test-logging commit `dbf2b73cf` passes the [core CI](https://github.com/Layr-Labs/d-inference/actions/runs/34076554842) and [integration](https://github.com/Layr-Labs/d-inference/actions/runs/34076554859) workflows. Later evidence commits are checked by the same workflows; their live status belongs to the PR. The separate threat-review job requires repair of its invalid API credential. No credentials, review requirements or signing workflows were changed here.

The remaining runtime release gate is production-key SSD restoration after a new process starts, for the three Qwens, using the accepted signed candidate and intended Keychain access group. Ephemeral-key tests cannot establish that behavior. The signed candidate is not yet available to this work. Human review, merge, signed release construction, publication and production routing activation remain separate actions; no default branch, release registration or production deployment was changed.
