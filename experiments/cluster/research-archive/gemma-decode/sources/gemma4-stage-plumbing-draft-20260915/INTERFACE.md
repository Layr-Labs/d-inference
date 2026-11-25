# Swift metadata interface

Eight new internal Runtime files add metadata plumbing. They do not alter the existing Qwen Plan, native adapter, resource admission or provider eligibility.

- `LayerStageTensorLayout` and `LayerStageSourceTensor` describe source shape, dtype, bytes and absolute location. They own no file descriptor or native array.
- `LayerStageTensorMapping` records one or two typed destinations. `LayerStageStorageConservation.validate` requires exact selected/excluded coverage, unique destinations, and an explicitly admitted tied-embedding replica group. It separates unique source bytes, replica bytes and per-rank destination bytes.
- `LayerStageCapturedTensorHeaders.parse` projects captured header/index bytes using the existing CheckpointManifest DTO and strict integer/JSON helpers. It performs no IO and cannot establish payload verification.
- `Gemma4ArtifactMetadata.admit` binds the exact retained configuration, manifest, index and three header hashes. Geometry and generated canonical tensor layouts must agree with all 1,339 text tensors; 358 vision tensors are excluded.
- `Gemma4LayerStagePlan(artifact:cut:)` admits every cut in `1..<30`. Its two `Gemma4StageConstructionDescriptor` values retain the original configuration bytes, global layer identities and local quantization tables. Its mapping explicitly replicates only the three tied embedding tensors.

The native adapter receives `originalConfiguration`, `rank`, and `sourceLayerRange`. Its module names must match each mapping's `localName`. Apply `localQuantization` only to the local module tree; do not replace the original 30-layer configuration. This preserves global native eligibility and ensures only rank 1/global layer 29 has final-output responsibility. The native candidate's `loadedEmbeddingOutputDType` is not a residual or KV dtype assertion.

Plan and conservation fingerprints use new identity domains. Existing Qwen fingerprint inputs and implementations are unchanged. All new metadata execution, payload-verification and actual-allocation flags remain false. Later native loading must bind verified descriptors, actual constructed inventories, measured KV dtype and resource admission before using this plan for execution.
