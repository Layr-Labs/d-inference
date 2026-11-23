# Provider Model Registry Boundary

> Last updated: 2026-11-23

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

### Ranged downloads

Per-connection throughput to the model CDN varies by network, from about 1 to
20 MB/s, so one connection per multi-GB shard leaves a slow network idle. Each
source of a manifest file (Hugging Face first where the build has an artifact,
then R2) goes through `ModelDownloader.fetchManifestFile`
(`provider-swift/Sources/ProviderCore/Models/ModelDownloader+Segments.swift`):

| Step | What happens | Code |
|---|---|---|
| Choose | Ranges only when `segmentsPerFile` (`DARKBLOOM_DOWNLOAD_SEGMENTS`, [configuration](../reference/configuration.md#operator-facing-daemon-paths-updates)) is above 1 and the file is at least `ModelDownloadSegments.minimumFileBytes` (`256 << 20`) | `fetchManifestFile` |
| Probe | A GET of `bytes=0-0`, redirects followed; only a 206 whose `Content-Range` total is the manifest size continues. A 200, a 416 or another total takes the single-stream `downloadFile`, unchanged | `servesRanges` |
| Plan | Equal byte ranges of a `.part` sized to the manifest size with `truncate` (sparse until written), recorded in `<file>.part.segments`. A single-stream `.part` prefix is credited to the ranges it covers | `SegmentedPartFile.prepare`, `SegmentedPartLayout.planned` |
| Fetch | The unfinished ranges, at most `segmentsPerFile` at once (a record saved with more ranges queues the rest), each over its own `URLSession` (the same configuration), so the ranges are separate connections rather than HTTP/2 streams of one. A 206 must name exactly the requested bytes and size before a byte is written at its offset | `downloadInSegments`, `fetchRange`, `RangeSegmentDownloadDelegate` |
| Retry | An attempt that wrote bytes is retried at once from where it stopped; a range fails after `attempts` attempts in a row that wrote none (Hugging Face 1, R2 `ModelDownloader.defaultAttempts`), which fails the file. A 200, a 416 or a 206 for other bytes (`RangesRefused`) is not retried: the file continues from the same source over one connection, from the `.part`'s gap-free prefix | `fetchRange`, `fetchManifestFile` |
| Verify | The whole file's SHA-256, read uncached under `uncachedWrites`. A mismatch deletes the `.part` and its record; the file is fetched again over one connection with the source's attempts that are left (R2: 2 more, 3 in all as before; Hugging Face: none, so it goes to R2 as before). The record is removed before the `.part` is promoted | `downloadInSegments`, `fetchManifestFile` |

A foreground download keeps fetching `concurrency` (4) files at once and
divides the ranges so that they open at most
`ModelDownloadSegments.maximumConnections` (16) connections together
(`ModelDownloadSegments.perFile`). Background prefetch, Autopilot placements
and automatic revisions still fetch one file at a time, so their ranges are
as many connections as the foreground's files without ranges.

Invariants:

1. The record never counts a byte that is not on disk: `SegmentedPartWriter`
   writes with `pwrite` at the range's next offset, syncs the `.part` with
   `fsync`, then saves the record atomically, every
   `SegmentedPartWriter.checkpointBytes` (`32 << 20`) and when the transfer
   stops for any reason, a cancellation included.
2. Bytes the record cannot account for are never kept: a record that does not
   decode, describes another size, or counts bytes beyond the `.part`'s length
   is unusable, and `prepare` deletes the `.part` with it
   (`SegmentedPartLayout.isConsistent`).
3. The single-stream path sees only prefixes: before it runs (one connection,
   a source without ranges, a refused range or a digest mismatch),
   `SegmentedPartFile.collapseToPrefix` truncates a ranged `.part` to its
   gap-free prefix and removes the record.
4. Resume credit and free-disk checks count the record's bytes, never the
   pre-sized length (`ModelDownloader.resumableBytes`, used by the foreground
   progress, both capacity checks and `selectedDownloadPlan`).
5. Progress (`onChunk`) is the sum of every range's bytes, reported under one
   lock, so it only grows during a transfer. When a ranged `.part` collapses
   to its prefix for the single stream, the file's progress steps back once,
   to that prefix.
6. The Hugging Face to R2 fallback removes the `.part` and its record
   (`SegmentedPartFile.remove`), so no Hugging Face byte reaches an R2 file.
7. `uncachedWrites` opens the `.part` with `F_NOCACHE`, which applies to every
   `pwrite` on that descriptor (`SegmentedPartWriter.cachingDisabled`).

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
only), the ordinary template render check, `native_media_tools` and
`native_media_controls` (`ToolChoiceEnforcementPolicy`, with image input and a
template that renders: its media route serves forced tool choice, tool-result
media, JSON output and tools), and its managed LOAD footprint
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
