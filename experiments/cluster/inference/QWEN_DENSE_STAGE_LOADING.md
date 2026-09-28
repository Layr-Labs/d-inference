# Registered dense-Qwen selected-stage loading

> Last updated: 2026-09-15 · commit `605651bb9`

`qwen-dense-stage-load-check` loads one default half of the exact registered 9B
or 27B checkpoint, checks its installed layout, and releases it. This experimental
entry executes no forward pass or request. Its standalone pure admission fixture
and public runner passed. Separate guarded native runs passed for both registered
9B halves; the 27B path remains unqualified.

The [closed CLI](Sources/ClusterInference/QwenDenseStageLoadCLI.swift)
(`QwenDenseStageLoadCLI`) requires exactly five argument pairs, once each:

| Flag | Accepted value |
|---|---|
| `--mode` | `qwen-dense-stage-load-check` |
| `--model-dir` | Absolute registered checkpoint directory |
| `--registered-dense-profile` | `registered_qwen35_9b` or `registered_qwen38_27b` |
| `--stage-index` | `0` or `1` |
| `--timeout-seconds` | Canonical decimal integer from 1 through 300 |

There are no defaults: use 16/16 halves for 9B or 32/32 for 27B, with one selected
stage per fresh guarded process. Prompts, cuts, traces, transport, repeats and
resource overrides reject. Use the source-matched executable and metallib from
[the build instructions](README.md#build), with the
[required arithmetic environment](Sources/ClusterInference/QwenLongPrefillArithmeticEnvironment.swift).
The parent must enforce its own deadline, observe resources and verify process
reaping; this native entry does not supply a public process supervisor.

The [loading owner](Sources/ClusterInference/QwenDenseSelectedStageLoading.swift)
(`materializeQwenDenseSelectedStage`) reuses complete checkpoint verification and
actual full/compact constructor inventory checks. Both compact inventories retain
their pair metadata binding; a separately rebuilt selected-stage requirement
binds the private loading gate. The shared materializer installs and evaluates
only the selected stage's active tensors, then checks the existing complete load
receipt. The [legacy loader limits](QWEN_DENSE_LOADING.md) remain unchanged.
Passing the [pure profile API](QWEN_DENSE_PROFILE.md) or a synthetic resource
predicate cannot create the private gate.

The [live resource policy](Sources/ClusterInference/QwenDenseStageLoadPolicy.swift)
(`QwenDenseStageLoadPolicy`) requires at least 6 GiB actual free memory before
hashing and after release. At each loading check it requires
`max(6 GiB, R + 2*H + S + 4 GiB)` actual free bytes, where `R` is the remaining
allocator bound plus inert allowance and `H` is the largest selected host tensor
until all reads are permitted. `S` is the conservative host scratch allowance
`8 * 1024 * 1024 + 16_384` bytes while selected reads remain, and zero afterward.
The current allocator limit must cover its
active/cache bytes plus `R + H + 2 GiB`; individual bounds must fit the device's
maximum buffer. Pressure must be 0...2 and absolute reported swap must be zero.
Missing, inconsistent or stale samples reject. The
[Darwin sampler](Sources/ClusterInference/QwenDenseStageLoadResources.swift)
subtracts speculative pages from kernel free pages. Reclaimable bytes and the
recommended working set are read-only diagnostics. No allocator limit is raised.
These headroom rules are operational screens, not memory reservations or proven
whole-process peak bounds.

## Aligned selected-payload reads

[`VerifiedCheckpoint.File`](Sources/ClusterInference/VerifiedCheckpoint.swift)
requests `F_NOCACHE=1` and `F_RDAHEAD=0` on its existing verified descriptor before
selected payload reads. [`CheckpointAlignedReader.read`](Sources/ClusterInference/CheckpointAlignedReader.swift)
uses 16 KiB-aligned offsets, lengths and anonymous private scratch pages, with
at most 8 MiB mapped at once. It requires a 16 KiB OS page size. The anonymous
scratch mapping does not map the checkpoint file. Only selected bytes are copied
into the existing owned `Data`; scratch is unmapped before the MLX tensor copy.
Descriptor identity, bounds, overflow, interruption and exact EOF checks remain
active. No global cache flag changes, and ordinary full-reference reads retain
their existing policy.

[`CheckpointAlignedReadAccounting`](Sources/ClusterInference/CheckpointAlignedReadAccounting.swift)
records selected, requested, returned and padding bytes; read, interruption and
short-EOF counts; and maximum scratch request/allocation sizes. A selected span
can read fewer than 16 KiB of padding at each edge. Interrupted calls add requested
bytes without returned bytes. These operational fields appear in
`sourceLoad.selectedPayloadReadAccounting`; existing tensor counts and semantic
storage commitments retain their meanings. `fileCacheAbsenceEstablished` stays
`false`: requesting uncached IO does not prove that no file pages are cached.

Success emits one bounded `qwen_dense_stage_load_report` JSONL record with the
existing load receipt, metadata budget, OS/MLX observations and runtime/bundle
paths. Native does not hash its own executable or bundle; the parent must bind
those bytes. [The producer](Sources/ClusterInference/QwenDenseStageLoadProbe.swift)
checks native errors, weak model/file-owner release, cache cleanup and final
resources before [publishing](Sources/ClusterInference/QwenDenseStageLoadEntry.swift).
A failed load cannot resume or emit success. Source assertions and metadata
receipts do not independently prove tensor values, provider eligibility, 8K fit,
M3 arithmetic, numerical parity or throughput.

## CPU checks and retained native results

Run the pure fixture on macOS from the repository root:

```sh
bash experiments/cluster/inference/Tests/SelectedStageLoading/run.sh
```

The runner compiles 32 source files under Swift 6 with warnings as errors, without
MLX or a model download. It reuses the existing registered-profile metadata and
observed-stage fixture helpers; compiler output is removed on exit. An optional
first argument selects another reviewed production source directory. The updated
32-source standalone fixture passed 21 accepted and 122 rejected checks with empty stderr
for CLI/profile/role binding, pure budget predicates, exact resource boundaries
and malformed observations.
These synthetic cases do not execute the private live gate, payload ordering,
partial materialization or cleanup.

Its exact actual-free thresholds include scratch while reads remain. The native executable's
`adapter-check` adds `checkpoint_aligned_selected_read_check`: nine accepted and
ten rejected cases use tiny real temporary files for aligned and edge reads,
selected-byte equality, bounds/overflow, EOF/interruption and mutation behavior.
This checks file IO without model arrays or a memory-savings claim. All 43 native
adapter records pass; the preceding 42 retain their exact bytes and order.

Guarded native 9B stage-0 and stage-1 runs each completed in a fresh process on
one 24 GB Mac after disk-cache clearing. They loaded 463 and 464 active tensors
respectively (2,519,016,704 and 2,519,024,896 bytes), then released the model and
verified file owner. Both parents recorded native exit zero, empty stderr, clean
source/bundle checks and complete process cleanup; sampled pressure stayed at 1
and reported swap stayed at zero. The runs qualify separate selected-stage
materialization, without a forward pass or simultaneous stage residency.
A separate metadata audit passed both complete reports: exact default-half
ownership, local layer mapping, active and inert descriptors, loaded dtypes,
layout digests and storage commitments match the retained registered inventory.
Each half preserves twelve F32 `A_log` tensors. The audit does not read weight
values or independently observe allocation peaks or native lifetime. Independent
tensor-value comparison, 27B loading, physical two-machine execution and throughput
remain unqualified.
