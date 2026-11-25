# Committed history and one proposal: source draft

This increment adds a private final-rank request owner over the actual verified
9B cut4 MTP assets. It passes native typechecking; registered history/proposal execution is still pending. The
successful48GiB loading check established target/head/replica payload ownership;
it did not establish any forward, history or accepted-prefix behavior.

`Qwen35ClusterMTPForward.forward` uses the existing residual-ingress Qwen trunk
exactly once and returns pre-final-norm hidden beside the ordinary narrowed
target output. `QwenLayerStageSession` adds explicit capturing methods; ordinary
prefill/decode bodies retain their existing nil-capture path. The shared state
core evaluates hidden with output/recurrent/KV roots, validates, then commits.
The consumable capture is created only after the session schedule also commits.

`QwenResidentMTPRequest.prefill` keeps that capture pending. Its
`observeCommitted` requires the existing generation control's two frame ACKs,
exact frame/input tokens and source/request identity. It delegates normalization
and cross-chunk hidden[t]→token[t+1] pairing to the unchanged assistant. It
retains raw final hidden as the seed carry; it does not normalize assistant
hidden again or treat the selected output as a consumed target input.

After the first target token and continue decision are both acknowledged,
`propose` calls the existing full-head `draftStep` once, evaluates its cache and
other roots, and returns a scalar tagged by request, base agreement, round,
committed input frontier, seed and token-chain digest. `accepted` remains false.
Discard is terminal for this single-proposal owner, preventing duplicate replay
of the trusted seed restored by the assistant's `discardRound`. Retirement
cancels the incomplete target session and releases assistant roots without an
expired-deadline callback; the outer owner still owes peer retirement/fencing.

The owner derives the existing target allowance plus the existing assistant
allocation projection, captured hidden and named proposal intermediates using
actual allocation bounds. It requires an explicit same-Mac deadline≤300s and a
caller reservation covering that sum. The caller must pass a deadline no later
than its enclosing loaded-owner deadline and retain the reservation until both
local and peer retirement. The named budget is not a whole-kernel peak claim.
No loader, weight receipt, worker, Provider, capability or wire DTO is changed.
The base generation agreement still declares MTP disabled; this is a separate
private proposal probe, not a bilateral MTP execution agreement.

## Next target transaction, before any MTP-on execution

The target's `CBv2OwnedRequestState.run` currently commits every forward. Its
cleanup rollback explicitly does not make advanced target attention KV reusable.
Calling run twice and trimming afterward is therefore not a verification API.
The next bounded native interface must provide these operations together:

1. `beginVerification(proposal)` binds both ranks to one round, original frontier,
   source/build/assistant placement, greedy full-head policy and depth1. Admit
   storage for both target recurrent generations and all speculative KV writes.
   Require every actual KV row's `supportsSpeculativeWrites` before mutation.
2. `stageSeed` and, if still allowed, `stageDraft` perform serial one-token target
   forwards while retaining their recurrent evaluations and reversible KV
   transaction. No session schedule or canonical token history advances yet.
   Reuse `beginSpeculativeWrite`, `rollback`, `commitSpeculativeWrite`, and
   recurrent evaluation commit/rollback; do not duplicate model math.
3. `reconcilePrefix` derives retained target input count from target-authoritative
   outputs and EOS/length/client-stop policy. For depth1, one or two inputs may
   remain: the seed, optionally the draft. Matching/published draft count and
   consumed draft-input count differ when generation stops on that draft.
   Roll back rejected recurrent evaluations in reverse order, commit kept ones,
   roll back the KV suffix and commit its transaction on every rank.
4. Only after matching both-rank reconciliation ACKs may the assistant call
   `finalizeRound(confirmedInputTokens:1+committedDraftInputCount, ...)` and outputs
   become publishable. For one consumed draft, pass that draft token with the
   target hidden from the preceding seed input (verify hidden row0), not the
   assistant hidden or the target hidden produced by consuming the draft itself.
5. Failure/cancellation retains all charges, rolls back or retires local target
   and assistant state, then requires actual peer retirement/fencing. It cannot
   turn sent cancellation, timeout, EOF or a proposal match into successful ACKs.

Local `EngineLoopV2+MTPFinalize.swift:197–257` is the source for target-first
reconciliation and assistant finalize ordering. `Qwen35MTP.swift` owns trusted
history, proposal math, suffix trim and release. Its generic local engine also
supports sampled target-prefix acceptance and rectangular verification; neither
is admitted by this first distributed proposal path.
