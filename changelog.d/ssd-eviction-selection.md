### Select SSD eviction victims without sorting the whole index first

- Attention-block and complete-checkpoint caches retire the least recently used
  file found by one linear index scan. Only when that file is busy or cannot be
  deleted do they copy the index into a snapshot that yields newer candidates
  oldest-first on demand, instead of sorting every entry up front. For an index
  that does not change during eviction, victims are chosen in the same order as
  before. The pass past busy or undeletable files stays bounded, and
  external-removal reconciliation still returns control to the disk budget
  before another file is removed.
