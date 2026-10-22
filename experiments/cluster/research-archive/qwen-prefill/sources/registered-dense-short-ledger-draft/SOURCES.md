# Source basis and limits

All file bytes below are pinned by `source-pins.json`; line numbers refer to that
snapshot. These are local primary implementation sources. No model payload, new
header, candidate output or runtime observation was needed for this ledger.

| Term | Existing primary source |
|---|---|
| Exact model/config/manifest/tensor identity; both models have 4 KV heads | `QwenRegisteredDenseModelProfile.swift:44` and `QwenDenseRegisteredSpecification.swift:26`; shared retained metadata is independently pinned. |
| Actual prompt/teacher history and two output rows | `QwenLayerStageRecordedRequest.swift:19`; Schedule produces widths 2/1/1 and frontiers 2/3/4. |
| Capacity is prompt+output, not final committed frontier | `CBv2OwnedRequestState.swift:20`; `ContiguousKVBackend.swift:328` reserves min(maxLength,prompt+initialSlack). Here maxLength is 5. |
| BF16 conv and F32 SSM shapes | `Qwen35.swift:830` reads/stages CBv2 rows; missing conv uses input dtype, SSM uses Float32. `CBv2RequestGeometry.swift` captures config dimensions. |
| State copy behavior | `CBv2OwnedStateSnapshot.swift:34` captures each component's Data and keeps it only with includeBytes true. `QwenLayerStageRecording.swift:34` and `QwenLayerStageRecordedComparison.swift` pass false. |
| Three-generation F32 state allowance | `QwenLongPrefillTensorBudget.swift:86`, freshly calculated with maximumTokens 5 and chunkSize 2; it excludes weights and native scratch. No 8K result is renamed. |
| GDN fusion creates and evaluates three concatenated arrays | `Qwen35.swift:409`, then named views replace projections. `QwenDenseStorageRequirement.swift:89` checks 12 source tensors per recurrent layer and their byte sum. |
| GDN short workspace shapes | `Qwen35.swift:493` fused projection rows and `Qwen35.swift:535` convolution input. Further recurrent kernel intermediates are not bounded by this inventory. |
| Attention projections and score fallback allowance | `Qwen35.swift:1193` produces Q+gate, K and V. Two dense [1,Q,2,5] matrices are an operational fallback allowance, without proving either exists in the selected kernel. |
| Hidden and dense MLP expressions | `Qwen35.swift:1525` computes norms, attention/recurrent output and residuals. `Qwen3Next.swift:122` computes gate, SiLU, up and product. Charged F32 shapes are not complete graph liveness proof. |
| Native and CPU final row copies | `QwenLayerStageRecordedLogits.swift:28`: copied original row, evaluated F32 cast, finite Swift Float array. Baseline retains original bytes plus values; candidate comparison keeps record values. Two complete rows are captured. |
| Pair boundary copies | `QwenLayerStageBoundary.swift:22` copies a residual and compares Data from original/copy. Two arrays plus two CPU copies are widened to F32. No cross-process transport exists here. |
| Actual allocator integration | `libs/mlx-swift/Source/MLX/AllocationFootprint.swift:10` bounds one buffer under current allocator rules; graph inputs/scratch need separate bounds. Arithmetic cannot verify the callback's provenance. |

This is metadata/source compatibility. Actual constructors, verified descriptors,
loaded BF16 arithmetic, full model release before pair load, allocator policy,
live OS admission and numerical parity remain separate owner responsibilities.
Workspace/object/serialization unknowns remain unknown after a CPU fixture pass.
