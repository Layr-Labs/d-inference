# Provider Model Registry Boundary

> Last updated: 2026-10-14

Providers discover model identity through external registry manifests, then
download and verify model bytes locally. The database and catalog API are owned
by the platform, not by this repository.

## Mechanism

`provider-swift/Sources/ProviderCoreFoundation/ManifestBuilder.swift` constructs
publication manifests. `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`
downloads published artifacts and verifies them. Discovery is not full weight
hashing: retain fast startup scans and on-demand verification. Broken templates
must be reported rather than silently repaired.

Published metadata is not a loadability or quality certificate. Keep full LOAD
quotations, native transient allowances, memory safeguards and post-load
serviceability checks. Do not replace registry discovery with a hardcoded model
catalog. Exact supported layouts and parameters belong in the [manifest reference](../reference/model-registry-format.md).

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
model registration/revision APIs. Hash and upload complete immutable artifacts,
publish the manifest last, then verify the registered identity. Publication,
alias promotion and rollback require specific approval. See [model publication](../operations/model-migration.md)
and [revisions](../operations/model-revisions.md).

Backend validation, database ownership and alias routing are documented in
[platform model registry](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/model-registry.md).
No local backend build or deployment is part of this procedure.

## Related

- [Hardware and memory](hardware-support.md)
- [Model revisions](model-revisions.md)
- [Provider tests](../developer/test.md)
