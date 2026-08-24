# 027 — E2 `[4,1024]`: +3.4%, checksum mismatch, dead

Status: **dead** (throughput miss + correctness veto)

## Hypothesis

With M=32,768 qualified in E1, raise `prefillChunkSize` from 512 to
1,024 and `maxBatchedTokensPerStep` from 2,048 to 4,096. A B=4 burst
then executes packed `[4,1024]` forwards instead of `[4,512]`.

The pre-registered disagreement was:

- note 012: 1.5–2.2×;
- note 011: 1.08–1.25×, because the once-per-pass term is only 66.2 ms;
- acceptance bar: 2.5× and byte-identical greedy checksums.

## Setup

- M3 Max, AC, `powermode=2` for both runs;
- same rebuilt binary SHA-256
  `ead0d577d008b0280ffc71a31098af0e96cafc76285c571a678c5d5a4882825f`;
- Qwen snapshot and contiguous KV unchanged;
- B=4, 2,048 prompt tokens/row, 2 generated tokens, two iterations;
- schema-5 harness metric: `4 * (2048 - 1) / prefill_makespan`;
- control first, then candidate; arrival error < 0.031 ms.

Artifacts:

- `artifacts/e2-control-b4-2048.json`
- `artifacts/e2-wide-b4-2048-c1024-t4096.json`
- matching `.meta` power/provenance files

## Result

| Arm | Chunk / budget | Median aggregate prefill | Makespan |
|---|---:|---:|---:|
| rebuilt control | 512 / 2,048 | **1,641.9 tok/s** | 4,992.9 ms |
| E2 wide | 1,024 / 4,096 | **1,698.4 tok/s** | 4,821.0 ms |

Speedup: **1.034×** versus the adjacent control and 1.023× versus the
old requested-token baseline (1,661 tok/s). This is below even note
011's 1.08× lower bound and nowhere near 2.5×. It confirms that deleting
one scheduler pass does not delete the per-token QMM work.

## Correctness veto

Checksums were stable across iterations within each arm, but not across
arms at the same B, prompts, and sampling:

| Row | Control | Wide |
|---:|---|---|
| 0 | `367d935a6f8ff4e5` | `90cd1e7e3d7b902c` |
| 1 | `c62bd1b375584fdf` | same |
| 2 | `59b88fe2cabd4c36` | same |
| 3 | `2fe41bf76ca273a7` | `55c1dd8a608d139e` |

Changing chunk boundaries changed greedy output for 2/4 rows. Under
GOAL.md and reviewer 016 that is an automatic veto, regardless of speed.

## Verdict

- Do not run `[4,2048]`; it is the same dead mechanism at a larger M.
- Do not ship the chunk/budget overrides; they only enable a measured
  correctness-breaking geometry.
- Keep the B=1/B=2/B=4 harness and its first-class prefill accounting.
- The next 2×-class experiment must improve the exact existing
  gather-QMM arithmetic/path at the current 512/2,048 geometry.

## B=2 baseline unlocked by the harness

Default geometry, B=2×2,048: **1,626.4 tok/s** median, 2,517.2 ms
prefill makespan. Artifact: `artifacts/baseline-rebuilt-b2-2048.json`.
