# Additive v3 native prefill transport

Source-only draft. No repository/runtime edits, build, native/GPU/model execution,
SSH, timing or CLI work was performed. It depends on frozen v3 wire manifest
`6bd3fdbf16650a8c33c3c9b3771bcca7b5b7a55ce0c1c04c35b0bb23413750c2` and leaves the
tested v1/v2 native paths unchanged. The seven files separate progress/tickets,
CPU result types, the existing P2P calls, the guarded owner, control operations,
sender and receiver. A bounded independent source review found no blocker.

## API

```swift
QwenLayerStagePrefillTransport(
    collective: Collective,
    agreement: QwenLayerStagePrefillStartAgreement,
    admittedRank: Int
) throws

sendStart(_ packet: QwenLayerStagePrefillStartWirePacket,
          onPhase: (QwenLayerStagePrefillControlPhase) throws -> Void, check:) throws
receiveStart(onPhase:check:) throws -> QwenLayerStagePrefillStartWirePacket

sendUntilReceived(_ boundary: QwenLayerStageBoundary,
                  expectedFrame: QwenLayerStageFrame,
                  onPhase: (QwenLayerStagePrefillSendPhase,
                            QwenLayerStagePrefillBoundaryTicket) throws -> Void,
                  check:) throws -> QwenLayerStagePrefillBoundaryTicket
finishConsumed(_ ticket: QwenLayerStagePrefillBoundaryTicket,
               onPhase:check:) throws

receiveAndConsume(
    expectedFrame: QwenLayerStageFrame,
    consume: (QwenLayerStageBoundary) throws -> QwenLayerStagePrefillConsumption,
    onPhase: (QwenLayerStagePrefillReceivePhase,
              QwenLayerStagePrefillBoundaryTicket?) throws -> Void,
    check:
) throws -> QwenLayerStagePrefillReceiveResult

sendFirstToken(onPhase:check:) throws -> QwenLayerStagePrefillFirstTokenWirePacket
receiveFirstToken(onPhase:check:) throws -> QwenLayerStagePrefillFirstTokenWirePacket
sendPostStopRelease(onPhase:check:) throws
receivePostStopRelease(onPhase:check:) throws
retire() // Pure failure poisoning; no native operation.
```

Every `check` is `() throws -> Void`. Control callbacks use
`QwenLayerStagePrefillControlPhase`. Boundary send phases reuse the existing
`QwenLayerStageLookaheadSendPhase` meanings through a type alias. Receive phases
are explicit v3 names in `TransportTypes.swift`; `consumptionAndSelectionValidated`
replaces the old captured-result event. All phase/check callbacks must perform
only CPU bookkeeping/checks. They must not run model work, call another native
transport or enter this owner recursively. Exactly one synchronous MLX caller
is allowed per process; the owner is not a general cross-thread scheduler.

`QwenLayerStagePrefillConsumption` holds the actual `QwenLayerStagePrefillCommit`
and optional actual `QwenLayerStagePrefillTokenReceipt`. Final requires selection;
intermediate requires nil. `QwenLayerStagePrefillReceiveResult` holds only
`ticket`, `commit`, `selection` and `tokenPacket`. These are CPU values. There is
no generic callback result that can hide an array or retain a native graph.

The ticket holds only a v3 envelope plus private issuing-owner and per-ticket
UUIDs. Public fields are `envelope`, `frame` and `headerSHA256` (exact v3 envelope
bytes). It deliberately has no v2 `OverlapTicket`/`scheduleTicket`, because those
bind a different flow. The future driver owns the separately bound serial or
one-prompt-lookahead preparation policy.

The transport exposes `rank`, `agreement`, `startCompleted`,
`hasPendingConsumption`, `completedBoundaryCount`, `tokenTransferCompleted`,
`postStopReleaseCompleted`, `isComplete` and `isFailed`. `isComplete` describes
protocol IO only; it never claims model/request retirement. The driver still
checks its contexts and model release separately.

## Ownership and order

Constructor admission requires the expected rank, actual collective rank and
two-process group to match. The existing Cmlx shim also checks actual native
group identity for each P2P call. Source agreement is immutable and locally
prepared from verified models/request metadata; the native driver must bind its
actual context identities to it before use.

Rank zero takes its start timestamp before `sendStart` and constructs fresh
request state only after it returns. Rank one strictly decodes `receiveStart`
before constructing fresh request state. Pre-clock model loading/readiness and
agreement exchange remain the driver's responsibility. No context is created
by this transport.

Sender frame order is checked against the immutable local request before IO.
The v1 inner header is built from the **actual** native boundary fields, shape,
dtype and length; it is validated against the local expectation and actual
copied payload SHA before v3 envelope construction. Header send → ready ACK →
payload send → received ACK returns an owner-bound CPU ticket. Pending state is
installed before the received-completion phase hook. `finishConsumed` accepts
only that pending ticket, validates the consumed ACK and advances the completed
frame count before its completion hook. A second header cannot precede this
drain, and stale/cross-owner tickets permanently fail the transport.

The caller must release its PreparedFrame/native source wrapper after received
ACK and before preparing a next prompt frame. This transport retains no producer
array after returning, but cannot release the caller's reference. Serial drains
before the next preparation; one-lookahead may prepare exactly one next prompt
frame before draining. Neither policy admits decode in this bounded output-one
flow. No preparation work belongs inside transport phase callbacks.

Receiver order is validated header → ready ACK → owned native receive and SHA
validation → received ACK → callback/commit validation → optional final token
packet validation → original-wrapper release → consumed ACK. The payload and
callback run inside an inner autorelease scope, returning only the concrete CPU
result. A weak reference must prove the original received MLXArray wrapper is
gone before `consumedBoundaryReleased` and before consumed ACK. This is an
original-wrapper release check, not a claim that arbitrary forbidden callbacks
cannot squirrel away a different alias. The actual native owned-storage check
still runs before the callback.

Final token creation occurs inside that scope **before final consumed ACK**.
It validates the actual selection's complete source/session/request identity,
final frame/frontier, vocabulary, native dtype/shape, argmax/finite policy and
ordinal zero. Only the encoded CPU packet is retained in transport state.
Intermediate commits require narrowed `[1,1]` output and no selection; final
requires `[1,V]` logits with the independently agreed final-logit dtype.

All boundary IO must finish and the sender's pending consumed ACK must be drained
before token operations. Rank one sends only its saved final packet. Rank zero
strictly validates that packet against the exact final envelope it sent. Only
after `receiveFirstToken` returns may rank zero record the first-token stop.
It then calls `sendPostStopRelease`; that call is a semantic event, not evidence
the clock was read. Rank one waits for `receivePostStopRelease` before final
snapshots, full-logit diagnostics or teardown. Post-stop ACK/retirement are
separate work and cannot be silently subtracted from an earlier interval.

## Native costs and failure

`CollectivePointToPoint` and its Cmlx CPU-stream send/receive implementation are
unchanged. Control lengths are UInt32[1], control bytes UInt8, ACKs Int32[64].
Payload receive uses only locally known shape/dtype/byte bounds after header
validation. Native F16/BF16/F32 payloads are never converted, packed, compressed
or routed through a reduction. Existing CPU/GPU completion fences, staging and
ownership checks remain. New controls deliberately include exact copied host
bytes and strict parsing/hashing; this is not a zero-copy or throughput claim.

Each public operation is single-entry and installs an MLX error scope; native
control construction/readback helpers check their own MLX scope immediately.
Checks run after every callback and before/after completed native operations.
If a callback catches an attempted recursive-entry error, the owner remains
poisoned and the next check throws. Any IO, callback, metadata, selection or
release failure poisons the entire transport and discards pending CPU progress.
The original error is rethrown. Native context cancellation is intentionally
external: the driver must cancel its context(s), preserve primary and cleanup
errors, and fence the whole pair on every error, including failures before any
transport operation or after a native model commit.

`retire()` cannot unblock a peer inside synchronous native send/receive. Existing
independent native alarms, parent deadlines and pair process cleanup remain
required. No restart/retry with the same agreement, request UUID or epoch is
authorized. There is no native execution evidence for these draft files yet;
root owns compilation, bounded smoke, actual driver integration and validation.
