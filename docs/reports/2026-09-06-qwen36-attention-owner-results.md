# Qwen3.6 complete attention-owner metadata

> Last updated: 2026-09-06 · commit `4d53fd012`

The corrected contiguous diagnostic captures all ten Qwen3.6 attention owners:
original queries, incoming keys/values, visible cache storage, kernel outputs,
and outward outputs are all BF16. Its trace-off and trace-on runs pass strict
integrity checks and preserve all seven completed trajectories exactly. This
closes the incomplete contiguous metadata capture; the underlying backend
numerical difference and release acceptance remain open.

## Corrected pair

Both runs use the same optimized probe built from provider `384c321aa` and native
`e972340a`, with [explicit attention-owner identity](2026-09-06-attention-owner-identity.md).
They run the exact Qwen3.6 35B artifact, September 6 input, B1, cache off, MTP off,
and normal production single-slot KV grant. The only trace changes are bounded
metadata and actual-logit selectors at output index 62, with candidates 1928/6829.

| Observation | Result |
|---|---|
| Main rendered prompt / generated output | 5,523 / 83 tokens |
| Main, repeat, three tenant controls, donor, recovery | All seven exact prompt IDs, output IDs, counts, finish and outcome across the pair |
| Canceled output / recovery prefix | Four tokens in each run; both exact prefixes of their own recovery |
| Trace-off diagnostics | Absent |
| Trace-on capture | One selected forward, ten owners, confirmed sample, no refusals |
| Actual decision | Request 2, index 62, seed 11346, target/argmax 1928 |
| Native forward | `chained_decode`, B1/L1, cache offset 5584 → 5585, `contiguous_sdpa` |
| Candidate logits 1928 / 6829 | BF16 23.5 / 23.5; no NaN or infinity |

The concrete `(storageLayerIndex, modelLayerIndex)` pairs are
`(0,3), (1,7), (2,11), (3,15), (4,19), (5,23), (6,27), (7,31), (8,35), (9,39)`.
Each records original Q, incoming K/V, visible K/V, kernel output, and outward
output as `bfloat16`. The archive retains shapes and graph-construction strides
for every tensor, separately from dtype. These are observed metadata; no tensor
contents or independent attention reference are captured by this probe.

The new control also preserves all seven completed trajectories from the earlier
contiguous control. That is an explicitly earlier-build comparison, separate
from the new pair's same-build tracing check. Diagnostic timing is excluded from
performance claims.

## Original failure remains preserved

The original four-cell run used probe `b7039d47` on native `847e3207` and remains
**failed for incomplete contiguous owner capture**. Its contiguous trace captured
only `(3,3)` and `(7,7)`, with eight unexpected/repeated-owner refusals and one
missing-owner refusal. Source inspection found model-layer indices used where
dense attention-owner indices were required; the explicit identity fix corrects
that diagnostic mapping.

The original paged trace captured all ten owners and observed BF16 throughout;
its actual candidate logits were 23.5 / 23.75, selecting 6829. Each original
backend's tracing preserved its own seven completed trajectories. Original
contiguous/paged main outputs first differ at index 62 after the same 5,523 prompt
tokens and 62 prior generated IDs. Those results remain their original-build
evidence. The new two-cell contiguous pair is **not a mixed-build four-cell
comparison**, and metadata success does not waive the strict backend failure.

## Provenance and evidence

The [manifest](evidence/qwen36-attention-owner-results-2026-09-06/manifest.json)
indexes 177 payloads in the
[archive](evidence/qwen36-attention-owner-results-2026-09-06/payloads.tar.gz).
`corrected-two-cell/` contains the new raw reports and exact comparisons;
`original-four-cell/` retains every original result, failure and comparison.
Other groups preserve the frozen plan, source/runtime binding, transfer receipts,
helper validation and final postflight. No binary, metallib, weight, key, or
checkpoint payload is included.

| Identity | SHA-256 |
|---|---|
| Model artifact aggregate | `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed` |
| Input bytes | `4fb1ebf2b8a4b9b29be3388da3613398c8c7b6f768ca8bac11636a8928dd570e` |
| Corrected probe, 80,515,200 bytes | `c15304623b6abc806fc47d312552eb888b10898ff6ef9f851e980fa1143578ba` |
| Runtime binding | `03bba023c5a22459469ee33bff351732a7adb4c3ab2d104d90d586a7f25f6377` |
| Control result manifest | `8c6140b7479e1ce742a3cf2c180009836599d00001030de5d9e0bff313d88a42` |
| Trace result manifest | `411af73958641a8262cc4aec43a9e89116a8bd1f7bda880a9966803f6ec09838` |
| Evidence manifest | `e74122bd817d4e9178d693e0c8b70298e768caf86e0faf5b21f5e2b60dc08333` |
| Evidence archive | `cefae38c6beae42e054989354bf0cbf4bc2704b58fb974741f97208e959beff8` |

All 23 plan/manifest files and seven runtime files match the reviewed bytes and
permissions on the M5. The native input argument names the wrapper's owned
`runs/<cell>/input.json` copy; its bytes equal the canonical input exactly. Nine
local strict-result fault checks and eleven remote wrapper checks pass. Both
model jobs retire; final postflight finds no owned jobs, GPU 33.76°C, and 353.12 GB
free. No other model jobs or machine settings are changed by this pair.
