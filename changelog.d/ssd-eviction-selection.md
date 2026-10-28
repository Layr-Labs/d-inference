### Reduce SSD eviction candidate-selection work

- Attention-block and complete-checkpoint caches try a linear oldest-entry probe
  before sorting the index for eviction. Busy or undeletable files still allow
  bounded fallback to newer candidates, and external-removal reconciliation still
  returns control to the disk budget before another file is removed.
