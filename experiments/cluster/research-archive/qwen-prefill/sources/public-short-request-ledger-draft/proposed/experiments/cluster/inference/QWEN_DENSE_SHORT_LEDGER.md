# Registered dense-Qwen short request ledger

> Last updated: 2026-09-14 · commit `e4df336bc`

`QwenDenseShortRequestLedger` calculates a pure memory allowance for the exact
registered 9B/27B short comparison geometry. It binds metadata and request history
without loading weights, observing resources or executing a forward pass.

The [entry](Sources/ClusterInference/QwenDenseShortRequestLedger.swift)
(`QwenDenseShortRequestLedger.derive`) takes an admitted profile, its default
16/16 or 32/32 Plan, the actual recorded request, a closed scope, and an
`allocationFootprintUpperBound: (Int) throws -> Int` callback. The request must
contain three prompt IDs, chunk size two, one teacher ID and output count two.
Committed frontiers are 2/3/4; reserved KV capacity is **five** slots. Different
geometry, vocabulary or Plan rejects before allocator callbacks. The resulting
fingerprint includes the full recorded history and each supplied allocation bound.

The [closed scopes](Sources/ClusterInference/QwenDenseShortLedgerTypes.swift)
(`QwenDenseShortLedgerScope`) are `fullReference` and `sequentialStagePair`.
The latter accounts for two co-resident stage owners and retained CPU baseline
evidence. Full-reference and pair calculations describe separate residency phases;
loading owners account for their weights separately.
The [registered profile](QWEN_DENSE_PROFILE.md) and
[loading checks](QWEN_DENSE_LOADING.md) retain their separate identities and gates.

`forwardReserveBytes`, called `Q` by a loading owner, adds these named allowances:

| Term | Derivation and source |
|---|---|
| State | [QwenDenseShortStateLedger](Sources/ClusterInference/QwenDenseShortStateLedger.swift) records BF16 KV/conv and F32 SSM shapes at each frontier. Its separate F32 allowance covers three recurrent generations, KV capacity five and offsets; the existing 512 MiB named-state ceiling remains. |
| Fusion | [QwenDenseShortFusionLedger](Sources/ClusterInference/QwenDenseShortFusionLedger.swift) derives each GDN concatenated weight/scales/biases buffer from registered projection tensors. Their logical sum must equal the storage identity's fusion term. It allows overlap with old storage without claiming a permanently duplicated model. |
| Workspace | [QwenDenseShortWorkspaceLedger](Sources/ClusterInference/QwenDenseShortWorkspaceLedger.swift) charges source-shaped hidden, MLP, projection, convolution and score allowances, plus final BF16/F32 rows. Instance counts are allowances, not observed liveness or kernel dispatch. |
| CPU evidence and boundary | [QwenDenseShortRequestLedger](Sources/ClusterInference/QwenDenseShortRequestLedger.swift) counts baseline native/F32 rows, additional pair comparison rows, one maximum state-component copy and pair boundary copies. Raw state history is not retained; object and serialization overhead remain unknown. |

Each named native array shape is bounded separately before multiplication by its instance
count. Checked sums/products reject overflow, and a bound below the logical array
size rejects. The ledger retains no callback or native object and returns no
partial result on failure. It does not reuse the long-profile requirement's 8K
state values or change existing loader caps.

The caller must supply the actual allocator policy and separately establish its
provenance. `allocatorProvenanceIndependentlyVerified` and
`runtimeExecutionAuthorized` remain `false` in the pure result. `Q` excludes
resident weights, loader host copies, unknown native scratch, unmeasured graph retention,
object/JSON buffers and OS/framework overhead. It is **not a whole-process peak
bound or execution permit**. Live resource admission, provider/hardware
eligibility and numerical qualification remain the native owner's responsibility.

Run the pure fixture on macOS from the repository root:

```sh
bash experiments/cluster/inference/Tests/ShortRequestLedger/run.sh
```

The [runner](Tests/ShortRequestLedger/run.sh) compiles 21 source files under Swift
6 with warnings as errors, uses the existing registered-profile metadata on
stdin, and removes temporary compiler output on exit. It imports no MLX and
downloads no model. An optional first argument selects another reviewed production
source directory. The standalone fixture passed **31 accepted / 42 rejected**
checks with empty stderr; public runner execution remains pending. Its invented
allocator callbacks test exact state/fusion vectors, scope and history binding,
per-array padding, pre-callback refusal and arithmetic errors. These tests grant
no native forward permission or memory-fit guarantee.
