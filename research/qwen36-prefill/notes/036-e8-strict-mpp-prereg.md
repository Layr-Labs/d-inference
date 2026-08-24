# 036 — E8 preregistration: strict BF16×BF16→FP32 portable MPP

Status: **dead — strict precision produces the same M3 errors**

## Root cause from E6

`mpp::tensor_ops::matmul2d_descriptor`'s sixth argument is
`relaxed_precision`. MLX's NAX fragment sets it to `true`. E6 therefore
did **not** test the required same-quality mixed path; it allowed operand-
precision accumulation and failed 11 correctness cases.

## Candidate

`patches/e8-strict-portable-mpp-experiment.patch`:

1. opt-in M3 process gate (`MLX_FORCE_NAX_EXPERIMENT=1`);
2. set both QMM NAX descriptors to `relaxed_precision=false`.

The kernel still:

- reconstructs affine W4/g64 weights into BF16 threadgroup tiles;
- consumes the incumbent BF16 activation values;
- uses MPP BF16×BF16 with FP32 destination/accumulation;
- writes the established BF16 output;
- leaves the shipping architecture gate untouched by default.

This is Candidate A from hostile review 032. It does not use native
uint4 TensorOps or change weight rounding.

## Ratchet

1. Build source-matched host and metallib.
2. `SortedGatherQuantizedMMTests` first.
3. If correct, run Qwen gathered and dense NAX microbench cells.
4. Continue only at **≥22 weighted TFLOPS**. Below 22 is the note-026
   hard stop for 2.5× under the current quality contract.
5. Any operation or full-model checksum mismatch: dead.

No M5 number is transferable. The M3 optimized-shader result decides.

## Result

The strict descriptor compiled and executed through the M3 optimized
shader fallback. `SortedGatherQuantizedMMTests` failed the **same 11
assertions with the same maxima as E6**:

- ordinary QMM: 14;
- Qwen gate_up: 5.03;
- Qwen down: 6.75;
- sorted boundary cases: 3.0–3.5.

Artifact: `artifacts/e8-strict-mpp-correctness.txt`.

Changing `relaxed_precision=true` to `false` did not alter these outputs.
The mismatch is therefore caused by the MPP fallback's matrix
tile/reduction behavior (or unsupported generation behavior), not by
relaxed destination precision.

Per ratchet: no timing. Patch reversed, Cmlx compared equal to baseline,
cached baseline metallib restored, host rebuilt.

Candidate A—incumbent BF16 operands through MLX's MPP matmul with FP32
destination—is closed on this M3 implementation. A wholly new MPP
reduction schedule would still have to reproduce the incumbent 8-wide
reduction contract; the existing 16-wide MPP primitive does not.
