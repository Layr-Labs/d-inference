# Registered 27B: portable experimental arithmetic binding

2026-09-14. Source-only proposal; no repository changes, builds, model jobs,
downloads, SSH or production requests. Exact inspected bytes are in
`source-pins.json`. The saved catalog is a 2026-09-13 snapshot, not a live query.

The next useful change is a **CPU evidence-binding audit for the existing
registered short parity path**, keeping actual Metal device selection and the
current native executable unchanged through its first parity test.
There is no source evidence here that 27B needs a new operator or weight conversion
to attempt this path on M3. There is also no M3 numerical or performance proof.

## Prior work reused

- [2026-09-13 eligibility audit](../qwen38-output-gate-and-eligibility-audit-20260913.md)
  already identified the explicit M5/NAX rollout rule and absence of a demonstrated
  non-NAX kernel failure explaining it.
- [Output-gate audit](../qwen27-output-gate-audit-draft/FINDINGS.md) separates GDN
  SiLU/Swish semantics from provider eligibility. Current `QwenLayerStageMetadata`
  now accepts only the compatible `swish`/`silu` declarations without rewriting
  raw config; `Qwen3NextRMSNormGated` still normalizes, applies FP32 SiLU/multiply,
  then casts back. No gate rewrite is proposed.
- [Registered-profile plan](../qwen27-model-profile-draft/PLAN.md) already proposed
  identity/storage separation. Its missing-loader and metadata-rejection status
  is historical: current registered constructor, selected-stage, short full/pair
  loading and short parity sources exist. This proposal reuses them.
- The [active goal](../../d-inference/docs/design/distributed-inference-goal.md)
  requires two M3 Ultras, exact registered artifact and paired eligible single-node
  comparison. Its hardware/performance acceptance remains a separate qualification.

## What currently enforces which restriction

| Boundary | Exact fields or source | Consequence |
|---|---|---|
| Retained catalog | Model `EigenLabs/Qwen3.8-27B-4bit-mtp`, version `2026-09-03-r1`, `required_provider_capabilities=[apple_m5,mlx_nax]`; description says M5 only | Explicit provider policy. `min_ram_gb=36` and provisional activation floor are not hardware/numerical qualification. |
| Swift provider | `ModelRuntimeRequirements.swift:139–161` unions both capabilities for the exact case-sensitive non-MTP **and** MTP IDs even without catalog requirements | Renaming/removing a catalog field is not a legitimate portable-profile implementation. |
| Detection/loading | Same file `:40–55` requires structured `.m5` for `apple_m5`, bound nonempty metallib hash plus diagnostic for `mlx_nax`; `ProviderLoop+ModelLoading.swift:201` and `StandaloneServer.swift:1398` call `requireEligible`; `ModelDownloader.swift:67` evaluates catalog requirements too | M3 fails the M5 rule even if a caller supplies `naxAvailable=true`; existing tests cover M1–M4. |
| Coordinator | `provider_capabilities.go:63–179` binds `RuntimeCapabilities`, `ChipFamily`, `MetallibHash` to signed registration, `TemplateHashes["mlx_metallib"]`, fresh code/hardware/runtime approval; `:214–280` gates catalog acquisition/serving | Backend approval is also a coordinator concern. Its embedded fallback names the non-MTP ID; the retained MTP catalog row plus Swift exact-ID gate cover the registered artifact. |
| Artifact identity | `QwenDenseRegisteredSpecification.swift:38–45` pins raw config `4691…c1ff`, raw manifest `d123…6dcc`, aggregate `bbd0…8463`, inventory `ebe2…1624`, 1,847 tensors | These immutable artifact pins are independent of provider capabilities. The artifact manifest describes files/checksums, not a portable runtime permit. |
| Experimental profile | `QwenRegisteredDenseModelProfile.swift:4–17,94–103`, `QwenDenseConstructorAdmission.swift:4–43` | Exact registered metadata and initial 27B 32/32 Plan; `providerEligibilityEstablished=false`. The generic exporter’s 15 legal 27B cuts do not widen this execution scope. |
| Experimental arithmetic | `QwenLongPrefillArithmeticEnvironment.swift:6–47` | Query block 128, BF16 conversion 1, TF32 1; `MLX_METAL_GPU_ARCH` and `MLX_SDPA_BLOCKS` absent. This does **not** require NAX or certify a device/binary. |

The cached catalog’s `metadata.activation_floor_basis` mentions M4 Max non-NAX
cells; that string has no raw numerical/timing evidence attached in this review.
It cannot establish portable support or a memory threshold. The approved runtime
metallib identity above is also distinct from the artifact’s `manifest.json`.

## Actual backend behavior and the remaining observation gap

`libs/mlx/mlx/backend/metal/device.cpp:999–1018` returns NAX unavailable when built
with `MLX_METAL_NO_NAX`; otherwise it requires OS 26.2 and detected architecture
generation at least 17 for non-phone devices (18 for phone). Device architecture
comes from Metal unless `MLX_METAL_GPU_ARCH` overrides it (`:641–655`). Preserve the
existing prohibition on that override. The experiment itself targets macOS 26.2
in `Package.swift` and `build.sh`; this OS requirement is separate from M5 hardware.

Non-NAX branches already exist in `quantized.cpp:1044–1124` (QMM),
`matmul.cpp:917–936` (including Ultra-family split-K selection), and
`scaled_dot_product_attention.cpp:218–250,754–772`. With head dimension 256,
query length above eight takes the unfused path unless the earlier eligible
NAX-specialized case applies. Query blocking at 128 remains in the existing
CBv2 attention helper. These are source dispatch possibilities, not measured
routes or proof that all 27B arithmetic succeeds.

**TF32=0 is not a NAX-off switch:** QMM/GEMM/SDPA NAX predicates allow
`enable_tf32() || dtype != float32`; BF16 remains eligible. Do not change TF32,
pretend to be an older GPU, or alter packed quantization merely to name a portable
profile. The current actual-device contract can already select fallback kernels.

`GPU.deviceInfo()` exposes actual Metal architecture and limits. The existing
`GPU.gemma4ExpertQMMDiagnostics().naxAvailable` is useful observed provenance but
its C++ snapshot catches every exception and returns a zeroed/partial result
(`device.cpp:1025–1059`). A false field alone is therefore **not** a reliable
successfully-observed “NAX disabled” attestation. Current short runtime reports
include architecture/OS/limits, but no status-bearing NAX observation and no
native verification of executable/metallib hashes. Preserve those limits.

## Smallest concrete implementation increment

The existing full and pair reports already carry the same
`QwenDenseStageLoadRuntimeObservation` schema, including actual architecture, OS,
device memory/max-buffer, executable/bundle paths and PID. Both owners reread the
fixed arithmetic environment. There is no reason to duplicate these structures
or rebuild the native binary merely to hash them. The concrete gap is validation:
the current short outer contract requires a `runtime` member but does not validate
its fields, compare the two observations, or join their process/bundle identity to
the completed parent and source/runtime evidence. The numerical oracle explicitly
leaves runtime/lifetime/resource provenance to those separate joins.

1. Add an out-of-tree pure `audit_short_execution_binding.py` and fabricated tests;
   no native change. Inputs are explicit bounded files plus expected SHA pins:
   complete stdout, prompt/teacher, completed parent receipt, numerical receipt,
   source/bundle manifests, and any separate hardware/source-correlation receipt.
   Reuse the frozen `audit_short_parity.audit` for numerical replay and the existing
   parent contract for request/artifact/Plan joins. Require a completed parent,
   native exit 0/reaped, no primary/cleanup/postflight failure, matching raw stdout,
   same native PID, and exact already-admitted command/input pins. A failed parent
   or missing second native record cannot be upgraded by numerical success.
2. Validate the **existing** two runtime objects with strict types/key sets and
   equal architecture, OS, PID, device limits and executable/bundle identity;
   compare PID/path identity to the recorded parent command/owned bundle. Join
   `expectedNativeSHA256`, `bundleManifestSHA256`, `sourceManifestSHA256` to the
   separately supplied pinned manifests/correlation receipts. Select executable
   and metallib members using the existing bundle schema, never a guessed filename
   or arbitrary path from a receipt. Distinguish verified retained file bytes from
   parent/source-correlation assertions; matching hashes do not prove a rebuild
   from those sources or prove which metallib was loaded. Never follow origin paths
   embedded in historical receipts or invoke their archived launcher code.
3. Emit a small separately domain-separated evidence binding with policy name
   `qwen_dense_metal_actual_device_query128_bf16_v1`, exact inherited arithmetic
   definition, artifact/config/inventory/Plan/request/native-baseline identities,
   raw stdout/parent/numerical/source/bundle pins, and the existing runtime objects.
   The frozen parent strips `MLX_`, `DARKBLOOM_`, `JACCL_` variables then supplies
   the exact three-value environment; bind that parent source and its recorded
   `arithmeticEnvironment`. Do not treat a user-supplied dictionary as evidence of
   an already initialized native process. NAX availability remains `unknown`.
   Hardware evidence is separately verified or explicitly caller-asserted; raw
   Metal architecture alone does not certify an M3 Ultra model/core configuration.
4. Test a valid synthetic join plus changed runtime PID/architecture/OS/bundle,
   altered environment, failed parent, stale stdout/audit, missing metallib member,
   resealed wrong source/native pin, and incoherent baseline-to-pair evidence.
   Assert unknown NAX and no provider/performance qualification throughout. This
   adds cross-runtime/profile substitution rejection, not another Plan serializer,
   legal-cut predicate, numerical tolerance, source validator or execution permit.

The first profile is deliberately **actual-device native dispatch**, not a claim
that all devices execute the same kernels. A strictly non-NAX-only execution
policy can follow only if needed: add a small status-bearing generic diagnostic
delegating to existing `metal::is_nax_available()`, distinguish failure from false,
then require successful false before model work in a new explicit native scope.
Do not infer it from the silent diagnostic fallback or alter the current bundle.

The short baseline’s current source fingerprint binds artifact/config/layout/Plan,
BF16 and request/frames, **not** hardware/backend (`QwenLayerStageRecordedEvidence`,
`QwenDenseShortReferenceAdmission`). Both owners currently reread the same exact
environment in-process. A new binding belongs in an audit receipt over the original
bytes; it may classify their evidenced settings but cannot relabel the original
native arithmetic or upgrade qualification. For later distributed
work, the existing long agreement already compares `arithmeticEnvironmentSHA256`;
retain that equality and keep per-rank hardware/runtime provenance separately bound.

No resource gate is bypassed: use the existing full/pair live policies with
actual-free `max(6 GiB, R + 2H + Q + 4 GiB)`, zero swap, and allocator
`active + cache + R + H + Q + 2 GiB`; reclaimable stays diagnostic. The pair retains
both lazy inert allowances. Short 3/2/teacher1 (capacity5) qualification does not
admit 8K. The long reference/resource admissions still explicitly select the
registered 9B geometry, so a later 27B 8K extension must reuse its exact profile and
fresh 27B state/storage ledger without merely changing a model label.

Production portable support is a later, explicit qualification/registry change:
introduce a versioned execution-profile eligibility dimension bound to the **same
artifact**, backend/runtime and hardware evidence; preserve the current M5/NAX
requirements for the existing profile. Do not manufacture `apple_m5`/`mlx_nax`,
rename the model to dodge exact-ID rules, or infer eligibility from metadata export.
This source increment can make experimental evidence reusable; actual M3 Ultra
parity, continuation, memory behavior, RDMA and target TPS still require their own
measurements under the goal’s acceptance criteria.
