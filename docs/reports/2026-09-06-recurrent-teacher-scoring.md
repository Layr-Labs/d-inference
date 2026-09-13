# Recurrent teacher scoring uses normal state and peak admission

> Last updated: 2026-09-06 · commit `8af245cc7`

The ordinary teacher-forced diagnostic now runs recurrent targets through
request-owned state on contiguous and paged storage. Its private row uses normal
admission's peak reservation and retires every owner before refunding capacity.
Seven focused suites pass 45 functions and 59 expanded cases. Exact fleet-model
reruns and release acceptance remain pending.

## Failure and correction

The Qwen3.6 scoring attempt reached the attention-only adapter invariant because
the helper omitted recurrent state. Normal serving already supplies that state;
this failure does not establish a production request failure.

Native `8344e8bdc44c57e09527467a5dc5c415a8f90010` factors the existing
recurrent forward dispatch and uses it for diagnostic prefill and forced-token
decode. Each call creates fresh state, evaluates its roots and commits after
the fence. Cleanup discards pending state, releases committed state and KV,
and restores the paged write-fault boundary.

Independent review found that the initial helper checked one recurrent
generation, while committed and pending generations can coexist. Native
`c3fd66987919c12f7d119104734c0347e95f080d` adds
`AdmissionV2.reserveUnscheduledRequest`, which reuses ordinary target pricing,
recurrent peak, allocator overhead, watermarks, external reservations and
physical-floor accounting. A call-owned lease keeps that obligation until
state and KV aliases retire. Ordinary scheduling and request admission remain
unchanged. The two commits integrate as native
`a834412931d7dadb8929b2b6b4f3365ccbc5e48b`, retaining the corrected dependency pin.

## Validation

| Suite | Functions | Expanded cases |
| --- | ---: | ---: |
| Teacher peak admission | 2 | 3 |
| Real tiny Qwen dense/MoE hybrids | 1 | 4 |
| Paged runtime dtype and open-binding faults | 2 | 8 |
| Ordinary teacher scoring | 8 | 8 |
| Score diagnostics | 6 | 9 |
| Paged admission | 11 | 12 |
| Recurrent state and lifecycle | 15 | 15 |

All selected suites execute without failures or skips. The last suite uses
XCTest; its 15 passing cases precede an empty Swift Testing summary. Root review
counts the frameworks separately. Tight-budget cases refuse before a model
forward when one generation fits but two do not. Larger budgets admit scoring,
and success, diagnostic failure and paged write faults leave no private
reservation or poisoned binding. Four real tiny hybrid cases check forced
inputs, continuity, fresh-call state and ordinary greedy equivalence.

Tests use MLX Swift `c06149b4f7defa1b958c1e175f6c9a12c86c8a4f`, core
`fab0f39f69140393b454c32d6f4bf7a9b32f9dcc` and the corrected metallib
`1c8e612c9c54e8652669c582aad6124438c77f1dce2dc0b1eb50dce1bf083565`.
Root verifies 936 canonical files, 937 files in the compiled snapshot, the
changed source, test logs, binary and metallib. The compiled snapshot's local
dependency-path override is retained separately.

The relocated module-cache failure and the fixture's initially missing native
dtype table remain preserved. The corrected hybrid fixture obtains its dtype
table from the real model with fresh caches; the synthetic fixture declares its
known BF16 storage. No numerical or lifecycle assertion is removed.

## Evidence and limits

The [manifest](evidence/recurrent-teacher-scoring-2026-09-06/manifest.json) and
[archive](evidence/recurrent-teacher-scoring-2026-09-06/payloads.tar.gz) retain
38 payloads: source, patches, failed and passing logs, compiler provenance and
independent reviews. Build products and model weights are excluded. These tests
do not establish full Qwen3.6 scoring, cross-backend model quality, concurrent
fleet-model throughput or production readiness. Follow the
[diagnostic procedure](../developer/test.md#ordinary-teacher-forced-score-diagnostics)
for the exact-model rerun.
