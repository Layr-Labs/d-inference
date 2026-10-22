# Shared Qwen resident facade (private staging)

This stages an actual model-owning facade in `DarkbloomClusterRuntime`, using the
separate six-file `DarkbloomClusterProtocol` value target. No main-repository
files, default provider route, benchmark entry or original private package moved.
`proposed/libs/darkbloom-cluster` is an overlay on the previously compiled
66-source package. The complete assembled package is at
`../shared-resident-facade-build-20260915/workspace/libs/darkbloom-cluster`.

The assembled library contains 87 Swift files: 81 runtime and six protocol.
`source-lineage.json` records the exact base and final members; 60 of the original
66 remain byte-identical. Nineteen explicitly listed copies are byte-identical
to their reviewed origins. These include the final aligned reader, accounting,
selected materializer and host-scratch resource policy, not the earlier malloc
or unaligned reader. The rank-only cache-off benchmark candidate is separate
and is not silently applied here.

## Native owner API

`QwenResidentRuntime.load(QwenResidentLoadConfiguration)` verifies the actual
registered artifact and effective JACCL configuration, constructs/validates both
compact inventories, materializes only the selected rank, admits the maximum
named request allowance, and completes bilateral load agreement before making
`readiness` non-nil. The configuration contains supplied ordered peer/build
identity, local model directory, rank, cut and an absolute local uptime deadline.
Build/hardware identities are bindings supplied by the owner, not attestations.

The closed initial profile is `registered_qwen35_9b_greedy_generation_v1`:
registered Qwen3.5 9B BF16/4-bit source, cuts 12 or 16, two JACCL ranks, MTP off,
8192 prompt / 512 chunk / 128 output / 8320 context limits. It permits at most
16 fresh UUIDs in one worker lifetime of at most 300 seconds.

`reserve(requestID:request:) -> Int` performs actual live admission and retains
CPU request metadata, without creating request state or executing a forward.
The returned bytes and `readiness.requestCapacityBytes` are local named rank
allowances. The parent sums the two local allowances and caps each reservation
by its remaining aggregate ceiling; it must not divide an aggregate evenly or
substitute the smaller rank's limit for the larger rank's need.

`start(requestID:onCommittedToken:)` runs the existing typed serial generation
request inside the native request lifecycle. Rank 0 alone invokes the callback
with output ordinal, token ID and committed frontier. Returning false requests
an agreed clean stop; throwing is abnormal failure. CPU completion is returned
only after the typed driver reports bilateral request-state retirement and the
lifecycle/autorelease scope has exited. No model, tensor or descriptor escapes.

`cancel(requestID:)` is a thread-safe control flag for the matching reserved or
running request. Other model methods belong to one synchronous executor and
refuse overlapping operations. `shutdown()` synchronizes and releases local
model ownership; it never stands in for the parent's two-worker retirement or
process fence. A failed native worker withdraws readiness and is not reused.
Dropping the object without explicit shutdown does not reopen process admission.

The worker must impose a hard process deadline. Cooperative checks cannot
interrupt a blocked native collective or syscall. On abnormal failure, the
outer owner must cancel/fence the peer and retain its provider lease until both
workers are retired or fenced; a thrown function cannot manufacture a retired
acknowledgment. The facade has no heartbeat or authenticated remote supervisor.

## Resource and source boundaries

Both load and request admission retain actual-free >= 6 GiB, zero reported swap,
pressure <= 2, AC, normal power mode and nominal/fair thermal state. Selected
loading accounts for remaining actual allocator bounds, two host copies,
aligned host scratch and existing headroom. Request admission recalculates the
existing conservative state formula at the actual P+O and adds exact selected
GDN fusion replacement banks, with actual per-array allocator/max-buffer bounds.
These are named allowances, not whole-process peak guarantees. The O128 maximum
named logical state is 754,188,320 bytes; the separate O1/8K receipt is unchanged.

Load agreement uses the full-source parameter layout and a sorted, BOTH-stage
storage commitment. It excludes rank-local paths, local deadline, local active
layout and read accounting. All source bytes and both inventories are checked
before tensor materialization; legacy preparation caps are not broadened.

Model construction and selected loading reuse existing sanitizer, quantization,
prepared-source, inventory and materialization functions. The small new source
preparation coordinator makes the explicit registered/cut12|16 admission; it is
not a second tensor loader. When applying the final move, experiment checks
should use scoped test adapters into these internals, rather than making every
helper public or retaining independent production loaders. The earlier tested
move-list identifies the remaining diagnostic consumers.

## Validation status

Library build 1 passed in 91.873 seconds with jobs=2. All seven new native facade
files compiled; inherited MLX package warnings are retained in its log. No model,
GPU or JACCL execution occurred. That build predates one explicit native-error
preference wrapper in `QwenResidentRuntime+Load.swift`; the original source is
preserved with the build receipt, and test retry 2 compiled the corrected source successfully.

Test attempt 1 failed during package-manifest evaluation: a test target had been
inserted into the runtime dependency array. No test source compiled or executed.
The failing manifest and receipt are retained. The private manifest is corrected.
Test retry 2 compiled the final native-error correction and all seven focused
tests passed (0.123 s test body; 19.846 s build/test), with source pins unchanged.
They use the existing pinned retained metadata via an explicit environment path;
there are no fixture/model copies and no live resource or native-forward tests.

Run from the build directory, once the compiler slot is available:

```sh
python3 run_facade_tests.py 2
```

The normal library remains a macOS 14 package. Actual JACCL worker deployment
must compile Swift AND C++ for macOS 26.2 with the pinned source-matched Metal
library. A successful macOS 14 typecheck does not enable the native JACCL backend.
The next increment is a small actual native worker executable over the frozen
protocol; there is no worker entry or production backend hookup in this handoff.
