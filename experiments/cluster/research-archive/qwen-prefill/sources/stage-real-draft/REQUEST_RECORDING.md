# Recorded sequential Qwen request helpers

Source-only drafts for the bounded local layer-stage diagnostic. These files
have not been compiled or executed. They make no performance, network, RDMA,
multi-machine, or release-qualification claim.

## API

```swift
let timeline = try QwenLayerStageRecordedRequest(
    request: requestSpec, vocabularySize: vocabularySize,
    prompt: promptTokenIDs, teacher: teacherTokenIDs)

let baseline = try recordQwenLayerStageBaseline(
    loaded: verifiedBaseline, plan: plan, request: timeline, check: check)

// The coordinator releases verifiedBaseline and proves its weak model reference
// is nil before it loads either stage. Only baseline evidence crosses that scope.

let comparison = try compareQwenLayerStageRecordedRequest(
    baseline: baseline, stages: [stageZero, stageOne], plan: plan, check: check)
```

`QwenLayerStageRecordedRequest` is Foundation-only. It receives the exact prompt
and teacher IDs; teacher count must equal `outputCount - 1`. It uses the existing
`QwenLayerStageSchedule` to admit and commit the planned timeline. Bounds remain
prompt 1...128, chunk 1...32, output 1...4, vocabulary 1...262144 and at most 132
frames. Prompt 65/chunk 32/output 4 produces prefill frontiers 32, 64, 65, then
teacher-decode frontiers 66, 67, 68. There is no sampling or implicit token policy.

The recording function constructs its own existing `CBv2RequestSession`, runs
every frame, records state after its commit, and closes the session before
returning evidence. It requires the verified full-loader receipt exposed by
`loadVerifiedQwenLayerStageBaseline`; the ordinary synthetic fixture's manually
constructed `LoadedModel` does not carry that proof. A future tiny helper test
can use the verified baseline factory on its saved fixture checkpoint.

The comparison function constructs fresh `QwenLayerStageSession` instances and
the existing `QwenSequentialStagePair`. It uses the exact recorded timeline. It
checks both stage frontiers and output geometry, joins state by global layer
index/component, and rejects any omitted, duplicate, or extra state component.
Metadata and SHA-256 digests must equal the baseline for all KV keys/values,
device position offsets, convolution state, and SSM state on every frame. The
entire native vocabulary logit row must also match byte for byte on final
prefill and every teacher decode. Intermediate evaluation handles compare only
their output kind, shape, and dtype; their discarded scalar value is irrelevant.

The stage receipts must match the baseline's verified artifact aggregate,
original configuration, complete loaded source layout, conversion flag,
embedding activation dtype, source byte count, vocabulary, and layer plan.
`QwenSequentialStagePair` additionally enforces the shared two-stage storage
commitment. The comparison uses the current explicit compact native boundary
copy; it does not imply a future transport allocation or zero-copy contract.

## Evidence and ownership

`QwenLayerStageBaselineEvidence` is `Encodable`, with source identity, complete
token timeline, frame/frontier metadata, state entries and digests, and native
logit hashes plus finite full-vocabulary Float32 values. Its logit records retain
private `Data` copies of the logical native bytes for exact comparison. Custom
encoding omits that `Data`. The evidence is deliberately not `Decodable`: an
encoded report alone cannot recreate the private native-byte oracle.

No retained evidence property contains an `MLXArray`, model, cache, session,
device buffer wrapper, or closure. State snapshots use `includeBytes: false`;
they hash copied logical bytes and retain only metadata/digests. Logit capture
uses explicit `.asData(access: .copy)`, whose pinned implementation allocates
CPU storage. Each frame has an autorelease pool to drop output arrays and
temporary Float32 conversions before the next frame. Comparison results keep
finite Float32 logit values, and discard each candidate's private native bytes
after comparing it.

The helper accepts a borrowed full model and cannot release the caller's own
references. The coordinator must place baseline loading plus recording in an
autorelease scope and check a weak model reference after leaving it, before
loading stages. It also owns memory admission, process deadline, any cache
clearing, artifact pin/preflight, output emission, and top-level native runtime
initialization. The recorded evidence does not assert that the caller released
its model; `allRequestStateRetired` refers to the helper-owned request only.

Retained baseline logit payloads are bounded by four rows of 262144 values:
at most 4 MiB of native bytes plus 4 MiB of Float32 values. These are logical
payload counts, not allocator/RSS predictions. A retained comparison adds at
most another 4 MiB of Float32 values. State metadata scales with the admitted
plan (at most 128 layers) and bounded frame count; no cumulative raw state bytes
are retained. Snapshot hashing temporarily copies a complete logical component,
and logit conversion temporarily allocates a Float32 device row and CPU vector.
JSON with full vocabulary values may be much larger than the binary payloads.
Consequently these records serve correctness diagnosis, not timing measurement.

## Failure and integration

Every capture or comparison error fails the operation. Baseline cleanup uses a
small root-owned addition to the original session:

```swift
func cancel() throws {
    isFailed = true
    try close()
}
```

This hook is required but was not yet in `Sources` when these drafts were
written. It leaves original baseline forwarding/state mechanics unchanged and
marks even an external recording error after the last frame as failed. Cleanup
runs under a native error scope. Staged comparison cancels every successfully
constructed stage, including an already-advanced stage if its peer or the
comparison fails. Cleanup errors remain attached to the primary error; failed
operations never return partial success evidence. Success is returned only
after all helper-owned sessions are closed without a failure flag.

Files are split by concern: request timeline, CPU evidence, logit capture,
baseline recording, and staged comparison. No CLI, Options, Main, existing
session, model loader, transport, or submodule file was edited by this draft.
