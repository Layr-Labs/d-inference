# Qwen3.6 B2 repeatability: failure tracks prefill geometry

> Last updated: 2026-09-06 · commit `2eebb5412`

The Qwen3.6 concurrency attempt stops on a strict per-request repeatability failure with SSD disabled. Both paged batches finish correctly and produce the same two answers, but those answers exchange request indices. The observed swap tracks 512- versus 2,048-token prefill chunks; this evidence does not isolate an SSD or numerical-kernel defect.

## Observed result

Run `127-qwen-concurrency2` schedules twelve original Qwen3.6/Qwen3.5 B2/B4 cells on the [reviewed candidate](2026-09-06-release090-candidate-build.md), runtime104 version `0.8.16`, with normal embedded MTP. The contiguous cache-off B2 cell passes. The next paged cache-off B2 cell completes but fails `completed_donor_repeat_output_mismatch`. The ten dependent cells remain unrun, including every SSD cell. The earlier `122` archive-layout setup failure is separately preserved; its corrected packaging does not change these inputs or runtime.

| Paged request | Prefill chunks / maximum tokens | Output tokens |
|---|---|---|
| First batch, request 0 | 11 / 512 | 78 |
| First batch, request 1 | 3 / 2,048 | 83 |
| Repeat batch, request 0 | 3 / 2,048 | 83 |
| Repeat batch, request 1 | 11 / 512 | 78 |

All four input token arrays are identical. The two output token sequences match exactly across their geometry-matched rows; the strict index-matched comparison fails at token 11. Both answer variants coherently describe the proposed water-infrastructure work. Every request stops normally; both batches complete two requests without failures, actual B2 overlap is observed, and SSD remains disabled with zero saved tokens. Cancellation donor and recovery follow the same 83-token trajectory. Accounting drains and all owned processes retire.

The contiguous control also varies with prefill geometry: its 2,048-token path produces 78 output tokens and its 512-token path produces 82. Its request indices retain their geometry on repetition, so its strict comparison passes. The benchmark submits task-group children independently; the scheduler assigns prefill work by arrival and active decode state. Per-request metrics establish the geometry/output correlation, but the run lacks an exact enqueue-to-forward trace proving scheduling causality. This remains a diagnosis, not a relabeled pass.

## Next control and evidence

Prepared control `131` keeps the exact Qwen3.6 B2 paged/cache-off input, runtime, output cap and normal MTP. Its sole environment change is the existing `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE=0` override. It requires all four requests to demonstrate 11 chunks with a 512-token maximum and retains strict repeatability, width and integrity checks. The control is unrun in this record; it changes no production default.

The [summary](evidence/qwen36-concurrency-diagnosis-2026-09-06/evidence.json), [original report/verdict capsule](evidence/qwen36-concurrency-diagnosis-2026-09-06/evidence.tar.gz) and [archive receipt](evidence/qwen36-concurrency-diagnosis-2026-09-06/archive.json) preserve the failure. Root independently verifies all 319 original files and both complete before/after source, runtime and model audit pairs. The capsule contains 13 original files plus the source-linked geometry diagnosis. No failed comparison, unrun cache arm or cleanup result is omitted from the status.
