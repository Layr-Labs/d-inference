# Resident cohort agreement: next bounded step

> Last updated: 2026-09-14 · commit `e4df336bc`

The current owner independently validates each complete local cohort, then
performs loaded-stage readiness for each request. That does not establish that
both ranks chose the same future request count, ordering or warmup boundary.
A differing last request count can leave one peer waiting; differing warmup
counts can silently classify the same requests differently.

Add one bounded agreement before loading either stage. Preserve the existing
request loop, fresh state, v4 start/boundary/token controls, clocks and final
retirement. This is a proposal only; no CLI or runtime is implemented here.

## Pure descriptor

Proposed closed type: `QwenLongPrefillResidentCohortAgreement`, initialized by
`init(options:requests:warmupCount:) throws`. It calls the real
`QwenLongPrefillResidentRankAdmission.validate` and exposes immutable
`descriptor` and `fingerprint`; there is no unchecked descriptor constructor or
raw decoding path. At most 16 entries are admitted before encoding.

The descriptor has a new schema version and these common fields:

- Source configuration SHA, expected artifact aggregate SHA, selected Plan
  fingerprint, arithmetic-environment SHA and SHA of the admitted canonical
  resource receipt.
- Scheduling policy, logits dtype, fixed loopback transport and execution path;
  profile identity and trace-disabled scope. No rank-local paths, local rank or
  local stage-only identity enters this common digest.
- Request count and warmup count. The first admitted epoch is the cohort's
  initial epoch; no second independently supplied cohort identity is needed.
- An ordered array of ordinal, canonical epoch/UUID, full recorded-request
  fingerprint and raw prompt-file SHA. `excludedWarmup` is derived from the
  ordinal and common warmup count, never separately accepted from the caller.

Use existing `canonicalJSONData`, enforce `maximumEncodedBytes = 16_384`, and hash
`qwen-long-prefill-resident-cohort-v1|` plus those bytes. The profile/request/Plan
fingerprints retain their existing domains. Repeated A/B/A token histories are
valid when their UUIDs and epochs are fresh. Different JSON whitespace with the
same token history still changes the raw prompt pin and the cohort agreement.

## Native placement and reuse

1. Construct the pure agreement before `Collective`, after the current admission.
2. Construct the existing loopback `Collective`, then exchange the cohort digest
   before `loadVerifiedQwenLayerStage`, owner construction or any request clock.
3. Retain the matched cohort descriptor/fingerprint as CPU metadata. Load each
   private stage once and execute the current loop without modification.
4. Keep every existing per-request loaded-stage agreement/readiness. The pre-load
   descriptor has no actual storage commitment or native-dtype observation and
   must not replace those later checks.

The smallest transport change is to extract the current exact [64] Int32,
256-byte completed send/receive body into one internal digest helper. The old
readiness wrapper keeps its exact existing domain, return fields and behavior;
a new resident wrapper supplies the new domain-separated cohort digest. Limit
this helper to the two known callers. Rank zero still sends then receives;
rank one receives then sends, inside `MLX.withError` and the existing checked
error/deadline callback. There is no all-reduce, model forward, clock sample,
retry, new distributed packet schema or acknowledgement protocol.

On mismatch/error, abort before stage loading and publish no successful cohort
report. Existing parent deadline and whole-cohort fencing remain necessary:
the existing blocking receive can strand a peer when the other throws. A match
attests agreement between the peers' admitted CPU descriptors; it does not
prove payload verification, resources, numerical results or a completed cohort.

## Focused validation before exposing a CLI

Pure checks should demonstrate deterministic ordered fingerprints, valid fresh
A/B/A identities, and rejection by actual admission for duplicate/malformed IDs,
invalid warmup counts and changed local source/Plan/resource policies. For two
individually valid descriptors, changed later prompt/UUID/epoch, request order,
request count, warmup boundary, serial/lookahead policy or selected Plan must
produce different digests. Do not require raw token equality to reject raw-file
pin drift.

A small source/CPU seam check should prove the exchange precedes the load and
that a failed exchange cannot invoke the supplied load seam. Preserve the old
readiness digest vector and wrapper result, exact per-request agreement bytes,
and no added per-request clock/phase events. Real peer mismatch/failure cleanup
and a resident model run remain root-owned follow-up qualification.
