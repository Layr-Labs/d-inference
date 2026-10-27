# Gemma selected-layer native source candidate

This is an isolated, uncompiled MLXLLM source candidate. MAIN, registered
admission, owner controls and installed defaults are unchanged. Five runtime
files and one value-only test file are proposed; only `Gemma4Text.swift` already
exists. `runtime.patch` and `integration.json` contain exact pre/postimage pins.
No model, constructor, payload, compiler, remote operation or GPU was run.

The prior contract source review found no concrete blocker in its ranged
constructor, global native policy, windowed-state and dtype qualification
claims. Review receipt:
`../gemma4-distributed-contract-review-20260915/source-review.json`,
SHA `9c62a532e1b2cbc250c281d0e83f74fcce2bac27d4a7ab310a01c2e4c7920da0`.
That review binds all 19 contract members and 30 source pins. It did not execute
the metadata tests or independently audit every Python validation branch.

## Constructor and Runtime join

```swift
let stage = try Gemma4LayerStage(
    originalConfiguration: decodedOriginalGemma4Configuration,
    rank: descriptor.rank,
    sourceLayerRange: descriptor.sourceLayerRange)
```

`Gemma4LayerStageLayout` performs a pure check of the closed 30-layer text MoE
geometry, original 4-bit/group64/affine policy and all 120 exact shared/router
8-bit entries. It rejects compacted configs, shared KV, PLE, altered attention
geometry and invalid rank/range responsibilities. It derives local cache kinds
from original global indices, so a non-phase-aligned cut still selects the
correct full-attention layers. Local model/cache indices remain local.

The Runtime-owned `Gemma4StageConstructionDescriptor` from
`gemma4-stage-plumbing-draft-20260915` remains responsible for original config
bytes/hash, Plan/storage identities, local quantization relocation, descriptors
and source authentication. MLXLLM imports no Runtime type. Decode the descriptor's
unchanged original bytes through `Gemma4Configuration`; do not replace its layer
count, policy or layer-type array with compact values.

The module constructs only `sourceLayerRange.map` of existing
`Gemma4DecoderLayer(configuration, layerIdx: global)`. Small wrappers give exact
`language_model.model.layers.<local>` parameter names. Each rank has one
`language_model.model.embed_tokens` object. Rank1 alone owns final norm and uses
that same embedding object's `.asLinear`; no separate head is created. All
experts remain split and the existing topology/weighted-unsort/native selector
rules remain in force. No expert or attention implementation is duplicated.

Materialization is a subsequent operation: apply the descriptor's relocated
quantization policy, install only the selected verified parameter arrays and
verify exact complete local parameter coverage. This candidate does not load
weights, invoke the ordinary whole-model sanitizer, authenticate payloads or
advertise a constructed module as ready. The retained artifact already has
canonical split-expert names; any future raw-HF conversion must use the existing
sanitizer rather than adding conversion math here.

## Forward and dtype boundaries

- `inputResidual(tokens:)` performs rank0-only lookup/scaling for 1...512
  host-validated token IDs. Rank1 never embeds residual ingress.
- `forwardResidual(_:caches:phase:)` consumes one row of existing local CBv2
  caches. It checks matching kinds, distinct row owners, equal starting
  frontiers and legacy-cache compatibility, then calls the existing decoder.
- The output contains the residual plus actual K/V graph-metadata observations
  for every selected layer: local/global index, both dtypes and both shapes.
  `requireKVDTypes(_:)` compares them with the independently admitted native
  types before the shared request owner commits state. A throw can follow
  earlier cache writes, so the caller must poison/retire the whole request.
- `finalLogits(_:)` is rank1-only and preserves norm-before-final-row selection,
  the tied embedding projection and the exact existing compiled softcap.

`loadedEmbeddingOutputDType` inspects the actual quantized embedding's scale and
bias types and refuses unquantized/unsupported formats. It is deliberately not
a K/V or later residual dtype declaration. Supported floating residuals are
accepted; future Runtime admission must bind the observed residual wire type,
per-layer K/V types and corresponding memory charges. Actual K/V observations
are metadata of the real decoder outputs, not fabricated BF16 expectations or
value readbacks. This candidate does not implement
`CBv2CompleteCheckpointKVTypeProviding` or claim a measured dtype.

The existing `CBv2NativeKVTypeProbe` remains the reusable probe mechanism for
future guarded integration; any stage adapter around it must charge fresh
probe state/graphs and retire them before serving. `forwardResidual` adds no
cache bank, recurrent state owner, rollback, request schedule, transport or
release mechanism. The windowed/empty-recurrent Runtime adaptations in the
contract remain separate required work.

## Shared prefill policy

`Gemma4LayerPrefillPolicy` is called by both the ordinary full trunk and the new
stage loop. It centralizes tail narrowing, last-query capability, expert-prefill
selection and submission cadence using the existing knobs and functions.
The ordinary loop passes its existing `layers.count - 1` final index, preserving
its prior behavior even for a changed inner-layer array. A native stage always
passes original final index 29, and only rank1 permits final-output narrowing.
Global layer number controls submission; cache indexing remains local.

Only five formerly file-private constants/functions become module-internal so
the focused files can reuse them. Their values, parsing, math and environment
controls are unchanged. No new forced native route, fusion or environment
bypass is introduced. A source-only assertion pass verified the 30 upstream
pins still match MAIN and checked the selected constructor/policy seams.

## Validation and build plan

Seven staged tests exercise all 29 cuts and local/global kinds, invalid
partitions, compacted/unsupported configs, exact mixed precision, rank0 full-row
preservation, global-final last-query selection/global submission and a matrix
against the old full-trunk policy conditions. They create no model or MLXArray.
They have not compiled or run. Native parameter-tree, loaded dtype and numerical
behavior remain unqualified.

After root review and a compiler grant, materialize a private workspace from
the exact current source/dependency snapshot, apply the six integration members
with their base-hash guards, and preserve pre/post-build pins. The focused test
selection in that workspace is:

```sh
swift test --package-path libs/mlx-swift-lm --jobs 2 \
  --filter Gemma4LayerStagePolicyTests
```

Also retain the existing Gemma expert-eligibility, shared-KV, position and
prefill-policy tests when root chooses the broader regression slice. Compiling
this target includes native dependencies; it is not authorized by the current
source-only task. No private native build has been prepared or started here.

Before physical execution, remaining gates are whole-payload authentication,
selected parameter/storage verification, an explicit MoE/windowed/native-probe
resource bound, actual dtype observation, shared request-state integration and
whole-versus-split parity. Constructing the real modules itself performs
SwitchGLU's small activation probe and requires native error/resource/deadline
guards. There is no claim of memory fit, native kernel dispatch, numerical
parity, throughput or product readiness.

Modularity: configuration/layout checks, module ownership, forward operations
and shared policy are separate focused files. Existing decoder, KV and recurrent
implementations remain unchanged. No independent review of this new patch has
completed yet; the earlier clean review concerns the source contract only.
