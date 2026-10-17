# Nemotron 3.5 Lightning as a two-stage layer pipeline

> Last updated: 2026-10-09 18:10 UTC (branch `work/nemotron`, base `e15f5b891`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and
reports are outside the repository in the task's evidence folder
`nemotron-20261009`; its `STATUS.md` lists every ladder step with the file
that shows it. Nothing here was pushed.

## Status

The model ran across the two Macs at one cut (25) on one short request, in all
three modes, with the single-Mac reference's tokens. Everything after that in
the order of proof was not run: the work was stopped for a handoff at 18:08 UTC.

| Step | Result |
|---|---|
| Model-free checks (script checks, provider checks) | passed |
| Unit tests of the two Nemotron suites (10 tests: registered admission; a synthetic model through Plan, construction, state and stage forward against the complete model) | passed |
| Full library and worker unit suites | built, **not run** |
| SDK seam test | **not compiled, not run** |
| A. Stage load and release at cut 25: rank 0 on Mac A, rank 1 on Mac B (and each other rank) | passed; memory back to baseline |
| B. Staged reference on Mac A, twice | passed: `exact` |
| C. Two workers on Mac A over the local test socket, pipeline | passed: `exact` against B (not a hardware pass) |
| D. Across the cable: preflight; pipeline, pipeline-compact, phase-split | passed: ranks agree, tokens equal B in all three |
| D. Rank 1 ended with SIGTERM mid-decode | passed: rank 0 exited by itself, no worker left, memory back on both Macs |
| Second cut, 4,096 and 8,192 prompt tokens, Mac B's reference, each Mac alone, other local-socket modes, product comparison | **not run** |
| Block cost probe on Mac A | **not run** (Mac B's is measured) |

## Artifact

| Field | Value |
|---|---|
| Runtime model ID | `registered_nemotron35_lightning` |
| Catalog model ID, version | `nvidia-nemotron-3.5-lightning`, `2026-09-30-r1` |
| R2 prefix | `v2/nvidia-nemotron-3.5-lightning--ed925578dfaf/2026-09-30-r1` |
| Manifest SHA-256 | `7a3486d633ae181dbdf0e955e24e10a143de86cdf1e91cfb3345f7978a0b4e8a` |
| `config.json` SHA-256 | `c75cadc4b4ddff18c8f84d24584092528f9ffc3b723a4bcf29c3c51505dd5643` |
| Aggregate SHA-256 | `366d9285ec367633c25b5c064ad94482e04be043c2a515a16e4fcf12c0a8f85b` |
| Files, bytes | 10 files, 19,059,595,830 bytes |
| Text tensors | 729 tensors, 18,290,661,248 bytes (the 34 tensors of the artifact's `mtp.` head, 751,635,200 bytes, belong to no stage) |

The runtime needs a flat directory of real files with the catalog manifest as
`manifest.json`. The night benchmark's cache entry for this model is a
directory of links into an external volume, so it cannot be cloned in place:
copy the files, then hash them against the manifest.

## The model as two stages

52 blocks, each `x + mixer(norm(x))` with one mixer, in the pattern
`MEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEMEM*EMEMEMEME`: 23 Mamba2 blocks
(`M`), 23 mixture-of-experts blocks (`E`, 128 experts, top 6, one shared
expert) and 6 attention blocks (`*`, no RoPE). Only the residual crosses a cut.

| Block | Request state | Bytes on disk |
|---|---|---:|
| Mamba2 | convolution history `[1, 3, 6144]` in the activation dtype, SSM state `[1, 64, 64, 128]` in float32 | 41,201,792 |
| Attention | keys and values `[1, 2, T, 128]` in the activation dtype | 24,864,000 |
| Mixture of experts | none | 730,324,736 |

- **Stage construction.** A stage is the product class `NemotronH35Model`
  constructed from the artifact's configuration with `layers_block_type`
  sliced to the stage's blocks, the quantization table re-indexed, and the
  speculative head's declaration removed. Stage 0 keeps the embedding and
  replaces `norm_f` and the head with bounded placeholders; stage 1 keeps
  `norm_f` and the head and replaces the embedding.
- **SDK seam.** The product class refused a residual input, exported its
  hidden state only after `norm_f` and kept its trunk private. The local SDK
  branch `darkbloom/nemotron-stage-seam` adds two entry points,
  `cbv2StageResidual` and `cbv2StageLogits`, on `NemotronHModel`. The serving
  entry points are unchanged. See "What changed".
- **Cuts.** A cut is structural when each stage keeps an attention block (the
  loader proves a stage's KV dtype from one) and the cut is beside an expert
  block: 32 cuts, 6 to 41 without 12, 19, 26 and 33. The resident row lists
  the sixteen that directly follow an expert block (7, 9, 11, 14, 16, 18, 21,
  23, 25, 28, 30, 32, 35, 37, 39, 41), which is also the most partitions a
  capability record carries.
- **State and budget.** A Mamba2 block's state has the shapes the shared
  budget already derives for a recurrent layer, so the budget geometry gained
  only a way to name its state-bearing layers by count (6 attention, 23
  recurrent of 52) instead of by an interval. The largest request's named
  state is 271,556,632 bytes.
- **Arithmetic contract.** `nemotron_h_cbv2_query128_bf16_tf32_default_v1`:
  the dense contract's three values under this family's name.
  `MLX_GATHER_QMM_EXPERT_SLICES` is not part of it, because the expert-tile
  gather it selects accepts neither this model's assignment count (3,072 for
  a 512-token chunk) nor its expert shapes; see
  `mlx/backend/common/gemma4_expert_qmm.h`, `classify_gemma4_expert_qmm`.

## Results so far

One request: 34 prompt tokens, 64 outputs, cut 25, rank 0 on Mac A (blocks 0
to 24, 8.16 GiB), rank 1 on Mac B (blocks 25 to 51 and the head, 8.88 GiB).
Mac A's GPU lane and Mac B's lane were held; the compile lanes were not, so
other compiles ran on Mac A. **These figures are not for quoting**: the prompt
is one chunk, and each is a single run.

| Run | First token | Decode | Against the reference |
|---|---:|---:|---|
| Staged reference on Mac A, run 2 | | 80.6 tok/s | run 1 and run 2 `exact` |
| Cable, pipeline (first run after the stage check) | 2.70 s | 57.3 tok/s | tokens equal, logits differ |
| Cable, pipeline-compact | 0.19 s | 77.4 tok/s | tokens equal, logits differ |
| Cable, phase-split | 0.19 s | 98.0 tok/s | tokens equal, logits differ |

- Logits differ from the Mac A reference only through rank 1's chip: the
  state of blocks 0 to 24 is equal, the first difference is block 25's state,
  and the final row's largest difference is 0.1875 with the same argmax (the
  reference's top-1 to top-2 margin there is 0.75).
- **Fault.** 128 outputs, pipeline; rank 1's worker on Mac B was sent SIGTERM
  0.3 s after the first token, with 65 tokens committed. The driver sent no
  signal to rank 0; it exited by itself with status 1. Worker processes left:
  0 on both Macs. Wired memory, before and 26 s after the signal: Mac A 9.57
  and 8.81 GiB, Mac B 4.88 and 4.77 GiB.
- **Block cost on Mac B alone** (4,096 prompt tokens, chunks of 512, best of
  2): all 52 blocks in 1.518 s, 2,699 tok/s without the head. Per block for
  the whole prompt: Mamba2 22.3 ms, mixture of experts 31.2 ms, attention
  13.1 ms; shares 34%, 47% and 5%. Cut 25 has 44% of that time before it. A
  pair-versus-alone comparison at a long prompt is **not measured**.

## What changed

The family lives in `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Nemotron/`
(metadata, Plan, construction, request geometry and stage forward, registered
profile). It is a row of the existing layer-stage pipeline, so the driver, the
transport, the staged reference and the phase split are the code the Qwen
models run.

| Commit | What |
|---|---|
| six cherry-picks from `work/qwen-moe` | the routed-expert protocol adapter and resident row this branch builds on (taken instead of writing a second version) |
| `882d9b35e` | the state budget geometry can name its state-bearing layers by count |
| `2e275a9fc` | stage metadata and the two-stage Plan |
| `53befde7f` | **moves the `libs/mlx-swift-lm` pin** from `3fd4944c3` to the local, unpushed seam commit `9e901a0` |
| `8f117c479` | construct, load and run a stage through the SDK's stage seam |
| `40880a473` | the resident row, registered profile, arithmetic contract, tokenizer row, fixtures and checks |

**SDK (`libs/mlx-swift-lm`, local branch `darkbloom/nemotron-stage-seam`).**
`9e901a0` adds `cbv2StageResidual` and `cbv2StageLogits` to `NemotronHModel`
and two defaulted parameters to the private trunk forward (`inputEmbedding`,
`appliesFinalNorm`). No existing call site passes them, so serving builds the
graph it built before. `3691e3d` adds the seam's own test; it has not been
compiled or run, because a test build of the SDK on its own resolves
`mlx-swift` from the network. Neither commit is pushed. The parent cannot be
integrated until the seam is on the SDK fork, which is the owner's decision.

**Shared files touched, and why.**

| File | Why |
|---|---|
| `DarkbloomClusterProtocol/ClusterRuntimeCapability.swift` | the adapter case `nemotron-h-layer-stage` |
| `Qwen/Metadata/QwenDenseProfileTypes.swift`, `QwenDenseRegisteredSpecification.swift`, `QwenRegisteredDenseModelProfile.swift`, `QwenRegisteredContentInventory.swift`, `QwenDenseStorageRequirement.swift` | the registered row and its dispatch into `Models/Nemotron/` |
| `Qwen/Metadata/QwenLayerStagePlan.swift` | a Nemotron configuration builds its Plan in `NemotronLayerStagePlan` |
| `Qwen/Resources/QwenLongPrefillTensorBudget.swift`, `QwenDenseStateBudget.swift`, `QwenResidentRequestResources.swift`, `QwenResidentResourceCeilings.swift` | state-bearing layers by count instead of by interval; the row's ceilings |
| `Qwen/Prefill/QwenResidentArithmeticPolicy.swift` | the arithmetic contract and the comment on why the expert-slice switch is not part of it |
| `Qwen/Resident/QwenResidentModelDefinition.swift`, `QwenResidentAdapterDefinition.swift`, `QwenResidentCapabilityMetadata.swift` | the resident row, its sixteen cuts and three modes, the vocabulary size |
| `Qwen/Loading/QwenModelConstruction.swift`, `PreparedQwenLayerSource.swift`, `QwenLayerStageInert.swift`, `QwenDenseObservedStage.swift` | construct and validate a Nemotron stage, install its inert modules, find its final norm |
| `Qwen/Generation/QwenLayerStageSession.swift`, `QwenPhaseSplitTerms.swift`, `Qwen/Diagnostics/QwenRecordedState.swift`, `QwenLayerStageRankStateCapture.swift` | the stage forward dispatch and the three block kinds |
| `State/CBv2RequestGeometry.swift`, `State/CBv2OwnedStateSnapshot.swift` | a geometry carries its layer count, so a stage with blocks that hold no state is counted correctly |
| worker `PromptTokenizer.swift`, `QualificationRequest.swift` | the tokenizer row with this model's chat wrapper; the qualification row |
| five script checks' file lists | the two metadata files join the closures those checks compile |

## Limits and open questions

- The SDK seam is a local commit. Integration waits for it to be on the SDK
  fork.
- The provider's installed pair path has no Nemotron row
  (`DistributedInstalledPairServingTable`), so `darkbloom start --distributed`
  would refuse this model. Not done here.
- The artifact's speculative (`mtp.`) head belongs to no stage. The pair runs
  greedy text without it; the product comparison is with thinking and MTP off.
- The registered profile admits at most 8,192 prompt tokens and 128 outputs,
  like the other resident rows.
- Mac B alone prefills this model faster than a pair can be expected to; see
  the numbers above before choosing a pair for speed.
