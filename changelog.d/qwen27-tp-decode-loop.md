### Qwen tensor-parallel decode routes, row exactness and finiteness check

- A Qwen3.8-27B tensor-parallel row now decodes the same bytes alone as beside
  other rows and in verify windows on the registered weights. A one-row decode
  step's fused SwiGLU computed its sigmoid with Metal's fast `exp`, while
  cohort and window steps use MLX's precise `exp`. The two round a gate of
  exactly bf16 -6.84375 differently, which could change later tokens. Dense
  Qwen tensor-parallel output changes only where a one-row decode step meets
  that gate value, and there it now equals the cohort path. Regenerate
  tensor-parallel serving references recorded with earlier builds once.
  Single-Mac output is unchanged.
- A non-finite logit on either rank of a Qwen tensor-parallel pair now fails
  both ranks in the same selection step, before any token is published;
  previously the other rank waited in the selection collective. The check moved
  into the selection's sealed sum, so a decode step no longer pays a separate
  finiteness read. Selected tokens are unchanged.
- Each rank logs its decode routes once per load, when it first serves
  (`darkbloom-qwen-tp-decode-census-v1`): which projections take the
  batch-invariant kernel and at which layout per row count, the attention and
  residual-norm routes, and the arithmetic switches in force.
- `darkbloom-cluster-tp-check qwen-rows` checks, on one Mac over the loopback
  ring, that a Qwen3.8-27B row decodes the same bytes alone, beside other rows
  and in verify windows at the registered per-rank widths, with random weights
  that follow the registered artifact's value statistics or with the registered
  checkpoint itself; `qwen-rows layers` names the first layer that differs.
