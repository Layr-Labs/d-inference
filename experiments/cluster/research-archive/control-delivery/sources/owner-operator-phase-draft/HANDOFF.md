# Eight owner observations, source-only draft

Only three existing owner files receive patches. New
`CBv2OwnerPhaseObservation.swift` supplies an eight-case enum, CPU scalar struct
and synchronous throwing callback alias. No model/layer operator signatures,
clock, collector, selection, serialization, CLI, output type or native graph
expression changes. Root owns integration, compilation and runtime tests.

The defaulted `observer: CBv2OwnerPhaseObserver? = nil` parameter is available on
`CBv2RequestSession.prefillChunk` and `QwenLayerStageSession.prefillChunk`; the
latter passes it to `CBv2OwnedRequestState.run`. Private forwarding methods also
default nil, so decode keeps its existing path. No callback is stored in a
model/session/state owner. A caller must choose the exact chunk and capture its
request/role/frame identity separately. Higher-level profiled context plumbing
and the separate operator sidecar remain root-owned future additions.

Each marker is inside `if let observer`, before constructing its observation
arguments. Nil therefore skips callbacks, observation construction and their
argument reads; no clock exists in this patch. There remain optional-argument
plumbing and conditional branches: this is not a claim of zero machine-code,
heap-layout or instruction overhead. Success adds no error/deadline checks,
`eval`, synchronization or tensor reads.

| Event pair | Exact scope |
| --- | --- |
| `graphConstruction.begin/end` | Existing model/adapter forward only, after inputs and recurrent binding are prepared. Most calls construct lazy graphs; existing internal fusion work may execute. |
| `rootStaging.begin/end` | Existing recurrent `evaluate()` plus cache-root assembly. The recurrent method stages a generation and returns its roots; it is not GPU evaluation. |
| `evaluation.begin/end` | Existing exact combined-root `eval`, followed by the owner's original error/deadline check. `evaluation.end` is deliberately after that check, so the observed interval includes its cost. |
| `validationCommit.begin/end` | Existing output/state validation and native recurrent commit, owner frontier advancement and completeness guard. The final marker follows the native commit, before returning output or publishing the enclosing schedule/frame. |

The first seven observations report the old `committedTokens`; only
`validationCommit.end` reports the incremented frontier. `tokenCount` is the
unchanged current call width. State binding/token-array creation and the stage's
incoming validation/residual digest are outside these intervals. These are CPU
owner spans, never per-operator GPU measurements.

Failure semantics are deliberate:

- Graph-end failure can leave a bound, unstaged recurrent evaluation; root-end
  or eval-begin failure can leave a staged generation. Original outer retirement
  still handles both and synchronizes before release.
- The pinned `ErrorHandler.withError` checks its native error box only after a
  body returns normally. An observer throw could otherwise bypass it. The pure
  `deliver` helper invokes the existing `check` only on an observer exception;
  a pending native/deadline error has precedence. If that check passes, the
  original observer error is rethrown unchanged. No failure is swallowed.
- Baseline observer failure propagates through the unchanged prefill catch,
  setting `isFailed`; outer request cancellation retires it. Stage failure sets
  owned-state failure, and the unchanged StageSession catch retires it before
  schedule commit or boundary publication.
- Failure at the last marker happens after native commit. It still poisons and
  retires the request; it does not roll that committed frontier back or permit
  reuse. The baseline prompt counter/stage schedule may remain behind its
  native frontier, as expected on a terminal failure.
- Callbacks are contracted to synchronous CPU-only observers. They must not
  reenter owners, mutate state/model, perform native work or retain tensors.
  This patch adds no general callback reentrancy enforcement. A collector must
  poison failures and publish only after the entire outer request/model owner
  succeeds, even if all eight callbacks were already received.

`source_check.py` replays only saved source files and pins. It independently
removes the eight markers and exact signature/pass-through additions to require
byte-identical original owner bodies, checks event/frontier/eval/error-check
ordering, and rejects 11 deliberate source mutations. The 12 Python checks
passed. `CBv2OwnerPhaseObservationCheck.swift` is an unexecuted pure Foundation
fixture for eight phases, nil argument skipping, successful no-extra-check
behavior, after-commit scalar shape and native/deadline exception precedence.
It must not be reported as compiled or passed before root executes it.

`owners.patch` modifies the existing files; add the new core Swift file
separately. Saved originals and pins allow review after root integration.
`prepare_draft.py` is the source-only generator, not an integration command;
do not rerun it against already integrated owner sources.
