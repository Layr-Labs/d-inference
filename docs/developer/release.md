# Release a provider version

> Last updated: 2026-09-03 · commit `5d400cf75`

Runbook for shipping a new `darkbloom` provider CLI: bump the two version
constants, land the changelog, push a `vX.Y.Z` tag, approve the `prod`
environment, and let [`.github/workflows/release-swift.yml`](../../.github/workflows/release-swift.yml)
build, sign, notarize, hash, upload, and register the bundle. The coordinator
verifies every registered artifact by re-downloading it, so a release either
lands fully or not at all.

## When to use

- Shipping a provider release to the fleet (production coordinator
  `api.darkbloom.dev`).
- Publishing a dev build to the dev coordinator for testing
  (`workflow_dispatch` with `environment=dev`).

Coordinator deploys are a separate runbook:
[`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md).

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
  (`coordinator/api/server_config.go`); without the CDN URL registration fails
  with `503 not_configured`.

## Steps

### 1. Bump the version in both places

The provider and coordinator versions must be identical strings:

- `provider-swift/Sources/ProviderCore/ProviderCore.swift` — `public static let version = "0.8.16"`
- `coordinator/api/server.go` — `var LatestProviderVersion = "0.8.16"`

```bash
./scripts/check-release-version.sh          # provider == coordinator, semver
./scripts/sync-install-embed.sh check       # coordinator/api/install.sh == scripts/install.sh
```

`check-release-version.sh` accepts an optional expected version
(`check-release-version.sh v0.8.17`) and an optional reported string from a
built binary (`darkbloom 0.8.17` or `0.8.17`); the workflow calls it in all
three forms. CI job "Release Integrity" runs the two commands above on every
push. Do not touch `minProviderVersionForDesiredModels` (`"0.5.17"`, same file)
for a routine release; it is the floor for desired-model fan-out, not the
current version.

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

Open a PR with the bump + changelog; "Release Integrity", "Provider Tests",
"Coordinator Tests", and "E2E Integration Tests" must be green. The release
workflow re-runs `scripts/verify-prompt-parity.sh` itself, so a prompt-contract
change that is not fixture-synced will fail the release, not just CI.

### 4. Tag and push (production)

```bash
git checkout master && git pull --ff-only
git tag -a v0.8.17 -m "v0.8.17 — <one-line theme>

<body: the changelog bullets for this release>"
git push origin v0.8.17
```

Accepted tag patterns (`on.push.tags`): `v*.*.*`, `v*-swift`, `v*-swift.*`.
Tags containing `-dev.` are rejected by `resolve-env` ("`-dev` tags are
unsupported by the exact-version release contract"); use step 5 for dev.
The version is derived from the tag (`v` stripped, `-swift*` suffix stripped)
and must equal the source constants, or `resolve-env` fails **before** the
environment approval is requested ("Fail before approval on version drift").

### 5. Dev release (manual dispatch)

```bash
gh workflow run release-swift.yml --ref <branch> -f environment=dev
# optional: -f version_override=0.8.17
```

Without a tag the version is read from `ProviderCore.swift` (or
`version_override`, which must still match the source). `environment=prod`
without a tag is refused ("Production publication requires a source-matching
release tag"). Dev releases use `DEV_*` secrets, register with the dev
coordinator, and create no GitHub Release.

### 6. Approve the environment deployment

In the Actions run, approve the pending `prod` (or `dev`) deployment. The
`release` job then runs on `macos` with these steps, in order (step names as
shown in the run):

| # | Step | What it does |
|---|---|---|
| 1 | Checkout (with submodules) | `fetch-depth: 0` so `gh release --generate-notes` has history |
| 2 | Validate release version integrity | `scripts/check-release-version.sh "$VERSION"` |
| 3 | Import Developer ID certificate | temp keychain from `APPLE_CERTIFICATE_P12` |
| 4 | Install awscli (R2) · Restore SwiftPM cache · Discard metallibs restored by the generic SwiftPM cache | tooling and cache hygiene — a cached metallib is never trusted |
| 5 | Verify production prompt parity | `scripts/verify-prompt-parity.sh` |
| 6 | Build source-matched mlx.metallib through root helper | `scripts/fetch-metallib.sh "$RUNNER_TEMP/metallib"` with `MLX_METALLIB_DEPLOYMENT_TARGET=26.2`; cached by MLX source SHA + helper SHA |
| 7 | Build provider-swift (release) | `swift build -c release --product darkbloom`, `darkbloom-enclave`, `darkbloom-fan-helper`; the built binary's `--version` is checked with `check-release-version.sh "$VERSION" "$REPORTED"` |
| 8 | Embed provisioning profile | decodes `PROVISIONING_PROFILE_BASE64`; fails unless the profile grants `aps-environment=production` and has no `get-task-allow` |
| 9 | Stage and sign bundle | stages `Darkbloom.app` (CLI, enclave, fan helper, `mlx.metallib`, every SwiftPM resource bundle via `scripts/stage-swiftpm-resource-bundles.sh`) plus a flat `bin/` layout; `codesign --options runtime --timestamp` on the metallib first, then each binary, then the bundle; `codesign --verify --deep --strict`; tars to `darkbloom-bundle-macos-arm64.tar.gz` |
| 10 | Notarize bundle | `xcrun notarytool submit --wait --timeout 15m`; on failure prints `notarytool log`; then `xcrun stapler staple` + `stapler validate`, re-verifies codesign, **rebuilds the tar**, and asserts the file list contains `./bin/darkbloom`, `./bin/darkbloom-enclave`, `./bin/mlx.metallib`, every resource bundle and `pagedattention.metal`. A smoke extract runs the CLI and re-checks the version |
| 11 | Hashes | computed **after** signing, notarizing, stapling and the tar rebuild: `BINARY_HASH = sha256(bin/darkbloom)` from the extracted tar, `BUNDLE_HASH = sha256(tar.gz)`, `METALLIB_HASH = sha256(flat mlx.metallib)` |
| 12 | Upload bundle to R2 | `s3://$R2_BUCKET/releases/v$VERSION/darkbloom-bundle-macos-arm64.tar.gz`, plus `releases/latest/darkbloom-bundle-macos-arm64.tar.gz` and the legacy `releases/latest/eigeninference-bundle-macos-arm64.tar.gz` |
| 13 | Register release with coordinator | `POST $COORDINATOR_URL/v1/releases` (below) |
| 14 | Create GitHub Release | prod + tag only: `gh release create <tag> <tar.gz> --notes-file … --generate-notes`; notes list the three hashes, signer, "Notarized: yes", `Min macOS: 14.0`, and the `curl -fsSL <coordinator>/install.sh \| bash` install line |
| 15 | Cleanup keychain | always |

The registration payload (`coordinator/api/release_handlers.go`,
`registerReleaseRequest`; unknown fields are rejected):

```json
{
  "version": "0.8.17",
  "platform": "macos-arm64",
  "backend": "mlx-swift",
  "binary_hash": "<sha256 of bin/darkbloom>",
  "bundle_hash": "<sha256 of the tar.gz>",
  "metallib_hash": "<sha256 of mlx.metallib>",
  "url": "<R2_PUBLIC_URL>/releases/v0.8.17/darkbloom-bundle-macos-arm64.tar.gz",
  "changelog": "<tag subject + body, or 'Release v0.8.17'>"
}
```

`handleRegisterRelease` requires `Authorization: Bearer <RELEASE_KEY>`,
validates semver/platform/hex, requires `metallib_hash` when `backend` is
`mlx-swift`, requires `url` to equal exactly
`<EIGENINFERENCE_R2_CDN_URL>/releases/v<version>/darkbloom-bundle-macos-arm64.tar.gz`
(`trustedReleaseArtifactURL`), then **downloads the bundle** (2 GiB cap,
2-minute timeout), checks `bundle_hash`, extracts `bin/darkbloom` and checks
`binary_hash` (`verifyReleaseArtifact`). Only then does it `SetRelease`,
resync the binary-hash policy (`SyncBinaryHashes`, `SyncRuntimeManifest`), and
invalidate the cached `/v1/version` and `/v1/releases/latest` responses.
Response: `{"status":"release_registered","release":{…}}`.

## Verification

```bash
COORD=https://api.darkbloom.dev
curl -fsS "$COORD/v1/releases/latest?platform=macos-arm64" | jq .   # version, hashes, url, changelog
curl -fsS "$COORD/v1/version" | jq .                                # same row (falls back to LatestProviderVersion when no release exists)
curl -fsS "$COORD/v1/admin/releases" -H "Authorization: Bearer $ADMIN_KEY" | jq '.releases[] | {version, active, created_at}'
```

- `GET /v1/releases/latest` returns the **highest active semver** for the
  platform (`coordinator/store/postgres.go`, `GetLatestRelease` →
  `releaseVersionGreater`), not the most recently registered row.
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
  `coordinator/api/server.go` via `registry.ProviderCountByVersion`) converge
  over the next hour.
- If the release-policy gate is enforced, confirm evidence for the new binary
  hash is accepted: see
  [`../operations/release-policy-rollout.md`](../operations/release-policy-rollout.md)
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
     -d '{"version":"0.8.17","platform":"macos-arm64"}'
   ```

   `handleAdminDeleteRelease` answers `409 release_in_use` while connected
   providers still run that `binary_hash` (in-use protection is active when
   binary-hash enforcement is on **or** a release inventory has ever been
   published). Add `"force":true` only when the release must be pulled
   immediately (e.g. compromised); providers on it lose routing until they
   downgrade.
2. `GET /v1/releases/latest` now serves the highest remaining active version;
   `/v1/version` follows within its 1-minute cache TTL.
3. Repoint the convenience objects in R2, which the workflow overwrote:

   ```bash
   aws s3 cp "s3://$R2_BUCKET/releases/v0.8.16/darkbloom-bundle-macos-arm64.tar.gz" \
     "s3://$R2_BUCKET/releases/latest/darkbloom-bundle-macos-arm64.tar.gz" --endpoint-url "$R2_ENDPOINT"
   aws s3 cp "s3://$R2_BUCKET/releases/v0.8.16/darkbloom-bundle-macos-arm64.tar.gz" \
     "s3://$R2_BUCKET/releases/latest/eigeninference-bundle-macos-arm64.tar.gz" --endpoint-url "$R2_ENDPOINT"
   ```

   (`install.sh` uses the versioned URL from `/v1/releases/latest`; the
   `latest/` objects are for legacy clients.)
4. Mark the GitHub Release as a pre-release or delete it
   (`gh release delete v0.8.17`), and record the outcome in `CHANGELOG.md` as
   `## Release candidate vX.Y.Z (not shipped; …)`.
5. Do **not** re-register the same version with a different artifact. Fix
   forward with a new patch version.

## Related

- [build.md](build.md) — building the same artifacts locally.
- [test.md](test.md) — the CI gates a release depends on.
- [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md) — shipping the coordinator half of a version bump.
- [`../operations/release-policy-rollout.md`](../operations/release-policy-rollout.md) — how registered releases feed the routing gate.
- [`../reference/api-contracts.md`](../reference/api-contracts.md) — `/v1/releases/latest`, `/v1/version` shapes.
