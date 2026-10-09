# Gemma 4 shared-projection KV operator qualification

> Last updated: 2026-10-09

Gemma 4 global attention can reuse one unweighted RMS result to produce the
same native K/V normalization. A generic bounded raw-projection cache prototype
stores a projection with half the native global K/V tensor bytes but fails the attention cost gate. These results
qualify the operator fixture, not a single-cache serving format or model quality.

## Scope and evidence

The Apple M4 Max with 128 GiB RAM ran MLX Python 0.31.2. The fixture uses
deterministic synthetic BF16 projections with the production Gemma 4 26B global
geometry: 16 query heads, two KV heads, dimension 512, and 128 rotated
coordinates. It reads only layer 5's BF16 K norm vector from the cached model;
its payload SHA-256 is
`eba8fbb183b3b06b203ba93d21b3120f141b90f185755b550835573960c47f3f`.
It does not load the model or generate tokens.

Reproduction: the [archived operator probe](evidence/gemma-normalization-2026-10-09/gemma-raw-kv-probe.py), using
`--model-directory`, `--repeats 7`, and `--output`. The immutable fixture output
is [operator.json](evidence/gemma-shared-projection-2026-10-09/operator.json).
The normalization reference is the pinned native RMS operator, not a mathematical
reassociation of real-valued arithmetic.
The [current probe](../../scripts/benchmarks/gemma-raw-kv-probe.py) preserves the
same numerical operations and adds explicit header/payload validation.

## Exact normalization reuse

The pinned Metal `rms_single_row` and `rms_looped` operators cast the
unweighted normalization to the output dtype before learned scaling
(`libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/rms_norm.metal`).
For matching raw and learned-weight dtypes, Gemma's K before RoPE is therefore
bit-identical to the normalized V multiplied by the learned K weight. Mixed
dtypes retain the original weighted RMS operator so its promotion is unchanged.

The experimental Swift helper and both model entry points used this relation.
The [portable candidate patch](evidence/gemma-normalization-2026-10-09/normalization-candidate.patch)
preserves `gemma4NormalizeSharedProjection` and its `Gemma4Attention` callers;
the serving SDK retains the original native normalizer.
Regression fixtures compare it with the native weighted and unweighted operators
on CPU and Metal in FP16, BF16 and FP32, including nonuniform learned scales,
dimensions 32/256/512 and mixed weight dtypes.

The final elastic-window fixture compares complete Gemma logits and KV
snapshots with the original native normalizer in both arms. The separate
[whole-model normalization controls](2026-10-09-gemma-normalization-controls.md)
compare the original implementation against the candidate; all token
identities match, but its 0.27% aggregate ITL improvement fails the preregistered
1% benefit gate.

| Tokens | Native two-normalization fixture | Shared normalization fixture | Native bit difference |
|---:|---:|---:|---:|
| 1,024 | 0.302 ms | 0.281 ms | 0 |
| 8,192 | 0.700 ms | 0.698 ms | 0 |
| 32,768 | 2.039 ms | 1.917 ms | 0 |

These medians include concatenation of the two outputs for evaluation. They are
operator measurements; they do not establish a whole-model prefill or decode
speedup. The candidate retains both K and V tensors and their dtypes/shapes. It was
not pinned into serving after the separate whole-model benefit gate failed.

## Bounded reconstruction cost gate

The prototype stores the original BF16 projection once. Each 512-token tile
repeats native K and V normalization and proportional partial RoPE, then combines
FP32 attention numerator/denominator with online softmax. It evaluates each tile
to bound graph lifetime; the synchronization cost is part of the measured path.
The comparator uses the native fused BF16 SDPA kernel with already prepared K/V.

| Tokens | Native global K/V | Single raw projection | Native attention | Bounded reconstruction | Ratio |
|---:|---:|---:|---:|---:|---:|
| 1,024 | 4 MiB | 2 MiB | 0.268 ms | 1.026 ms | 3.82× |
| 8,192 | 32 MiB | 16 MiB | 0.851 ms | 7.158 ms | 8.41× |
| 32,768 | 128 MiB | 64 MiB | 1.146 ms | 20.108 ms | 17.54× |

The first 512-token tile's K/V outputs compared equal to the full native transforms.
The fixture does not independently check every later tile. Attention
maximum absolute differences were 0.00251, 0.00133 and 0.000866 respectively;
the FP32 online reduction has different rounding from native BF16 SDPA.
The candidate does not pass either an exact-output or performance gate. It is
not integrated into serving, prefix checkpoint formats, MTP or quantized storage.

## Derived storage directions

The pinned exact normalization relation makes normalized V a stronger base than
the raw projection: attention can reconstruct K without repeating historical
RMS reductions. A fused read operator still needs correct native multiplication
rounding, absolute positions, partial RoPE and original attention reduction.

An intermediate representation stores all 512 V coordinates and only the 128
rotated K coordinates: `[0, 64)` and `[256, 320)` for the nontraditional
full-dimension pairing. They are not a contiguous 128-coordinate prefix. The 384 unrotated K coordinates are reconstructed as
the native-dtype product of V and learned K weight inside the attention read.
This stores 640 scalars instead of 1,024 per global token, a derived 37.5%
reduction in that component, while keeping rotated K bits and avoiding historical
trigonometry. A V-only representation derives a 50% component reduction but
also reconstructs the rotated coordinates. Neither representation is implemented
or qualified by this report.

Promotion requires fused-kernel scratch and position-table accounting, long
prefill and decode cost controls, real-model continuation, MTP and complete
checkpoint compatibility, and per-case quality qualification when combined with
lossy quantization. Component byte calculations do not count allocator overhead,
position metadata, selection state, attention workspace or other model layers.

## Related

- [KV layouts and prefix caching](../architecture/prefix-cache.md).
- [Provider inference engine](../architecture/inference.md).
