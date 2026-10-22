# Profiled prefill wire draft

Source review: 2026-09-14. This additive draft contains pure Foundation codecs
and fabricated CPU fixtures. It has not been Swift-compiled or executed. It
does not introduce native transport, CLI admission, model loading, clocks, or
numerical/performance qualification.

## Integration surface

Copy the eleven `QwenLayerStageProfiled*.swift` files together after integrating
the separately frozen geometry draft. Its `source-review-20260914.json` SHA256
is `8ca2a1d13792501ba13f37322766e30fd232a59e373883dc0c36bd010ddf7ca3`.
`checkQwenLayerStageProfiledPrefillWire()` is the new check entry; its result
contains accepted/rejected case counts and rejection labels. Existing v1/v2/v3
checks must still run unchanged. No existing source file is replaced by this draft.

The local owner constructs `QwenLayerStageProfiledPrefillStartAgreement` from
the new typed `QwenLayerStageProfiledPrefillRecordedRequest`, independently
verified source/stage metadata, explicit scheduling policy and native/logit
dtypes. A received start packet compares to this object; it never constructs
trusted geometry or a request. Legacy-decoded requests cannot enter this API.

`arithmeticEnvironmentSHA256` is a required argument. The future coordinator
must admit its actual process environment before MLX initialization, compute
`sha256(try canonicalJSONData(receipt))` on the resulting
`QwenLongPrefillArithmeticEnvironment.Receipt`, and bind both receipt and hash
in readiness before model loading. The codec checks canonical hash spelling
and exact local/peer agreement; it performs no global environment reads and
does not independently prove what environment produced the supplied hash.

The primary calls are:

- `QwenLayerStageProfiledPrefillStartWirePacket.decode(_:expectedAgreement:)`
- `agreement.boundaryExpectation(for: locallyExpectedFrame)`
- `QwenLayerStageProfiledBoundaryWireHeader` initialized with actual producer metadata
- `QwenLayerStageProfiledPrefillBoundaryEnvelope.decode(_:agreement:expectedFrame:)`
- `QwenLayerStageProfiledPrefillBoundaryAcknowledgement.values/validate`
- `QwenLayerStageProfiledPrefillFirstTokenWirePacket` initialized with actual local selection evidence
- `QwenLayerStageProfiledPrefillPostStopAcknowledgement.values/validate`

## Namespace and bounds

The new inner header is version 2 under the distinct outer version 4 flow
`profiled_prefill_measurement_v1`. It is unrelated to the old version 2
lookahead envelope. Old inner v1 and outer v1/v2/v3 decoders/bytes stay intact;
fixtures reject cross-version and cross-flow substitution in both directions.
Small requests explicitly admitted under the new profile retain their new
identity, including 65/32/1.

Start/boundary/token packet limits are 8/16/4 KiB. The local profile admits
batch 1, prompt 1...8192, chunk 1...512, exactly one output, no teachers or
decode, at most 128 prefill frames, hidden width at most 8192 and vocabulary
at most 262144. Native residuals remain capped at 16 MiB. The maximal
512-by-8192 Float32 frame reaches that cap; the check creates only metadata.

Each receive expectation selects the exact immutable local step by sequence,
compares its complete frame, and derives token digest, shape, dtype and byte
count locally with checked arithmetic. Received dimensions never authorize an
allocation. Intrinsic header bounds are also enforced before encoding.
Original bounded JSON is scanned before Foundation parsing to reject duplicate
or escaped duplicate keys, fractions/exponents, malformed UTF-8 and trailing
content. Closed exact comparison rejects unknown/missing fields and boolean
substitution for integer fields.

## Exact bytes and domains

For agreement/start/boundary/token, a fingerprint is
`SHA256(UTF8(domain + "\n") + exactBytes)`. Agreement bytes are its canonical
descriptor; start/envelope/token retain the original accepted wire bytes.
`wireBytesSHA256` is separately `SHA256(exactBytes)`. The token names its two
boundary commitments explicitly: `finalBoundaryEnvelopeFingerprint` and
`finalBoundaryWireBytesSHA256`. Accepted whitespace therefore changes both
packet commitments and all dependent ACK/token bindings. Inner metadata may
be canonicalized during validation; the enclosing packet retains and binds
the original bytes, including the nested inner representation.

`QwenLayerStageProfiledWireHash` declares all new domains. Boundary ACK material
joins its domain, flow, agreement fingerprint, phase, envelope fingerprint and
raw byte hash with `|`. Post-stop material joins its domain, flow, agreement,
`post_stop_release`, token fingerprint and raw byte hash. Both are 64 ASCII
hexadecimal digest characters represented as 64 Int32 elements (256 bytes),
not 32 decoded digest bytes. Ready/received/consumed phases remain distinct.

## Remaining native owner responsibilities

`QwenLayerStageProfiledPrefillWireLifecycle` gates only endpoint milestones:
start, final boundary, final consumed ACK, first token. It does not implement
the per-frame frontier or prove that earlier frames executed. The native owner
must sequence every header/payload/ACK from its admitted schedule, check actual
array ownership/dtype/shape/logical bytes, evaluate/fence transport, commit
state, and supply the next expected local frame. Constructor conveniences
based on expectations are for CPU fixtures; native producers must use actual
observed boundary/selection metadata.

On rank zero, the completed token decode precedes the stop timestamp; only
then may post-stop release be sent. Rank one waits for that release before
post-stop diagnostics/retirement. The pure types contain no clock. Resource
admission, model/source/binary/hardware binding, one-slot lookahead limits,
whole-cohort deadlines and failure cleanup remain separate requirements.

## Prospective verification

`profiled_wire_vectors.py` independently defines the canonical JSON/hash recipe
and writes new outputs exclusively. `wire-vectors-20260914.json` includes exact
base64 bytes, domain/raw digests and ACK vectors. The generated Swift golden
check compares actual future Swift serialization against these recipes,
including unchanged legacy fixture bytes. Python recipe checks alone cannot
establish that the Swift implementation compiles or accepts/rejects correctly.

The fabricated 8192/512/BFloat16 fixture has start/boundary/token sizes
1873/1277/1146 bytes. Swift fixtures cover both scheduling policies, all three
floating dtypes, ragged and maximum-frame geometry, malformed controls,
source/history/request/policy/environment mismatch, byte-bound ACKs, replay,
ordering and legacy separation. No model payload is read, and no 8K model
result, physical transfer, overlap, throughput or quality claim follows.
