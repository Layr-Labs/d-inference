# Optional prefill phase traces

> Last updated: 2026-09-14 · commit `e4df336bc`

The registered 8K rank and solo checks can record local CPU timestamps for
prefill and communication phases. The trace is a separate diagnostic file;
the existing ready and terminal JSON records retain their schemas. This
instrumentation helps locate time spent in the current execution path.
The [first solo validation](QWEN_PREFILL_PHASE_VALIDATION.md) passed both
numerical and phase checks and records all sixteen chunk intervals.
The [serial rank validation](QWEN_PREFILL_RANK_PHASE_VALIDATION.md) records the
two stages' independent local spans.

## Enable a trace

Add `--prefill-phase-trace-file NEW_PATH` to an admitted
`qwen-long-prefill-rank-check` or `qwen-long-prefill-solo-check` native invocation.
The parent directory must exist, and the final path must not exist. Each rank
needs its own path. All original model, prompt, arithmetic, resource and process
supervision requirements still apply. Other native modes reject the option.
The [public Python commands](../runtime/stage_checks/LONG_PREFILL.md) accept
`--prefill-phase-trace` and derive a separate owned path for each rank. Their
receipt records the request; sidecar collection and timing validation remain
separate. The forwarding passed 81 integrated CPU/fake tests; it has not been
executed natively through those public commands.

The disabled path constructs no recorder or event collection and performs no
additional clock reads. A stored optional reference and conditional branches
remain, so identical memory layout or timing is not claimed. An enabled run
includes recorder overhead and must be identified separately from an
uninstrumented measurement.

## Read the result

The `qwen_prefill_local_phase_trace` schema binds the full recorded-request
fingerprint, profile and role (`rank0`, `rank1` or `solo`). Every event contains
an ordinal, phase, optional frame sequence, committed-token frontier and local
`DispatchTime.uptimeNanoseconds` timestamp. Times and committed tokens cannot
decrease. Lookahead can revisit an earlier frame while draining its consumed
acknowledgement.

Solo emits 41 events, including a begin/committed pair around each of its 16
chunk calls. Rank traces mirror the existing 204 or 235 action records,
covering preparation, control and payload exchange, acknowledgements,
consumption, token return and retirement. No GPU synchronization, model forward
or tensor copy is added by the observer.

Subtract timestamps only within one process. These are CPU-observed spans,
including hook overhead and the instructions between a native operation and
its marker. They do not isolate GPU execution or establish cross-process clock
alignment or overlap. The full trace span also includes readiness and final
diagnostics outside the existing first-token timing interval.

The recorder seals only after the request has retired and its CPU result is
constructed. Publication follows successful outer model release, cache clearing
and native error checks. An error poisons the recorder and discards unpublished
events. This observer does not independently prove request retirement, numerical
correctness or model release; those remain separate checks.

The file is created exclusively with mode `0600`, is bounded to 512 KiB, and
never replaces or removes an existing path. A write or close failure fails the
native command and may leave a partial new file. Treat a sidecar as successful
only alongside its successful process and validated native result. No file
writes occur within the prefill timing interval.

## Validate the implementation

The standalone tests use Foundation and Darwin, temporary files and small CPU
fixtures. They do not initialize MLX or run a model:

```sh
bash experiments/cluster/inference/Tests/PhaseTracing/run.sh
```

The recorder tests cover identity, capacity, lifecycle, clock reversal and
reentrant failures. Output tests cover exclusive creation, permissions,
symlinks, a path created after preflight, cancellation and errors after seal.
The native `adapter-check` also checks the optional CLI's mode restrictions.

| Concern | Source |
|---|---|
| Identity and copied event values | [QwenPrefillPhaseTypes.swift](Sources/ClusterInference/Tracing/QwenPrefillPhaseTypes.swift) |
| Bounded recorder lifecycle | [QwenPrefillPhaseRecorder.swift](Sources/ClusterInference/Tracing/QwenPrefillPhaseRecorder.swift) |
| Outer success and failure handling | [QwenPrefillPhaseCapture.swift](Sources/ClusterInference/Tracing/QwenPrefillPhaseCapture.swift) |
| Combined optional publication gate | [QwenPrefillTraceCaptures.swift](Sources/ClusterInference/Tracing/QwenPrefillTraceCaptures.swift) |
| Exclusive output | [QwenPrefillPhaseFile.swift](Sources/ClusterInference/Tracing/QwenPrefillPhaseFile.swift) |
| Rank markers | [QwenLongPrefillRankTrace.swift](Sources/ClusterInference/QwenLongPrefillRankTrace.swift) |
| Solo markers | [QwenLongPrefillSoloRequest.swift](Sources/ClusterInference/QwenLongPrefillSoloRequest.swift) |
