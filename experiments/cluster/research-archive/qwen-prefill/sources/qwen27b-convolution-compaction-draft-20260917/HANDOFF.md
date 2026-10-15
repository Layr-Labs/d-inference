# Private convolution-compaction candidate — source only

This changes five existing Runtime files and adds two Runtime files over the exact qualified phase-memory successor. The source inventory is `resident-generation-phase-memory-draft-20260917/Build/source-snapshot-1.json`; that build reuses `resident-generation-phase-native-draft-20260916/Build/workspace`. Neither workspace nor any prior freeze was edited. `edits.json` restores every existing file byte-for-byte; `runtime.patch` includes the two additions. The separate source audit `70bab9da257950532dab834df38dc817817684e91b30f4084faa147fc431761f` is unchanged.

The only public-facing addition is a default-false parameter on the existing private Benchmark SPI:

```swift
QwenResidentRuntime.loadPhaseMemoryObservation(configuration,
    bootstrap: bootstrap, compactConvolutionState: true)
```

Ordinary `load`, serving, recording and existing worker calls retain the disabled default. There is **no worker argument/CLI activation in this runtime-only draft**. A later executable binding must explicitly select true and pin the actual new binary and call path. No current executable or current phase receipt demonstrates compaction. The existing bilateral load-intent digest includes the opt-in when true; disagreement refuses before model load. Default-false peers retain the original digest.

The request uses the existing owner, phase resource object, generation core, stage session, recurrent transaction, eval, validation, commit and retirement. It adds no protocol, owner, forward, `eval`, stream selection, synchronization, cache-policy change, device-to-host tensor read or file I/O. After the existing eval, nonblocking `evaluatedBufferInfo` checks the compact allocation bound; it does not demand transient `isUnique` ownership or wait for completion handlers.

## Authority and failure behavior

`QwenConvolutionCompaction` joins the actual registered profile, original configuration, 16/48 Plan, rank, request fingerprint and unchanged actual reservation. The existing session validates actual loaded metadata/parameters, then checks this authority again before creating request state. The phase SPI stays within the existing P8192/C256/O128 scope. The optional parameter on the existing internal recording wrapper permits a later short P32/C16/O2 numerical check without a new inference engine; it still requires constructing this checked authority and supplying the original charged diagnostic resources.

Before any wrapper mutation, `QwenConvolutionCompactionRows.stage` requires the exact local 27B shapes/dtypes/layer set, a noncaptured transaction, precisely one pending generation, input wrappers identical to the confirmed generation (or no input on the first step), exact root order, and all pending convolution wrappers distinct from every input/confirmed conv/SSM wrapper, pending SSM wrapper and each other. It builds every lazy compact result, checks native/deadline/resource errors, and verifies output metadata before replacing any context. Guards are checked over the entire layer set, not interleaved with mutation.

An error after context replacement still affects only the pending generation. The existing `CBv2OwnedRequestState.run` catch marks the state failed; the existing retirement path synchronizes and rolls back. It cannot commit or reuse that transaction. No rollback owner or failure-recovery loop was introduced.

## Named-memory proof

The original request allowance remains exactly unchanged. Its named convolution term is:

`3 × 48 × allocationBound(F32[1,3,10240])`.

The constructor recomputes the actual original allowance and checks equality with the reservation. The row helper proves:

`3 × selectedGDNCount × allocationBound(BF16[1,3,10240]) <= original named convolution term`.

The helper admits only twelve or thirty-six selected recurrent layers. This covers the old compact input, newly staged compact state and a third compact generation conservatively; the actual ordinary path rejects chained pending generations. It does not spend SSM, KV, fusion or unknown workspace allowance, and does not subtract large old concatenation buffers from any gate. Existing active-memory accounting and all actual-free/allocator checks remain unchanged. Large concatenation/conv1d workspaces remain outside the named-state proof. Release may move memory into allocator cache, so neither an OS-free increase nor a peak-memory reduction is promised.

Under the retained 16 KiB page policy, a compact layer is bounded by 98,303 B. Three compact generations are bounded by 3,538,908 B (rank 0) or 10,616,724 B (rank 1), inside the unchanged 23,592,816 B full-model F32 convolution term. These values are recomputed from the actual allocator bound in native code, not used as host constants.

## Qualification sequence — not executed

1. Review `runtime.patch`, the five exact preimages and the two new files. Run `python3 -B check_source.py` only after root permits source checking. This is an inverse/pin/syntax-text check, not a Swift compile or semantic test.
2. In a fresh private build output/cache namespace (or an explicitly reviewed same-cache successor that first preserves the current native), apply only the seven Runtime overlays to the pinned phase-memory inventory. Reuse its exact MLX/vendor/dependency closure. Do not apply this to MAIN or overwrite the existing qualified binary. Root must supply the bounded owned-process build wrapper before executing; maximum jobs 2 and the existing native-build deadline remain required.
3. Add `Tests/ConvolutionCompactionTests.swift` to the existing `DarkbloomClusterRuntimeTests` target in that private composition. Build with testability and run only its eleven exact XCTest methods, serially, with `DARKBLOOM_COMPACTION_TEST_DEVICE=cpu`. The same methods must then run separately with `...=gpu` under an explicit native/GPU grant. Unknown device values fail; there are no skipped-GPU successes. Existing Runtime admission/recording tests should also run because the option is threaded through their shared core. Tests and binaries are not yet typechecked or executed.
4. The tests use real `CBv2RecurrentRequestState.bind/stage/evaluate/commit/rollback`, actual CPU/Metal `contiguous`, C API ordinary-copy control, nonblocking buffer metadata and the existing eval probe. They cover C256/C512 raw BF16 patterns, allocator bounds, two commits, old-state preservation, shared wrappers, wrong shape/dtype/root order, captured/multiple pending refusal and injected errors before/after mutation. They do not construct a model or prove full session/physical cleanup.
5. For numerical qualification, use the existing recording wrapper and actual resource owner with a checked compaction authority for P32/C16/O2/cut16, both ranks. Compare all selected IDs, the final full BF16 row and every state component/frontier against the unchanged full reference. Preserve natural exits, both retirements, external owner ACKs, deadlines, raw resource floors and same-inode canonical gate evidence. The phase-only output is insufficient for this numerical gate.
6. Only after the short gate, create an explicit worker binding to the new phase SPI option for matched P8192/C256/O128 serial/lookahead. Pin actual new native/build/Ready identities; require the same retained expected IDs. Compare the existing phase and OS observations with the accepted uncompacted C256 results. Separate active-to-cache movement from actual-free changes. C512 comparison requires its own unchanged-workload binding and numerical gate. No cut24, serving enablement or speedup follows from this source draft.

Remaining bounded work is the reviewed build/test wrapper and explicit future worker activation binding. No executable hashes, results, deployment trees or hardware qualification are invented here.
