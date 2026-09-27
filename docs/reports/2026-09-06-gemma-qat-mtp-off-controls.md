# Gemma QAT matches across backends with MTP disabled

> Last updated: 2026-09-06 · commit `bc1819129`

Both real-model MTP-off controls pass execution and integrity checks, and the
unchanged strict backend comparison passes. All seven completed trajectories
have exactly equal prompt/output IDs, counts, finish and outcome. The earlier
[normal-MTP backend failure](2026-09-06-gemma-qat-actual-logits.md) remains open.

## Controls and result

The experiment uses the same optimized probe as the normal-MTP diagnostic run:
parent `6790dea1c7044ca336cd6383aac7e6d27afb7359`, native
`b01e1af06902c82e22227bf923447cc71c47b148`, executable SHA-256
`3de3086d924e38893c31583f47309f3345733364956e0972287fa1ef7a6966c7`.
The same QAT4 Gemma artifact, input, output cap 128, B1, cache-off setting and
production KV grant are retained. MTP is explicitly disabled; logit and
attention diagnostics are disabled. Two sequential fresh processes run
contiguous then paged attention on the M5 Max.

| Observation | Contiguous | Paged |
|---|---:|---:|
| Prompt tokens, both main rows | 5,418 | 5,418 |
| Completion tokens, both main rows | 61 | 61 |
| All completed trajectories compared | 7 | 7 |
| Execution and integrity | Pass | Pass |
| Strict backend comparison | Pass | Pass |

Tenant checks, the completed cancellation donor and recovery all match exactly.
Each canceled output is a prefix of its own recovery. Cache outcomes remain
`disabled`; this experiment makes no prefix reuse claim.

[INFERENCE] The contrast with the retained normal-MTP result narrows the
observed divergence to a condition present during speculative execution.
It does not establish whether the underlying cause is verification arithmetic,
state handling or another difference between those execution paths. The
normal-MTP comparison, broader model quality and release acceptance remain
separate gates. One sequential pair is not a repeated performance result.

## Validation and evidence

The two native/wrapper runs exit 0. Five local CPU checks pass after a
source-only correction to the expected report label, `off; no drafter supplied`.
The earlier controller using `off` is preserved; it was corrected before any
model run. Eleven unchanged wrapper tests pass on M5. Every cell verifies
runtime/source/input/model identities and original host readiness guards.
Final postflight shows no owned jobs, GPU 29.268 degrees C, load1 1.134 and
350,691,917,824 free bytes. No defaults, daemons or key namespaces changed.

The [manifest](evidence/gemma-qat-mtp-off-2026-09-06/manifest.json) and
[archive](evidence/gemma-qat-mtp-off-2026-09-06/payloads.tar.gz) retain 117
payloads: both raw cells, strict comparison, analysis, exact controls and
bindings, preserved label correction, transfer receipts and reviews. The
previously banked runtime is referenced by its source/artifact identities;
executables, runtime resources, weights and key material are excluded.

Manifest SHA-256: `1231b68f617da9d9d70dd0839a355f52a8311dae4a7886d84d26d49bd368ce25`.
Archive SHA-256: `08337a0833d22e0aca3b7c2e45d88db55fe45418ce08e6a40fbe1616a8131fd2`
(173,856 bytes).
