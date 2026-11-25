# Additive native profiled-prefill transport

Source draft only, 2026-09-14. No native execution, model payload, SSH, build or
candidate output access occurred while preparing these files. Copy the eight
Swift files into the experiment only after root review. All v1/v2/v3 sources
and the integrated pure v4 codecs remain unchanged.

`QwenLayerStageProfiledPrefillTransport` is constructed with
`init(collective:agreement:admittedRank:)`. It requires the admitted rank of a
two-rank group. It does not initialize a backend, load models, create a context,
parse a reference descriptor, exchange pre-clock readiness or start a timer.
The coordinator supplies the locally admitted v4 agreement, including its actual
pre-MLX arithmetic environment commitment, source/storage identity and policy.

The methods mirror the prior native transport with distinct v4 types:

- `sendStart(_:onPhase:check:)` / `receiveStart(onPhase:check:)` use the new v4 start packet.
- `sendUntilReceived(_ prepared: QwenLayerStageProfiledPrefillPrepared, expectedFrame:onPhase:check:)`
  returns a CPU-only `QwenLayerStageProfiledPrefillBoundaryTicket`.
- `finishConsumed(_:onPhase:check:)` validates exactly that owner's pending nonce.
- `receiveAndConsume(expectedFrame:consume:onPhase:check:)` accepts a callback
  returning `QwenLayerStageProfiledPrefillConsumption { commit, selection? }`,
  and returns `QwenLayerStageProfiledPrefillReceiveResult { ticket, commit,
  selection?, tokenPacket? }`. All returned fields are CPU metadata.
- `sendFirstToken` / `receiveFirstToken` return the new v4 packet. Only the actual
  final native selection is encoded, before the final consumed ACK is sent.
- `sendPostStopRelease` / `receivePostStopRelease` bind the exact token packet
  bytes. The sender's stop timestamp must precede release; the receiver waits
  for validated release before final digest copies, state capture or retirement.

All method callbacks include `check: () throws -> Void`. Send phases receive a
ticket; receive phases receive an optional ticket before header validation;
control phases receive their enum only. The new phase enums retain the prior
case spellings for coordinator action recording. Ticket fields are `envelope`,
`frame`, `envelopeFingerprint` and `envelopeWireBytesSHA256`. They intentionally
do not offer an ambiguous `headerSHA256` alias. Owner and nonce remain private.

The transport permits one pending consumed ACK. Received ACK means the receiver
has validated its completed, unique, compact, zero-offset native allocation and
payload hash. The sender then returns only a CPU ticket; its caller must leave
the Prepared/native-array autorelease scope and prove original-wrapper release
before preparing the next chunk. The receiver retains its payload through the
actual model consumption, exits its native autorelease scope, and checks a weak
original handle before sending consumed ACK. No extra payload copy is added.
This proves original-wrapper release, not the absence of arbitrary aliases a
forbidden side-effecting callback might retain. Policy-specific lookahead bounds
and sender release proofs remain coordinator-owned.

The sender checks the complete actual Prepared commit/history/source/output,
then constructs a header from actual residual shape, dtype, byte count, token
hash and payload hash. It checks both local agreement and prepared expectation;
it does not synthesize an actual boundary from expected values. Receive geometry
comes only from admitted local history before posting a payload receive. The
inner-v2/outer-v4 decoder, 16 MiB residual cap, 8/16/4 KiB start/header/token caps,
and exact ready/received/consumed and post-stop hash domains are reused unchanged.
The raw envelope/token byte hashes are checked separately from their domain
fingerprints throughout final-token state transitions.

`Collective.sendCompleted` / `receiveCompleted` reuse the existing Cmlx CPU-stream
shim. It checks C construction/evaluation/synchronization statuses, fences CPU
and GPU completion and validates receive ownership; it performs no reduction or
float cast. The shim intentionally uses `StreamOrDevice.cpu`: the pinned Swift
`StreamOrDevice.stream(_:)` ignores its argument. No model/transport MLX graph
may run concurrently inside a process. Phase callbacks record CPU metadata only;
`check` only checks/throws. The receiver's admitted consumer is the sole callback
allowed to run the model. Array/control/hash copies and fences are real costs;
this draft makes no transport performance or physical-link qualification.

Any operation/callback/MLX error permanently retires this transport and discards
pending CPU tickets. `retire()` does no native IO and cannot unblock a peer in a
backend call. The coordinator must retire/cancel its compute owner, preserve
primary and cleanup errors, and let the independent worker/cohort deadlines
terminate both processes; no retry or reuse of the failed epoch is supported.

Root can invoke `checkQwenLayerStageProfiledNativeTransportState()` in the pure
adapter checks. Its source defines two simulated 16-frame roles and 14 rejection
cases (role/order, stale/foreign nonce, pending ACK, recursive reuse and final
token/post-stop admission). It executes no IO or model commit and has not been
compiled or run here. `review-native-wire-source.py` checks source separation,
typed API dependencies, unchanged low-level completion contracts and critical
ordering sites; its receipt is a source review, not native verification.
