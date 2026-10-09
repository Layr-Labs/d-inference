# CPU rotation and scalar-codebook candidate experiment

Date: 2026-10-09. The chosen integration candidate from this bounded comparison is **signed block128 Hadamard on keys, then affine INT4 per64 channels; values use affine INT4 per64 channels; last128 K/V tokens remain native**. It lowers observed output distortion versus the full-head Gaussian-codebook INT4 variants in this single sample. This is a candidate numerical policy, not an all-model quality result or a native inference implementation.

No production, GPU, model generation, model weights or private caches were accessed. Only this `experiment/` directory was edited.

## Scope and origin

The real-model BF16 tensor packet was captured on 2026-09-06 using an artificial repetitive water-infrastructure benchmark conversation. It is Qwen3.6-35B-A3B-VL-MTP MXFP8, dense attention owner0 / model layer3, one decode query after a5523-token prompt, full stored history5585, K/V each `[1,2,5585,256]`, Q `[1,16,1,256]`. MTP is disabled and no recurrent/MTP tensors are present. Original packet hash is bound in JSON alongside every tensor SHA256 and model/input identity. Selected archived contiguous/paged K/V bytes are identical.

Frozen source: `docs/reports/evidence/qwen36-owner0-packets-2026-09-06/payloads.tar.gz`, member prefix `raw/qwen36-paged-owner0-packet/report.attention-packet/`. Verified archive SHA256: `0ad883a7d23b3de60643197446064e15fd91ac71ee759012f5ef4ebd25f30f81`. The earlier read-only extraction into `/tmp/darkbloom-cache-quant-diagnostic/packet` established public benchmark provenance and archive integrity. This runner validates descriptor/metadata/tensor hashes again and proves BF16→FP32→BF16 identity before quantization.

## Actual bytes and one-operator distortion

Combined native K/V payload is **11,438,080 bytes**. Recent128 K/V protected band is **262,144 bytes** in every row below. Encoded totals include actual packed INT4/INT8 codes, FP32 affine scale+bias or FP32 norms, serialized sign masks plus uint64 seeds, serialized FP32 codebooks where used, protected native band and compact codec JSON. GCM/DBK3 framing and allocator page metadata are excluded. Shared global parameters are conservatively counted separately for K and V. Savings column excludes only the small JSON manifest.

Reference attention keeps original Q unchanged and runs original-basis FP32 QK/softmax/V on either dequantized FP32 or dequantized values rounded back to native BF16. The reference uses unmodified captured K/V. Relative-L2 is an operator-vector difference, **not percent answer-quality loss**.

| Candidate | Encoded bytes incl JSON | Payload saved | Protected native bytes | Output relative-L2, native BF16 restore | Output relative-L2, FP32 decode | Worst head relative-L2, BF16 |
|---|---:|---:|---:|---:|---:|---:|
| `native_rotation_control` | 11,438,378 | 0.00% | 262,144 | 0.0000% | 0.0000% | 0.0000% |
| `affine8_per_token` | 6,548,900 | 42.75% | 262,144 | 0.0696% | 0.0685% | 0.1767% |
| `affine4_per_token` | 3,754,916 | 67.17% | 262,144 | 1.4548% | 1.4563% | 3.7391% |
| `rotated4_kv_gaussian_codebook` | 3,143,952 | 72.52% | 262,144 | 1.7997% | 1.7915% | 6.2924% |
| `rotated8_kv_gaussian_codebook` | 5,939,856 | 48.07% | 262,144 | 0.0807% | 0.0856% | 0.2402% |
| `rotated4_k_gaussian_v_affine` | 3,449,439 | 69.85% | 262,144 | 1.8352% | 1.8255% | 6.5102% |
| `block128_hadamard_k_affine4_v_affine4` | 3,754,960 | 67.17% | 262,144 | 1.1507% | 1.1581% | 3.2416% |
| `block64_rotated4_kv_gaussian_codebook` | 3,405,848 | 70.23% | 262,144 | 1.3661% | 1.3638% | 4.0401% |

The unquantized signed-Hadamard forward/inverse control is near the numerical floor. Full-head nonuniform INT4 gives the smallest representation here (~72.5% fewer K/V bytes), but its selected-output error is higher than block128 key rotation with affine INT4 (~67.2% smaller). Explicit block64 nonuniform INT4 also beats the full-head nonuniform error in this sample, while increasing norm overhead. INT8 variants remain separately reported as less aggressive candidates.

The earlier K-channel/V-token affine4 storage diagnostic gave1.0947% relative-L2 with recent128; the current block128 key-affine4 candidate gives1.1507%, so this comparison does **not** prove it dominates every affine arrangement. It directly compares the integration candidate requested here against per-token affine4 and nonuniform variants. Additional seeds, layers, query positions, prompts, models and long-context whole-model tests can change the ordering. A native GPU benchmark is needed to select the efficient fused attention kernel, independent of these CPU errors.

## Rotation/codebook policy and all-model handling

`rotated_scalar_codec.py` implements normalized sign-FWHT, explicit norm separation and an offline deterministic Lloyd-Max codebook for standard Gaussian coordinates. The Gaussian codebook is computed without using the KV sample, then serialized as FP32. Solver convergence/stationarity and the actual centroid/hash values are recorded. All transformed coordinates are packed, including padding coordinates when the generic full-head path pads to the next power of two. The inverse transform completes before cropping to the original width. This preserves the original vector under the unquantized control up to ordinary FP32 arithmetic, with no implicit dimensional truncation.

This is **TurboQuant-MSE-style inspiration**, not the full [TurboQuant paper](https://arxiv.org/abs/2504.19874) implementation. Signed Hadamard is not a Haar rotation; Gaussian Lloyd-Max is not the exact finite-dimensional sphere/Beta codebook; QJL residual correction and its inner-product unbiasedness are absent. The paper's model-quality claims do not apply to this prototype.

Actual current model widths can avoid padding: R=min(128,lowbit(D)): D192 uses three explicit64-channel blocks, D64 uses one64 block, D128 uses one128 block, D256/512 use2/4 blocks128; D80 and160 use5 blocks16 and32. Exact-block forward/inverse helpers and checks implement this rule. The candidate runner exercises block128 affine keys and block64 nonuniform separately. Treat these block transforms as distinct quantizers and bind rotation width, sign mask, seed and format version. Do not silently substitute padded/full-head and blocked policies. K and V widths are independent; unit checks cover Dk3/Dv5 GQA and D192 exact inverse/norm preservation. The generic padding path is a fallback for arbitrary positive widths, not evidence of model quality at those widths.

A production plan must preserve actual storage-owner and borrower identity: encode an owner's K/V once, let borrowers refer to that owner, and retain the owner's key rotation for all query heads that borrow it. Native query normalization/RoPE/masks, sinks, softcap and absolute positions keep their existing semantics. The128-token native band means a128-token GPT-OSS window stays entirely native; full-attention history still compresses. Recurrent, conv/SSM and MTP state stay native. A live implementation must decode per tile or calculate in the rotated domain with a fused kernel; materializing the whole native cache would erase the memory benefit.

## Verification and reproduction

Six focused unit tests pass:

- Exact INT4/INT8 packing/unpacking, including odd/ragged counts, bit-range checks and invalid trailing nibble.
- Full rotation inverse, norm and inner-product preservation for widths1,3,64,80,128,192,256,512.
- Explicit exact-block rotation with R=min(128,lowbit(D)) for widths1,3,64,80,128,160,192,256,512; no padding or geometry change.
- Lloyd-Max monotonicity, symmetry, serialized hash, stationarity, analytical1-bit centroid and known2-bit solution.
- Actual serialized-payload decode, all padded coordinates retained, zero-vector handling, invalid nonfinite input and authoritative sign masks independent of PRNG recreation.
- Independent K/V widths and grouped-query owner mapping against a direct scalar reference.

```sh
python3 -m unittest discover -s reports/runtime-kv-path-2026-10-09/experiment -p 'test_*.py' -v
python3 reports/runtime-kv-path-2026-10-09/experiment/run_rotated_packet.py --packet /tmp/darkbloom-cache-quant-diagnostic/packet --output reports/runtime-kv-path-2026-10-09/experiment/results.json
```

Dependencies: NumPy and SciPy; runtime version and source hashes are bound in JSON. Numerical tests use small synthetic arrays only as correctness tests. The reported distortion uses the real archived model packet. CPU encode/decode times are single observations with BLAS thread controls set to1; they are not provider TTFT or throughput measurements. No native compressed cache allocation, paging, cancellation, cache identity/adoption or SSD writes are implemented by this experiment.
