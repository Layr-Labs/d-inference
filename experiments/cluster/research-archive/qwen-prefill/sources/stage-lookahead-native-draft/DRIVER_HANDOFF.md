# Native lookahead driver draft

2026-09-14. Source only; no Swift build, model run, transport run or GPU execution
was performed for these native driver drafts. Root owns integration and execution.
The separate pure overlap harness passed earlier; that does not validate this
native wiring, ARC release or model parity.

The supported entry point is:

```swift
runQwenLayerStageLookaheadRequest(
    context: QwenLayerStageLookaheadContext,
    transport: QwenLayerStageLookaheadTransport,
    request: QwenLayerStageRecordedRequest,
    check: () throws -> Void
) throws -> QwenLayerStageLookaheadRequestResult
```

Use a freshly loaded one-shot context and transport after root admission has
proved stageIndex == actual collective rank, common fresh epoch/request UUID,
source/config/artifact/plan identity, world two and flow
`prompt_lookahead_one_v1` / envelope v2. The entry checks the exact immutable
recorded prompt, teachers and timeline against the context and pure plan. It
installs a request-wide MLX error scope, including context capture/logit work.
The `check` callback may check/throw only; it must not evaluate MLX or reenter.

The five new implementation files are independent of root's Context/Transport:

- `QwenLayerStageLookaheadRequest.swift`: scope, role dispatch, unconditional
  failure retirement/cancellation and final clean-result check.
- `QwenLayerStageLookaheadSenderDriver.swift`: pure nextAction driver, one native
  slot, old CPU ticket/capture, actual send-phase mapping and consumed completion.
- `QwenLayerStageLookaheadReceiverDriver.swift`: exact sequential receive/consume
  callback, actual receive-phase mapping, commit frontier and CPU completion.
- `QwenLayerStageLookaheadDriverSupport.swift`: request/capture binding and primary
  plus cleanup error preservation.
- `QwenLayerStageLookaheadRequestResult.swift`: CPU-only result and bounded scalar
  action trace; no timestamp or GPU-overlap assertion.

The sender clears its `prepared` property inside the dispatch autorelease scope;
the scope holds the old boundary through completed Send and validated received
ACK. It returns only a nonce ticket and CPU capture. The original MLXArray weak
handle must be nil after scope exit before `sentSourceReleased` and before the
next preparation. A separate scalar tracks that explicit source slot while a
local dispatch variable, rather than the property, owns it. The weak check proves
release of that wrapper only; it does not prove native storage uniqueness or
exclude aliases retained by state roots or backend buffers.

The receiver callback has the concrete return type `QwenLayerStageRankFrameCapture`.
It does not retain the incoming boundary. Root transport owns the payload/consume
autorelease scope and weak handle check, then calls `consumedBoundaryReleased`
before consumed ACK. The receiver maps `consumptionAndCaptureCompleted` using the
actual `context.committedTokens` after the callback has returned successfully.

Every phase callback maps directly to its pure machine event, then records CPU
state. No phase hook calls MLX or reenters transport. The sender consults native
`hasPendingConsumption` only outside phase callbacks because transport installs
that pending ticket after the received-ACK phase callback returns.

Each consumed completion uses its saved old CPU capture and actual envelope SHA.
Stage zero's live frontier is checked against producedFrames, which can be two
frames ahead of its consumed-ACK frontier. The machine prioritizes exactly one
next prompt preparation; it never prepares decode while an ACK is pending.
There is no production generated-token path. For 65/32/4 the sender must record
two prompt lookaheads and all six completions at final frontier 68. Rank one does
not infer the producer's lookahead count.

`execution.completions` retains the existing completion schema and phase strings:
rank zero `consumed_ack_received_and_validated`, rank one
`consumed_ack_send_completed`. `execution.actions` records every actual phase,
preparation, source release, completion and close, with contiguous ordinal values.
Its cap is `24 * frameCount + 8` (always <=4096). Current driver structure yields
73 sender actions / 85 receiver actions for six frames; these are source-derived
expectations for future audit, not observed native results.

Sender-only `producedFrames`, `receivedFrames`, `promptLookaheadCount` and the three
frontier-gap maxima are optional and omitted on rank one. Every sender action
checks produced-received <=1, received-completed <=1 and total gap <=2. Receiver
records its own committedFrames/completedFrames; its pendingConsumedFrameSlots
means the single admitted active frame, including header phases before payload.
Both report explicit boundary owner slots (not physical allocation totals) and
the count of original wrappers whose release passed its weak check. Captures and
full-vocabulary finite logit vectors live only once in completions; actions do
not duplicate native state or logits.

Any admission, native forward, post-commit capture, phase, check, trace, release,
ACK or close error retires the pure machine and transport, clears prepared/native
owner references and unconditionally cancels the context. Primary and cleanup
errors are preserved. The parent must fence both processes even if local cleanup
fails or blocks; rank one can be blocked sending consumed ACK while stage zero's
next preparation fails. No returned success exists until every final consumed
ACK, local native request retirement and post-result check has completed.

Required next proof: root's integration build; isolated v2 synthetic/tiny phase
checks including failure with a prepared next frame; exact per-frame state and
logit comparison to the separately released frozen baseline; then the bounded
real artifact. Action ordering establishes an opportunity for overlap only.
