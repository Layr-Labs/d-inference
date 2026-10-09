# Release A Provider Version

> Last updated: 2026-10-09

Build, qualify, sign and publish an explicitly approved provider artifact. Registration uses the existing external coordinator API; no backend build or deployment runs here. Source ownership changes do not authorize infrastructure or hosting changes.

## Prepare and check release caches

1. After merging release inputs, let **SDK 27 release preparation** complete on
   `master`, or dispatch `.github/workflows/provider-release-cache.yml` on
   `master`. It runs optimized compilation and SDK qualification on separate
   `blacksmith-12vcpu-macos-27` runners, with no signing secrets or publication steps. This seeds
   caches in the default branch's scope, which release tags can restore. PR
   validation caches stay isolated to their PR and do not seed `master`.
   Pipeline shutdown changes run these lanes on their PR as well; the
   [shutdown drain regression](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/test.md#sdk-27-release-qualification)
   must pass before retrying a release that failed that assertion.
2. Inspect each lane's **SDK 27 build cache** summary. It reports exact hits and
   the actual Swift restore key; a compatible prefix restore is useful even when
    the exact-hit output is false. Swift caches are toolchain-specific;
   the Metal helper separately validates source and compiler identity. A compiler,
   SDK, dependency, checkout-path or build-recipe change requires a cold rebuild.
   Metal setup must reach a working compiler probe: an asset download may finish
   before the tool is registered. The bounded setup helper retries discovery and
   uses Apple's component export/import fallback before failing the job.
3. Run the authorized release from the reviewed fixed source. Its optimized and
   qualification jobs run concurrently. Only their successful completion permits
   the environment-protected signing job to download and validate the unsigned
   artifact from that same run. Signing, package smoke, notarization, final hashes,
   upload and coordinator registration remain mandatory.
4. Compare observed lane durations and cache restore/save time in Actions. The
   first cache warm is a cold build, and runner concurrency limits can serialize
   jobs. Cache warming reduces subsequent compilation; it does not make tests,
   notarization or runner scheduling instantaneous. No fixed release duration is
   guaranteed by this workflow change.

GitHub caches are immutable and scoped to their branch or tag; one tag cannot
restore another tag's cache. The previous release cache therefore could exist
while a new tag still rebuilt everything. See [GitHub's cache access rules](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows#restrictions-for-accessing-a-cache).
The new build cache writes after successful compilation even if later test
assertions fail, preserving reusable objects for a retry while publication stays
blocked. A failed compilation does not certify source timestamps for reuse.

Rerunning a failed workflow uses its original source. To include a merged fix,
start the release from that fixed commit using the existing version/tag policy;
do not assume **Re-run failed jobs** picks up changes from `master`. This procedure
never moves an existing tag or retries publication automatically.

Implementation: `.github/actions/provider-release-build/action.yml`,
`scripts/provider-release-cache.py`, `.github/workflows/release-swift.yml` and
`scripts/provider-signing-validation.py` (`stage`, `unpack`). See the
[build cache contract](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/build.md#sdk-27-release-builds-and-caches) and
[SDK qualification checks](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/test.md#sdk-27-release-qualification).

## Resume signing from a retained unsigned build

Use this when build and SDK qualification succeeded but signing failed because
of workflow tooling or runner setup. Keep the release tag on the original
candidate. After the corrected workflow is merged into current `master`, run:

```bash
gh workflow run release-swift.yml --ref master \
  -f environment=prod -f resume_run_id=36750197236 -f resume_run_attempt=1
```

The example identifies the failed 0.9.13 candidate at `ee46e5f34`. Substitute the
explicit source run and successful build attempt for another recovery.
`scripts/provider-release-resume.py` validates repository, workflow, push/tag
origin, current signed tag, source signature/version, both successful jobs, and
one unexpired immutable unsigned artifact. It refuses a source run that already
retained a signed publication artifact. The resolver and download step both
check identity; download verifies the GitHub artifact ZIP digest before the
existing archive, file inventory, source/version and entitlement checks.

The recovery skips compilation and SDK qualification and resumes at the normal
protected signing job. Code signing, notarization, final signed-bundle smoke,
independent App Attest qualification, R2 staging and publication remain required.
`release-provenance.json` distinguishes original build source/run from the
current signing workflow source/run. The tag is rechecked before registration.
The unsigned artifact expires after three days; missing/expired bytes require a
new build. Changed candidate source also requires a new build and reviewed tag.

For a failure after a signed artifact was retained, retry only the failed
staging/publication jobs from that signing run. That existing retry path
preserves signed bytes and does not need unsigned recovery or re-signing.

## Environment-free signing validation

[`provider-signing-validation.yml`](../../.github/workflows/provider-signing-validation.yml)
is a separate manual workflow for a reviewed full `source_sha` and its existing
`version`. It has no GitHub `environment` field or environment selector and no
coordinator registration, R2 upload, GitHub Release, tag or deployment step.
Its token has only `contents: read` and `actions: read`.

The build job has no signing secrets. It checks the source's verified commit
signature and version parity, builds the exact provider and metallib, then stages
an unsigned app with the existing SwiftPM resource helper. A new runner downloads
that same run's artifact, verifies its inventory/source/version, rejects unsafe
archive paths and links, and checks the candidate entitlements against the
reviewed workflow tooling (`scripts/provider-signing-validation.py`).

Unpacking limits the compressed archive and total declared member bytes to
2 GiB, each member to 512 MiB, and the archive to 16,384 members. Normalized
duplicate paths, including case aliases, are refused. The app's bundle ID,
executable name and both version fields must match the expected source before
signing and when the final receipt is written.

The signing job uses repository-scoped `APPLE_CERTIFICATE_P12`,
`APPLE_CERTIFICATE_PASSWORD`, `PROVISIONING_PROFILE_BASE64`, `APPLE_ID` and
`APPLE_APP_PASSWORD`. It imports an isolated temporary keychain, validates the
profile's team, keychain group, production APNs grant, expiry and declared
application identity (`scripts/provider-signing-validation.py`, `profile`). Both
`com.apple.application-identifier` and `application-identifier` are checked when
present: each must name the exact provider team/app or a wildcard that covers
it. Profiles may omit those declarations; conflicting, malformed or unrelated
declarations fail validation. The job signs the normal app components, then
checks the signed CLI's keychain group, APNs entitlement and disabled debug-task
entitlement. It checks Apple notarization and a stapled ticket, and emits
post-sign file hashes. Keychain material is removed even on failure. Only explicit Actions
artifacts and non-secret notarization diagnostics are retained for three days.

The normal APNs entitlement retains its required `production` value; this is a
static signing entitlement, not a GitHub environment or a provider registration.
The workflow never executes the candidate CLI, helper, model or inference server.
Signed runtime smoke, installation, model correctness and release approval remain
separate gates. The original release workflow's `validation_only` option still
selects a deployment environment and is not this isolated path.

Review and make the new manual workflow available before authorizing a dispatch.
Source preparation and the CPU helper tests do not claim a completed signing run:

```bash
python3 scripts/test-provider-signing-validation.py
```

## When to use

- Shipping a provider release to the fleet (production coordinator
  `api.darkbloom.dev`).
- Publishing a dev build to the dev coordinator for testing
  (`workflow_dispatch` with `environment=dev`).
- Building a signed, notarized validation bundle for isolated tests
  (`environment=dev`, `validation_only=true`).

Coordinator deploys are a separate runbook:
[coordinator-deploy.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/coordinator-deploy.md).

## Prerequisites

- Write access to the repo; the release branch is `master` and CI is green.
- Rights to approve deployments to the `prod` GitHub environment (the `release`
  job binds `environment: ${{ needs.resolve-env.outputs.environment }}`, so a
  production tag waits on the environment's protection rules). **A production
  release is a production mutation; get the approval from a second human.**
- Repository secrets (repo-level, prefixed per environment; the workflow's
  "Resolve env-specific secrets" step picks `DEV_*` or `PROD_*` and falls back
  to the unprefixed legacy names):

  | Secret | Used for |
  |---|---|
  | `DEV_R2_ACCESS_KEY_ID` / `PROD_R2_ACCESS_KEY_ID`, `DEV_R2_SECRET_ACCESS_KEY` / `PROD_R2_SECRET_ACCESS_KEY`, `DEV_R2_ENDPOINT` / `PROD_R2_ENDPOINT`, `DEV_R2_BUCKET` / `PROD_R2_BUCKET` | `aws s3 cp` upload of the bundle to R2 |
  | `DEV_R2_PUBLIC_URL` / `PROD_R2_PUBLIC_URL` | Public CDN base used in the registered `url`; must equal the coordinator's `EIGENINFERENCE_R2_CDN_URL` |
  | `DEV_COORDINATOR_URL` / `PROD_COORDINATOR_URL` | Target of `POST /v1/releases` |
  | `DEV_RELEASE_KEY` / `PROD_RELEASE_KEY` | Bearer token for `POST /v1/releases`; must equal the coordinator's `EIGENINFERENCE_RELEASE_KEY` |
  | legacy fallbacks `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_PUBLIC_URL`, `COORDINATOR_URL`, `RELEASE_KEY`, variable `R2_BUCKET` | used only when the prefixed secret is empty |
  | `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD` | Developer ID Application certificate (`Eigen Labs, Inc. (SLDQ2GJ6TL)`) imported into a temporary keychain |
  | `PROVISIONING_PROFILE_BASE64` | Embedded in `Darkbloom.app`; must grant `aps-environment=production` |
  | `APPLE_ID`, `APPLE_APP_PASSWORD` | `xcrun notarytool submit … --team-id SLDQ2GJ6TL` |

- The coordinator that will receive the registration has
  `EIGENINFERENCE_RELEASE_KEY` and `EIGENINFERENCE_R2_CDN_URL` set
  ([coordinator/api/server_config.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/server_config.go)); without the CDN URL registration fails
  with `503 not_configured`.

## Steps

### 1. Check source and artifact version

Update `ProviderCore.version` in `provider-swift/Sources/ProviderCore/ProviderCore.swift`
only for an authorized release. The tag, source version and built binary must
agree. Coordinate the platform's independently pinned version/installer snapshot
in a reviewed platform change; do not restore a local backend source dependency.

```bash
./scripts/check-release-version.sh
```

Preserve exact signed artifact identity, App Attest qualification and post-signing
hashes. A stale platform snapshot or missing release row is not fixed by silently
bumping provider source. Public golden vectors do not execute private platform
code; cross-implementation and actual signed/native qualification remain separate.

### 2. Write the changelog entry

`CHANGELOG.md` is hand-written, newest first. Convention (from the existing
headings): while in development the top section is
`## Unreleased (YYYY-MM-DD) — <theme>`; at release time rename it to
`## vX.Y.Z (shipped; YYYY-MM-DD)` (or `## Release candidate vX.Y.Z (not
shipped; YYYY-MM-DD)` for a candidate that was tagged but not promoted).
Bullets start with a bold lead-in (`- **Per-request profiler** — …`) and name
exact identifiers (tables, env vars, message fields). Nothing in the pipeline
reads `CHANGELOG.md`; the release row's `changelog` field comes from the **tag
message** (step 4), so write the tag message from this entry.

### 3. Merge to `master` and wait for CI

Open the authorized release PR with the version and changelog changes. Require
the retained release-integrity, provider, SDK, public-golden and documentation
checks. Coordinate private platform qualification separately, at explicit source
and artifact revisions. Do not claim public fixed vectors alone prove parity.
Keep signing, release registration and production activation independently approved.

### 4. Tag and push (production)

```bash
git checkout master && git pull --ff-only
git tag -a v0.9.10 -m "v0.9.10 — <one-line theme>

<body: the changelog bullets for this release>"
git push origin v0.9.10
```

Accepted tag pattern (`on.push.tags`): `v*.*.*`.
Tags containing `-dev.` are rejected by `resolve-env` ("`-dev` tags are
unsupported by the exact-version release contract"); use step 5 for dev.
The version is the tag with `v` stripped and must equal the source constants,
so a retired `vX.Y.Z-swift` alias fails resolution. `scripts/resolve-provider-release.sh` checks
this before writing job outputs or requesting environment approval.

### 5. Dev release (manual dispatch)

```bash
gh workflow run release-swift.yml --ref <branch> -f environment=dev
# optional: -f version_override=0.9.10
```

Without a tag the version is read from `ProviderCore.swift` (or
`version_override`, which must still match the source). `environment=prod`
without a tag is refused ("Production publication requires a source-matching
release tag"). Dev releases use `DEV_*` secrets, register with the dev
coordinator, and create no GitHub Release.

Dev and production builds carry the same version string. A Mac reaches the dev
release only through the dev installer
(`curl -fsSL https://api.dev.darkbloom.xyz/install.sh | bash`), which writes
the dev `[coordinator] url` into `provider.toml`
(`scripts/install.sh`, `bind_provider_coordinator`); updates then come from the
dev coordinator. See [dev-environment.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/dev-environment.md), step 9.

### Signed validation bundle

To test a source revision before release registration, dispatch the same signing,
notarization and final-bundle smoke pipeline in validation mode:

```bash
gh workflow run release-swift.yml --ref <branch> -f environment=dev -f validation_only=true
gh run download <run-id> --name darkbloom-signed-validation-<commit>-<attempt> --dir <new-directory>
```

The branch and recursive submodule commits must be available to CI. Source version
checks and the dev environment's approval rules still apply. This mode needs the
Apple signing/profile/notarization secrets; it skips publication-secret resolution,
R2 uploads, release registration and GitHub Release creation. The default remains
`validation_only=false` for ordinary releases.

The Actions artifact contains the final signed tarball and
`darkbloom-validation-identity.json`, with source/submodule revisions and final
bundle, executable and metallib hashes plus the full SHA-256 CodeDirectory digest and build SDK version.
The release build, SDK qualification, signing and signing-validation jobs use
Blacksmith's pinned `blacksmith-12vcpu-macos-27` image (currently public beta)
with Xcode 27. The selector resolves the image's default Xcode after checkout,
requires SDK 27.0 / Apple Swift 6.4, and scopes native SwiftPM through the existing
wrapper. Python 3.12.10 and the checksum-verified CMake bootstrap are explicit;
the older-OS validation job pins `blacksmith-12vcpu-macos-26` so it cannot drift
to macOS 27. Blacksmith hosts the protected signing jobs and receives their
existing signing credentials after environment approval. Publication remains a
separate protected Linux job. See the [runner and cache contract](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/build.md#sdk-27-release-builds-and-caches).
The workflow obtains Xcode's matching Metal compiler through
`xcodebuild -downloadComponent MetalToolchain` when the image omits it, and
checks availability before computing the source-matched metallib cache key.
`scripts/prepare-provider-release-toolchain.sh` scopes
`scripts/provider-release-swift.sh` to provider builds/tests while Xcode remains
the Metal/signing toolchain. The release SDK runs the provider unit suite and
isolated allocator gates. `SDKROOT` covers compilation/linking, and a final
executable whose recorded SDK differs from the selected SDK fails qualification.
The CodeDirectory digest is also printed in production release notes and supplies
the measurement side of an explicitly qualified App Attest binary/code-hash pair.
Recording it does not authorize the build. In validation-only mode, a second
job downloads that exact artifact to the older macOS runner, verifies its
source/archive hashes and notarization, and requires all four runtime smoke
markers. It asserts that the host is below macOS 27 so the compatibility lane
cannot silently become another current-OS run. Retention is 14 days. Verify those hashes
before an isolated model or persistent-cache restart test, and retain the artifact
with that test's evidence. A successful artifact build does not establish restart
durability or authorize rollout.

### 6. Approve signing, qualify the exact artifact, then publish

After `build-provider` and `qualify-sdk` both succeed, approve the pending
`prod` (or `dev`) deployment for **Sign, notarize and retain exact artifact**
(`build-and-release`, `blacksmith-12vcpu-macos-27`). Compilation and SDK tests have already run
in the parallel jobs; the signing job consumes their source-bound artifact.
The relevant signing steps run in this order:

| # | Step | What it does |
|---|---|---|
| 1 | Checkout · Validate release version integrity · Select SDK 27 signing toolchain · Ensure matching Metal compiler is available | Verify the source version and exact SDK before signing |
| 2 | Fetch and verify this run's unsigned build | Download the build job's same-run artifact and validate source SHA, version and SDK |
| 3 | Import Developer ID certificate · Embed provisioning profile | Prepare the temporary keychain and validate profile-authorized entitlements |
| 4 | Stage and sign bundle | Build and sign the app with hardened runtime, preserve SwiftPM resources, and copy its `darkbloom`, `darkbloom-enclave` and `mlx.metallib` to regular files under `bin/`. Release hashes are computed from those copies: the coordinator's artifact check reads `bin/darkbloom`, and `install.sh` and self-update verify `bin/darkbloom` and `bin/mlx.metallib` before installing the app. They also keep older updaters working. Current installers never install them as a flat layout |
| 5 | Notarize bundle | Notarize, staple, rebuild and extract the final archive, run runtime smoke, then calculate final binary/bundle/metallib and full CodeDirectory SHA-256 values |
| 6 | Prepare signed release qualification evidence | `scripts/provider-release-publication.py prepare` retains the registration payload, annotated-tag changelog and independent operator qualification template |
| 7 | Retain exact signed publication artifact | Retain the final bundle and metadata in `provider-publication-<SOURCE_SHA>-<SIGNING_ATTEMPT>` for 30 days |
| 8 | Cleanup keychain | Always remove the temporary signing keychain |

After signing succeeds, the independent **Stage retained signed artifact in R2**
job (`stage-release`, Linux) resolves its R2 credentials, downloads the exact
`needs.build-and-release.outputs.publication_artifact` from the same run,
verifies its identity/digest, and uploads only the immutable bundle-digest
path. It does not compile, sign, notarize, register a release, or update latest
aliases. The signing job has no R2 upload credentials or AWS CLI step.
A transient R2/artifact-download failure belongs to this downstream job:
**Re-run failed jobs** reuses the retained bytes and original metadata even
when the workflow attempt number changes. Publication explicitly depends on
successful staging.

After R2 staging succeeds, review/test these final signed bytes for production, fill in the template's
actual qualification evidence, and submit it through the admin approval route
as described in [build qualification](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/app-attest-build-qualification.md#steps).
Use a verified Privy admin session from `scripts/admin.sh login` or the admin
key; the publication key and admin-owned inference/provider credentials cannot
approve builds. A 200 approval response confirms durable/local readiness but
does not publish the artifact.

Approve the environment-protected **Publish qualified signed release** job
(`publish-release`, Linux). Its steps are separate from signing:

| # | Step / helper phase | What it does |
|---|---|---|
| 1 | Checkout · Resolve env-specific secrets | Load the source-matching publication helper and scoped release/R2 credentials |
| 2 | Download this run's exact signed publication artifact · Install publication tools | Retrieve the retained signed bytes without compiling or notarizing again |
| 3 | Register release with coordinator and publish aliases: registration | Revalidate source/run/version/origin/bundle digest, then `POST /v1/releases`; the coordinator verifies the artifact and atomically checks the exact independent approval |
| 4 | Readiness | Wait boundedly for `/v1/releases/latest` to report the committed qualified build, or a newer release; do not treat an older cached response as completed publication |
| 5 | R2 aliases | Only for the current latest build, update both `releases/latest/darkbloom-bundle-macos-arm64.tar.gz` and its legacy `eigeninference-bundle` alias |
| 6 | GitHub publication | Prod/tag only: create or resume a draft, upload a missing bundle (repair only an incomplete `starter` placeholder), verify the downloaded asset's exact hash, then publish. An already published exact asset is verified without replacement |

If qualification is absent, the publication job stops with 409 before advancing
the registered/latest release or aliases. Approve the retained artifact and
**Re-run failed jobs**. Never rerun successful signing to retry publication:
a new signature changes the artifact identity. A partial GitHub failure also
resumes from its existing draft/asset state. Completed mismatched assets and
incomplete already-published releases require operator investigation; retries
never overwrite them. Code: `scripts/provider_release_github.py`
(`publish_github_release`). GitHub documents the incomplete `starter` state in its
[release-asset API reference](https://docs.github.com/en/rest/releases/assets).

The retained production registration payload (`registerReleaseRequest` in
[coordinator/api/releases/release_handlers.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/releases/release_handlers.go); unknown fields are rejected) contains:

```json
{
  "version": "0.9.10",
  "platform": "macos-arm64",
  "backend": "mlx-swift",
  "binary_hash": "<final binary SHA-256>",
  "bundle_hash": "<final archive SHA-256>",
  "metallib_hash": "<final metallib SHA-256>",
  "code_directory_hash": "<full CodeDirectory SHA-256>",
  "source_commit": "<40-character source commit>",
  "ci_run_id": "<original build workflow run ID>",
  "require_app_attest_qualification": true,
  "url": "<R2_PUBLIC_URL>/releases/v0.9.10/artifacts/<BUNDLE_SHA256>/darkbloom-bundle-macos-arm64.tar.gz",
  "changelog": "<tag annotation, or Release v0.9.10 when no tag notes exist>"
}
```

Use the downloaded payload instead of reconstructing signed-artifact hashes
by hand. `HandleRegisterRelease` authenticates the scoped release key,
validates semver/platform/digests and the exact configured R2 origin/path,
then downloads and verifies the final archive and provider binary (2 GiB cap,
two-minute timeout). New publication uses the bundle-digest path; the original
version-only path remains accepted for compatibility/importing existing builds.
`persistReleaseForPublication` refreshes qualification and calls
`SetQualifiedRelease`, which checks approval under the revocation row lock
before writing the active release. Missing, mismatched or revoked approval is
409; unreadable policy is 503. Production workflow requests always require
qualification; enabled production App Attest serving also enforces it on the
server even when a caller omits the flag.

After the commit, `SyncBinaryHashes` and `SyncRuntimeManifest` converge the live
policy and invalidate release/version HTTP caches. Response:
`{"status":"release_registered","release":{…}}`. Cached `/api/version` and
`/v1/releases/latest` responses also check current qualification and catalog
readiness while production App Attest serving is enabled.

Runtime policy retains the union of every active release's hashes, preserving
older qualified releases during adoption. Hashes leave that catalog on release
deactivation ([Rollback](#rollback)); see
[runtime manifest](../architecture/security/attestation.md#runtime-manifest).

## Verification

```bash
COORD=https://api.darkbloom.dev
curl -fsS "$COORD/v1/releases/latest?platform=macos-arm64" | jq .   # version, hashes, url, changelog
curl -fsS "$COORD/api/version" | jq .                                # same row (falls back to LatestProviderVersion when no release exists)
curl -fsS "$COORD/v1/admin/releases" -H "Authorization: Bearer $ADMIN_KEY" | jq '.releases[] | {version, active, created_at}'
```

- `GET /v1/releases/latest` returns the **highest active semver** for the
  platform (`GetLatestRelease` in [coordinator/store/postgres/](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/store/postgres), ordered by
  `releaseVersionGreater` in [coordinator/store/](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/store)), not the
  most recently registered row.
- Install on a clean Mac: `curl -fsSL $COORD/install.sh | bash`;
  `scripts/install.sh` reads `/v1/releases/latest` and verifies the bundle
  hash before installing. `darkbloom --version` must print the new version.
- Connected providers pick the release up through the background auto-update
  monitor (`provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift`:
  initial delay 5 m, interval 30 m, disabled by `auto_update=false` or
  `DARKBLOOM_NO_UPDATE_CHECK`), which reads
  `/v1/releases/latest?platform=macos-arm64`
  (`provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift`). Watch the
  Datadog gauge `providers.per_version` (tag `version:<x.y.z>`, emitted from
  [coordinator/api/server.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/server.go) via `registry.ProviderCountByVersion`) converge
  over the next hour.
- If the release-policy gate is enforced, confirm evidence for the new binary
  hash is accepted: see
  [release-policy-rollout.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/release-policy-rollout.md)
  ("Verification").
- Coordinator log line: `release registered` with `version` and a truncated
  `binary_hash`.

## Rollback

A registered release is immutable (hash-pinned); rollback means **deactivating
it** so the previous active version becomes "latest" again.

1. Deactivate the bad release (admin key or Privy admin):

   ```bash
   curl -fsS -X DELETE "$COORD/v1/admin/releases" \
     -H "Authorization: Bearer $ADMIN_KEY" -H "Content-Type: application/json" \
     -d '{"version":"0.9.10","platform":"macos-arm64"}'
   ```

   `HandleAdminDeleteRelease` answers `409 release_in_use` while connected
   providers still run that `binary_hash` (in-use protection is active when
   binary-hash enforcement is on **or** a release inventory has ever been
   published). Add `"force":true` only when the release must be pulled
   immediately (e.g. compromised); providers on it lose routing until they
   downgrade.
2. `GET /v1/releases/latest` now serves the highest remaining active version;
   `/api/version` follows within its 1-minute cache TTL.
3. Repoint the convenience objects in R2, which the workflow overwrote:

   Confirm the prior qualified release returned by `GET /v1/releases/latest`
   after deactivation, then copy its exact version and `bundle_hash` into the
   variables below. For the planned 0.9.10 rollout, the expected prior version
   is 0.9.9; stop if the live record differs. Do not use an old version-only
   object path or assume the previous hash.

   ```bash
   : "${PREVIOUS_VERSION:?verified active release version}"
   : "${PREVIOUS_BUNDLE_SHA256:?verified bundle_hash of that release}"
   [[ "$PREVIOUS_VERSION" == "0.9.9" ]] || { echo "unexpected prior release" >&2; exit 2; }
   [[ "$PREVIOUS_BUNDLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || exit 2
   PREVIOUS_OBJECT="s3://$R2_BUCKET/releases/v${PREVIOUS_VERSION}/artifacts/${PREVIOUS_BUNDLE_SHA256}/darkbloom-bundle-macos-arm64.tar.gz"
   aws s3 cp "$PREVIOUS_OBJECT" \
     "s3://$R2_BUCKET/releases/latest/darkbloom-bundle-macos-arm64.tar.gz" --endpoint-url "$R2_ENDPOINT"
   aws s3 cp "$PREVIOUS_OBJECT" \
     "s3://$R2_BUCKET/releases/latest/eigeninference-bundle-macos-arm64.tar.gz" --endpoint-url "$R2_ENDPOINT"
   ```

   (`install.sh` uses the versioned URL from `/v1/releases/latest`; the
   `latest/` objects are for legacy clients.)
4. Mark the GitHub Release as a pre-release or delete it
   (`gh release delete v0.9.10`), and record the outcome in `CHANGELOG.md` as
   `## Release candidate vX.Y.Z (not shipped; …)`.
5. Do **not** re-register the same version with a different artifact. Fix
   forward with a new patch version.

## Related

- [`../developer/build.md`](../developer/build.md) — building the same artifacts locally.
- [`../developer/test.md`](../developer/test.md) — the CI gates a release depends on.
- [coordinator-deploy.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/coordinator-deploy.md) — shipping the coordinator half of a version bump.
- [release-policy-rollout.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/release-policy-rollout.md) — how registered releases feed the routing gate.
- [../reference/api-contracts.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/api-contracts.md) — `/v1/releases/latest`, `/api/version` shapes.
