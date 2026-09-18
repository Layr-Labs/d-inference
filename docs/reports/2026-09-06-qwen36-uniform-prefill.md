# Qwen3.6 uniform-prefill concurrency control

> Last updated: 2026-09-06 · commit `2eebb5412`

One Qwen3.6 batch-of-two control passes the original strict per-index repeat comparison when all four requests use uniform 512-token prefill chunks. This is a diagnostic control, not acceptance of the production default or the complete concurrency matrix.

## Observation

Run `132-q36-uniform-prefill2` uses the unchanged [candidate104 runtime](2026-09-06-release090-candidate-build.md), exact model and original 5,523-token prompts, paged attention, normal embedded MTP and caching disabled. Its sole serving override is `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE=0`. The controller also pins the ordinary Apple Python launcher environment; an earlier attempt stopped at that environment check before loading the model and remains preserved.

| Request | Prefill chunks | Largest chunk | Output tokens | Finish |
|---|---:|---:|---:|---|
| First, index 0 | 11 | 512 | 82 | stop |
| First, index 1 | 11 | 512 | 78 | stop |
| Repeat, index 0 | 11 | 512 | 82 | stop |
| Repeat, index 1 | 11 | 512 | 78 | stop |

Each index repeats its exact token sequence. The two batch positions still produce different sequences despite identical prompts and prefill chunk sizes. Both summaries preserve the proposed status of the infrastructure work. The 78-token sequence matches the corresponding earlier trajectory; the 82-token sequence differs at position 58. Uniform prefill alone therefore does not imply one universal output sequence.

Both batches exercise actual width two. Cache use remains disabled with zero saved tokens. The unchanged cancellation, tenant isolation, accounting and cleanup checks pass. Full source, runtime and model audits match before and after execution; all owned processes retire.

## Interpretation and evidence

This result supports investigating scheduling and execution geometry when interpreting the [earlier failed repeat comparison](2026-09-06-qwen36-concurrency-diagnosis.md). It does not prove that prefill chunk size is the only cause of token variation, nor does it exercise SSD or validate a change to the production defaults. The earlier failure remains unchanged. The remaining Qwen batch and SSD cells must run separately.

The [summary](evidence/qwen36-uniform-prefill-2026-09-06/evidence.json) records the complete diagnostic result. All 305 collected original files were verified. The [capsule](evidence/qwen36-uniform-prefill-2026-09-06/evidence.tar.gz) retains the raw report, native environment, before/after audits, verdict and retirement evidence; its [receipt](evidence/qwen36-uniform-prefill-2026-09-06/archive.json) binds all 11 members.
