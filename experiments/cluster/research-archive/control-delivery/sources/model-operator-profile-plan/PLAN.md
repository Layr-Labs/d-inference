# Bounded Qwen operator-observation seam

Source-only proposal, 2026-09-14. No API, model code, synchronization, runtime
configuration or output schema is changed by this document. The next useful
measurement is an eight-marker breakdown at the existing evaluation boundary
for one selected chunk. Add per-layer graph-construction groups only if that
breakdown warrants them.

The completed solo phase result places almost all of the first-token interval
inside the 16 chunk calls. Those calls include graph construction, existing
state-root evaluation, state validation and commit bookkeeping. This does not
yet establish how much time each GPU operator consumes.

## Shared dispatch and exact candidate seams

Paths below are relative to the repository; source bytes are pinned in the
adjacent `source-references.json`. `I/` means
`experiments/cluster/inference/Sources/ClusterInference/` and `L/` means
`libs/mlx-swift-lm/Libraries/`.

| Location and symbol | Proposed observation and constraint |
| --- | --- |
| `I/CBv2RequestSession.swift:90`, `forward` | Full-model owner: bracket the existing adapter call, recurrent/cache-root assembly, existing `eval([output] + roots + cacheRoots)`, and validation/commit. Four begin/end pairs, only on the admitted chunk. |
| `I/CBv2OwnedRequestState.swift:50`, `run` | Stage owner: the same four pairs around `forward`, `evaluation.evaluate()` plus cache roots, existing `eval`, then checks/output validation/state validation/commit. This is analogous to the baseline owner, not a shared implementation; do not refactor either owner merely to add markers. |
| `I/QwenLayerStageSession.swift:119`, `perform` | Install the selected observation scope around the actual forward owner. Keep input-boundary validation and stage0's existing `output.asData()` digest outside the operator groups. The enclosing phase already includes them. Map local layer indices through the admitted plan, rather than adding 16 to a KV/token offset. |
| `L/MLXLMCommon/ContinuousBatchingV2/SteppableAdapterV2.swift:125`, `recurrentPrefill` | Full-model and stage1 calls dispatch to the model's real narrowing conformance. Preserve `.evaluationOnly` versus `.lastPositionLogits`; do not replace this with an ordinary full-logit forward. |
| `L/MLXLLM/Models/Qwen35.swift:1974`, `Qwen35TextModel.cbv2RecurrentPrefill`, and `:2002`, `cbv2ForwardWithHidden` | Both reach `Qwen35TextModelInner.cbv2Forward`. Stage0 consumes the latter's `lastHidden` and discards lazy logits. Do not retain, read or evaluate the discarded head to observe it. |
| `L/MLXLLM/Models/Qwen35.swift:1693`, `Qwen35TextModelInner.cbv2Forward` | Shared trunk and local-layer enumeration. Validate one selected call's width/role/layer mapping here; scope only ordinary uncaptured CBv2 prefill. Keep MTP, exact-target verification, vision and generic MoE qualification outside this initial profile. |
| `L/MLXLLM/Models/Qwen35.swift:1525`, `Qwen35DecoderLayer.cbv2Forward` | Optional second step: three disjoint construction groups per layer—input norm plus attention/GDN branch; residual plus post-attention norm; dense FFN plus final residual. Bracket the existing expressions without adding materialization or altering expression order. |

The full model, stage0 and stage1 therefore execute the same decoder operators.
Their surrounding ownership/output paths differ. Registered9B has 32 global
layers: 24 GDN and 8 full-attention, split 12/4 per stage. Compact stage1 local
index 0 is global index 16; its token positions still start at the same prompt
frontier as stage0.

For a later single-layer deep view, the exact existing operator sites are:

- GDN `Qwen35GatedDeltaNet.cbv2Forward` (`Qwen35.swift:830`):
  `projectInputs`, request-state gather, `processChunk`, recurrent staging,
  gated norm/output projection. `processChunk` at line537 constructs conv/SiLU,
  Q/K normalization and the `gatedDeltaUpdate` call at line567. The shared
  `L/MLXLLM/Models/GatedDelta.swift:297` implementation selects the existing
  Metal kernel or fallback; place an outer call-site observation without
  entering its token loop or changing dispatch.
- Full attention `Qwen35Attention.cbv2Forward` (`Qwen35.swift:1193`):
  Q/K/V projections and norms, RoPE, `cache.updateAndAttend`, gate/output
  projection. Its current query-block dispatch is
  `L/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift:360` and `:591`.
  Width512/query128 makes four blocks. Observe the whole call initially;
  per-block hooks would add events and still describe lazy construction.
- Dense FFN `Qwen3NextMLP.callAsFunction`
  (`L/MLXLLM/Models/Qwen3Next.swift:133`) is the nested expression
  `downProj(silu(gateProj(x)) * upProj(x))`. The Qwen wrapper at
  `Qwen35.swift:1451` takes this path with `exact == false`. An outer group
  avoids rewriting that expression or selecting a different projection path.

## Smallest bounded selection and event budget

Initially select exactly chunk sequence7: offset3584, width512, frontier4096,
from the fixed8192/512/output1 request. This avoids the first-use GDN fusion
and final vocabulary-head differences. It is one mid-context diagnostic, not a
summary of every chunk. A later separate selection of sequence0 or15 answers
first-use or final-head questions without broadening a single trace.

Reserve eight owner markers for the four intervals above. If the optional
three-group layer view is also enabled for that one chunk, each layer adds six
markers. The current512-event capacity is sufficient without widening it:

| Request role | Existing phase events | Owner markers | Layer markers | Maximum combined count |
| --- | ---: | ---: | ---: | ---: |
| Full-model solo | 41 | 8 | 32 × 6 = 192 | 241 |
| Stage0 | 204 | 8 | 16 × 6 = 96 | 308 |
| Stage1 | 235 | 8 | 16 × 6 = 96 | 339 |

These are prospective counts only. The frozen phase JSON contract requires
exactly41/204/235 events and must continue to reject additions. Prefer a separate
bounded operator sidecar/recorder with its own admitted selection and contract;
its maximum would be200 events for solo and104 per stage. Reuse the512 capacity
implementation if useful, but never publish the new event set as an old trace.
If a future explicit combined format is chosen, use the totals above. Do not
sum nested layer groups with their enclosing construction interval.

## Interpretation, disabled cost and lifecycle

MLX operators mostly construct lazy graphs. Local timestamps around them measure
host-side graph construction, potentially including internal work; they do not
measure per-operator GPU execution. The existing `eval` interval includes the
whole demanded dependency graph and required state/cache roots. Keep exactly
that root list, its order and the current synchronization. `evaluation.evaluate()`
in `RecurrentStateV2.swift:667` stages the generation and returns roots; its name
does not mean it executes those roots on the GPU.

There is a specific first-use exception: `prepareFusedInputProjection`
(`Qwen35.swift:409`) evaluates concatenated packed weight/scales/biases at
lines442–443 before replacing source modules with named views. Never prewarm,
force, disable or repeat this preparation for profiling. A selected first chunk
must report that its GDN projection group can include this initialization.

For literal **no added production overhead**, compile the new call sites and
observation implementation out of ordinary builds. A diagnostics-only build
condition is the narrowest guarantee; default bodies remain unchanged after
preprocessing. A runtime-nil hook can promise no recorder allocation, event
formatting, lock or clock read, but still adds branches/argument plumbing and
cannot honestly promise zero execution/layout cost. Existing
`ForwardShapeDispatchV2.swift` is a useful synchronous TLS ownership precedent,
but its `pthread_getspecific` inactive lookup is not zero cost. Do not piggyback
operator clocks onto its existing production-active checks.

The diagnostic scope should bind full recorded-request fingerprint, profile,
role, exact selected frame and source-plan local→global layer mapping. It owns
only scalar events, never arrays/modules or closures retaining them. No global
unscoped observer, environment lookup in an operator, tensor inspection, JSON
construction, new `eval`, `asData`, `item`, `asArray` or synchronization belongs
in a marker. Device-level attribution would require a separately designed
backend profiler; these markers cannot supply it.

Qwen's model forwards are nonthrowing. A throwing callback cannot simply be
inserted there without broad signature changes. Keep observation failure in a
poisoned, scalar diagnostic scope and have the existing throwing request owner
check it immediately after the model returns, before subsequent root staging,
and at publication. Failed/reentrant/mismatched observations must never yield a
successful sidecar; existing owner cancellation/error propagation retains the
primary failure. Do not turn observer faults into model precondition failures.
The outer model-release/error fence remains required after request success.

Before any real diagnostic, root should gate exact selected-call/layer counts,
wrong-frame/role/replay/budget failure, nil/compile-disabled paths and poisoned
publication with pure fixtures; then use existing tiny parity/lifecycle checks
and same-source same-input baseline numerical qualification for the additive
build. Confirm unchanged model expressions, evaluation roots and operator
policy, and rebind the executable/archive. Native execution and any new API or
CLI remain separate authorized implementation work.
