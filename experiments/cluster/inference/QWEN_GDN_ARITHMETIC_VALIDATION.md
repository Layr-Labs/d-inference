# Qwen3.5 9B projection arithmetic controls — 2026-09-13

Restoring the original output width removes the first recurrent projection's
measured partition discrepancy for this input. Both rank projections, padded
with affine-zero rows and cropped afterward, reproduce all 395,264 native
values exactly. FP32 projections nearly agree across ranks but also change the
native reference. These operator results guide the cluster implementation;
they do not qualify whole-model TP or throughput.

## Experiment

The [input diagnostic](QWEN_GDN_INPUT_VALIDATION.md) found 125,801 differing
values before convolution or recurrence. This experiment retains that exact
32-token input, native forward, stored projection tensors, semantic head
selection and original full/rank outputs. It adds two controls:

1. Widen input and affine metadata to FP32, run full and selected projections,
   retain FP32 output, and cast each output back to native BF16.
2. Append zero packed words, zero scales and zero biases after each selected
   rank matrix until it has the original full output width. Run in native
   BF16 and crop the original selected rows. Actual selected weight bytes and
   input K remain unchanged.

The real geometry is M32/K4096, full N12352 and selected N6176. Padding restores
N12352. The native model forward remains unmodified; only reconstructed
operators receive these controls after capture and normal state commitment.
The command and bounds are described in the
[arithmetic diagnostic contract](README.md#gdn-projection-arithmetic-controls).

Four sequential calls cover tiny F32, tiny BF16, registered 9B solo and
registered 9B arithmetic diagnostics on an M4 Max, 36 GiB, 14 CPU / 32 GPU
cores. All four native calls and the driver exit zero. Both tiny fixtures
have exact full/rank agreement for all variants, using K128 and full N1028.
They do not establish behavior at the real model's matrix geometry.

## Registered 9B results

Each row compares 395,264 values. Relative RMS uses the reference named in
the comparison, so rows with different references are not interchangeable.

| Comparison | Differing values | Maximum absolute error | Relative RMS error |
|---|---:|---:|---:|
| Original native full vs reassembled native ranks | 125,801 | 0.25 | 0.002689177293 |
| FP32 full vs reassembled FP32 ranks | 361,306 | 0.00009155273438 | 0.000000700219207 |
| FP32 full vs ranks, each cast to BF16 | 98 | 0.03125 | 0.00004308785500 |
| Original native full vs padded/cropped native ranks | 0 | 0 | 0 |
| Original native full vs FP32 full cast to BF16 | 104,168 | 0.25 | 0.001459024674 |

The FP32 row has many differences with very small magnitudes. Casting those
outputs to BF16 removes most partition disagreements, while rounding
boundaries leave 98 unequal values. Widening also changes 104,168 values in
the full projection relative to native BF16. A small partition error alone
therefore cannot qualify a replacement policy against the native model.

Padding matches original native values and logical bytes on both ranks,
including all Q/K/V/z/b/a components. The full padded outputs also verify
the crop and zero-valued tail. Padding spends additional computation; this
experiment provides no evidence that it improves inference speed.

Every original normalized input, projection source identity, full/rank native
output and first-logit capture reproduces the preceding experiment exactly.
All 248,320 final logits also match a fresh ordinary solo control exactly,
with argmax token 2018. This checks the unchanged model/capture path for the
32-token request, independently of the experimental projections.

## Interpretation and next architecture work

The pinned Metal dispatch predicts split-K 1 for full N12352 and split-K 2
for selected N6176 at this M/K. The split-K temporary uses the input dtype.
Padding restores full N and the predicted unsplit path. Its exact result is
consistent with that explanation and demonstrates output-width sensitivity
without a transport operation or state update between projections.

Kernel dispatch was not traced. Padding also changes placement of selected
rows relative to the original full matrix. These observations do not prove
that split-K alone explains every whole-model TP discrepancy. The source is
`libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp`
(`QuantizedMatmul::eval_gpu`, `qmm_splitk`).

Two implementation directions follow: preserve arithmetic dispatch when
partitioning operators without computing zero rows, and pipeline whole
layers while retaining full projection widths. The layer pipeline needs
explicit stage loading, state ownership, ordered chunk transfer and overlap.
Its performance must be compared with the fastest eligible solo chunk
schedule; retaining operator widths alone does not establish a speedup.

## Verification and identity

The release build and 31 focused CPU oracle tests pass. Both diagnostic
admissions pass: 44 rejected input-mode fixtures and 45 arithmetic-mode
fixtures, including the pre-load working-set estimate. Worker protocol 5
still accepts 4,112 fixtures and rejects 97. All 37 launcher Python sources
match the preceding passing 187-test run; that unchanged suite was not rerun.

The independent CPU completion audit verifies 160 archived source entries,
bundle identities, argv/exits/cleanup, raw metrics, widening/cast-back,
semantic selection, padded crop and 37 actual source/variant tensor identities.
The driver verifies the complete artifact before, during and after execution.

Sampled pressure remains level 2 with zero new swap. Peak sampled owned RSS
is 3,599,646,720 bytes for solo and 5,782,241,280 for the arithmetic diagnostic.
Startup admission requires 8,266,034,790 bytes of reclaimable headroom, including
a 1 GiB diagnostic reserve. Some in-flight reclaimable estimates fall below
that startup requirement; live abort conditions are severe pressure or more
than 1 GiB new swap. Neither sampling nor these estimates is a hard memory cap.

- Executable SHA-256: `3896e9401fba1d629a184eeb695a6539d252361b894b8b028fb6011806de26f8`.
- Artifact aggregate: `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
- Configuration SHA-256: `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`.
- Independent audit SHA-256: `4b43e82046de1bbd2b3e33336d798d307f5e45cc12ed59a2e1fd344d44c75e60`.

Private raw evidence is retained under `runs/qwen-gdn-arithmetic-20260913`.
There is no continuation, target 27B, physical RDMA, M3 Ultra or throughput
qualification in this record. The 800–1,000 prefill TPS goal remains open.
