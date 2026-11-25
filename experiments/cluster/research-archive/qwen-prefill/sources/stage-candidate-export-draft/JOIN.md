# Attach observed services to native candidates

`QwenLayerStageCandidates.enumerate(configuration:canonicalSourceNames:activeMTP:)`
already delegates to actual Plan/Metadata validation and parameter/state ownership.
Its results are metadata-admissible candidates, not execution eligibility. Before
this proposal no generic public export existed: `adapter-check` and the public
candidate runner print fixture results; the registered constructor probe emits
one default Plan plus lazy constructor/source metadata, hashes checkpoint bytes,
and is not a Foundation-only candidate export. The proposed tool fills only that
export gap.

Use a model-agnostic Python function such as
`attach_services(catalog_bytes, qualified_measurement_group)` that consumes native
catalog records rather than layer counts. It returns exact matches, unmeasured
candidates, or mismatches. It must not call a Python cut enumerator, regenerate
construction configurations, or implement Foundation fingerprint serialization.
Other model families can supply their own native exporter under an adapter/version
identifier and the same outer source/measurement association contract.

| Join | Exact fields and responsibility |
| --- | --- |
| Catalog provenance | Exact catalog bytes/hash and reviewed exporter/dependency source pins; config raw hash, raw names hash, sorted-name hash, native Plan/stage/config identities. Caller-provided names remain unverified until joined to qualified source metadata. |
| Native candidate | Catalog `planFingerprint` equals agreement `planFingerprint` and load receipt `planSHA256`; each ordered stage fingerprint/config hash equals the matching producer/consumer agreement fields and local `stagePlanSHA256`/`constructionConfigurationSHA256`. |
| Actual source | Bind the load receipt's `verifiedAggregateSHA256`, `sourceConfigurationSHA256`, `sourceTensorManifestSHA256`, `sourceParameterLayoutSHA256`, conversion policy and actual activation dtype. Plan identity alone contains no artifact or name inventory. |
| Actual ownership | Exported `(sourceName, stageIndex, localName)` tuples equal the complete union of observed active-tensor mappings for the two stages, with no duplicates. Retain exact active/layout/storage receipts and their independent qualification; catalog name coverage does not prove shapes, dtypes, triplets, buffer ownership or values. |
| Exact observation | Within one run, bind both reports, scalar actions and optional phase sidecars through epoch, rank, full recorded request/profile identities, agreement, source records and raw stdout/sidecar hashes. Sidecars alone do not identify a Plan or physical device. |
| Reusable service | Bind chunk index/offset/count/final flag, logical prompt/history pin, request geometry, arithmetic, runtime/source revision, physical device, residency/observer settings and measurement-boundary version. Retain the originating request UUID/fingerprint as provenance. |

Within-run recorded request fingerprints include fresh request identity. Reuse
across trials must therefore compare stable logical workload fields (including
the existing native prompt token hash and geometry) while preserving each run's
UUID/epoch, not discard identity or pretend the observation came from a new run.
The agreement already exports both native stage/config hashes, profile/request
fingerprints, raw arithmetic receipt pin and native boundary geometry. The load
receipt supplies actual mapping and source/layout/storage identities. Keep opaque
hashes opaque and compare existing records; no new Plan serializer is needed.

The current `runtime/stage_checks/long_stage_cut.py` is a qualified-selection
descriptor for one public long cut/policy. It is neither the candidate enumerator
nor a reason to hardcode registered 9B cut positions into the measurement adapter.
Native `QwenLongPrefillStageCut` separately delegates its registered geometry to
the native structural helper. The generic metadata catalog and mode/profile
eligibility must remain separate.

An immediate adapter can attach the existing observed Plan/stage pair using its
complete native report identities, leaving other native candidates unmeasured.
After the pure exporter is compiled, use its catalog for complete candidate
coverage. Moving a cut creates new stage identities: do not fill their costs from
layer averages or copy one measured chunk to other context lengths. Selected-owner
chunk-seven timing is supplementary and does not supply an all-layer cost model.
Unknown physical devices, memory, staging and link service stay unknown. Nothing
in this export/join authorizes loading, forward execution or a performance claim.
