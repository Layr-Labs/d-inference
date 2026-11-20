# Accepted assistant rounds after the real Session pass

Source-analysis implementation boundary, not implemented behavior. The fifteen actual tiny Session cases now pass in qwen-mtp-target-session-supervisor-v2-20260915. This note binds the existing assistant and transport code that the next implementation must reuse.

## Next bounded native increment

Join actual target prefix commits with the existing real Qwen assistant finalizer, first in a private single-host two-stage registered9B correctness driver on the48GB machine. Reuse the verified source/Plan loader, actual Session and CBv2 state, model-specific assistant and existing generation control. The staged target transaction must not be reimplemented. Use fresh ordinary-reference and speculative states with an explicit combined resource authority and a short bounded prompt/output run. A full48GB fit still requires source-derived admission and actual live guards; it is not established by this note.

The existing QwenResidentMTPRequest is a one-unaccepted-proposal owner. Its begin guard only admits the first seed, and finishProbe discards the assistant. Add a focused repeated-round lifecycle; preserve the old probe API and results as separate evidence. A real proposal, real target verification, progressive commit, final reconciliation and assistant finalization must occur before a repeat is allowed. Reused round IDs, mismatching generation chains and partial reconciliation poison the request.

## Exact committed-history indexing

For baseF, the proposed target inputs are seed atF and draft atF+1. The actual target produces seedHidden and draftHidden, plus target token2 and a possible bonus. Keep1 consumes only seed; keep2 consumes seed and draft. Join matching rank0/rank1 receipts for the exact verification fingerprint/base/staged/retained/newly-committed/pending/final fields before treating a row as jointly committed. The current tiny fixture checks locally produced pairs; the reusable join must also bind the expected fingerprint rather than merely equality between two receipts.

At final reconciliation:

- Keep1: call the existing assistant finalizeRound with confirmedInputTokens1, empty committedDraftTokens[1,0] and empty committedTargetHidden[1,0,H]. Retain seedHidden as the next raw target carry.
- Keep2: call finalizeRound with confirmedInputTokens2, committedDraftTokens containing the accepted draft, and committedTargetHidden containing seedHidden. Retain draftHidden separately as the next raw target carry.

The accepted draft pairs with the hidden produced by the preceding seed. Passing draftHidden as the accepted draft history row shifts conditioning by one. This matches the production EngineLoopV2+MTPFinalize slice of verify.lastHidden starting at0. The assistant performs targetFinalNorm itself; pass raw pre-norm target hidden exactly once. Do not additionally observeCommittedTarget for these finalized rows because beginRound/finalizeRound already maintain the trusted transition history.

After a completed round, assistant committedInputCount should be target committedTokens minus1; after the next proposal it should equal that pre-verification target frontier. Kept target rows, carry, assistant evaluation roots, output/logit rows and both target transaction increments must remain charged through their actual lifetimes. Two independent guards that each omit the other's reserved future arrays do not prove a combined bound.

## Subsequent two-host path

Reuse the existing Collective completed IO and generation token/decision/retirement transport. Provisional residuals need distinct verification packets and readiness/consumed receipts; ordinary generation boundary ACKs cannot stand for a pending target commit. Bind the opt-in policy, epoch, request, original agreement, round, base, token chain, both builds, dtype/shape/hash and accepted prefix. Keep ordinary/MTP-off encodings byteexact when the option is absent.

Publish each next target token only after both corresponding native prefix commits. Obtain the existing client continue/stop decision before committing another prefix. Reconcile both pending suffixes before repeated assistant finalization. A lost peer or conflicting receipt retains the whole-request failure and existing out-of-band owner fencing obligations.

Correctness and speed are separate gates. The currently tested target stage method evaluates two inputs separately; it does not demonstrate a decode speedup. After a real registered off/on comparison, assess batching the two target inputs and reducing round-trip control cost through the existing captured-state facilities, preserving progressive publication/stop semantics. Do not claim that enabling MTP alone improves TPS.
