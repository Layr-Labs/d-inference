# Gemma QAT same-state verifier diagnosis and serial-target release policy

> Last updated: 2026-09-06 · commit `2eebb5412`

**Default `mtp_mode = "auto"` already runs Gemma without MTP while enabling embedded Qwen MTP. The correction protects Gemma only when MTP is explicitly enabled; it does not add overhead to default-auto Gemma serving.**

The remaining Gemma QAT discrepancy is reproducible from one identical produced target checkpoint: ordinary one-token evaluation selects token 795 while rectangular verification selects 735. This is an uncached verifier-width numerical difference on contiguous attention. Earlier corrected controls establish the same mismatch on paged attention, while contiguous and paged agree within each verification mode. The production policy patch selects serial target verification for the exact QAT artifact while preserving assistant drafting and acceptance.

## Bounded diagnostic result

These controls explicitly force MTP on; they are not evidence that Gemma MTP is enabled by default. The M5 Max, 128 GiB run uses Gemma QAT aggregate `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`, B1, cache off, the production single-slot KV grant, the retained 5,418-token prompt and seven complete trajectories. The actual target window at output index 30 is `[4615, 735]`, starting at cache position 5,447.

Two detached cache banks contain identical 323,297,400 checkpoint bytes and matching metadata before either forward. The original cache remains unchanged after both forwards. The ordinary arm selects 795; rectangular column zero selects 735, with score bits matching the actual live confirmed decision. Fork instrumentation preserves all seven outputs, verifier counters and prefill geometry against the fresh trace-only control from the same runtime. All 784 capture records validate. The 4,131,423,404-byte transient reservation is released; the measured diagnostic interval of 781,855,959 nanoseconds is excluded from adaptive cost samples.

| Captured boundary in layer 0 | Differing elements | Interpretation |
| --- | ---: | --- |
| Embedding, layer input, input norm | 0 | Matched input to projections |
| Query projection / query norm | 1 / 1 | First observed arithmetic difference |
| Query RoPE, K/V projections, attention and attention residual | 0 | That query difference disappears before attention output |
| Dense MLP output | 8 | First observed difference that persists into the residual |
| Dense output norm / dense-expert sum | 5 / 1 | Expert branch and router match |
| Feed-forward residual / layer output | 1 / 1 | Difference reaches layer 1 |

This identifies captured model boundaries, not an individual internal kernel. The checkpoint copies preserve values and bookkeeping, not original allocation aliases or lazy-graph identity. It does not establish a quality regression, an SSD defect, or a paging-specific defect. It supplies direct evidence that changing the target evaluation width is enough to change this decision from the same produced state.

## Production change and validation

`providerMTPVerificationPolicy` selects `serialTarget` with rectangular capacity zero only for `gemma-4-26b-qat-4bit` when an assistant exists. The assistant remains enabled; target scoring runs one canonical token column at a time and retains the existing acceptance/rollback implementation. Gemma 8-bit, GPT-OSS and Qwen policy are unchanged by this patch.

Explicit offline Gemma verifier controls obtain the bounded automatic baseline before `EngineV2BenchmarkMTPVerification.applying` validates their target and assistant. Existing checks still reject conflicting required verifier modes. This retains the failing rectangular diagnostic path for future arithmetic fixes. Policy and override regression tests cover exact artifact selection, other artifacts, missing assistants, bounded automatic diagnostics and required-mode protection. Syntax parsing and whitespace validation pass; compiled tests belong to the combined candidate validation.

The fresh same-runtime ordinary/serial-target pair passes execution-integrity checks and exact token IDs, counts and finish reasons for all seven complete trajectories. Each main completion contains 61 tokens. Cancellation/recovery and tenant trajectories also match. This validates the selected serial verification algorithm; the new production selection policy still needs its rebuilt candidate checks.

The existing `mtp_mode = "auto"` default activates only embedded Qwen-family heads; it already leaves Gemma target-only. Gemma assistant activation requires explicit `mtp_mode = "on"`. The new serial policy therefore protects explicitly enabled Gemma MTP; it does not force drafting or its overhead onto default-auto Gemma serving. Retaining default-auto is the recommended release setting: Qwen keeps embedded MTP and Gemma uses the faster ordinary path.

Serial target verification executes each target column separately and synchronizes it before the next. It loses rectangular target amortization and adds assistant work. The timings below are single ordered B1 observations, not a sustained-throughput acceptance result.

| Current-runtime request | Ordinary TTFT / decode / total | Serial-target TTFT / decode / total |
| --- | --- | --- |
| First | 1.084 s / 104.89 tok/s / 1.658 s | 1.060 s / 70.29 tok/s / 1.914 s |
| Repeat | 1.063 s / 105.04 tok/s / 1.637 s | 1.053 s / 70.23 tok/s / 1.908 s |

For the 60 tokens after the first delta, decode takes 0.571–0.572 seconds ordinary and 0.854 seconds serial. Serial decode throughput is about 33% lower, while complete request time is 15–17% longer for this prompt/output length. These are explicit-on costs; they are not a regression in the default-auto configuration.

## Source and evidence

The diagnostic runtime is parent `bed15273704a6bc6c632381f61a08439ea7a425b`, native `463fa1b1bf6f81ec2cd136ed5cf3f42b14e85978`, Swift `9561227d55a07db29f70a78aadc5d6b5aaeb10bf`, core `fab0f39f69140393b454c32d6f4bf7a9b32f9dcc` and C `d4328f2d8d54d711d5419e07ab9fa2f07b512a48`. Eight runtime files verify locally and before/after remote execution. The native executable SHA-256 is `5e2dae24a43e3c9f6605a1068605ed43367a85449677d33245085f9f3f17d43f`. The full source/runtime identity, seven serving flags, model/assistant hashes, command identities and comparison summaries accompany the share-safe evidence capsule. It contains no weight tensors, checkpoint contents, executable packages or keys.

The first staging attempt stopped before any model launch because a Python evidence module was omitted. The completed fresh control initially received `invalid_control_scope` because a copied legacy validator expected report schema 2 while this runtime emits schema 3. The original receipts remain unchanged. A separate review corrects only that expected version and revalidates every existing identity, lifecycle, memory and numerical check. The fork and subsequent controls use the corrected validator in fresh directories; neither failure is hidden or counted as a model pass.

All native and telemetry process groups retire. Final M5 observation at 20:40:32 UTC reports no owned or foreign processes, GPU 29.95°C and load 1.48; the lane is released for the combined-candidate build.

The [evidence manifest](evidence/gemma-qat-state-fork-2026-09-06/manifest.json) and [capsule](evidence/gemma-qat-state-fork-2026-09-06/payloads.tar.gz) retain the share-safe projections and original-report hashes.

Raw evidence roots are `/private/tmp/darkbloom-gemma-fork-execution2-090`, `/private/tmp/darkbloom-gemma-fork-execution3-090` and `/private/tmp/darkbloom-gemma-serial-execution-090`. The original [corrected backend controls](2026-09-06-gemma-qmv-controls.md) and [separate-run logit traces](2026-09-06-gemma-contiguous-logit30-traces.md) remain independent evidence.

This work closes the observed B1 verifier-output discrepancy for the serial-target shipping configuration. It does not certify the new production default in a rebuilt candidate, B2/B4, long-context quality, shared-memory pressure, HTTP operation or acceptable sustained performance. Gemma SSD caching and Gemma 8-bit are outside the requested release scope.
