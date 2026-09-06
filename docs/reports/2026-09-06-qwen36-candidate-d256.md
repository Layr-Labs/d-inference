# Qwen3.6 candidate passes existing D256 numerical gates

> Last updated: 2026-09-06 · commit `2eebb5412`

The combined correctness candidate passes all 13 existing Qwen3.6 D256 precision cases without changing their tolerances. This validates the tested single-query attention geometry and fault detection independently of the separate full-model wording comparison.

## Checks and results

The unchanged `CBv2PagedKernelTests` runs three functions: six BF16/FP32 long-history cases at 4,094, 5,523 and 5,585 tokens; six planted boundary/GQA-head fault cases; and one wider-query reference diagnostic. All pass, with no skipped tests, in 5.757 seconds. Fixed and segmented paged storage retain exact output and complete KV equality.

Paged BF16 relative L2 error against the original-query FP32 reference is approximately 0.00162–0.00170. The existing reference-relative error limit is 0.01; the separate elementwise and contiguous-relative assertions remain unchanged. Missing salient entries, swapped GQA groups and shared output drift are rejected by the existing fault controls. The wider-query diagnostic retains both original and narrowed-query references, rather than treating query rounding as reference accuracy.

## Build and evidence

A fresh canonical SwiftPM native test build uses the [reviewed candidate](2026-09-06-release090-candidate-build.md)'s exact local Swift/core sources and metallib. The native source inventory is unchanged except for a test-package dependency projection to those reviewed sources and 36 exact remote dependency revisions. Every checkout is clean and pinned before compilation and after testing. The compiled graph includes the real SDPA implementation and unchanged paged kernels, reference and tests. Source and runtime artifact audits remain identical before and after execution; all three owned resolve/build/test process groups exit zero and retire completely.

The [result](evidence/qwen36-candidate-d256-2026-09-06/result.json), [raw test log](evidence/qwen36-candidate-d256-2026-09-06/test.log) and [independent checks](evidence/qwen36-candidate-d256-2026-09-06/proof.json) retain the scoped evidence. These tests do not establish full-model answer quality, MTP verification-width equivalence, SSD restoration or release-wide acceptance. The [normal-MTP model comparison](2026-09-06-qwen36-candidate-logits.md) remains separately recorded.
