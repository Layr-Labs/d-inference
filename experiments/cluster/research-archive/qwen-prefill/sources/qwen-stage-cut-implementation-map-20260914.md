# Smallest 12/20 correctness experiment

Source-only review, 2026-09-14. No native execution, compilation, model payload reads, SSH, or repository changes were performed for this map.

The smallest first step is optional `--stage-cut 12` on **`qwen-layer-stage-compare` only**. Use its fresh same-source full baseline and existing sequential comparison. No new request profile, transport, external-reference parser, or numerical tolerance is needed.

## Short-path change surface

All Swift paths below are relative to `experiments/cluster/inference/Sources/ClusterInference/`.

| Location | Existing behavior | Minimal proposed change |
|---|---|---|
| `Options.swift`, original-mode validation | No split selector | Optional integer cut; reject its presence for every other original mode before dispatch/adapters. Keep omission behavior unchanged. |
| `QwenLayerStageComparisonAdmission.swift:40–42` | Requires even layer count and constructs equal halves | For an explicit cut, check `0 < cut < layers` before constructing Swift ranges, then call the existing `QwenLayerStagePlan` with `[0..<cut, cut..<layers]`. Keep the historical even/half branch when omitted. |
| `QwenLayerStageComparisonAdmissionCheck.swift` | Existing pure admission checks | Add accepted 32-layer cuts 12 and explicit 16, omitted-default identity equality, and rejection of zero/end/out-of-range/unaligned cuts and use outside the compare mode. |

**Scope trap:** rank, lookahead, prefill, prefill-rank and solo admission adapters reuse comparison admission by rewriting `Options.mode`. For example `QwenLayerStageRankAdmission.swift:36–43` and `QwenLayerStagePrefillAdmission.swift:19–22`. A check only inside comparison preflight cannot establish the original CLI mode. Reject the new flag before those rewrites; do not silently propagate it into those modes.

## Already reusable without split changes

- `QwenLayerStagePlan.swift:68–72` admits two contiguous nonempty ranges covering all layers, each at least one attention interval and starting at an interval boundary. A 32-layer, interval-4 model admits 12/20. It intentionally does not require an otherwise legal final model end to be interval-aligned. Global-to-local names and layer kinds follow the actual ranges.
- `PreparedQwenLayerSource.swift` and `VerifiedQwenLayerStageLoading.swift` retain pinned source descriptors, validate exact canonical shapes/dtype classes, require complete disjoint ownership across both stages and preserve actual plan/config/layout/storage identities. They contain no 16-layer requirement. Full widths/heads and stored parameter bytes are unchanged by moving the cut.
- `QwenLayerStageComparison.swift:43–74` records the full baseline using `inputs.plan`, retires/releases it before either stage loads, then loads and compares those exact stages. A new candidate gets a new plan-bound baseline receipt while its full-model arithmetic remains unchanged. Historical reference fingerprints need not be changed.
- `QwenLayerStageSession.swift:49–83` derives compact layer/cache geometry from the actual stage and plan. `QwenSequentialStagePair` owns the copied residual handoff and ordered commits.
- `QwenLayerStageRecordedEvidence.swift:44–93` derives the complete global component set from all plan layers, rejects missing/duplicate coverage, and compares state metadata and SHA digests exactly. It has no per-half count of 36. For 12/20 the stage inventories are 27/45 components; their full-model union is still 72.
- `QwenLayerStageRecordedComparison.swift:44–101` compares every frame/frontier and full-vocabulary row. `QwenRecordedLogits.requireExact` also compares private native CPU bytes directly, including signed zeros. Model/request cleanup and failure propagation already exist.

Keep existing artifact/request gates: dense Qwen only, MTP off, native arithmetic and CBv2; prompt <=128, chunk <=32, outputs <=4, teacher IDs for continuation, one repeat/zero warmups, <=180 seconds. The comparison's <=512 MiB named state/snapshot/two-boundary estimate uses the original whole-model geometry and is independent of the cut. Preserve verified loader limits of 8 GiB manifest payload, 6 GiB canonical source and 512 MiB largest host tensor. These are not total process/workspace memory guarantees; keep the guarded launcher's OS resource observations and cleanup.

## Meaningful qualification

First add pure admission negatives plus one focused unequal tiny fixture (for example 12 layers split 4/8; the historical 8-layer fixture cannot form unequal legal interval-4 stages). Reuse the existing loader ownership and recorded comparison checks: all active tensor bytes, global state coverage, per-frame frontiers, raw output rows and retirement. Keep the old fixture unchanged or make the new geometry an explicit separate case.

Then root can run the registered 9B short comparison with the saved 65-token prompt, chunk 32, four outputs and the same three teacher IDs. This yields six completed frames, final frontier 68, 72 state components at every frame, and four exact full-vocabulary rows against its fresh full baseline. Require actual 12/20 load ranges and common source/plan/storage identities in the saved report. An omitted/default 16/16 control in the same binary checks preservation. This qualifies a bounded numerical path, not a faster cut, 8K execution, physical transport or target-hardware performance.

## Later 8K work is separate

If short correctness passes, the additional 8K split-specific sites are:

1. `QwenLongPrefillReferenceAdmission.swift:45`: constructs 16/16.
2. `QwenLayerStageProfiledComputeAdmission.swift:17,24`: exact half ranges and `loaded.layerCount == 16`.
3. `QwenLayerStageProfiledStateDigest.swift:36`: `expected.count == 36`; replace only within explicit candidate admission with a count derived from the actual stage's exact component inventory.
4. `QwenLongPrefillPairAdmission.swift:15`: reference plan must equal candidate plan. Reusing an archived 16/16 reference requires recording its unchanged reference/plan identity separately from the candidate's plan/storage identities. A fresh candidate-plan reference avoids that parser/identity expansion.

Other 8K `16` checks count 512-token prompt frames and stay unchanged. Original 32 layers, source count 927, BF16 dtype/shape, 72-component union, final state 319,946,784 bytes and the registered 745,345,056-byte named-tensor estimate are artifact/request-wide. v4 already binds actual plan and both stage/config fingerprints; moving a cut does not require changing old wire domains or the `long_prefill_8k_v1` token geometry. No current long-mode admission should broaden as a side effect of the short option.
