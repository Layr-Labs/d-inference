# Provider Model Registry Boundary

> Last updated: 2026-10-30

Providers discover model identity through external registry manifests, then
download and verify model bytes locally. The database and catalog API are owned
by the platform, not by this repository.

## Mechanism

`provider-swift/Sources/ProviderCoreFoundation/ManifestBuilder.swift` constructs
publication manifests. `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`
downloads published artifacts and verifies them. Discovery is not full weight
hashing: retain fast startup scans and on-demand verification. Broken templates
must be reported rather than silently repaired.

Foreground downloads (`darkbloom models download` and the `darkbloom start`
picker) show one progress line for the whole model, never a line per file:
`ManifestDownloadProgress` sums each file's bytes on disk and
`DownloadProgressRenderer` draws the sum
(`provider-swift/Sources/ProviderCore/Models/ModelDownloadProgress.swift`).
The line's text, rate and pacing are pure functions of the bytes, the time
and the width (`TransferProgressLine` in
`provider-swift/Sources/ProviderCore/Models/TransferProgressLine.swift`). Its
layout depends on the width alone (`TransferProgressLine.layout(width:)`): each
figure's column is sized for that figure's widest form in this download, so
redraws at one width never move the bar or a figure, and the renderer keeps the
layout until the width changes. The rate leaves out bytes a resumed download
already had on disk; the rate and the time left wait for
`TransferProgressLine.estimateDelay`, and a time left over
`TransferProgressLine.maximumTimeLeft` is not shown. On a terminal the line is
redrawn in place with a carriage return and an erase to its end, one column
short of the window so it never wraps; elsewhere it is printed rarely and
plainly. The renderer also prints each download's one last line: the
completion, the model already being on disk, where the transfer stopped or the
failed check, so its callers print no completion line of their own. The
[CLI reference](../provider/cli-reference.md#darkbloom-models-download-id)
gives what is printed and when. A caller that shows progress itself sets
`ModelDownloader.byteProgress`, and then nothing is drawn: `darkbloom cluster`
shows the line on its own live row (`ClusterTransferReports`).

`StreamingFileDownloadDelegate` in
`provider-swift/Sources/ProviderCore/Models/StreamingFileDownloadDelegate.swift`
retains the first terminal result until its awaiting continuation is attached.
Cancelling a suspended `URLSession` task can deliver completion before
`ModelDownloader.streamDownload` attaches that continuation. Either ordering
resumes the waiter once; cancellation closes the writer and leaves received
bytes in the resumable `.part` file. `ModelDownloader.downloadFile` propagates
`CancellationError` without retrying, allowing download tasks and their artifact
writer lease to unwind.

Media discovery uses `ModelMediaPolicy.advertisesMedia` in
`provider-swift/Sources/ProviderCoreFoundation/ModelMediaPolicy.swift`.
`nemotron_h_omni` checkpoints do not advertise media support, even when
`vision_config` is present. The architecture match ignores surrounding whitespace
and case and applies independently of Hugging Face repository IDs or local aliases.

### Nemotron Super discovery

`EngineV2SupportedModels.isSupported(model:)` admits exactly one
`nemotron_h_omni` artifact: the registry id `nvidia-nemotron-3.5-super` with the
canonical declaration (`NemotronSuperServingPolicy.isServingIdentity`). The type
alone stays unsupported, so providers without this policy, other ids (including
the upstream Hugging Face id) and whitespace or case variants keep being dropped
at scan, advertisement and prefetch publication. `ModelScanner.parseModelInfo`
withholds that id unless `config.json` and `model.safetensors.index.json` are the
pinned bytes (`NemotronSuperServingPolicy.hasPinnedMetadata`); the managed load
verifies every shard. A discovered Super artifact reports `quantization`
`nvfp4`, image input (`ModelMediaPolicy.advertisesMedia`, for that exact id
only), the ordinary template render check, and its managed LOAD footprint
(`NemotronSuperServingPolicy.discoveryFootprint`): `estimated_memory_gb` is the
same on every Mac, what the narrowest configuration the managed load serves
requires (`NemotronSuperLoadFit.narrowestRequirementBytes`: the installation
and head claim, the 1,024-token prefill lane, one speculating request's
admission KV at the whole context and the 3 GiB admission slack), never below
the shard bytes plus `native_load_transient_bytes`, the LOAD bytes above the
shard bytes. It holds no media: capacity quotes for its image and video
probes charge the probe's whole media reservation
(`CapacityQuoteEngine.nemotronSuperMediaCharge`). Registration identity and RAM floor are in the
[registry reference](../reference/model-registry-format.md#nemotron-super).
Discovery does not register or publish the model.

Published metadata is not a loadability or quality certificate. Keep full LOAD
quotations, native transient allowances, memory safeguards and post-load
serviceability checks. Do not replace registry discovery with a hardcoded model
catalog. Exact supported layouts and parameters belong in the [manifest reference](../reference/model-registry-format.md).

The [raw GLM discovery quotation](../reference/model-registry-format.md#raw-glm-discovery-quotation)
uses bounded headers and non-weight file sizes, not a successful-download
receipt. A malformed GLM inventory has no generic loadable discovery fallback;
only the tokenizer shipped in the snapshot is supported. These checks do not
replace catalog/source identity or native pre-allocation validation.

### Uncached reads and writes

`ModelDownloader.uncachedWrites` (default off; single-Mac downloads are
unchanged) writes shards with the file cache off and computes the per-file and
aggregate SHA-256 from uncached reads. The two-Mac cluster's catalog download
sets it, so provisioning a model does not leave tens of GB in the Mac's file
cache before a memory-gated load. `WeightHasher` reads weights for the
provider's start-time hash with `F_NOCACHE` too (same digest; it falls back to
the earlier readers when the uncached read fails). The cluster store clones an
installed model with the catalog's exact published `manifest.json` bytes,
because the cluster worker pins those bytes; see
[two Macs as one provider](../provider/two-mac-cluster.md#models).

## Publication

The local manifest builder and publication scripts may call approved external
model registration/revision APIs. Upload and registry publication are separate
operations: a valid canonical manifest and its existing files can be registered
without uploading again or obtaining R2 write credentials. When bytes or the
serving inventory change, hash and upload a new complete immutable revision,
publish its manifest last, then verify the registered identity.

The default `.github/workflows/register-model.yml` mode sends model metadata
and prices to the registration endpoint. Its `publish_revision_only=true` mode
requires explicit `promote=true` because that action always promotes, and
sends only the version and optional pinned HF source to the existing model's
`publish-revision` action, preserving metadata and prices while promoting the
revision. Both modes need only the coordinator publishing key; upload tooling
separately needs model-bucket access. The exact request contracts and input rules
are in the [registry reference](../reference/model-registry-format.md#publish-tooling).
Publication, alias promotion and rollback require specific approval. See [model publication](../operations/model-migration.md)
and [revisions](../operations/model-revisions.md).

Backend validation, database ownership and alias routing are documented in
[platform model registry](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/model-registry.md).
No local backend build or deployment is part of this procedure.

## Flint shard-only local discovery

Recursive's official Flint export has numbered safetensors shards without an
index. `ModelScanner.isMLXModel` admits that layout only when a bounded,
regular-file config identifies the exact `flint` architecture. The config must
be nonempty and at most 1,048,576 bytes; a nonblocking descriptor and regular-file
check keep special files out of this discovery path. Discovery does
not verify tensor completeness: the native model loader and on-demand weight
hasher retain those responsibilities. This exception does not add a catalog
entry or accept arbitrary shard-only families.
The native loader accepts the [Flint package contract](../reference/model-registry-format.md#flint-local-package-exception)
without rewriting the artifact or synthesizing an index. HF/R2 publication and
catalog activation remain separate operations after end-to-end qualification.
Source: `provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift`.

## Related

- [Hardware and memory](hardware-support.md)
- [Model revisions](model-revisions.md)
- [Provider tests](../developer/test.md)
