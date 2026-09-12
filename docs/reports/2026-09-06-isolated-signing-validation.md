# Isolated signing validation — intact app accepted

> Last updated: 2026-09-06 · commit `f9423f94`

Frozen signing-infrastructure report for release reviewers. Run `34043318652`
proves Developer ID signing and notarization of the intact old-source app; it
does **not** establish Qwen56fa runtime acceptance or authorize production rollout.

## Exact scope and outcome

| Item | Frozen value |
|---|---|
| Candidate source | `f91fe843b0cb22e2d1b2a85c0652982f3a8ff146` |
| Source version | `0.8.16` |
| Workflow and reusable callee | `f9423f94ef41ced998009f4d503919e038c35175` |
| Entry point | `ci.yml`, `release/signing-validation-enable`, manual dispatch |
| Successful run / attempt | `34043318652` / `1`, completed `2026-09-06T15:55:25Z` |
| Build / signer jobs | `101513853907` / `101514973062`, both successful; eight ordinary CI jobs skipped |
| Selected identity | `Developer ID Application: Eigen Labs, Inc. (SLDQ2GJ6TL)` |
| Public leaf SHA1 | `95B67556E04653F56BA5411D20D33DD263EF6E2A` |
| Notarization | `69ff101b-3260-469a-b457-79e360637dbf`, `Accepted` |

The [run summary](evidence/signing-validation-2026-09-06/run-summary.json) and
[static verification](evidence/signing-validation-2026-09-06/artifact-verification.json)
record matching source/version, five submodule identities, reviewed entitlements,
and exact 15-file unsigned / 22-file signed inventories. The independently
downloaded unsigned manifest equals the manifest embedded in the signed artifact.

All five code objects—the app, CLI, enclave, fan helper and in-app metallib—pass
strict local verification with an Apple generic anchor, Developer ID Application
leaf OID `1.2.840.113635.100.6.1.13`, exact team `SLDQ2GJ6TL`, and the selected
leaf fingerprint. App/helper identifiers also pass. Local stapler validation and
Gatekeeper report `accepted`, `source=Notarized Developer ID`; these are static
checks, not application execution. The
[cleanup receipt](evidence/signing-validation-2026-09-06/keychain-cleanup.json)
confirms restoration of the original search list, temporary-keychain deletion,
and no errors. The unsigned CLI is only ad-hoc/linker-signed, without a team.

## Original failure and bounded fix

Run `34030878981`, workflow `8cc56074ae7a6dd6553fe3cd3692af1ba58ed9a2`, built the
same source/version but failed its first signing command at
`2026-09-06T11:47:53.2858760Z`:
`Developer ID Application: Eigen Labs, Inc. (SLDQ2GJ6TL): no identity found`.
Cleanup succeeded; notarization did not run and no signed artifact was produced.
The [failure receipt](evidence/signing-validation-2026-09-06/prior-failure.json)
does not prove a company-name change or a particular certificate-chain defect.

The reviewed fix activates/restores the temporary keychain search list, requires
one valid isolated Developer ID Application identity for the exact team, and
signs by fingerprint. The successful result proves this path worked for these
inputs; it does not promote any newer runtime source.

## Artifact handling limitation

The metallib's signature uses extended attributes. Preserve the intact app and
restore its archived AppleDouble/PAX metadata with explicit macOS extraction:

```bash
mkdir "$NEW_EMPTY_OUTPUT"
/usr/bin/tar --no-same-owner --no-same-permissions --mac-metadata --xattrs \
  -xzf "$SIGNED_VALIDATION_TAR" -C "$NEW_EMPTY_OUTPUT"
```

Python `tarfile` and default non-root macOS extraction lost this metadata during
the review; explicit restoration passes without re-signing or changing artifact
bytes. Separately, flat `bin/mlx.metallib` reports `code object is not signed at
all` even though its bytes match the in-app resource. **The flat `bin/` export is
not equivalent to the verified notarized app.** Any future flat-export use needs
separate packaging review, not an inferred approval from this run.

## Frozen evidence and exclusions

The [manifest](evidence/signing-validation-2026-09-06/manifest.json) hashes the
minimal JSON metadata and redacted verification excerpts; its own hash is in
[manifest.sha256](evidence/signing-validation-2026-09-06/manifest.sha256).
[Provenance](evidence/signing-validation-2026-09-06/provenance.json) records source
receipt hashes and transformations. No apps, binaries, archives, keys,
certificates, profiles, device identifiers, credentials or complete CI logs are
banked. The retained UUID is an Apple notarization submission ID, not a device ID.

[Git inclusion audit](evidence/signing-validation-2026-09-06/git-inclusion.json)
covers every evidence file, this report and its index. Excerpts use `.txt`:
`.log` and `.out` are ignored by Git and would need an explicit reviewed
`git add -f` later. Every retained file is tracked or normally stage-ready; this
banking task stages nothing and makes no commit, push or PR change.

No host contact, application/model execution, installation, release registration,
deployment, secret mutation or production change occurs while banking this
record. The M5 Q38 B2 pilot remains main-owned and untouched. Qwen56fa, runtime
correctness, installer/flat-export acceptance and production rollout remain
outside this proof. For current release procedures see the
[provider release runbook](../operations/provider-release.md).
