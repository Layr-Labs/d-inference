# Fixed-context scoring completes on Qwen3.6 and Gemma QAT4

> Last updated: 2026-09-06 · commit `b7e95f890`

All four real-model scoring cells complete after the recurrent-state and peak
admission correction. The same forced contexts produce matching argmax choices
at 81 of 83 Qwen3.6 positions and all 61 Gemma QAT4 positions. Full score records
remain mostly different across backends. These are valid diagnostic observations;
numerical acceptance and release readiness remain open.

## Inputs and runtime

Each model uses one retained prompt/continuation pair on the M5 Max with 128 GiB
RAM: Qwen3.6 has 5,523 prompt tokens and 83 forced tokens; Gemma QAT4 has 5,418
and 61. These positions are not independent quality prompts. Both backends use
the same input bytes, seven explicit serving settings and production KV grant,
with caching off, MTP off, one request and no resident-prefix allowance.

The canonical runtime is parent `38b674d53267018df35338bc4acee176de45c853`,
native `a834412931d7dadb8929b2b6b4f3365ccbc5e48b`, MLX Swift
`c06149b4f7defa1b958c1e175f6c9a12c86c8a4f` and core
`fab0f39f69140393b454c32d6f4bf7a9b32f9dcc`. The CLI hash is
`e812330b54c144d652acdfd50024f34fac7dcf40f7606f254818132268d5a11e`.
Its source includes the [recurrent scoring fix](2026-09-06-recurrent-teacher-scoring.md).
The original Qwen failure (PID 44303) remains unchanged, and no completed cell
is relaunched.

## Observed scores

| Model | Argmax differences | Identical complete records | Contiguous mean forced-token NLL | Paged mean forced-token NLL |
| --- | ---: | ---: | ---: | ---: |
| Qwen3.6 35B | 2 / 83 | 4 / 83 | 0.220221462 | 0.228223663 |
| Gemma 4 26B QAT4 | 0 / 61 | 1 / 61 | 0.240459161 | 0.234078548 |

NLL is measured against the retained forced continuation; it is not a task
accuracy score or an independent quality benchmark. All logits and score records
are finite. Each backend's plain, diagnostic and repeated-diagnostic results
agree, and all three passes execute the same number of prefill/decode forwards.
Qwen executes 11 prefill chunks and 82 forced-token forwards per pass.

Qwen's two differences are zero-based indices 53 and 59, at context lengths 5,576
and 5,582. At index 53, contiguous scores tokens 7244 and 2919 at 26.875 and 26.75;
paged ties both at 26.875 and chooses 2919. At index 59, contiguous scores tokens
26533 and 10897 at 21.75 and 21.5; paged ties both at 21.625 and chooses 10897. These BF16 ties explain
the selected IDs given the observed logits. They do not explain the upstream
numerical difference or establish that it is harmless.

## Integrity and limits

All four native processes exit 0. The recorded release check finds none of the
26 owned controller, probe and model PIDs still running. Staging verifies all
eight runtime files; remote checks retain model/config/runtime identities and
retirement receipts. Root independently verifies 170 result files and 38 controller
files, then rechecks report structure, exact forced contexts, finite score bits,
runtime identity and plain/diagnostic/repeat agreement. Model weights are not
copied or rehashed by that local review.

The [manifest](evidence/teacher-context-scores-2026-09-06/manifest.json) and
[archive](evidence/teacher-context-scores-2026-09-06/payloads.tar.gz) retain 210
payloads, including raw observations, inputs, execution code and independent
review. Existing thresholds and comparators remain unchanged. These observations
do not certify model quality, compiled-serving or speculative-forward
paths, SSD-hit equivalence, B2/B4 execution, long-run memory behavior or the full
release. The [same-input attention replay](2026-09-06-qwen36-owner0-operator-replay.md)
provides separate operator evidence for the numerical investigation.
