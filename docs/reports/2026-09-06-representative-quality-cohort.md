# Representative quality cohort preparation

> Last updated: 2026-09-06 · commit `ffe365029`

The prepared cohort contains 12 logical prose, code and reasoning cases for all six fleet artifacts, including both Gemma formats. Each model/case has a serving input, teacher input and canonical token record: 72 of each. No model has run against this cohort, and no quality result is claimed.

| Input property | Bound |
| --- | --- |
| Short prompts | 324–574 tokens |
| Long prompts | 5,486–8,956 tokens |
| Teacher reference continuation | Exactly 64 tokens |
| Serving output cap | 128 for prose/code; 256 for reasoning |
| Planned backend pairs | 144 serving cells and 144 separate teacher cells |

Source revisions, licenses, original notices, hashes and deterministic selection rules are retained in the package. The cases use two Gutenberg texts, two CPython modules and two GSM8K questions at short and long context lengths. Selection consulted no model output. The custom reasoning subset is not an official benchmark score, and the separation check against listed local tuning fixtures makes no claim about model training data.

All 144 prompt/reference encodings match the pinned canonical sidecar's counts and complete-block hash plans. Full token arrays remain pinned to the exporter and require exact runtime matching; the sidecar does not independently expose tail-token IDs. Vocabulary and context-plus-cap checks pass. Static token bounds are not physical admission clearance.

Preparation passed 68 unique CPU checks in normal and optimized Python, including an extracted-archive rerun. ROOT independently verified all 307 package files, the archive hash, complete input loading and both 144-cell plans. Existing serving trajectory, lifecycle, identity and memory gates remain active. No new numerical tolerance is introduced.

Teacher likelihood stays separate from serving correctness. Its private eager path cannot become a serving oracle merely because likelihoods agree; ordered prefill geometry, kernel/dtype/recurrent paths and conditioned history need their own evidence. The known 11-versus-3 chunk mismatch remains an explicit refusal. The existing B1/B2/B4, sustained decoding, HTTP, signed restart and release gates are not replaced by this preparation.

The [evidence manifest](evidence/quality-cohort-2026-09-06/manifest.json) binds the complete executable package and preparation receipts. Runtime bindings remain unreviewed. The first staged model/case is GPT-OSS/Alice-short, with two serving cells and two teacher cells; it requires a fresh runtime binding and host review before execution.
