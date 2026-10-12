# Register and publish an official provider build

> Last updated: 2026-10-12

Use this runbook for automatic registration of the exact signed provider build
and recovery of a failed publication. The coordinator implementation belongs in
`Layr-Labs/darkbloom-platform`; its [authorization reference](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#durable-build-qualification)
owns the durable identity and runtime verification contract.

## When to use

Every official provider publication, including retries using retained signed
artifacts. Per-release hardware qualification and manual build approval are not
release prerequisites. Optional hardware smoke tests can reveal problems that
CI and notarization cannot, but do not gate publication.

## Prerequisites

- Explicit release authorization and reviewed source. Production requires a
  verified signed annotated version tag whose commit is in reviewed `master`
  ancestry; dev, manual and unsigned-build recovery runs use trusted `master`.
- Deploy the platform's updated `POST /v1/releases` persistence semantics before
  using this provider workflow. No new endpoint, signing key, configuration flag
  or hardware service is needed. All serving/rollback coordinators must preserve
  durable official-build identity and revocation.
- Existing repository-scoped signing, notarization, R2 and scoped release
  credentials. Release jobs do not attach GitHub `prod` or `dev` environments;
  the shared environments and their security settings are not changed.

## Steps

1. Follow [provider release](provider-release.md) to run CI tests, build, sign and
   notarize the reviewed source. Retain the final bundle, registration payload,
   changelog and original source/signing-run provenance. Hashes describe the
   final signed bytes, not the unsigned build.
2. Let the staging job upload those bytes to the immutable bundle-digest R2 path.
   Staging does not advance latest aliases or create a public GitHub release.
3. Let publication submit the retained payload through the existing scoped
   `POST /v1/releases`. The platform verifies the staged artifact and records the
   complete native build identity in the existing durable
   `AppAttestBuildQualification` registry before publishing through the existing
   revocation row-lock fence. Partial identity, conflicting identity or a revoked
   binary fails closed. Existing records retain their identity and audit data.
4. Wait for registered-release readiness, then publish R2 latest aliases and the
   GitHub release. On staging/publication failure, rerun only the failed jobs.
   Reuse the exact signed artifact and original producing run/attempt; do not
   rebuild or re-sign it. Completed mismatched GitHub assets are not overwritten.

## Verification

Confirm `/v1/releases/latest` reports the expected version, artifact URL and
hashes. Registration makes the build official; it does not grant a provider
permission to serve. Runtime authorization still requires real Apple proof and
Apple receipt verification, a match to the official full CodeDirectory hash and
runtime hashes, current connection/security evidence and no durable revocation.

CI is now the authority for official build identity. Tests, signing and
notarization are not proof that runtime Apple APIs work on a deployed Mac. The
pipeline trusts repository writers and existing repository secrets; YAML
tag/source checks are not protection against a hostile writer who can change
workflows or use those secrets. The coordinator trusts source/run provenance
from the authenticated pipeline rather than independently verifying GitHub.

## Rollback

Use the [release rollback procedure](provider-release.md#rollback) to deactivate
a release. A separate administrator may permanently revoke an unsafe binary via
`POST /v1/admin/app-attest/builds/revoke`; retrying registration cannot undo that
tombstone. Recover with another reviewed signed build, not a relaxed runtime
gate or a deleted revocation row.

The existing admin build-approval API remains a compatibility/recovery tool,
not a normal release step. It does not replace live Apple verification.

## Related

- [Provider release pipeline](provider-release.md)
- [Platform official-build operations](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/operations/app-attest-build-qualification.md)
