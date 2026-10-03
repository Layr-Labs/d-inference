package api

// DAR-347 follow-ups: the dispatch-time "stop the storm" logic must NOT turn a
// memory-pressured provider's ambiguous "batch token budget" rejection into a
// permanent fleet-wide 429 (#1), and a deterministic verdict observed from a
// speculative race LOSER must survive even when the surviving racer reports a
// transient/timeout error (#2).
