# 028 — Exact BK64 expert-tile prototype

Status: implemented, source-contract qualified, awaiting M3 Metal compile/A/B.

## Hypothesis

At the existing BM32/BN32 sorted expert geometry, raising only K tile depth
from 32 to 64 halves full-threadgroup load/MMA synchronization rounds. If
those barriers and loop setup materially limit the measured ~11 TFLOPS kernel,
BK64 will make the M=16,384/32,768 Qwen W4/g64 BF16 projections at least 1.3x
faster without changing routing or arithmetic order.

## Source contracts

- `qmm_t_expert_impl` requires `BK >= 32` and `BK % 32 == 0`: 64 passes.
- `QuantizedBlockLoader<BN, BK, ..., group_size=64>` requires
  `BK <= group_size` and `group_size % BK == 0`: 64 is the largest legal
  depth and exactly one affine quantization group.
- Regular Steel `BlockMMA` has no BK32 specialization or BK maximum. It walks
  BK in 8-wide fragments; BK64 therefore instantiates eight fragments rather
  than four per outer iteration.
- Both Qwen K values (2,048 gate/up and 512 down) divide by 64.
- BM32 descriptors, BN32 output tiles, 128-thread threadgroups, expert
  boundaries, and the sortedness retract path are unchanged.

## Threadgroup memory and barriers

For BF16, `BK_padded = BK + 16 / sizeof(BF16) = BK + 8`.

| Variant | Xs | Ws | Total |
|---|---:|---:|---:|
| BK32 | `32 * 40 * 2` = 2,560 B | 2,560 B | 5,120 B |
| BK64 | `32 * 72 * 2` = 4,608 B | 4,608 B | 9,216 B |

BK64 consumes 9 KiB, 28.1% of M3's 32 KiB threadgroup-memory limit. It fits,
but its memory-limited residency ceiling falls from six to three threadgroups;
the Mac A/B must decide whether fewer barriers beat that occupancy risk.

Each outer K iteration has two threadgroup barriers plus one final store
barrier:

| Projection K | BK32 | BK64 |
|---:|---:|---:|
| 2,048 | 129 | 65 |
| 512 | 33 | 17 |

The three SIMDgroup barriers per 8-wide `BlockMMA` fragment are unchanged:
768 at K=2,048 and 192 at K=512 in both variants.

## Arithmetic contract

No source-level reassociation is introduced. The FP32 accumulator still sees
8-wide MMA fragments in K order `0, 8, 16, ...`. BK32 applies one BF16
scale/bias pair across two consecutive 32-deep loads; BK64 applies that same
pair once across the identical 64-value group. Packed W4 decoding, BF16
dequantization, FP32 accumulation, BF16 output, and sorted expert descriptors
are unchanged.

`MLX_GATHER_QMM_EXPERT_BK=64` selects the new AOT symbol once at device
construction. Missing, `32`, `bk32`, and invalid values retain BK32. A
source-mismatched metallib fails the explicitly selected BK64 experiment
closed while the default can still use an older BK32 metallib.

## Mac qualification

Build/stage a source-matched metallib, then run correctness under BK64:

```bash
cd libs/mlx-swift
BIN_DIR="$(swift build --show-bin-path)"
cd ../..
./scripts/fetch-metallib.sh "$BIN_DIR"
cd libs/mlx-swift
MLX_GATHER_QMM_EXPERT_SLICES=1 \
MLX_GATHER_QMM_EXPERT_BK=64 \
swift test --filter SortedGatherQuantizedMMTests
```

Run separate processes for the exact BK-depth benchmark:

```bash
MLX_EXPERT_TILES_PERF=1 MLX_EXPERT_TILES_PERF_BK_DEPTH=1 \
MLX_GATHER_QMM_EXPERT_SLICES=trust MLX_GATHER_QMM_EXPERT_BK=32 \
swift test --filter QwenExpertTilePerfTests 2>&1 | tee /tmp/qwen-bk32.log

MLX_EXPERT_TILES_PERF=1 MLX_EXPERT_TILES_PERF_BK_DEPTH=1 \
MLX_GATHER_QMM_EXPERT_SLICES=trust MLX_GATHER_QMM_EXPERT_BK=64 \
swift test --filter QwenExpertTilePerfTests 2>&1 | tee /tmp/qwen-bk64.log
```

Kill BK64 unless `median(BK32) / median(BK64) >= 1.30` in every gate-up and
down cell at M=16,384 and M=32,768, all 25 timed calls per cell report tile
hits with zero fallbacks, and the BK64 correctness suite passes.
