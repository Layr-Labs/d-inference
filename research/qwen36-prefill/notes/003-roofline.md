# 003 — Roofline (first principles)

Status: needs-measure (arithmetic is firm; measured BW/ALU is not)

## Two different roofs

**Decode roof:** bytes/token ≈ active_params × bytes/param.
3e9 × 0.5 B ≈ 1.5 GB/tok at 4-bit if only top-8+shared fire.
400 GB/s → ~270 tok/s. Measured decode will sit under this.

**Prefill roof:** bytes/chunk ≈ (experts touched) × expert_bytes.
At 512+ tokens, top-8 over 256 experts ≈ all experts. Chunk ≈
full 21 GiB weight file + scales + activations + KV + scores.

## Arithmetic on 400 GB/s, 8K prompt, B=1

| Chunk policy | Weight streams | Time if 21 GiB packed 4-bit | tok/s |
|---|---:|---:|---:|
| 512 | 16 | 0.84 s | 9,750 |
| 2048 (stripe) | 4 | 0.21 s | 39,000 |
| one-shot 8192 | 1 | 0.053 s | 155,000 |

| If GEMM reads bf16 dequant | streams | time | tok/s |
|---|---:|---:|---:|
| 512 | 16 | 2.8 s | 2,925 |
| 2048 | 4 | 0.70 s | 11,700 |

v0.8.6 claimed ~1,766 tok/s at 8K. That is:

- 18% of the 512-chunk 4-bit roof
- **below** the 512-chunk bf16 roof (so either more than weights
  move, effective BW << 400, or chunks are smaller / extra passes)
- 2.5× = 4,415 tok/s → **illegal** if the true roof is the 512 /
  bf16 line; **legal** if 4-bit packed + fewer streams.

## Aggregate B=4

If four prefills run as four forwards, weights stream 4×.
Aggregate tok/s ≈ B=1. Packed `[4, L]` (or flattened 4L with
correct KV offsets) streams weights once. If weight-bound,
aggregate → ~4×. If activation/L²-bound, aggregate → ~1×.

2026-08-19 M4: 4×8K aggregate 1,312 vs solo 1,319. That is the
unpacked signature. 0.8.6 claims +13–17% after packed landed —
far from 4×, so either packed is not firing, shapes are not
equal-length, or the workload is not weight-bound at B=4.

## What to measure first

1. B=1 tok/s at 512 / 2048 / 8192 (slope ⇒ per-token; intercept ⇒
   per-chunk / launch).
2. B=2 and B=4 equal-length aggregate vs B=1 (packed signature).
3. GPU busy vs wall (overlap). If busy-union == sum, H1 is live.
4. Bytes moved if we can get a counter; else infer from chunk-size
   slope.

Until those four numbers exist, every kernel rewrite is cosplay.
