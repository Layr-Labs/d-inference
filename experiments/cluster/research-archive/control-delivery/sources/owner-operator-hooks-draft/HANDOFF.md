# Selected-chunk owner observer wiring

Source-only draft, 2026-09-14. Five existing request/compute files receive only
defaulted parameters, selected-factory calls and observer pass-through. No
recorder, clock, model expression, evaluation root, old phase event, transport
message, output schema or native error/retirement body is changed here.

`QwenPrefillOwnerObserverFactory.swift` defines the root-approved API:

```swift
typealias QwenPrefillOwnerObserverFactory =
    (QwenLayerStageFrame) throws -> CBv2OwnerPhaseObserver

func qwenPrefillSelectedOwnerObserver(for frame: QwenLayerStageFrame,
    factory: QwenPrefillOwnerObserverFactory?
) throws -> CBv2OwnerPhaseObserver?
```

The selector first checks `frame.sequence == 7`, then unwraps the factory, then
invokes it. Every other chunk returns nil without factory invocation or observer
construction. The helper itself adds a CPU call/branch and frame read; disabled
mode is not claimed to have zero instruction overhead. It never reads a clock.

| Existing entry | Additive argument and destination |
| --- | --- |
| `runQwenLongPrefillSoloRequest` | `ownerObserverFactory: QwenPrefillOwnerObserverFactory? = nil`; selected callback passed to `CBv2RequestSession.prefillChunk(observer:)`. |
| `runQwenLongPrefillRankRequest` | Same defaulted factory, passed to the actual sender or receiver. |
| `runQwenLongPrefillRankSender` | Same factory. Its existing shared `prepare(step)` helper selects before `context.prepare(observer:)`. Both serial and lookahead reach that one helper. |
| `runQwenLongPrefillRankReceiver` | Same factory. Selection occurs inside the transport's actual `consume` callback, before `context.consume(observer:)`. |
| `QwenLayerStageProfiledPrefillComputeContext.prepare/consume` | `observer: CBv2OwnerPhaseObserver? = nil`, forwarded unchanged to the corresponding `QwenLayerStageSession.prefillChunk` call. No second observer is created. |

All frames come from the existing admitted local recorded request. The root
factory must bind its actual full recorded-request fingerprint, profile and
role to `QwenPrefillOwnerRecorder.identity`; require frame 7, prefill phase,
offset 3584, width 512 and `finalPromptChunk == false`; and permit one acquisition
only. The collector checks the eight owner phases and frontiers 3584→4096. This
selector does not replace those checks or admit received wire geometry.

The factory should capture CPU identity, one-shot bookkeeping and recorder only.
It returns `{ try recorder.observe($0) }`, without retaining a loaded model,
boundary or other native array. A factory error follows the existing outer
request catch. An observer error follows the existing owner failure/retirement
path, including errors after native commit. Late boundary checks, transport
failures, final diagnostic failures and outer model-release failures must still
poison the collector even if all eight observations were received. Root owns
that capture/failure fence and calls `sealAfterOuterSuccess()` only after the
entire outer owner succeeds. This patch never publishes a trace.

The selected factory runs inside the existing coarse prefill/prepare/consume
span and before the first owner marker. Its CPU cost is therefore included in
the enclosing phase, not the eight owner intervals. All existing phase callbacks
remain unchanged, and the old phase sidecar must retain its exact 41/204/235
event contracts. There are no added selection/token/model or transport steps.

Prerequisite: the separately frozen eight-marker owner patch must supply
`CBv2OwnerPhaseObserver` and defaulted `observer:` arguments on both baseline and
stage sessions. The Foundation collector is a separate artifact. Apply
`hooks.patch`, add the new factory source, and let root integrate capture/CLI
code. Root owns all Swift compilation and native checks.

`source_check.py` restores only these additions and requires byte-identical
original bodies, checks both stage paths and the shared lookahead preparation
site, and verifies unchanged native/check/old-phase call counts. Ten CPU source
checks passed, including nine deliberate mutations. They do not execute model
code. `QwenPrefillOwnerObserverFactoryCheck.swift` is an uncompiled/unexecuted
Foundation fixture for all fifteen unselected chunks, nil selection, exact
frame/callback forwarding and factory-error propagation. Its six accepted
checks and one expected failure are prospective until root runs it.

`prepare_draft.py` is an out-of-tree generator with original-source occurrence
checks. Do not run it again against already integrated hooks. Original copies
and pins remain available for later source review; no repository file was
modified while preparing this draft.
