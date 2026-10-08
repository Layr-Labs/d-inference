# Bounded layer-stage boundary header

These are Foundation-only source drafts. A standalone Swift harness assembled
from the exact pure source files passed six valid frames and 44 rejection
fixtures on 2026-09-14. The harness imported Foundation/CryptoKit, never MLX; it
did not build the inference target or execute GPU/native transport operations.
The drafts add a header value and validation helpers, not another worker
protocol or transport implementation. There is no performance or multi-machine
correctness claim from this CPU check.

## API

```swift
let source = try QwenLayerStageWireSourceIdentity(
    sourceConfigurationSHA256: localReceipt.sourceConfigurationSHA256,
    artifactAggregateSHA256: localReceipt.verifiedAggregateSHA256,
    storageCommitmentSHA256: localReceipt.storageCommitmentSHA256,
    planFingerprint: localPlan.fingerprint,
    producerStageFingerprint: localPlan.stages[0].fingerprint)

let expected = try QwenLayerStageBoundaryWireExpectation(
    request: admittedRequest, frame: nextExpectedFrame, tokenIDs: actualFrameTokens,
    sourceIdentity: source, hiddenSize: admittedHiddenSize,
    nativeDType: admittedActivationDType)

let header = try QwenLayerStageBoundaryWireHeader.decode(
    receivedHeaderData, expected: expected)
// Only now receive the residual using expected.shape, expected.dtype,
// and expected.byteCount, all derived from local admission.
```

The source identity is supplied from the receiver's verified stage receipt and
source plan. Its constructor checks canonical lowercase SHA-256 syntax; it does
not verify a checkpoint itself. The existing storage commitment binds the
checkpoint conversion policy. The producer fingerprint is stage zero's source
plan descriptor, even on the receiving stage-one process.

The expectation reconstructs the bounded pure `QwenLayerStageSchedule` to prove
the supplied frame belongs to the admitted request. The caller remains
responsible for selecting the currently expected frame: the helper neither
advances a live request nor approves replays. It checks token count and
nonnegative Int32 token representation, then hashes the exact supplied IDs using
the existing boundary token-hash convention. Vocabulary validation remains with
the original admitted request and actual stage session.

The header has no independent connection epoch. The launcher must bind the
agreed request UUID to the newly admitted two-rank cohort and use a fresh UUID
after any fenced failure/restart. Both ranks receive the same locally admitted
request specification; they must not generate independent request UUIDs.

Expected residual layout is always `[1, frame.tokenCount, admittedHiddenSize]`.
Token count is at most 32, hidden width at most 8192, and dtype exactly Float16,
BF16 or Float32. The trusted byte count is derived from these values and is at
most 1 MiB. No incoming shape or dtype controls a receive allocation.

## Sender and receiver obligations

After stage zero returns its evaluated, committed boundary, a native sender
adapter constructs `QwenLayerStageBoundaryWireHeader` from the **actual** boundary
identity/frame/token/payload hashes and actual array shape/dtype/byte count. The
explicit initializer takes those fields plus a `QwenLayerStageWireSourceIdentity`.
Call `validate(expected:)` before `encoded()` and sending. The convenience
`init(expected:payloadSHA256:)` is useful for pure checks and independently
validated metadata; it must not hide an actual producer discrepancy by copying
expected fields over mismatched actual fields.

The header's only accepted version is 1. Its exact field set is `version`,
`requestFingerprint`, `sourceConfigurationSHA256`, `artifactAggregateSHA256`,
`storageCommitmentSHA256`, `planFingerprint`, `producerStageFingerprint`, `frame`,
`tokenIDsSHA256`, `payloadSHA256`, `shape`, `dtype`, and `byteCount`. The frame is
also closed: `sequence`, `phase`, `tokenOffset`, `tokenCount`, `finalPromptChunk`.
Every field is mandatory; unknown fields, nulls, duplicate keys (including
escaped duplicates), fractional/exponent integer syntax, and Boolean counts or
dimensions are rejected. The final-prompt flag must be a JSON Boolean.

The transport first receives its fixed-width header-length control. It must
reject zero or lengths above `Header.maximumEncodedBytes` (16384) before posting
the bounded UInt8 JSON-header receive. `decode(_:expected:)` repeats that byte
bound before scanning or JSON parsing, then invokes `validateWorkerJSON`,
checks exact top-level/frame fields and strict integer types with
`BoundedProbeInput.integer`, and decodes the scalar value. All expected request,
source, frame, token, shape, dtype and length fields are compared before this
method returns. The raw bytes may contain whitespace and arbitrary key order;
the decoded values must satisfy the same closed contract.

Bare `JSONDecoder().decode(Header.self, from:)` is intentionally rejected. Only
the bounded/scanned static decoder supplies a private decoding permit. This
prevents callers from accepting a header through Foundation's permissive
integer decoding or extra-field behavior. The type remains `Codable`; encoding
is standard Codable, while its accepted raw input entry is explicit and bounded.

After residual receive, the adapter must validate actual logical payload bytes,
then reconstruct the existing `QwenLayerStageBoundary` using the header fields
and the actual received array. `validatePayload(Data)` provides an optional
CPU-only length/digest check. The native path can instead use the existing
boundary owned-array validation, which checks payload hash, shape/dtype/bytes,
unique compact allocation and zero data offset before stage one consumes it.
The header alone cannot establish that the payload digest is truthful. Numeric
conversion of a UInt8 representation is not a substitute for preserving native
floating-point bytes.

The sender retains its boundary until checked send completion. A send completion
does not prove consumption: the root adapter must send a matching acknowledgement
only after stage one's forward has evaluated and committed its output and all
request-state roots. Keep one boundary in flight, select the next expected frame
only after that acknowledgement, and retire request/cohort state on any error.
This file does not implement acknowledgements, retries, process deadlines, or
group recovery.

## Pure check and integration

`checkQwenLayerStageBoundaryWire()` exercises the six prompt65/chunk32/output4
frames and rejects identity, sequence, token, layout, length, version, field-set,
JSON type/syntax, size-limit, raw-decoder-bypass, and payload digest/length faults.
It allocates only tiny Foundation `Data` fixtures and does not execute MLX.

Dependencies are the existing pure `QwenLayerStageRequestSpec`,
`QwenLayerStageFrame`, `QwenLayerStageSchedule`, `validateWorkerJSON`,
`BoundedProbeInput`, `canonicalJSONData`, `sha256`, `ProbeError`, and the pure
check's `emitJSON`. No MLX model/array type appears in a stored property or
signature. Root owns integration into Sources, CPU check wiring, native adapter,
framing/control messages, and all native/transport tests. These drafts edit no
existing source, CLI, model constructor, worker protocol, or submodule.
