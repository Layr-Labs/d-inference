# Selected-chunk owner timing

> Last updated: 2026-09-14 · commit `e4df336bc`

The registered 8K solo and rank checks can time four boundaries inside one
prefill chunk. This diagnostic separates graph construction, root staging,
existing evaluation and state commit so partitioning work can use measured
costs. It preserves the existing model expressions and evaluation roots.

## Enable the diagnostic

Add `--prefill-owner-trace-file NEW_PATH` to an admitted native
`qwen-long-prefill-solo-check` or `qwen-long-prefill-rank-check` invocation.
The parent directory must exist and the final path must be new. Each process
needs its own path. The option always selects frame 7: prompt offset 3584,
width 512, committed frontier 4096. This middle chunk excludes the first chunk's
one-time preparation and the final vocabulary projection.

The flag defaults to disabled and is restricted to these registered checks.
All original resource, model, arithmetic, prompt and supervision requirements
still apply. The public Python commands do not forward this owner option yet.
It can accompany the [full phase trace](QWEN_PREFILL_PHASE_TRACE.md) if their
output paths differ; the two schemas and event counts remain independent.

## Interpret the four spans

| Begin/end event prefix | Existing work between the markers |
|---|---|
| `graphConstruction` | Adapter/model forward after recurrent binding and input preparation |
| `rootStaging` | Stage the recurrent generation and assemble recurrent/cache evaluation roots |
| `evaluation` | The existing combined-root `eval` followed by its existing error/deadline check |
| `validationCommit` | Validate output/state, commit the recurrent generation and advance the native frontier |

Most model operations construct lazy graphs. Root staging returns arrays for
evaluation; it does not itself mean GPU execution. The evaluation span can
include compilation, scheduling, synchronization and CPU checks. These eight
CPU timestamps do not measure individual GPU operators or isolate kernel time.
Stage input validation and residual digests outside these boundaries remain
unclassified. The last event follows native commit, before the surrounding
frame is published.

The `qwen_prefill_selected_owner_trace` schema binds the full recorded-request
fingerprint, profile, role and fixed selected frame. It requires exactly eight
ordered events, 512-token widths, frontier 3584 for the first seven events and
4096 for the last. Production observations use local
`DispatchTime.uptimeNanoseconds`; injected test clocks are labelled separately.
Subtract timestamps only within one process. Recorder overhead is included.

## Failure and publication

An observer exception first checks for a pending native or deadline error,
preserving that error's precedence. It then follows the owner's existing
failure and retirement path. Even failure after the final commit marker
retires the request; it does not roll back the native frontier or permit reuse.
Nil observers construct no event arguments and add no clocks or callbacks.
Optional arguments and branches remain, so zero overhead is not claimed.

The recorder seals only after the whole outer request/model owner and its
final native checks succeed. Publication uses the same exclusive, bounded,
mode-`0600` writer as the phase trace. No file is written during prefill. If one
of two requested file writes fails, an earlier file can remain; the invocation
fails and both mutable recorders are poisoned. A file alone never proves a
successful request, numerical correctness or model release.

## Validate and locate the code

Run `bash experiments/cluster/inference/Tests/PhaseTracing/run.sh` for the
Foundation-only recorder, failure-precedence and publication tests. Native
`adapter-check` checks the CLI restrictions, exact frame binding and disabled
selector. The [recorded solo and serial-stage validation](QWEN_PREFILL_OWNER_VALIDATION.md)
passed separate numerical and local phase-correlation audits on the 9B workload.

| Concern | Source |
|---|---|
| Eight owner observations | [CBv2OwnerPhaseObservation.swift](Sources/ClusterInference/Tracing/CBv2OwnerPhaseObservation.swift) |
| Fixed identity and trace schema | [QwenPrefillOwnerTypes.swift](Sources/ClusterInference/Tracing/QwenPrefillOwnerTypes.swift) |
| Ordered clock and failure handling | [QwenPrefillOwnerRecorder.swift](Sources/ClusterInference/Tracing/QwenPrefillOwnerRecorder.swift) |
| Select one admitted frame | [QwenPrefillOwnerObserverFactory.swift](Sources/ClusterInference/Tracing/QwenPrefillOwnerObserverFactory.swift) |
| Bind frame once to its recorder | [QwenPrefillOwnerFrameBinding.swift](Sources/ClusterInference/Tracing/QwenPrefillOwnerFrameBinding.swift) |
| Seal and publish after outer success | [QwenPrefillOwnerCapture.swift](Sources/ClusterInference/Tracing/QwenPrefillOwnerCapture.swift) |
| Coordinate both optional traces | [QwenPrefillTraceCaptures.swift](Sources/ClusterInference/Tracing/QwenPrefillTraceCaptures.swift) |
