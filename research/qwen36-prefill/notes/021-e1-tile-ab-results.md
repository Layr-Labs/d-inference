# 021 — E1 Mac A/B: tile hits at 32768/65536, 1.06× vs legacy

Status: measured. Allowlist stays (correct + not slower). 1.3× kernel-only
keep bar **missed**. Do not raise CBv2 budgets on this result alone.

## Setup

- Host: m3-max-128gb-2, AC, `powermode=2`, battery 100%
- Binary: mlx-swift tests compiled on this Mac against the E1 allowlist
- Metallib: installed 0.8.10 `Darkbloom.app` `mlx.metallib` (162 MB),
  colocated with the test bundle. Symbols present:
  `build_sorted_expert_tiles_bm32_e256`,
  `affine_gather_qmm_gemma4_expert_tiles_...`
- Log: `artifacts/e1-tile-vs-legacy.log`

## Correctness

`MLX_GATHER_QMM_EXPERT_SLICES=1 swift test --filter SortedGatherQuantizedMMTests`

All cases passed, including new M=32768 / 65536 aligned and fragmented
Qwen + Gemma shapes. `testQwenSortedGatherQuantizedMMMatchesLegacyOnRandomTensors`
66.4 s. Tile route is numerically the legacy gather at the new M.

## Perf (median ms, 25 timed iters, High Power)

`hits=25 fallbacks=0` on every tile cell. Existing metallib runs M=65536.

| cell | tile ms | legacy ms | legacy/tile |
|---|---:|---:|---:|
| gate_up T512 | 2.328 | 1.977 | 0.85 |
| gate_split T512 | 1.449 | 1.162 | 0.80 |
| down T512 | 1.481 | 1.131 | 0.76 |
| gate_up T1024 | 3.545 | 3.571 | 1.01 |
| down T1024 | 2.031 | 1.950 | 0.96 |
| gate_up T2048 | 6.541 | 6.813 | 1.04 |
| down T2048 | 3.563 | 3.541 | 0.99 |
| **gate_up T4096** | **12.516** | **13.241** | **1.06** |
| down T4096 | 6.584 | 6.818 | 1.04 |
| **gate_up T8192** | **24.486** | **26.117** | **1.07** |
| down T8192 | 12.610 | 13.331 | 1.06 |

Note 018 kill: tile ≥1.3× legacy at the new M. **Miss.** Tile is ~6%
faster at T4096/T8192 and **slower** at T512.

## Physics

Time scales linearly with M (6.5 → 12.5 → 24.5 ms). Isolated QMM tok/s
is flat (~2.5–2.7 M assignments/s). This kernel is not the 2×/4×
weight-stream win. The full-model win of a wider CBv2 step is fewer
re-reads of dense / GDN / attn / shared-expert weights, plus fewer
evals — not this gather beating legacy by 1.3×.

## Verdict

- Keep the allowlist. It is correct, it hits, and it is not slower than
  legacy at the shapes E2 will use.
- Do not claim a CBv2 tok/s win. The allowlist is inert until the
  scheduler budget/chunk rise (E2).
- Next experiment, one cell: new binary, High Power, B=4×2048 with
  `prefillChunkSize=1024` and `maxBatchedTokensPerStep=4096` vs the
  locked 1661 tok/s baseline. Same binary must first reproduce the
  default 512/2048 control within 8%.
