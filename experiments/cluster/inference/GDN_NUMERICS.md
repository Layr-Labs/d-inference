# GDN partition numerical checks

These checks run the pinned Qwen35 GDN implementation on small synthetic models.
They validate partitioned projections, grouped key/value heads, masking, and cache
continuation. Their numerical budgets do not qualify a real checkpoint's output
quality and provide no inference-performance evidence.

The native affine quantized projection dispatch depends on output width. In the
12-value-head fixture, the fused projection is 4,120 rows before partitioning and
2,060 rows per rank. With batch two and a seven-token chunk, the full projection
can use `qmm_splitk` while each rank uses `qmv_quad`. The pinned
`quantized.cpp` allocates split-K intermediate sums in the input dtype: BF16
partials are rounded before the final reduction.

The measured controls isolate this arithmetic difference:

- Float32 projections preserve convolution state within 7.2e-7 and recurrent
  state within 1.2e-9.
- BF16-rounded parameters evaluated using Float32 arithmetic also preserve
  recurrent state to approximately 1e-9.
- BF16 single-token continuation, which keeps both sides on the small-matrix
  path, produces exactly equal convolution and recurrent states.
- The native crossing case's largest convolution difference is 0.015625 at
  2.15625 versus 2.171875: one local BF16 ULP. Convolution relative RMS is
  0.002092, recurrent relative RMS is 0.004175, and output relative RMS is
  0.008070.

The synthetic acceptance budgets are consequently separate for each quantity:

| Quantity | Float32 | BF16 activations |
|---|---|---|
| GDN output | max absolute 5e-5 and relative RMS 2e-5 | max absolute 0.01 and relative RMS 0.025 |
| Convolution state | max absolute 5e-5 | relative RMS 0.01 and max absolute two BF16 ULPs at the observed reference peak |
| FP32 recurrent state | max absolute 5e-5 | max absolute 0.01 and relative RMS 0.01 |

Every case reports its observed scales, calculated absolute bounds, relative
bounds, and pass results. BF16 ULP size is `2^(floor(log2(abs(peak))) - 7)`,
clamped at the BF16 subnormal spacing `2^-133`. Both diagnostic controls remain
part of the suite. Actual output and convolution dtypes must match the requested
activation dtype; recurrent state must remain Float32.

`errorAtMaximumAbsoluteErrorInLocalBF16ULPs` reports the local ULP scale only at
the element with the largest absolute error. It is not the maximum local-ULP
distance across every element, particularly near cancellation or zero.
