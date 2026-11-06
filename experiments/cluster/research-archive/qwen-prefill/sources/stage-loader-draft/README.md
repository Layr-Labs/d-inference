# Verified dense Qwen layer-stage loader draft

Source-only proposal, 2026-09-13. These files are outside SwiftPM and have **not
been compiled or executed**. No model/GPU work, checkpoint mutation, performance
claim, or pipeline correctness qualification accompanies this draft.

The entry point is `loadVerifiedQwenLayerStage(directory:originalConfiguration:
plan:stageIndex:expectedAggregateSHA256:)` in
[VerifiedQwenLayerStageLoading.swift](VerifiedQwenLayerStageLoading.swift).
It returns `LoadedQwenLayerStage`: the compact public Qwen model, original plan,
stage index, receipt, activation dtype and geometry metadata. This is for a
guarded stage session, not ordinary complete-model token-to-logit generation.
The session must call `requireInputKind(.tokens)` for stage 0 or
`requireInputKind(.residual)` for stage 1 before selecting an entry point.
Active MTP must already be disabled; the loader rejects the global enabled flag
and any constructed model with an attached MTP head.

## Preparation, ownership and limits

[PreparedQwenLayerSource.swift](PreparedQwenLayerSource.swift) uses the existing
`PreparedQwenCheckpoint` with a scoped unpartitioned public model. This preserves
canonical sanitation, policy resolution, exact expected keys and pinned file
verification. The scope returns only descriptors and scalar metadata, and checks
that its weak model reference has cleared. It never evaluates that model or its
lazy quantization/default parameter graphs.

The retained manifest aggregate must equal the caller's lowercase SHA256; the
manifest binds the exact retained configuration bytes. The existing 8 GiB
manifest-payload, 6 GiB canonical-source and 512 MiB individual-source-tensor
caps apply. The latter two use actual descriptors before materialization.
Safetensors support remains U32/F32/F16/BF16. Packed versus floating classes,
every full shape and the dense `Qwen3NextMLP` topology are checked. This draft
does not introduce TP geometry or expert composition. Widths and heads remain
those in the source configuration.

[PreparedQwenLayerStage.swift](PreparedQwenLayerStage.swift) validates **both**
compact inventories before any checkpoint tensor read. The other stage is
constructed lazily, inspected, and released before constructing the stage to
load. Each active key must map injectively to one canonical source key, have its
original full shape/dtype class, and retain its original resolved affine policy.
Active plus explicit inert keys must exactly cover the compact constructor.
Across the two stages, every canonical tensor appears once and the sum of
active descriptor bytes equals the canonical source bytes. Vision/MTP have
already been excluded by source sanitation; no remaining canonical entry may
be silently dropped.

The payload loop uses each pinned descriptor's full owned-copy read. It applies
the existing F16-to-BF16 policy, evaluates/checks **that active array only**, and
updates its compact local name. Each evaluated array must have a unique,
zero-offset row-contiguous allocation with the expected number of elements and
bounded allocator footprint. Loaded bytes and largest host tensor come from
the actual descriptor reads. No `eval(model)` or ordinary path reopen occurs.
The checkpoint is checked unchanged before and after reads; no returned object
retains its descriptors. Source deletion ownership still needs runtime testing.

The metadata-only constructor lifetime checks do not measure allocator peaks.
Declared tensor byte counts are not RSS or total MLX allocation measurements.

## Explicit inactive parameters

[QwenLayerStageInert.swift](QwenLayerStageInert.swift) runs before compact-model
quantization. Inactive paths are explicitly excluded from quantization and are
never evaluated by the loader.

* Stage 0's head is replaced by a Linear subtype with a `[1,H]` placeholder.
  Its forward accepts the real input shape and returns `[B,M,1]` lazy zeros,
  without retaining the supplied normalized activation. The stage session
  discards logits and evaluates only the returned pre-final-norm hidden/state.
* The pinned `Qwen35TextModelInner.norm` is a plain `let RMSNorm`, not
  `@ModuleInfo`. Public `Module.update(modules:)` cannot replace it. Its existing
  object is retained and its H-element weight is reset to explicit ones in the
  boundary activation dtype. Its discarded graph is not evaluated. The receipt
  calls this `parameter-only-replacement`, separately from module replacements.
* Stage 1's embedding is replaced by an Embedding subtype with a `[1,H]`
  placeholder. Its dtype is derived from the source embedding's floating weight
  or affine scales/biases, **after** the configured F16-to-BF16 conversion.
  This preserves pinned Qwen's metadata-only KV/conv dtype contract without an
  embedding probe forward. Its token lookup and tied-head fallback deliberately
  trap: the session must reject wrong ingress before invoking a model method.

Suggested future planner responsibility text for stage 0 final norm:
`Reset its H-element parameter before evaluation; retain immutable RMSNorm
object; stage 0 exports pre-final-norm hidden and never evaluates this graph`.
The integrated planner/source was not changed by this draft.

## Receipt semantics

[QwenLayerStageLoadReceipt.swift](QwenLayerStageLoadReceipt.swift) defines the
stage-specific active global-to-local inventory, explicit inert inventory,
descriptor byte accounting, and a common two-stage storage commitment. The
source tensor manifest hashes canonical names, verified file paths, offsets,
full shapes, stored/loaded dtypes and actual byte counts. File contents are
bound by the verified aggregate. This is not a second resident-content digest.

`sourceParameterLayoutSHA256` describes the full canonical layout after the
declared conversion; `activeParameterLayoutSHA256` describes loaded local keys;
`parameterLayoutSHA256` additionally includes the explicit inert parameters.
`activeMappingSHA256` binds the full active mapping and dtypes. Source config,
construction config, full plan and stage plan have separate hashes. The common
storage commitment has both ordered stage summaries, so independently loaded
stages can require exact agreement without assuming equal stage byte counts.
Inert declared bytes are reported separately and never credited as loaded
source bytes. No private filesystem model path is serialized in the receipt.

## Proposed bounded integration checks (not run)

1. Extend the existing generated dense loader fixture to eight layers and a
   phase-aligned 4+4 plan. For existing F32 and FP16-metadata-to-BF16 cases, compare
   **every** active local tensor's raw bytes, shape and dtype with the ordinary
   full-model baseline using its original global name. Check owned allocation
   metadata and the common commitment's exact union/count/byte conservation.
2. Keep both loaded stages, delete fixture source files through the existing
   test fixture flow, and repeat every active raw-byte comparison. Assert the
   returned stage objects carry no descriptor or full metadata-model reference.
3. Verify final inactive parameter shapes/dtypes, quantization exclusion and
   separately reported bytes. On stage 1, compare metadata KV/conv dtype with
   the source baseline **without calling the inert embedding**. On stage 0,
   prove the session evaluates pre-final-norm hidden/state while discarded
   norm/head graphs remain unused.
4. Reject a wrong aggregate, nonmatching retained config/plan, invalid stage
   index, missing/extra tensor, wrong packed class/shape, and an active policy
   remapping mismatch before tensor materialization. Check wrong ingress via
   the throwing session contract rather than executing a deliberate trap.

Only after these loader checks should the separate stage-session draft compare
whole logits and remapped KV/conv/SSM states against same-schedule solo CBv2.
