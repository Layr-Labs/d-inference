### Qwen tensor-parallel speculative rounds keep the GPU busy

A single-request speculative round no longer waits for each assistant draft
step before building the next one, and no longer waits for the drafts before
building the verify window: the draft chain and the window are submitted back
to back, and the window itself is submitted layer by layer as a decode step
already was. The drafted tokens' vocabulary check is evaluated with the window
and read when the window is confirmed. Every rank still runs the same
collectives in the same order, the emitted tokens are unchanged, and a failure
on either rank fails the round on both. Batched rounds keep their draft
schedule. `DARKBLOOM_QWEN_TP_MTP_PIPELINED_DRAFT=0` (diagnostic only) waits for
each draft step.
