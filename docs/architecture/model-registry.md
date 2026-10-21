# Provider Model Registry Boundary

> Last updated: 2026-10-15

Providers discover model identity through external registry manifests, then
download and verify model bytes locally. The database and catalog API are owned
by the platform, not by this repository.

## Mechanism

`provider-swift/Sources/ProviderCoreFoundation/ManifestBuilder.swift` constructs
publication manifests. `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`
downloads published artifacts and verifies them. Discovery is not full weight
hashing: retain fast startup scans and on-demand verification. Broken templates
must be reported rather than silently repaired.

Media discovery uses `ModelMediaPolicy.advertisesMedia` in
`provider-swift/Sources/ProviderCoreFoundation/ModelMediaPolicy.swift`.
Staged `nemotron_h_omni` checkpoints do not advertise media support, even when
`vision_config` is present. The architecture match ignores surrounding whitespace
and case and applies independently of Hugging Face repository IDs or local aliases.
This guard does not enable text inference, qualify a RAM tier, or register the model.

Published metadata is not a loadability or quality certificate. Keep full LOAD
quotations, native transient allowances, memory safeguards and post-load
serviceability checks. Do not replace registry discovery with a hardcoded model
catalog. Exact supported layouts and parameters belong in the [manifest reference](../reference/model-registry-format.md).

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

## Related

- [Hardware and memory](hardware-support.md)
- [Model revisions](model-revisions.md)
- [Provider tests](../developer/test.md)
