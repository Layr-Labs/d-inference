# Next increment: bind the actual verified loader to the closed dense profile

Source-only plan, 2026-09-14. No implementation, compiler, native/SSH work or
checkpoint payload reads. Reuse the six pure core files frozen at
`76977a8d4f9157b3ecfd47963750938978de642352af057336e4a475d9936366`.
Root's subsequent fixture-only `String(describing:)` fix does not alter this seam.

The downloaded-header receipt
`../models/qwen38-downloaded-header-verification-20260914.json`, SHA
`8d443bfbafe59d72a962ecdcbb8ba32e9459869a8fd3536b2e375a8a23efe33c`,
reports exact retained headers:2,211 raw entries,1,847 text entries and
15,132,802,048 text bytes. It explicitly does **not** validate the constructed,
sanitized canonical inventory. That is the next runtime-relevant gap. Do not
repeat the download/header audit or write another numerical-proof framework.

## Implement the descriptor validator first

Extract the common checks currently split between `DiagnosticQwenStorage` in
`VerifiedQwenDiagnosticLoading.swift` and `prepareVerifiedQwenLayerSource` in
`PreparedQwenLayerSource.swift` into a small Foundation validator. Its input is
a CPU descriptor projection from the **actual** `PreparedQwenCheckpoint`:
canonical name, source shape/dtype/bytes, source-part count, expected constructor
shape and packed-versus-floating parameter class. Also supply the actual retained
source count, exact closed profile, rebuilt Plan and role-bound requirement.

Return a read plan of validated scalar records and expected loaded layout. Keep
the existing one-part dense restriction, complete name equality, matching shapes,
affine policy/topology checks and F16→BF16 policy. Compare the full observed
descriptor signature/count/bytes with the closed profile, not only namespace
counts. Validate the actual stage inventories against `Plan.parameters`, both
construction identities and the selected active/inert byte totals before the
first `tensor.read(.all)`. This immediately strengthens the real loader rather
than creating another detached metadata receipt.

A useful narrow API shape is:

```swift
validateDenseSourceDescriptors(observed: [ObservedDenseTensor],
    retainedSourceCount: Int, profile: QwenRegisteredDenseModelProfile,
    requirement: QwenDenseStorageRequirement) throws -> DenseSourceReadPlan

validateDenseStageInventory(source: DenseSourceReadPlan,
    plan: QwenLayerStagePlan, stageIndex: Int,
    active: [ObservedStageTensor], inert: [ObservedInertTensor]) throws -> DenseStageReadPlan
```

These are validation results, not resource permission. Keep them small and
private to the verified-loading path; existing load receipts already carry the
useful inventory evidence, so a new parallel JSON proof format is unnecessary.

## Thread one explicit policy through the existing materializers

Keep all old function signatures as wrappers on the current legacy policy.
Factor the existing bodies once; do not copy the materialization loops. Add
registered overloads at these exact seams:

| Existing symbol | Registered overload/change |
| --- | --- |
| `VerifiedCheckpoint.init` | Add optional `expectedManifestSHA256`, default nil. Check the raw manifest bytes actually read before decoding/verifying files. The current code pins aggregate/configuration but does not enforce the profile's raw manifest pin. Preserve descriptor lifetime, full file hashing and unchanged-file checks. |
| `PreparedQwenCheckpoint.init` | Forward that optional pin and the role's exact bounded manifest total. No sanitizer/composition/quantization change. |
| `loadVerifiedQwenDiagnostic` and `loadVerifiedQwenLayerStageBaseline` | New overload accepts a registered loading context; use the shared observed-descriptor validator and profile limits before the first payload materialization. Keep the existing eval/error/update/freeze/layout/activation checks. |
| `prepareVerifiedQwenLayerSource` and `loadVerifiedQwenLayerStage` | Forward the same context through metadata preparation; validate both actual compact inventories before reads, then retain the current per-tensor settled compact-ownership and byte checks. |

The loading context must bind profile, requirement, Plan, role and independently
performed runtime admission. Do **not** accept `QwenDenseResourcePlanningInput`,
`fitsCallerPlanningCeiling`, an arbitrary byte ceiling or a caller Boolean as
that admission. A policy hash plus positive reserves still proves nothing about
current resources. Keep the new registered overload internal/unwired until the
entry's actual device/OS/resource gate exists; old callers cannot select it.

Budget the process role correctly: a one-process pair loads both stages under
one `.sequentialPair` requirement; two separate rank processes use `.stage0` and
`.stage1`. Two isolated-rank requirements cannot justify co-resident pair loading.
The owner must bind the allowed load sequence/role, preventing reuse of a full
or stage admission for an additional resident model. Preserve baseline release
before pair loading and all existing cancellation/weak-release handling.

For registered27B the observed validator must admit the exact15,132,802,048-B
source and635,699,200-B largest tensor; the legacy6-GiB/512-MiB refusals remain
unchanged. The manifest limit is the exact16,320,415,757-B profile total, not a
globally widened default. The legacy4/8-GiB partitioned limits also stay intact.
Allocator/workspace/fusion and current OS admission remain separate from these
descriptor bounds. Preserve pre-forward compact/layout evidence: native GDN
fusion legitimately replaces parameter modules with views after first use.

## Tests now; request admission next

CPU fixtures for the new validator can use the existing927/1,847 retained
descriptors plus fake observed constructor records. Check complete positive
full/stage maps; wrong source/loaded dtype, shape, packed class, part count,
missing/duplicate names, stage owner/local name, inert shape/bytes, wrong Plan or
role, size overflow and stale9B limits. A fake materializer counter must remain
zero for every rejection. Add a bounded temporary-manifest fixture proving a
wrong raw manifest pin fails before file verification/materialization. Existing
legacy validator/load tests must retain their current outcomes. These tests add
value without reading16GB or constructing a model.

After this shared loader increment, change the long request admission to accept
a common admitted dense request assembled from profile+token profile+prompt+
arithmetic+runtime admission. Keep 9B entry points as exact wrappers. Bind the
actual `LoadedModel`/`LoadedQwenLayerStage` receipt to the new source read plan;
then use the existing64-layer-capable `CBv2RequestGeometry` and sessions.
Replace only the new-scope927/32 and72/319,946,784 guards with validated profile
and state requirements; fix pair agreement's hardcoded4096 to admitted hidden
width. A27B reference requires a distinct model-qualified evidence domain, never
the existing `registered9b` label. Do not start with a copied27B inference runner.

The first later native check should exercise the verified27B loader and actual
constructor inventory under the new runtime gate before any long forward. It
should return existing inventory/layout evidence and release the model. A fresh
same-chunk full baseline and pair/rank numerical qualification follow separately;
the present plan neither authorizes nor claims those runs.
