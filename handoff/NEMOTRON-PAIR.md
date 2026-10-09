# Nemotron 3.5 Lightning as a two-stage layer pipeline

> Last updated: 2026-10-09 (branch `work/nemotron`, base `e15f5b891`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and
reports are outside the repository in the task's evidence folder
`nemotron-20261009`; its `STATUS.md` lists every ladder step with the file
that shows it. Nothing here was pushed.

## Status

STATUS_TABLE

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

RESULTS

## What changed

COMMITS

## Limits and open questions

OPEN
