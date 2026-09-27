# Gemma QAT: retained B2/B4 continuation

> Last updated: 2026-09-06 · commit `2eebb5412`

Gemma4 26B QAT passes the four remaining retained concurrency cells: contiguous and paged at B2 and B4, with MTP and SSD disabled. All actual forward-width, production-grant, request completion, tenant isolation, cancellation, accounting and retirement gates pass. This completes the bounded retained width coverage started in the [earlier model matrix](2026-09-06-retained-model-validation.md); it does not establish release-wide acceptance.

The successor uses the same immutable runtime104/source manifest `e7b769e2713e48c53fb62fbe74e449bb409c8fc1b7e5f036b14e808a7c3da3f5`, original QAT model manifest, retained input and seven serving variables. Engine SHA256 remains `cc86a3328be98a498ea0dad077c7a6fd64add25aabe5ac7d9cba78bc93a11568`. Full source/model/runtime audits are identical before and after each of the four processes.

At each width, both long-first and long-repeat batches complete every request. All batch answers contain 61 tokens and agree exactly across the two backends. SSD outcomes are disabled with zero saved tokens throughout. B2/B4 are established by native forward telemetry, not merely request queue counts.

Both raw backend diagnostics remain false for the separately executed tenant, cancellation-donor and recovery answer comparisons. Contiguous says leak-detection methods “have been suggested”; paged says they “will be implemented.” The prompt describes proposed work, so the paged single-request wording overstates certainty. Both batched backends instead produce the “have been suggested” wording. These are cross-backend answer differences, not isolation failures within a run. The semantic-fidelity caveat remains for representative quality evaluation; this evidence does not isolate a numerical defect.

The separately reviewed continuation treats backend wording as diagnostic while keeping request/cache/accounting gates strict. Its four-cell scope passes, its raw diagnostics remain intact, and every broad release/performance gate remains false. The original 109 strict B1 failure is unchanged. There is no new SSD restoration, sustained-context, HTTP, routing or whole-release claim here.

The [selected evidence and identities](evidence/qat-concurrency-validation-2026-09-06/evidence.json), [original reports and verdict capsule](evidence/qat-concurrency-validation-2026-09-06/evidence.tar.gz) and [archive checksum](evidence/qat-concurrency-validation-2026-09-06/archive.json) declare the exact projection. All 134 files were collected and independently verified against original manifest `7decf91d3a7abeeaaa1e0265566c170475a047ae7c5f0bcc6b8bfbbeafb2a7c6`; 18 original files are selected for publication. Full audits and the sealed 6,876,692-byte archive remain retained. All owned groups retired, and the fresh host observation found no owned or unexpected jobs before lane release.
