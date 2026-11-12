# First resident prefill scheduling trial

The current shared generation driver is serial. After O128 serial correctness is qualified, the first bounded trial should prepare one next prompt chunk on rank 0 after the current payload's completed send and before waiting for its consumed acknowledgment. Keep cut4, chunk512, native completion fences, boundary checks, token/decision protocol, retirement, and live resource thresholds fixed. This is a source-derived proposal, not a measured speedup or an enabled backend.

## Current source

`QwenLayerStageGenerationDriver.runGenerationFrame` commits rank 0's chunk, calls `sendBoundary`, then acknowledges rank 1. `sendBoundary` transmits the header length and bytes, receives boundaryReady, completes the residual send, and waits for boundaryConsumed. Rank 1 validates the received allocation, performs its chunk, validates its commit, and only then sends consumed. Consequently rank 0 cannot prepare chunk k+1 while rank 1 consumes k.

The shared Runtime has no `serial_v1`/`prompt_lookahead_one_v1` switch. Those policies belong to the older experimental long-prefill sender. Its lookahead explicitly waits for a separate received ACK, releases its original wrapper, prepares one next chunk, then drains consumed. Current generation has ready and consumed ACKs, with no received ACK. Reusing its source algorithm is useful, but its credit point and receipts cannot be relabeled as the current generation protocol.

Each generation boundary performs five completed native P2P operations per rank: header length, header bytes, ready ACK, residual, consumed ACK. Each call evaluates the communication operation and synchronizes the CPU and GPU streams. A 16-chunk prompt therefore has 80 such operations per rank before token/decision traffic. These fences protect completion and ownership; removing them is a separate native-lifetime change, not part of this trial.

Stage execution evaluates output, recurrent roots and cache roots before commit. KV validation reads device position offsets. Rank 0 reads the whole residual for its payload hash, then its transport ownership validation hashes it again; rank 1 hashes after receive and again at session input validation. These are synchronization/readback scopes worth measuring, but the first trial retains them. Resource checks are already rate-limited to 250 ms inside serving/recording execution; slowing that cadence is not an optimization proposed here.

## Narrow change

Split only rank 0's boundary operation into completed header/payload send and consumed drain. A private pending ticket retains CPU packet/identity plus the exact native committed frontier captured before any prefetch. Release the current original boundary wrapper before preparing ahead. Do not retain an extra send handle, start another header, or overlap model evaluation with a local native communication operation.

For a nonfinal prompt chunk, prepare exactly its next admitted prompt frame into one private slot. The next frame comes from the immutable request, not a future selected token. Shared frame control remains on k until its validated consumed ACK; only the local native session may temporarily be one prepared chunk ahead. When acknowledging k, use the captured frontier for k, never the now-advanced `session.committedTokens`. The next loop must match the prepared frame, tokens, identity and captured frontier to its actual next control expectation.

There is no prefetch after the final prompt chunk and none during decode. Token publication, synchronous provider decision, stop/EOS/length semantics and both-state retirement remain unchanged. A prefetch or pending-consumed failure poisons the request; it does not roll back and resume. Preserve current local retirement plus out-of-band peer fencing.

`CollectivePointToPoint.send` permits source release after completed send; it expressly does not prove peer consumption. This trial uses that release property only. It neither invents a received ACK nor advances shared control early. Bind the opt-in scheduling policy into generation agreement/report identity; serial remains the default. No new wire message is needed.

## Memory and cut4

At hidden4096/BF16/chunk512, each residual is 4,194,304 logical bytes. The existing resident ledger already charges two allocator-bounded boundaries plus conservative full-model state and selected fusion banks to each worker. Do not silently repurpose that reserve: the opt-in must separately charge its additional prepared-boundary and any retained CPU ticket/trace allowance before admission and recheck the combined amount during execution. If the additional ownership/allowance cannot be bounded, the trial must refuse rather than weaken the six-GiB floor or allocator/OS checks.

Keep one resident model and one native request state per rank, one prepared next boundary, one pending CPU consumed ticket, and one in-flight transfer. Free k's original wrapper before creating k+1's boundary. Same-process model computation remains serial, so this does not introduce simultaneous local model workspaces. Native/allocator observations still decide whether the actual execution fits; a named ledger does not establish the whole-process peak.

Cut4 leaves four transformer layers plus input embedding on rank 0 and 28 layers plus final head on rank 1. This geometry does not prove relative duration on different chips. The potential saving is bounded by the overlap of rank0 preparation(k+1) with rank1 consumption(k), and cannot shorten the consumer's work itself. Keep the 24/48 placement and cut fixed for the first comparison: prior root-reported cut8 resource refusal is not a reason to lower the 24 GB host's floor. Decode remains autoregressive and receives no benefit from this prompt-only trial.

## Qualification and measurement

Pure checks should cover serial equivalence, one prepared slot, exact captured/current frontiers, one-frame prompt, final-prompt/decode refusal, skipped/duplicate frame/ticket, cancellation and prefetch failure, checked extra capacity, and refusal when the extra allowance does not fit. Actual native qualification must preserve all O128 selected IDs, token chain, full-row/state digest comparisons, clean stop variants, and both-rank retirement under the same pinned source/model/input identities.

Measure first-token latency and whole O128 request duration separately. Use local per-chunk preparation, header/ready/payload, consumed-wait and consumer spans with the same optional observation cost in serial and lookahead. Never subtract clocks across Macs or sum blocked spans as independent service. The approximate opportunity is sum(min(consumer[k], producer[k+1])); it is not a speedup prediction without the actual stage costs and overheads. Retain cold first-use separately from resident repeats, fresh request UUID/state, per-host minimum actual-free/allocator observations, zero swap and the unchanged hard deadlines.

No model, candidate, compiler, network or GPU execution was performed for this note. The proposed overlay stays disabled until root completes matched serial correctness and approves its source/CPU checks.
