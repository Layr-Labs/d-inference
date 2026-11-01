### Qwen tensor-parallel decode routes in the rank log

- Each rank of a Qwen tensor-parallel pair logs its decode routes once per load
  (`qwen-tp-decode-census-v1`): which projections take the batch-invariant
  kernel and at which layout per row count, the attention and residual-norm
  routes, and the arithmetic switches in force.
- `darkbloom-cluster-tp-check qwen-rows` checks, on one Mac over the loopback
  ring, that a Qwen3.8-27B row decodes the same bytes alone, beside other rows
  and in verify windows at the registered per-rank widths (random weights).
