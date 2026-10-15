# Explicit 27B 8K lookahead comparison

This derivative retains the frozen cut16 catalog, arithmetic, full-reference
validator, global state comparison, snapshot and packet reader byte-exact.
Only the agreement/preparer require native oneChunkLookahead, and candidate
execution requires its closed schedule record. Rank0 must prepare15 frames,
retain at most one prepared boundary, finish with zero pending-consumed frames
and no decode prefetch; rank1 counters are zero. The generic count expression
is prefill_frames-1 and is16-1 for this fixed P8192/C512/O128 request.

The policy patch is the existing qualified9B lookahead check applied to the
registered comparator without replacing its27B catalog/geometry. Six existing
fabricated lookahead test methods were adapted only to27B/cut16 and144 states;
all passed before candidate access. Full128 IDs,496640BF16 final-row bytes,
36/108 state ownership and143frames/frontier8319 remain required. No candidate
output has been read. This is not a per-token full-logit or physical cleanup
attestation. Actual reference remains serial full-trunk control, not relabelled
as a lookahead run. Math/reference/state sources are unchanged.
