# Registered dense-Qwen short pair loading

> Last updated: 2026-09-14 · commit `e4df336bc`

`runQwenDenseShortPairLoadSupport` loads both compact stages of an exact registered
9B or 27B model in one owned scope, retaining stage 0 while stage 1 loads. It
returns CPU evidence after release. This internal loading-only API has no CLI
entry, forward pass or reference comparison.

The [support entry](Sources/ClusterInference/QwenDenseShortPairLoadSupport.swift)
reuses `QwenDenseShortReferenceAdmission` from the
[full-reference support](QWEN_DENSE_SHORT_REFERENCE_LOADING.md). That immutable
value binds the default 16/16 or 32/32 Plan and the raw prompt/teacher bytes,
request UUID and recorded 3/2/2 history, with capacity five and frontiers 2/3/4.
Sharing it means the intended request matches; it does **not** prove a reference
ran or passed. `referenceExecutionVerified` remains `false`.

| Boundary | Source and behavior |
|---|---|
| Observed ownership | [QwenDenseShortPairLoadBudget.derive](Sources/ClusterInference/QwenDenseShortPairLoadBudget.swift) binds the exact full canonical source, two validated stage budgets in order 0/1, common Plan and separate short-pair ledger. The stage source names must be unique and conserve the complete canonical names and bytes. |
| Private loading scope | [materializeQwenDenseShortPair](Sources/ClusterInference/QwenDenseShortPairLoading.swift) constructs and validates both compact inventories before payload reads. `withExtendedLifetime(values)` retains both real models throughout the ordered pair load. A private gate checks the actual stage/local tensor entry before each read and refuses incomplete or reordered stage completion. |
| Existing materializer | [materializeVerifiedQwenLayerStage](Sources/ClusterInference/VerifiedQwenLayerStageLoading.swift) evaluates and fences each active array, verifies owned allocation and loaded layout, and performs final file checks. It adds no `eval(model)` and may leave inert parameters lazy. |

The outer owner verifies the pinned raw manifest, config and artifact aggregate
once, then reuses its verified descriptors. Its full metadata constructor is
released before compact loading. Arithmetic-environment and MTP checks, exact
source dtype handling and legacy loader caps retain their separate boundaries.
No model or arbitrary model continuation escapes this API.

The [resource policy](Sources/ClusterInference/QwenDenseShortPairResourcePolicy.swift)
(`QwenDenseShortPairResourcePolicy.evaluate`) uses actual per-array allocator bounds
and live OS/native observations supplied by the private owner:

| Term | Meaning throughout the pair load |
|---|---|
| `R` | Remaining active allocation bounds **plus both inert allowances**, including after both stages complete. Freeze and metadata inspection do not prove inert materialization. Loaded active arrays are charged through current native active/cache observations. |
| `H` | Largest host-tensor allowance across the pair while any active read remains; zero after the last active read. |
| `Q` | The separately bound `sequentialStagePair` [short request ledger](QWEN_DENSE_SHORT_LEDGER.md). It reserves named future state/fusion/workspace and CPU baseline evidence; this loading path does not execute those forwards or produce that baseline. |

At every load observation, actual free must be at least
`max(6 GiB, R + 2H + Q + 4 GiB)` and the allocator limit must cover current active
bytes + cache bytes + `R + H + Q + 2 GiB`. Initial and released-state checks retain
the 6 GiB actual-free floor. Absolute reported swap must be zero, pressure must be
0 through 2, and observation age and duration are each bounded to one second.
Reclaimable bytes are diagnostic only. The device maximum buffer is checked for
actual bounds. These operational reserves do not establish a whole-process peak
or promise that subsequent resource checks will pass.

Successful return follows native error checks, weak release checks for both
models and the verified file owner, stream synchronization, cache clearing and
a final resource check. The [report](Sources/ClusterInference/QwenDenseShortPairLoadTypes.swift)
(`QwenDenseShortPairLoadReport`) retains only CPU receipts, budgets and observations.
The caller still supplies deadline checks and independent process fencing.
Source/ownership assertions do not independently prove buffer lineage, tensor
values, numerical parity, provider eligibility or throughput.

Run the pure admission fixture on macOS from the repository root:

```sh
bash experiments/cluster/inference/Tests/ShortPairLoading/run.sh
```

The [runner](Tests/ShortPairLoading/run.sh) compiles 39 source files under Swift 6
with warnings as errors, reuses the existing registered-profile metadata on stdin
and removes temporary output on exit. An optional first argument selects another
reviewed production source directory. It imports no MLX and reads no model
payload. The standalone fixture passed **24 accepted / 82 rejected** checks with
empty stderr; public runner execution remains pending. Invented allocator and
resource observations test exact ownership, F32 preservation, stage ordering,
resident stage-0 charge, retained inert allowances and refusal/overflow cases.
They do not run the private gate, materializer or cleanup path. Native pair
materialization and forward parity remain unqualified by this record.
