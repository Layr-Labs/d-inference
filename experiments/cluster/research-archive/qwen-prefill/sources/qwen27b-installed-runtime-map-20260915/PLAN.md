# Registered 27B extension: exact source map, no execution claim

This is a metadata calculation and an implementation gap list. No runtime,
provider allowlist, capability descriptor, source bundle or MAIN file was changed.
No weight payload, compiler, native worker, remote host or model was executed.
`map_metadata.py` checks three exact retained metadata files and conserves all
1,847 canonical text tensors over every structural four-layer cut. Its output
is **not** a Swift Plan fingerprint, memory admission, installed capability or
proof that any such cut currently executes.

## Artifact and reusable implementation

The registered artifact is `EigenLabs/Qwen3.8-27B-4bit-mtp`, aggregate
`bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`.
The native metadata identity is `registered_qwen38_27b`. The public route must
remain the manifest's exact ID; the folder name is not the public model ID.
Configuration, manifest and retained header-layout pins are in `metadata-map.json`.

The config uses the existing dense `qwen3_5` implementation: 64 layers, interval
4, H5120, MLP17408, 24 query/4 KV heads, head dimension256, 16 linear key heads,
48 linear value heads, dimensions128, convolution4, BF16 and affine W4/G64.
Vocabulary is248320. The manifest totals16,320,415,757 B; selected text weights
are15,132,802,048 B (14.093519 GiB). Vision333 tensors and MTP31 tensors are
excluded from the initial target-only path. The largest target tensor is
635,699,200 B (606.25 MiB), versus the legacy512 MiB host limit.

Local metadata includes a2026-09-14 verification receipt and weight files with
the declared sizes. That is retained evidence, not a new payload verification.
The older `weight-layout.json` explicitly describes header-range observations;
the present calculation checks its complete canonical hash against the catalog.
Actual loading must still verify every manifest member through VerifiedCheckpoint.

Already reusable without changing math or lifetime semantics:

- [QwenDenseRegisteredSpecification.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenDenseRegisteredSpecification.swift) pins both models, exact inventory and geometry.
- [QwenLayerStagePlan.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenLayerStagePlan.swift) conserves complete whole-layer ownership, interval phase, affine policies and inactive embedding/head replacements; legal structural cuts are4,8,...,60.
- [QwenDenseObservedSource.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenDenseObservedSource.swift) and [QwenDenseObservedStage.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenDenseObservedStage.swift) already use exact registered source/host bounds. Do not reroute this through legacy6 GiB/512 MiB validation.
- [CBv2RequestGeometry.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/CBv2RequestGeometry.swift), stage session, generation driver and token/commit controls derive actual loaded geometry. P8192/C512/O128 still means capacity8320, 16 prefill +127 decode frames, final frontier8319 without early stop. The BF16 residual is5 MiB, below the unchanged16 MiB wire cap.
- Installed manifest/model/Plan, owner, Pair, HTTP tokenizer-only registry and deadline/lifetime/resource-release machinery carry typed capability identities. Their general framing needs no27B-specific rewrite. The loaded tokenizer must come from this artifact: its tokenizer.json SHA06b95093...e523 differs from9B; do not reuse9B prompt IDs or expected outputs.

## Minimum connected source changes

These form one closed registered execution-profile extension, followed by real
qualification. A one-line allowlist edit is insufficient.

| Source / symbol | Required change |
|---|---|
| [ClusterRuntimeCapability.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterRuntimeCapability.swift), `ClusterRuntimeAdapter.runtimeModelID/profileID`; [validation](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterRuntimeCapabilityValidation.swift) | Separate architecture adapter from the closed model/profile mapping. Validate exact adapter+model+profile tuples, not a universal9B property. Preserve existing9B wire bytes. Proposed new ID: `registered_qwen38_27b_greedy_generation_v1`; it is not currently supported. |
| [QwenResidentAdapterDefinition.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentAdapterDefinition.swift) | Replace global9B profile/cuts with a specification-selected definition containing model, profile, bounded candidate cuts, max named state and permitted scheduling policy. Keep300 s,16 requests, greedy,8192/512/128/8320 and MTP off. Begin serial for27B; advertise lookahead only after its own correctness pass. |
| [QwenResidentCapabilityMetadata.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentCapabilityMetadata.swift) | Resolve the exact config+manifest pair through the same closed definition as live admission. Generate actual native Plan hashes and supported cuts from that definition. Metadata is not readiness/qualification. |
| [WorkerConfiguration.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/WorkerConfiguration.swift) | Replace literal9B/cut4\|8\|12\|16 checks with the selected closed definition. Reject crossed model/config/artifact/cut/profile combinations before bootstrap/load. Preserve strict argument/deadline parsing. |
| [QwenResidentAdmission.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentAdmission.swift) | Resolve specification by exact identity+raw metadata, use its definition and model-specific named-state maximum. Bind the selected definition into the existing profile/load agreement; retain arithmetic/JACCL and immutable prefill selection. Existing9B behavior and ceiling stay unchanged. |
| [QwenRegisteredDenseModelProfile.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenRegisteredDenseModelProfile.swift), `makePlanningPlan` | Explicitly extend current27B32/32 planning-only scope to chosen interval-aligned cuts, with exact complete inventory fixtures. It remains metadata-only and cannot itself grant execution. Do not change the legacy/default-half StageLoadBudget API. |
| [QwenResidentSource.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentSource.swift) | Replace accidental `LocalCorrectnessStorage.maximumManifestPayloadBytes`8 GiB input with the exact selected specification manifest byte bound and raw pin; require prepared model equals the admitted model instead of9B. Keep legacy storage constants/callers unchanged. |
| [QwenResidentRequestResources.swift](/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentRequestResources.swift) | Admit the closed selected profile/Plan, recompute at its actual request P+O/chunk, and compare to its own maximum. Preserve per-array actual allocator rounding, full-model conservative state charged to each rank, selected GDN fusion charge,6 GiB actual-free floor,4 GiB loading/request headroom and2 GiB allocator headroom. Do not solve this by reducing these terms. |
| Existing registered/native fixtures and capability/worker/provider tests | Add exact27B inventory/cuts and crossed-model rejection; keep9B canonical descriptor/serial behavior unchanged. Parameterize diagnostic expectations:27B has144 full-model final-state components, not the9B72. |

The current8 GiB source ceiling rejects this artifact even before selected loading.
The existing768 MiB9B state ceiling also rejects it. The registered P+O8193
metadata formula is1,599,082,560 B; at the resident8320 maximum it is
**1,616,248,896 B (1.505249 GiB)**. Use an independently checked per-profile
maximum, not a globally enlarged9B constant. The current per-profile storage
record remains the old8192/512/output1 metadata scope; do not relabel its
`namedStateBudget`/`finalState` as the128-output ledger. Live generation already
derives a separate request allowance and must continue doing so.

## M4 memory decision, not a performance projection

The table applies the existing formulas with allocator bounds set to logical
bytes, therefore every number is a **lower bound**, not a grant. `H` is606.25 MiB;
`S` is8 MiB+16 KiB. Initial actual-free requirement is
`max(6 GiB, selected+inert+2H+S+4 GiB)`. Initial allocator requirement additionally
depends on current active/cache bytes and actual per-array rounding. The final
column is free memory still required **after weights are resident**, before the
maximum request: `max(6 GiB, fullState+selectedFusion+4 GiB)` before rounding.

| Cut (rank0 on24 / rank1 on48) | Selected GiB 0 / 1 | Initial free GiB 0 / 1 | Post-load request free GiB 0 / 1 |
|---|---:|---:|---:|
|4/60|1.463635 /12.629885|6.655564 /17.821805|6.000000 /7.494375|
|8/56|2.261223 /11.832297|7.453152 /17.024216|6.000000 /7.361767|
|12/52|3.058812 /11.034708|8.250741 /16.226627|6.000000 /7.229158|
|16/48|3.856401 /10.237119|9.048330 /15.429039|6.035683 /7.096550|
|32/32|7.046755 /7.046765|12.238684 /12.238684|6.566116 /6.566116|

Choose the first correctness cut from fresh actual-free and allocator observations
on both machines, including after verification and load. Meeting the initial
gate alone does not guarantee meeting the post-load/request gate.4/60 reduces
the24GB weight burden but increases48GB storage/work;32/32 is not a default
memory-fit assumption for this heterogeneous pair. No current peer free memory,
native rounded allocation, maxBuffer allowance, workspace peak or throughput was
measured here. VerifiedCheckpoint still checks all manifest payloads; its
descriptor-local checksum cache policy does not prove zero file-cache growth.

## Preserve local policy and qualify the new route

[The execution plan](/Users/developer/DarkbloomDev/d-inference/docs/design/distributed-cluster-execution-plan.md)
explicitly requires a qualified distributed profile in provider **and** coordinator.
[ModelRuntimeRequirements.swift](/Users/developer/DarkbloomDev/d-inference/provider-swift/Sources/ProviderCore/Models/ModelRuntimeRequirements.swift)
protects both exact27B IDs with M5+NAX, including the MTP-named artifact. Preserve
all ordinary solo/download/prefetch/model-loading gates. Never report M4 as M5,
claim NAX availability or alter the public model name to evade those gates.

Add a separate distributed execution-policy selection bound to the exact artifact,
runtime/profile/arithmetic/Plan, both members and resource/ownership mode. Keep
unqualified profiles out of advertised inventory; an installed capability file or
Ready alone is not numerical/hardware qualification. The current local-only
installed path must explicitly require that distributed policy before admitting
this protected artifact; simply broadening its native descriptor would silently
create a policy bypass. For coordinator service, carry the execution profile and
single-cluster capacity explicitly into eligibility/routing, not into the existing
M5/NAX hardware capability list. [The coordinator gate](/Users/developer/DarkbloomDev/d-inference/coordinator/registry/provider_capabilities.go)
currently embeds the non-MTP exact ID only, whereas provider protects both;
binding the new route to the artifact also avoids exploiting that asymmetry.

Ordered exit criteria:

1. Model-free native-profile/capability/Plan/resource fixtures prove all exact
   identities and complete ownership;9B snapshots and rejection behavior remain.
2. Source-matched native build and actual selected load on both M4 members pass
   unchanged resource gates, with no full-model load on24GB. Short prefill/decode
   correctness precedes8K; old registered short-reference math supports both
   metadata profiles, while the old long-reference admission is explicitly9B.
3. Extend the independent full-model reference's **admission/loader** to this exact
   artifact and P+O8320, retaining its existing CBv2 math and resource checks. Then
   compare actual128 greedy IDs, final logits and144 state components at the
   correct frontier; no9B expected outputs or fabricated reference.
4. Only then enable the explicit qualified installed distributed policy and test
   normal HTTP/tokenizer path, server counts, external first-content timing,
   cancellation, fresh-state recovery and lifetime/quota cleanup. Profile cuts
   using measured stage/transfer times. Add lookahead and then MTP separately.

No native capability or runtime overlay is emitted in this package: the missing
policy and connected admission changes are larger than a safe isolated profile
toggle. The concrete reusable increment here is the independently replayable
metadata/cut/resource mapping and exact source-pinned edit list.
