# Qwen3.6 Head-Dimension-256 Attention Qualification

Date: 2026-08-17

Hardware: Apple M4 Max, 40 GPU cores, 128 GB unified memory

Artifact: `EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8-mtp`

Qualified dependency identities:

| Repository | Commit |
|---|---|
| `Layr-Labs/mlx` | `4937e294fccb2513b2e3e57d1d1c25cc646001c3` |
| `Layr-Labs/mlx-c` | `1dd06c957e3ef694de8bab9c3bdc687e6a75ff0f` |
| `Layr-Labs/mlx-swift` | `c9a6c77b3aff2ba1b0fe545e72c65105c55e8c28` |
| `Layr-Labs/mlx-swift-lm` | `5307541a915022df4084131f82e2ac49a3cf9faf` |

Source-matched no-JIT metallib SHA-256:
`bbbdecbdacb2406f0fde6454493d4a9de82685047c69531977d90e3829c88ec7`.

## Result

The existing MLX D256 Steel template is a valid bounded-memory path, not a
speed path on M4 Max. The release therefore separates the two decisions:

- qualified M4 Max providers use composed attention with qL=512 for speed;
- `force_fused` explicitly requests the D256 Steel kernel when bounded
  transient memory is more important than throughput;
- automatic fused selection remains unqualified and fails closed;
- other hardware retains the historical qL=128 posture pending measurement.

## Production A/B

Release builds, production CBv2 engine, contiguous KV, source-matched no-JIT
metallib. Medians of two same-build iterations:

| Prompt | qL=128 control | qualified qL=512 | Improvement |
|---:|---:|---:|---:|
| 8k | 6,206.8 ms | 6,056.6 ms | 2.4% |
| 32k | 32,879.5 ms | 31,660.9 ms | 3.7% (1.22 s) |

Five-iteration confirmation measured 6,296.9 -> 6,206.5 ms at 8k and
33,012.7 -> 31,693.8 ms at 32k. The qL=512 result uses 40.6 MiB more
transient MLX memory at 32k (1.974 GB vs 1.931 GB, +2.2%).

Production measurement command (control uses an explicit block of 128; the
qualified arm omits the override):

```sh
./.build/release/darkbloom benchmark \
  --model EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8-mtp \
  --scheduler-prefill --prefill-lengths 8192,32768 \
  --prefill-iterations 5 --kv-backend contiguous
```

The explicit forced-fused arm measured 33,063.0 ms and 1.668 GB transient at
32k: 15.5% less transient memory than qualified qL=512, but slower. It is not
an automatic performance route.

## Kernel Experiments

Four separate fused designs were implemented, correctness-tested, profiled,
and removed after losing the composed-path gate:

1. Q8, K32/K64/K128, four SIMD groups, D64 output shards.
2. Q32 with D128 shards, eight SIMD groups.
3. Q16 across two query heads sharing one KV head.
4. Q8 across all eight GQA query heads, 512-thread workgroup.

All passed lower-right causal, GQA8, non-contiguous BHLD, tail, and NaN gates.
The best fused experiment still lost composed attention by more than 2x at
long context. No experimental kernel or selector remains in the source tree.

## Controls

- `DARKBLOOM_CBV2_ATTN_EXECUTION=fallback`: composed attention.
- `DARKBLOOM_CBV2_ATTN_EXECUTION=fused`: explicit D256 Steel path.
- `DARKBLOOM_CBV2_ATTN_EXECUTION=auto`: fails closed until hardware-specific
  fused qualification exists.
- `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=<n>`: operator override; `0` disables
  composed query blocking.

The default qL=512 qualification is intentionally limited to the exact tested
`Mac16,5` configuration: Qwen3.6, M4 Max, 40 GPU cores, and 128 GB RAM. M3 Max
qualification is a separate hardware run; M5/NAX is deferred to the next
workstream.

## Release Gates

- MLX D256 FP16/BF16 masks, tails, sinks, long-K barriers, CPU rejection,
  source compatibility, VJP, and forced-vmap rejection.
- mlx-c legacy and v2 ABI link tests.
- mlx-swift full test suite and generated-source regeneration.
- mlx-swift-lm cache-route, query-block, MTP/decode/span, and policy tests.
- Source-matched no-JIT metallib symbol verification before and after signing.
- Real-artifact default and forced-fused Qwen production canaries.
