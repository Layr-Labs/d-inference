# Explicit long-prefill geometry foundation

Source-only draft, 2026-09-14. The five implementation files and three focused
fixture files import Foundation only. No existing repository source, native
code, protocol, CLI or compute path was changed here. No Swift build, native
execution, GPU work or SSH was performed. Root owns integration and validation.

## Stable API

- `QwenLayerStagePrefillProfile.longPrefill8KV1` has raw value
  `long_prefill_8k_v1`, a distinct profile fingerprint, and named maxima for
  prompt count 8192, chunk size 512, frame count 128, hidden size 8192 and
  vocabulary size 262144.
- `QwenLayerStageProfiledPrefillRequestSpec(profile:requestID:batchSize:
  promptCount:chunkSize:outputCount:) throws` admits batch one, positive bounded
  prompt/chunk counts, output exactly one and `ceil(prompt/chunk)<=128`.
  `prefillFrameCount` and `maximumTokens` are checked derived values; the latter
  reserves the output position, so 8192 tokens require a model context of 8193.
- New raw request bytes enter `QwenLayerStageProfiledPrefillRequestSpec.decode(_:)`.
  It bounds input at 2 KiB, uses the existing strict raw JSON scanner, requires
  exactly six fields, and grants a private decoder permit only after checking
  raw integer types. The custom decoder calls the same throwing initializer.
  `.encoded()` returns canonical JSON. There is no omitted/default profile.
- `QwenLayerStageAdmittedRequest` is the closed enum `.legacy(existingSpec)` or
  `.profiled(newSpec)`. It exposes requestID, batch/counts, profile, fingerprint,
  prefillFrameCount, forwardCount and maximumTokens. It has no free-integer
  initializer, decoder or replacement fingerprint domain.
- `QwenLayerStageAdmittedSchedule(request:)` accepts that already-admitted enum.
  Its nonthrowing initializer does not admit raw geometry. The original
  admitPrefill/admitDecode/commit and frontier API remains available. Legacy
  calls delegate to the unchanged original schedule. Profiled calls use a
  checked prefill-only state machine and reject every decode request/frame.
- `QwenLayerStageProfiledPrefillRecordedRequest(request:vocabularySize:prompt:
  teacher:) throws` binds the exact prompt and requires an empty teacher list.
  It exposes request, vocabularySize, promptTokenIDs, teacherTokenIDs, steps and
  fingerprint. Each step has the existing frame type, tokenIDs,
  committedTokens and expectsLogits. Only the final prompt step expects logits.
  No raw recorded-request decoder can construct a large unvalidated token list.

## Integration boundaries

The legacy `QwenLayerStageRequestSpec` initializer, custom decoder, four-field
encoding, v1 fingerprint and all its limits are untouched. The wrapper returns
the legacy fingerprint verbatim. The new request and recorded-request domains
include the named profile and its fingerprint, even when using a short prompt.

The legacy decoder's historical treatment of extra JSON fields is likewise
unchanged. Never decode a profiled request as the old type and then promote it:
an old decoder is not a profile-dispatch mechanism. A future wire adapter must
select the explicit version/profile namespace and compare local fingerprints.
The new strict request decoder rejects missing/unknown profiles and extra keys.

The shared session adapter can add an explicit `profiledRequest:` convenience
initializer while retaining its existing `request:` initializer. Both may
enter a private `admittedRequest:` initializer, use the normalized schedule,
and use `.maximumTokens` for reserved state capacity. None of this changes the
model's full widths, layer ownership, recurrent roots, token positions, output
arithmetic, native boundary checksum/copy, commit checks or retirement rules.

The profile is request geometry, not model or resource admission. Hidden/dtype
maxima in the profile fingerprint are constraints for future model/wire
admission; this CPU request constructor receives no model or residual. Caller
input parsing remains independently bounded. A future 9B run still needs the
registered artifact, exact new 8K input, same-chunk baseline, environment,
named-tensor budget, OS screens, deadline and retirement gates. Existing
v1/v2/v3 start/header/token/ACK paths remain unchanged and are not widened by
this foundation. No new protocol is implemented in these files.

## Prospective pure qualification

Root can add `try emitJSON(checkQwenLayerStageProfiledPrefillGeometry())` to the
adapter check after reviewing/copying the eight Swift files. The check returns
one CPU-only result; it does not emit internally. Dependencies already exist:
`ProbeError`, `sha256`, `canonicalJSONData`, `validateWorkerJSON`,
`BoundedProbeInput.integer`, and the three original request/schedule/recorded
types. No MLX array or model is created.

Fixtures cover exact 8192/512 (16 frames), 1025/512 (512+512+1), 8192/64
(128 frames), a one-token prompt, exact token coverage and final-only logits.
They reject 8192/32 (256 frames), invalid batch/output, overflow-sized integers,
malformed JSON integer lexemes, unknown/missing profiles, duplicate/escaped
keys, decoder bypass, altered sequence/frontier/count/final flags, replay and
decode. Rejected commits preserve every prior frontier. The legacy 65/32/4
delegate is compared to its untouched schedule after all six frames.

Independent Python SHA-256 vectors pin the new profile/request/recorded
identities, the old request/recorded identities, and distinct short-request
profile identity. The old exact four-field canonical JSON bytes are checked.
These Swift fixtures are drafted and unexecuted; the fingerprint-only Python
calculation is CPU evidence, not a Swift compile or native qualification.
