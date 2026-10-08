# Verified real baseline for sequential layer stages

Source-only draft. [VerifiedQwenLayerStageBaseline.swift](VerifiedQwenLayerStageBaseline.swift)
has not been compiled or executed. It adds no CLI, model-loading branch,
transport or benchmark claim.

`loadVerifiedQwenLayerStageBaseline(directory:originalConfiguration:
expectedAggregateSHA256:)` returns the ordinary `LoadedModel` type around a
full, unpartitioned public dense Qwen model. The metadata fields follow the
existing loader: family, model label, original config hash/data, vocabulary,
full layer count, dense FFN kind, actual embedding activation dtype, FFN scale
dtypes, resident parameter-layout hash and the verified BF16-conversion flag.
`directShardLoad`, `partitionPlan` and `partitionStorage` are nil;
`verifiedDiagnosticLoad` carries the existing verified full-load receipt.

The factory disables MTP before construction and installs no attention-output,
FFN-output, branch-precision or reduction wrappers. It is a native-arithmetic
baseline for the separately guarded stage path. Construction/config validation
and the existing verified loader reject MoE and active MTP. This helper belongs
in a serialized diagnostic process; it does not change the serving factory.

## Verification and retained identity

The caller supplies exact retained configuration bytes and the expected
artifact aggregate. The source configuration is bounded to 1 MiB and validated
with the same pure metadata rules used by the layer-stage planner. The helper
constructs from the original bytes; it never substitutes compact stage config.

`loadVerifiedQwenDiagnostic` supplies pinned file descriptors, manifest/payload
hash verification, exact retained-config and aggregate matching, canonical
source-name preparation and full expected keys/shapes/packed-versus-floating
dtype classes. It enforces the existing **8 GiB manifest payload**, **6 GiB
canonical source**, and **512 MiB individual source tensor** caps before tensor
materialization. Its F16-to-BF16 conversion and per-layer quantization policy
remain unchanged. Dense FFNs retain the currently supported affine W4/G64
validation; this helper does not add a new quantization capability.

After verified loading, the helper evaluates the actual embedding on token 0
once and checks its `[1,1,H]` shape and floating activation dtype. Empty-cache
CBv2 geometry must agree on KV/conv dtype. The probe array and geometry stay
local. The returned verified receipt contains scalar identity/accounting only;
no checkpoint descriptor is retained by it. Request helpers must still validate
the complete prompt/teacher/chunk/context schedule before executing a session.

## Proving the baseline is gone before either stage loads

The orchestrator should use an autorelease scope, retain only CPU evidence, and
keep a weak model reference outside that scope. For example, in pseudocode:

```swift
weak var baselineModel: Module?
let evidence = try autoreleasepool {
    let loaded = try loadVerifiedQwenLayerStageBaseline(...)
    baselineModel = loaded.model
    let session = try CBv2RequestSession(loaded: loaded, ...)
    defer { try? session.close() }
    // Run the agreed chunks and continuation; copy logits/state evidence to Data.
    // Explicitly close and check the session on success, too.
    return cpuEvidenceOnly
}
guard baselineModel == nil else { throw ProbeError("Baseline remained retained") }
// Only now load verified stage 0 and stage 1.
```

The outer native error scope, explicit success-close, failure cleanup and
process deadline are the orchestrator's responsibilities. Do not retain a
session, model adapter, closure capturing `LoadedModel`, or device-array output
in the returned evidence. A cleared weak reference proves release of the Swift
model, **not** that the MLX allocator cache is empty or every byte is returned to
the OS. Synchronize/check before sampling live/cached MLX and OS memory; preserve
those observations separately. Never keep the full baseline beside both stages.

## Resource accounting before a real run

For two full-width stages, sum actual active descriptor bytes from their common
storage commitment. Exact one-owner coverage makes that sum equal the canonical
full-model source bytes, rather than two copies of the full model. Add both
stages' separately declared inert bytes. With the independently inventoried
9B source, that is 5,038,041,600 active bytes; H=4096 and BF16 placeholders add
24,576 bytes for stage-0 norm/head and stage-1 embedding. These are logical
parameter payloads, not a process-memory admission estimate.

A conservative planning worksheet should separately include:

* Allocator footprint bounds for **every** active and inert tensor; summing
  logical bytes alone omits per-allocation alignment/cache reuse.
* Both compact KV capacities at the full request-token bound, and each recurrent
  specification's `peakBytesPerRequest()`; use the actual source activation dtype.
* At least two boundary buffers during the explicit owned copy, plus bounded CPU
  raw-byte hashing/comparison copies. For M=32/H=4096/BF16, one logical boundary
  is 262,144 bytes. Prompt/state/logit evidence kept on the CPU is additional.
* Loading transients from one source host tensor (at most 512 MiB), the copied
  MLX input and any dtype-conversion output. Stage loads are sequential; account
  for the already-loaded first stage while loading the second.
* Frozen fused-projection/cache materialization, activation and kernel workspace,
  model/graph metadata, allocator cache and OS headroom. Descriptor counts do
  not provide a closed upper bound for these. Full-width layers can lazily retain
  fused GDN matrices alongside their source projections during forward.

Only the first categories have direct tensor/geometry-derived bounds. Use the
existing memory-pressure/swap monitor, measured load/forward observations and a
hard process deadline for the remaining admission decision. Do not label the
5.038 GB payload, or a worksheet omitting those terms, a total memory upper bound.
No hardware run, peak-memory qualification or throughput measurement is implied.
