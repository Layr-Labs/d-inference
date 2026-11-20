# Registered dense-Qwen selected-stage loading

> Last updated: 2026-09-14 · commit `e4df336bc`

`qwen-dense-stage-load-check` loads one default half of the exact registered 9B
or 27B checkpoint, checks its installed layout, and releases it. This experimental
entry executes no forward pass or request. Its standalone pure admission fixture
passed; public-runner and native materialization qualification remain pending.

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
`max(6 GiB, R + 2*H + 4 GiB)` actual free bytes, where `R` is the remaining
allocator bound plus inert allowance and `H` is the largest selected host tensor
until all reads are permitted. The current allocator limit must cover its
active/cache bytes plus `R + H + 2 GiB`; individual bounds must fit the device's
maximum buffer. Pressure must be 0...2 and absolute reported swap must be zero.
Missing, inconsistent or stale samples reject. The
[Darwin sampler](Sources/ClusterInference/QwenDenseStageLoadResources.swift)
subtracts speculative pages from kernel free pages. Reclaimable bytes and the
recommended working set are read-only diagnostics. No allocator limit is raised.
These headroom rules are operational screens, not memory reservations or proven
whole-process peak bounds.

Success emits one bounded `qwen_dense_stage_load_report` JSONL record with the
existing load receipt, metadata budget, OS/MLX observations and runtime/bundle
paths. Native does not hash its own executable or bundle; the parent must bind
those bytes. [The producer](Sources/ClusterInference/QwenDenseStageLoadProbe.swift)
checks native errors, weak model/file-owner release, cache cleanup and final
resources before [publishing](Sources/ClusterInference/QwenDenseStageLoadEntry.swift).
A failed load cannot resume or emit success. Source assertions and metadata
receipts do not independently prove tensor values, provider eligibility, 8K fit,
M3 arithmetic, numerical parity or throughput.

Run the pure fixture on macOS from the repository root:

```sh
bash experiments/cluster/inference/Tests/SelectedStageLoading/run.sh
```

The runner compiles 30 source files under Swift 6 with warnings as errors, without
MLX or a model download. It reuses the existing registered-profile metadata and
observed-stage fixture helpers; compiler output is removed on exit. An optional
first argument selects another reviewed production source directory. The separate
standalone fixture passed 21 accepted and 122 rejected checks with empty stderr
for CLI/profile/role binding, pure budget predicates, exact resource boundaries
and malformed observations.
These synthetic cases do not execute the private live gate, payload ordering,
partial materialization or cleanup. Public runner and native execution remain
pending independent qualification.
