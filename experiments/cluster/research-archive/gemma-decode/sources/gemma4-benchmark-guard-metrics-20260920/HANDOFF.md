# Gemma guard instrumentation

Source-only overlay against the actual `ceb0bca6…` resident product and applied-source receipt `6fc4df52…`. No compiler, CPU fixture, native/GPU, model, remote, or physical action was executed while authoring. Existing frozen sources and results are unchanged. Apply the ten entries in `source-inputs.json` only after each original preimage matches the disposable build workspace. There is no Package change and no separate inference path.

The native check launches **no subprocesses**. `QwenDenseStageLoadResources` uses Mach host counters and `sysctlbyname`; `QwenResidentResourceEnvironment` uses IOPowerSources and ProcessInfo. Python's independent external sampler launches OS commands, but that is outside the native callback.

The qualified callback is redundant: `Runtime.checked` calls entry guard → owner guard → entry guard. Each entry/owner guard calls `Environment.require` (which already calls `requireInitial`) and then calls `requireInitial` again. One logical callback therefore performs six actual OS observations and three power/thermal checks, with a new ISO8601DateFormatter for each OS observation. The repeated native fault/deadline checks are separate. The completed-send shim calls the callback eight times; receive calls it seven times. A length-prefixed JSON control thus causes 18 callbacks on send and 16 on receive, including the wire's explicit checks. The decode payload/consumption/token protocol alone causes at least 94 callbacks on rank 0 and 95 on rank 1, before the forward/owned-copy/driver checks.

Retained P128/C64/cut8/O16 data, 45 measured decode frames per role:

| Role | Mean frame ms | Before owner ms | Owner interval ms | After owner ms |
|---|---:|---:|---:|---:|
| Solo | 20.671 | 1.478 | 16.883 | 2.309 |
| Serial rank 0 | 115.630 | 1.426 | 11.862 | 102.341 |
| Serial rank 1 | 115.642 | 52.883 | 21.311 | 41.448 |
| Lookahead rank 0 | 116.024 | 1.429 | 11.816 | 102.779 |
| Lookahead rank 1 | 116.075 | 53.094 | 21.651 | 41.331 |

`retained-timing-summary.json` binds the five actual stdout files. Every subtraction is within one process. The owner interval includes its existing checks; the evaluation phase includes the existing post-eval check. Outside-owner spans include checks, peer work, copies, synchronization, control protocol, and waiting. These measurements do not isolate RDMA link cost or GPU kernel time.

## Instrumentation only

The new Foundation-only `Gemma4BenchmarkGuardMetrics` holds nine fixed scalar buckets: logical guard, entry guard, owner guard, environment guard, actual OS snapshot, allocator snapshot, outer native fault checks, completed native send, and completed native receive. Every category reports count and inclusive elapsed nanoseconds. Wire categories additionally report the nested logical-guard nanoseconds within those same calls, allowing subtraction on the same process and interval. The remainder still includes native synchronization and peer waiting; it is not a pure link measurement. Outer native-fault counters cover the instrumented entry/runtime scopes, not every MLX error checker in the process.

The OS hook records the already-running reader from its original start through return/failure, including timestamp formatting. Optional hooks default to nil for other Qwen callers. There is no timer, file I/O, extra OS/allocator sample, graph evaluation, stream synchronization, or new retained tensor. Existing check order and throwing bodies are preserved. The measurement wrapper records failures in a nonthrowing defer, so it rethrows the original error. Every output bucket is bounded; arithmetic overflow/clock regression is explicitly flagged, never wrapped into a plausible duration.

Each request exports prefill and decode deltas at its existing first/last-token agreement boundaries, plus the final cohort aggregate after native release. No per-check event log is retained. The scalar observer's clock/counter/copy cost remains inside the measured workload. Existing owner phase arrays remain unchanged. A new named 32,768-byte host allowance covers retained counter copies and incremental bounded report data, in addition to the existing 8 MiB report/evidence allowance. All original budget terms, 6/4/2 GiB policies, state/allocation transitions, process fences, error checks, and external supervisor checks remain unchanged.

Seven Foundation-only groups are staged in `Tests/GuardMetricsChecks.swift`: fixed buckets, inclusive/nested timing, original-error propagation, actual callback count, request deltas, visible overflow/regression, and maximum four-request encoding/storage bound. Root may compile/run them through its existing owned CPU runner with this exact compiler argv (create a fresh Build output directory first):

```sh
xcrun swiftc -swift-version 6 -warnings-as-errors -j 2 Runtime/Gemma4BenchmarkGuardMetrics.swift Tests/GuardMetricsChecks.swift -o Build/GuardMetricsChecks
Build/GuardMetricsChecks
```

The executable qualification remains the existing `GemmaResidentBenchmark` target, same source/dependency workspace, sole bounded root compiler. Rebind the actual resulting native/description and fresh jobs before physical use. The first comparison should reuse P128/C64/cut8/O16 and full numerical capture for solo + serial pair + lookahead pair, with the existing terminal/resources/row/state comparator. For metrics, require nine exact ordered categories, no overflow, same-process nonnegative deltas, wire nested-guard time ≤ its inclusive duration, OS snapshot count consistent with the source guard count, and full original retirement before accepting any timing. Report both total workload timing and guard-inclusive breakdown. No speed claim is available from this unexecuted overlay.

## Proposed consolidation after measurement

The next minimal optimization is one **fresh observation per logical callback**, with no time-based cache and no lower check frequency:

1. Expose an internal environment observation that retains the current AC/low-power/thermal refusal and returns its freshly validated OS snapshot. Keep existing nil/default APIs unchanged.
2. Split this private owner's check into fresh observation and pure validation against that same snapshot plus one current allocator snapshot. Preserve every phase/progress, selected suffix, host/copy/scratch, named-state/workspace, allocator, and 6 GiB inequality exactly.
3. Within `Runtime.checked` only, keep all existing before/after native fault and absolute deadline checks, and pass that one invocation-local observation through entry and owner validation. Validate age/deadline again on return. No observation may cross a model/transport operation, async boundary, or subsequent checked invocation. Direct entry/owner calls outside that scope still obtain their own fresh observation.
4. Keep every original allocation/phase check and every Collective callback in place. The observation is not an admission grant or substitute for canonical ownership. Do not remove stream completion fences, ACKs, checksums, numerical checks, or external OS sampling. Preserve error/fault precedence on both success and thrown-reader paths.

That can reduce six direct OS snapshots to one within each logical callback without pretending memory stayed constant across model operations. It requires a separate reviewed runtime delta plus failing-resource, stale-observation, deadline/native-error, allocation-transition, and exact numerical controls. It is **not implemented** in this instrumentation package; no guard or floor has been weakened.
