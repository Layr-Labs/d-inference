# Final Qwen 3.5 and 3.6 concurrency checks

> Last updated: 2026-09-07 · commit `363117ca7`

Both Qwen models pass the final batch-size 2 and 4 comparisons on the verified 0.9.0 runtime. All 12 cells execute their required forward widths; all eight backend/cache comparisons pass structural checks. The 72 main responses finish naturally and preserve the requested summary's meaning despite wording differences.

## Results

Each model and batch width runs contiguous attention with cache off, paged attention with cache off, and paged attention with SSD on. Normal embedded MTP and production memory admission remain enabled.

| Model | Batch width | Backend comparison | SSD comparison | Main warm restores |
| --- | --- | --- | --- | --- |
| Qwen 3.6 | 2 | Pass | Pass | 2 × 5,120 tokens |
| Qwen 3.6 | 4 | Pass | Pass | 4 × 5,120 tokens |
| Qwen 3.5 | 2 | Pass | Pass | 2 × 5,120 tokens |
| Qwen 3.5 | 4 | Pass | Pass | 4 × 5,120 tokens |

All 12 main warm requests perform real authenticated restores, saving 61,440 prefix tokens in total. Separate controls also exercise tenant isolation, cancellation and recovery. Active requests, active tokens, KV in-use bytes and KV reservations return to zero after shutdown. Every owned process retires; a fresh host observation confirms no remaining test processes.

The foreground run completes in 1,003 seconds. Collection verifies 516 selected original files against the full manifest. Forty-four encrypted cache files remain in the original remote archive, whose owner-recorded hash and size are retained. The exported projection does not claim to rehash that full 5.62 GB archive or preserve its original file modes.

## Wording and scope

Generated-token comparisons use explicit record mode. Original differences remain visible, and strict token equality is not reported as passing. The 72 main responses contain six distinct texts, each retaining the proposed infrastructure work and the council's request for costs, schedules and downstream-user risks. None introduces a material change to that fixed summary task.

This closes the outstanding Qwen 3.5/3.6 B2/B4 structural comparisons and the bounded semantic review of this workload. It does not establish general model quality, long-generation performance, connected routing or durable production-key restart. The earlier strict stopped run remains a separate failed experiment; its results have not been relabeled.

The source and runtime identities remain those of the [verified final candidate](2026-09-07-release090-final-build.md). The later [merged dependency pins](2026-09-07-release090-merged-dependency-pins.md) preserve its selected inference implementation.

## Evidence

The [result summary](evidence/qwen-concurrency-final-2026-09-07/evidence.json) records every cell, response lengths, main warm hits, original collection identity and manual review. The [archive](evidence/qwen-concurrency-final-2026-09-07/evidence.tar.gz) contains original reports, inputs, metadata, retirement and collection records; its [manifest](evidence/qwen-concurrency-final-2026-09-07/manifest.json) binds all selected members.

Related: [original Qwen concurrency diagnosis](2026-09-06-qwen36-concurrency-diagnosis.md), [acceptance criteria](../design/release-090-acceptance.md).
