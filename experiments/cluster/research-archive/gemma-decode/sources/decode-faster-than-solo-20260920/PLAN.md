# Faster than solo decode

The acceptance target is a measured single-stream decode win against a matched solo implementation, while preserving the distributed prefill improvement. The existing Gemma result is 32.010 pair versus 47.068 solo tokens/s at P4096/C64/O16, greedy, MTP off, 4-bit weights, BF16 residuals, plaintext lab RDMA. This is not yet a decode win.

Compare MTP-off and MTP-on solo and distributed. Use identical artifact, prompt IDs, output limit, sampling, target implementation, resource policy and warmup convention. Report accepted output tokens per total decode wall time, including all rejected work and communication. Separate correctness captures from representative O128 timing. Include prefill, internal first token and external TTFT where actually measured. A win against MTP-off solo alone must not be described as faster than the best solo mode.

The existing sequential layer split cannot hide both stage times for one autoregressive stream. The checked EP16/112 partition sends only 27 of 240 selected experts to the smaller Mac, while duplicating the dense trunk, and is not the first speed candidate.

## Candidate: asynchronous assistant proposals

Keep the full Gemma target on the 48 GB member. The 24 GB member owns its registered assistant and the required target embedding, and proposes a bounded continuation from a clearly identified, immutable target hidden/KV snapshot. While the target verifies one candidate window, the assistant can continue its own hidden chain on the other GPU. This continuation is deliberately speculative and does not claim to use freshly reconciled target conditioning.

Every committed token remains target-authoritative. Reuse a queued continuation only when all verified proposals match and the next queued proposal equals the target's emitted bonus token. On mismatch, cancellation, stale scope or failed acknowledgement, discard the speculative continuation and reconcile/reseed. Limit queued proposals, snapshot lifetime, windows in flight and memory explicitly. Initial scope is greedy only; stochastic equivalence is not assumed.

This is a hypothesis, not a promised speedup: additional lookahead can lower acceptance, and communication can consume the overlap. Matched measurements decide whether this mode activates.

## Execution order

1. Preserve and inspect the registered assistant/config/embedding identities; qualify the standalone conditioning and load boundary.
2. Add a separate rectangular attention-only verification owner using the existing window-safe KV staging and accepted-prefix rollback. Keep the Qwen serial recurrent seam unchanged.
3. Implement and test the bounded asynchronous proposal/bonus-bridge state machine, then connect it to target and assistant owners.
4. Remove demonstrated redundant GPU fencing only from a new host-Data control API; retain the generic array/residual fences and fresh per-invocation resource policy. Independently test the documented scalar external-power observation before considering that substitution.
5. Run short actual target/assistant correctness, then matched local and remote MTP performance with multiple prompts and longer output. Publish failures and acceptance rates as well as speed.

Use the established bounded build and physical supervisors, canonical device leases and fresh resource gates. One compiler slot, jobs=2; no native GPU work on the development Mac. Do not lower product activation floors, delete prior evidence or claim encrypted/product admission from a private plaintext test.

## Current measured decision

The complete P128/C64/O128 cohort on native54b2809e passes exact IDs, final rows and state for local and remote MTP depths1/2. Best solo is now local depth2 at79.7598 decode tokens/s, versus ordinary61.6844 and best remote66.1892. Longer-output acceptance makes local MTP effective, and changes the baseline the cluster must beat. Retain the full measured aggregate and do not call a win over ordinary a win over best solo.

Prioritize the measured remote costs: depth2 exposed refill1.92394ms/token and snapshot reseed1.31983ms/token, then control exchanges. Qualify batch snapshot GPU boundaries independently first. Design explicit depth2 production of three lookahead tokens through separately fenced native batches of2+1; the existing two-token background credit cannot replenish the three positions consumed on a successful depth2 verification round. In parallel, qualify a bounded, default-off proposal policy that can reuse a stale continuation after a bonus-only mismatch while every emitted token remains verified by the unchanged target. Ordinary draft rejection still retires the branch. Pure source tests are not runtime qualification.

After a measured gain, compose only qualified changes and repeat same-build ordinary/local/remote comparisons, multiple prompts and long context. Preserve the prefill benefit and obtain external TTFT measurements. Encrypted production routing, planner activation, general model integration and failure recovery remain distinct unfinished deliverables.
