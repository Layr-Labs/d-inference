# Bounded prefill start and first-token return

This is a Foundation-only source draft. It contains no clock, model execution,
native receive allocation, P2P call or changes to existing v1/v2 code. The CPU
checks are drafted but have not been executed. Integration still owns truthful
event ordering, deadlines, native ownership and peer fencing.

## Typed contract

`QwenLayerStagePrefillStartAgreement` takes a locally known immutable recorded
request, a canonical 32-hex cohort epoch, the verified common source identity,
both compact configuration hashes, the consumer stage fingerprint, native
transformation, hidden width, residual dtype, independently qualified logit dtype,
and `SchedulingPolicy.serial` or `.promptLookaheadOne`. It retains CPU metadata
only. Scope is batch one, prompt 1...128, chunk 1...32, output one, no teachers,
hidden width 1...8192 and vocabulary 1...262144. Both ranks already know the same
prepared input IDs; wire data never becomes authoritative request input.

The new version is **3**, flow **`bounded_prefill_measurement_v1`**. Policy values
`serial_v1` and `prompt_lookahead_one_v1` are explicit fields in the agreement
descriptor and its fingerprint. The descriptor also binds epoch, request UUID,
spec fingerprint, recorded-request fingerprint, full prompt-token hash, counts,
both stages, source artifact/configuration/storage/plan, widths/dtypes, and native
selection policy. Its fingerprint is SHA-256 of the fixed domain
`qwen-prefill-start-agreement-v1\n` followed by canonical descriptor JSON.

`QwenLayerStagePrefillStartWirePacket(agreement:)` prepares the start packet.
`decode(_:expectedAgreement:)` checks its complete contents against the locally
admitted descriptor. The 8 KiB closed object is
`{version,flow,kind:"start",agreementFingerprint,agreement}`. No packet can
renegotiate a policy, shape, input ID or model after readiness.

`QwenLayerStagePrefillBoundaryEnvelope(boundary:agreement:)` is a small pure v3
envelope over the unchanged v1 boundary header. Its 16 KiB closed schema is
`{version,flow,kind:"boundary",agreementFingerprint,boundary}`. Decode additionally
takes the locally scheduled `expectedFrame`; it delegates complete header and
geometry validation to the existing v1 decoder. Its fingerprint hashes the
exact received outer bytes. Serial and lookahead use the same `ready`,
`received`, `consumed` ACK phases, each 64 ASCII digest values encoded as Int32
(256 bytes). ACK domain is
`qwen-stage-ack-v3|flow|agreementFingerprint|phase|exactEnvelopeSHA256`.
Old v1/v2 envelopes and ACK namespaces remain incompatible before payload IO.
The new native boundary transport is deliberately not implemented here.

`QwenLayerStagePrefillFirstTokenWirePacket(selection:agreement:finalBoundary:)`
takes the **actual** existing CPU token receipt. It compares every source/session
identity field, exact request/frame/frontier, vocabulary, ordinal zero, uncast
native argmax plus finite-guard policy, output shape/dtype and UInt32 selection
dtype before encoding. This is why sender integration must not replace the
actual receipt with expected fields. The 4 KiB packet carries version/flow/kind,
agreement/epoch/request identities, consumer stage fingerprint, exact final
boundary-envelope SHA, final frame/frontier, vocabulary, token ordinal, selection
policy, selected token ID, logit shape/dtype, selection dtype and finite flag.
Source/configuration/spec are bound through the validated agreement fingerprint.
The receive decoder independently derives every value except the selected token
from local agreement/final-envelope data, then requires that original integer to
be in the known vocabulary. It receives no logits or state snapshots.

These source files import Foundation only and reuse the existing CPU
`QwenLayerStageSessionIdentity` and `QwenLayerStagePrefillTokenReceipt` declarations.
Those declarations currently share repository files with native types. An
isolated interpreter harness must include just their CPU declarations plus the
existing Foundation request/schedule/header/scanner/hash helpers; importing or
executing MLX is not required by this codec.

## Exact ordering and clock placement

1. Load and verify the actual models; prepare the fixed token IDs, construct the
   local agreement, exchange/validate readiness fingerprints, and finish any
   previously qualified warmup with retired request state. These steps precede
   the measured start. This diagnostic assumes both ranks have the prepared IDs;
   it does not include an unimplemented raw-token distribution operation.
2. Rank zero records its monotonic start immediately before start-packet send
   and before constructing its fresh compute context. Rank one receives and
   strictly admits start **before** constructing its fresh compute context.
   Neither rank may create fresh request state during pre-clock readiness.
3. Each v3 boundary uses header → ready ACK → payload → received ACK → native
   consume/commit → consumed ACK. Serial prepares the next frame only after
   consumed; lookahead may prepare one next prompt frame after received, then
   drains consumed before the next header. The already qualified one-thread
   native ownership and queue bounds remain obligations of the future owner.
4. For the final frame, rank one evaluates the narrowed full vocabulary row and
   all required state roots, commits the final frontier, performs native argmax
   plus finite reduction/scalar reads, and prepares the validated token packet.
   It releases the received boundary before sending final consumed ACK, then
   sends the token packet. Selecting before this ACK ensures a selection failure
   cannot masquerade as a successful token-return phase.
5. Rank zero validates final consumed ACK, receives the bounded token packet,
   and validates it against that exact final envelope and agreement. It records
   its stop only when **both** final consumed and first selected token are valid.
   A consumed ACK, report-file arrival or typed token packet by itself is never
   the stop event.
6. **After recording stop**, rank zero sends `post_stop_release`, a 256-byte
   digest ACK bound to the agreement and exact token packet bytes, and waits for
   that send's completion. Rank one validates it before beginning native teardown.
   Both ranks then close/release request state. This ACK and retirement are
   separately recorded post-stop work, not part of first-token latency. The ACK
   is necessary to prevent rank-one teardown from racing into rank zero's
   interval before its token receive/validation finishes. No timestamp travels
   on the wire, and the pure codec cannot prove the caller read its clock first.

Start encoding can be prepared before the clock. Start send/receive validation,
fresh state creation, all prompt compute/commit/evaluation, existing residual
hashing/copies/fences, boundary handshake, final norm/head, native selection and
token return remain inside the proposed interval. Final diagnostic snapshots,
full-logit copying and evidence serialization must wait until the stop is
recorded on rank zero and the post-stop release reaches rank one. This draft
performs or measures none of these operations.

## Strictness, replay and failure

All receive entries bound bytes first and invoke `validateWorkerJSON` on the
original nested input before Foundation parsing. It rejects duplicate decoded
keys, fractions/exponents, trailing data and malformed input. Closed-schema
comparison preserves distinctions between integer, Boolean, string and null.
Boundary decoding additionally checks original nested numeric types before
delegating to v1. Accepted insignificant whitespace is preserved where ACKs hash
exact envelope/token bytes; semantic start agreement remains canonical.

`QwenLayerStagePrefillWireLifecycle` combines decoding with one-shot acceptance
of start, final boundary, final consumed and token in order. Every malformed,
out-of-order or replayed event poisons it. `firstTokenComplete` requires both
final consumed and token acceptance. `QwenLayerStagePrefillPostStopGate` separately
rejects invalid/replayed release ACKs on rank one. These do not authenticate a
peer or remember epochs across recreated processes; the coordinator must admit
a fresh request UUID/epoch and permanently fence the failed cohort. A new gate
with an old agreement is not an authorized retry.

Any parse, selection, callback, native or transport failure retires both request
contexts and both protocol states. A peer can be blocked in ACK send/receive, so
an external process deadline and pair fencing remain required. Teardown failure
after a valid token must still fail the run's completion record; it must not be
discarded because a first-token timestamp already exists.

`checkQwenLayerStagePrefillWire()` returns CPU-only check metadata. Its fixtures
cover both scheduling policies and all three native dtypes; minimum/maximum
request bounds; actual selection identity mismatches; changed source/request/
policy; duplicate/escaped-duplicate keys, Boolean/fraction/exponent integers,
unknown/missing fields, wrong token metadata and vocabulary range; exact-byte
ACK binding; and one-shot/out-of-order lifecycle failures. Native IO, actual
clock placement and peer cleanup remain untested until a separately reviewed
owner integrates this draft.
