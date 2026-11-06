# Matched solo first-token timer draft

2026-09-14. Source-only, outside the repository. No Swift build, native execution,
GPU, model forward, SSH or timing trial was performed while preparing this draft.
The eight Swift files are additive; existing session/loader/stage/v3 files are unchanged.

## Stable API

```swift
QwenLayerStageSoloPrefillReference.decode(
    _ data: Data,
    expectedFileSHA256: String,
    expectedBaselineEvidenceFingerprint: String,
    plan: QwenLayerStagePlan,
    request: QwenLayerStageRecordedRequest
) throws -> QwenLayerStageSoloPrefillReference

runQwenLayerStageSoloPrefillRequest(
    loaded: LoadedModel,
    plan: QwenLayerStagePlan,
    request: QwenLayerStageRecordedRequest,
    reference: QwenLayerStageSoloPrefillReference,
    check: () throws -> Void
) throws -> QwenLayerStageSoloPrefillResult

checkQwenLayerStageSoloPrefillReference()
    throws -> QwenLayerStageSoloPrefillReferenceCheckResult
```

The timer owns one fresh `CBv2RequestSession`; the caller owns the loaded model.
It keeps prompt 1...128, chunk 1...32, output one, no teacher and one batch row.
This does not introduce repeats, warmups or resident-cohort execution.
The pure check fixture reuses the existing tiny synthetic configuration and v3
wire timeline; all state hashes in that fixture are explicitly fabricated CPU
metadata. It constructs no native arrays. Checks are drafted, not executed.

## Reference descriptor and trust boundary

Root's frozen CPU auditor produces a compact JSON object with the exact
`QwenLayerStageSoloPrefillReference.Descriptor` schema. The parser admits at most
128 KiB, checks an explicit exact file SHA and native baseline evidence fingerprint,
uses the existing raw JSON scanner to reject duplicate/escaped-duplicate keys
and non-integer lexemes, then compares typed re-encoding for a closed nested schema.
Boolean fields remain Boolean. The same pure helper checks source dimensions
against planner limits and uses overflow-checked products/sums before deriving shapes.

`source` mirrors the existing recorded source identity. `request` binds the
original baseline request and recorded-request fingerprints, current prefill
counts/vocabulary/prompt-ID SHA, final prefill frame and frontier. Its prompt-ID
SHA uses comma-separated decimal IDs, matching the existing recorded convention.
The current request has its own fresh UUID/fingerprints; equality with the
baseline fingerprints is rejected. The coordinator owns UUID freshness beyond
this local check and must not reuse IDs across launches.

`finalState` contains complete sorted global layer/component entries, native
shape/dtype/byte counts, each logical-byte SHA and the existing
`cbv2-owned-state-v1` aggregate. The parser independently derives expected Qwen
KV/conv/SSM geometry from the source plan, including valid zero-length convolution
history. `finalLogits` is one native `[1,V]` row's metadata/SHA, with no values.
`selection` binds `mlx_argmax_all_axes_with_finite_guard_v1`, a finite reference
token and maximum tie count. The CPU exporter must derive the first-index argmax
and tie count from the pinned baseline values before this file is pinned. The
native parser cannot prove that derivation from a digest alone.

When exporting from an older baseline containing teacher decode frames, select
its `phase=prefill, finalPromptChunk=true` record at the exact agreed prefix;
do not use the last decode record. The descriptor's output count is one and
contains no teacher input. Root's independent exporter/auditor proves this
extraction against the original baseline evidence fingerprint.

Before the clock, loaded-model admission compares actual verified artifact,
configuration, layout, source tensor bytes, native conversion/dtype and complete
model identity with the pinned reference. No synthetic stage identity is created.
The model must be the verified unpartitioned dense Qwen source without MTP,
TP storage, direct-shard loading or precision wrappers.

## Clock, capture and cleanup

The timer begins immediately before `CBv2RequestSession.init`. Its three chunks
for the initial 65/32 request use the actual `.evaluationOnly` and
`.lastPositionLogits` public CBv2 paths. Every output/KV/recurrent root is evaluated
and checked by that existing session before commit. Only bounded CPU commit
metadata is accumulated per frame. The final native row is retained privately.

Native uncast `argMax`, `all(isFinite)`, evaluation and scalar readbacks use the
same operations/order as the current stage selection helper. The clock stops
after the locally validated token is available. Source/reference admission,
model loading and the verified loader's existing embedding-dtype probe precede
the clock; no full-model baseline/request forward precedes it. There is no
transport, artificial boundary work or extra solo wire delay.

After stop, the owner copies/hashes native final-logit bytes and captures one
complete final state, then compares both with the reference and checks the
selected token. It does not reconstruct native bytes from Float32 JSON values.
Reports truthfully set `logitMetadataAndDigestExact=true` and
`nativeLogitBytesCompared=false`; candidate byte arrays/full-vocabulary values
are not exported. State evidence compares complete metadata and native-byte digests.

The final native row is dropped before close. The existing request closes only
after complete prompt consumption. Any earlier error drops that row and cancels
the request under an MLX error scope, preserving primary plus cleanup errors.
If a later error occurs after verified clean retirement, cleanup does not try
to reopen or change the already-retired state. The result remains a thrown error.
The owner keeps one MLX caller; the supplied `check` is the root deadline/error
callback and must not recursively start another model request.

Returned values contain CPU records only and make no `modelReleased` assertion.
The coordinator must release its loaded model in an outer autorelease scope,
synchronize streams, verify a weak model handle is nil, clear the allocation
cache consistently with the existing single-shot path, and report final release.
UInt64 durations include a separate post-stop-through-request-close duration;
model release/report serialization are outside both reported request intervals.

## Root-owned Options/Main/launch plumbing

Use the planned distinct mode `qwen-layer-stage-solo-prefill-check` and flags
`--solo-reference-file`, `--solo-reference-sha256`,
`--solo-baseline-evidence-sha256`. Scope these flags exclusively to this mode.
Delegate its model/token/native-precision/storage preflight to the unchanged
comparison admission with output one/no teacher. Keep one repeat, zero warmups,
seed seven, timeout at most 180 seconds and all existing source/resource gates.
The helper's local identity checks do not replace that preflight's conservative
state/boundary budget or the parent resource screen.

Before loading, bounded-read and validate the already pinned CPU reference,
using the admitted plan and newly constructed exact request. Load via
`loadVerifiedQwenLayerStageBaseline`, emit truthful loaded/no-request-state
readiness if needed, then invoke this timer once. Never call the recorded
baseline forward in this process to obtain a reference before timing. Preserve
fresh-process conditions for the parent study. Current correctness flags remain
`throughputMeasurementValid=false`; this is a matched-chunk solo diagnostic,
not the fastest eligible solo or a two-machine throughput qualification.

The root adapter check can emit the return value of the pure reference check.
It covers valid dtypes/caps/zero-conv, strict byte/file/evidence pins, extra and
ambiguous keys, integer lexemes, request/frame/history/source-plan changes,
state coverage/geometry/hash changes and invalid selection/logit metadata.
Canonical compilation, native comparison and independent audit remain pending.
