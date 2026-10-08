# Registered dense-Qwen short full-reference loading

> Last updated: 2026-09-14 · commit `e4df336bc`

`runQwenDenseShortReferenceLoadSupport` loads one exact registered 9B or 27B full
model, evaluates its parameters, and returns CPU evidence after releasing the
model and verified file owner. This experimental internal API has no CLI entry
and executes no embedding arithmetic, request state or forward pass.

| Boundary | Source and behavior |
|---|---|
| Request admission | [QwenDenseShortReferenceAdmission.admit](Sources/ClusterInference/QwenDenseShortReferenceAdmission.swift) binds the registered config/manifest, default 16/16 or 32/32 Plan, caller-supplied request UUID and separately pinned raw prompt/teacher bytes. Each input is bounded to 4 KiB. The recorded schedule is three prompt IDs, chunk size two, one teacher ID, output count two and frontiers 2/3/4, with capacity five. Admission alone grants no loading permission. |
| Source and budget | [QwenDenseShortReferenceLoadBudget.derive](Sources/ClusterInference/QwenDenseShortReferenceLoadBudget.swift) binds the complete observed canonical inventory, full-reference requirement, recorded history, short ledger and ordered allocation bounds. Registered U32, BF16 and F32 tensors retain their corresponding loaded types; the 9B inventory includes 24 F32 `A_log` tensors. |
| Private owner | [runQwenDenseShortReferenceLoadSupport](Sources/ClusterInference/QwenDenseShortReferenceLoading.swift) checks the arithmetic environment and MTP exclusion, verifies the checkpoint once, constructs the model and validates its actual descriptors. Only its file-private gate can admit the ordered payload reads using live observations. |
| Materialization | [materializeVerifiedQwenDiagnostic](Sources/ClusterInference/VerifiedQwenDiagnosticLoading.swift) reads, sanitizes, evaluates and updates one tensor at a time, then evaluates the full parameter tree and checks the loaded layout and byte totals. Its caller owns and discards the model on failure. |

The checkpoint's exact raw manifest, configuration and artifact aggregate remain
separate identities. The owner passes the verified checkpoint into preparation,
then checks its file identity again after loading. The shared materializer's
legacy entry keeps its original bounds, including the
[6 GiB source / 512 MiB host-tensor limits](Sources/ClusterInference/QwenDenseLegacySourceBounds.swift)
(`QwenDenseLegacySourceBounds`). This registered path does not widen those limits
or change provider eligibility.

The owner obtains each native allocation bound from
`Memory.allocationFootprintUpperBound` and checks the device maximum buffer size.
The [resource policy](Sources/ClusterInference/QwenDenseShortReferenceResourcePolicy.swift)
(`QwenDenseShortReferenceResourcePolicy.evaluate`) requires:

| Resource | Requirement at the current load ordinal |
|---|---|
| Actual free bytes | At least `max(6 GiB, R + 2H + Q + 4 GiB)`. |
| Allocator limit | At least current active bytes + cache bytes + `R + H + Q + 2 GiB`. |
| OS observation | Absolute reported swap use is zero; pressure is 0 through 2. Observation duration and age are each at most one second. |

`R` is the sum of remaining ordered weight allocation bounds. `H` is the largest
host tensor while entries remain, and zero at the completed ordinal. `Q` is the
separately bound [short request ledger](QWEN_DENSE_SHORT_LEDGER.md), whose named
state, fusion, workspace and CPU evidence allowances are described there.
Initial and released-state checks retain the 6 GiB actual-free floor. Estimated
reclaimable memory is diagnostic only. The 4 GiB and 2 GiB headroom values are
operational policy; neither those values nor `Q` establish a whole-process peak
bound. Pure decisions made from synthetic observations cannot create the private
live gate.

The owner checks native errors around work and preserves accompanying cleanup
failures. Successful return follows stream synchronization, weak model/file-owner
release checks, cache clearing and a final resource check. The
[report](Sources/ClusterInference/QwenDenseShortReferenceLoadTypes.swift)
(`QwenDenseShortReferenceLoadReport`) contains only CPU receipts, budgets and
observations. Artifact hashing and layout checks do not independently compare
resident tensor values. The caller supplies the throwing deadline check and
parent process fencing remains required; loading does
not establish numerical parity, forward eligibility, throughput or memory safety.

Run the pure admission fixture on macOS from the repository root:

```sh
bash experiments/cluster/inference/Tests/ShortReferenceLoading/run.sh
```

The [runner](Tests/ShortReferenceLoading/run.sh) compiles 38 sources under Swift 6
with warnings as errors, reuses the existing registered-profile metadata on stdin
and removes temporary compiler output on exit. An optional first argument selects
another reviewed production source directory. It imports no MLX and reads no
model payload. The corrected standalone fixture passed **22 accepted / 101
rejected** checks with empty stderr; public runner execution remains pending.
The fixtures exercise exact source dtypes, request/role/Plan binding, ordered
reads, checked allocation arithmetic and synthetic resource refusals. They do
not run the private owner or materializer. Native full-reference loading remains
unqualified by this record.
