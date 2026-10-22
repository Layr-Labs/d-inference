# Release A Provider Version

> Last updated: 2026-10-22

Build, sign, notarize and publish an explicitly authorized provider artifact.
The pipeline registers its exact official identity through the external platform
API; no backend build or deployment runs here. Source ownership changes do not
authorize releases, infrastructure or hosting changes.

## When To Use

Use `.github/workflows/release-swift.yml` for a production version tag, a dev
publication, or a signed validation bundle. Build, SDK qualification, signing,
R2 staging and publication are separate jobs. Staging/publication failures retry
the retained artifact rather than rebuilding or re-signing it.

A push to `master` that changes the provider or its release tooling publishes a
dev release automatically, and a staging release too once the `STAGING_ENABLED`
repository variable is set (DBLM-771: staging tracks main). A `vX.Y.Z` tag
publishes production. `.github/workflows/release-swift.yml` is the
thin caller that routes each trigger to one or more environment lanes; the
reusable `.github/workflows/release-provider.yml` runs the resolve, build,
qualification, signing, R2 staging and publication chain for one environment. To
find the newest dev release, read `https://api.dev.darkbloom.dev/v1/releases/latest`.

`ProviderCore.version` is prepared as `0.10.0`. The candidate moves request
normalization to v9 for every model, adds native Flint, Nemotron 3.5 Super and
GLM-5.3-Flash serving, and updates the MLX pins, so its metallib changes. See
the [`v0.10.0` changelog entry](../../CHANGELOG.md) for the full scope and its
qualification limits.

Tag `v0.10.0` only after production runs a `darkbloom-platform` coordinator
that normalizes requests with v9, enforces the Nemotron 3.5 Super
provider-version floor at `0.10.0`, gates GLM-5.3-Flash on the `glm5_next_v1`
capability and serves a provider-contract snapshot pinned to the merged
preparation commit. A v8 coordinator accepts the `0.10.0` registration and
serves its providers, but without cache scopes and without the new models'
gates. Then tag promptly: until providers update, a v9 coordinator serves
0.9.22 providers without cache scopes. The platform owns the coordinator
deployment and its cache-routing allowlist; model registration and promotion
are separate approvals. This preparation does not tag, register, upload or
deploy anything.

Platform evidence, inspected on 2026-10-22 (recheck current `master` before
tagging):

| Claim | Source |
|---|---|
| Platform `master` normalizes with v9 | [`identity/contract.go` at `45f6728f`](https://github.com/Layr-Labs/darkbloom-platform/blob/45f6728fa734bf9145660107664404d730ea5e47/coordinator/internal/promptcontract/identity/contract.go) (`NormalizationVersion`) |
| Production `74e9f989` normalizes with v8 | [`identity/contract.go` at `74e9f989`](https://github.com/Layr-Labs/darkbloom-platform/blob/74e9f9893d02f9d2ba67a501f8838665e1c25cba/coordinator/internal/promptcontract/identity/contract.go) (`NormalizationVersion`) |
| A cache plan applies only to a matching prompt contract | [`registry/cache_tiers.go` at `45f6728f`](https://github.com/Layr-Labs/darkbloom-platform/blob/45f6728fa734bf9145660107664404d730ea5e47/coordinator/registry/cache_tiers.go) (`CapabilityMatchesPlan`) |
| Super has a per-identity provider-version floor | [`registry/catalog_version_floor.go` at `45f6728f`](https://github.com/Layr-Labs/darkbloom-platform/blob/45f6728fa734bf9145660107664404d730ea5e47/coordinator/registry/catalog_version_floor.go) (`nemotronSuperRegistryMinimumProviderVersion`, unset there; [darkbloom-platform#400](https://github.com/Layr-Labs/darkbloom-platform/pull/400) sets `0.10.0`) |
| GLM-5.3-Flash requires `glm5_next_v1` | [`registry/provider_capabilities.go` at `45f6728f`](https://github.com/Layr-Labs/darkbloom-platform/blob/45f6728fa734bf9145660107664404d730ea5e47/coordinator/registry/provider_capabilities.go) (`ProviderCapabilityGLM5Next`, `embeddedRequiredProviderCapabilities`) |
| Production `74e9f989` has neither gate | Neither symbol exists in [`coordinator/registry` at `74e9f989`](https://github.com/Layr-Labs/darkbloom-platform/tree/74e9f9893d02f9d2ba67a501f8838665e1c25cba/coordinator/registry) |

`v0.9.22` was [published on 2026-10-15](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.22)
from `7925ba4c0f1f82c8d3e4ef04758a77865b5ee510`, `v0.9.21` was
[published on 2026-10-14](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.21)
from `9951a7db72d3db9a9cb0ec5e777969afe968c9b6`, and `v0.9.20` was
[published on 2026-10-12](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.20)
from `5dc5313e5201e8d84db15adc153ceaf56147cc71`. Publication does not establish
that every optional feature or environment has been activated.

## Prerequisites

- Explicit human authorization to release reviewed source. Production requires
  a verified signed annotated version tag in reviewed `master` ancestry; dev,
  manual and unsigned-build recovery runs use trusted `master`.
- Green release-integrity, provider, SDK, public-fixture and documentation gates.
  Private platform compatibility qualification remains separately owned; fixed
  public vectors do not execute the private implementation.
- Platform-owner confirmation that the updated `POST /v1/releases` persistence
  semantics are deployed before publication. All serving/rollback coordinators
  must preserve durable official identity and revocation. Do not perform the
  backend deployment here; use the platform's current source/runbooks.
- Existing repository-scoped signing, notarization, R2 and scoped release
  credentials. Do not modify shared security settings or provision new keys as
  part of this procedure without separate approval.

Release jobs do **not** attach GitHub `prod` or `dev` environments or wait on
environment approvals. This does not remove the requirement for human release
authorization. Resolution executes trusted `master` policy and pins downstream
checkouts to the verified SHA. Production publication rechecks the signed tag,
target and current `master` ancestry immediately before registration; a withdrawn
tag cannot publish after that check.

The pipeline assumes trusted repository writers. YAML checks cannot defend
against a hostile writer who can change workflows or use repository secrets.
CI establishes official artifact identity, not proof that runtime Apple APIs work.
Per-release physical hardware smoke and manual admin build approval are not
publication prerequisites. Runtime Apple proof, receipt verification, official
CodeDirectory/runtime hashes, current security evidence and permanent revocation
remain enforced.

| Secret | Purpose |
|---|---|
| `DEV_R2_ACCESS_KEY_ID` / `PROD_R2_ACCESS_KEY_ID`, `DEV_R2_SECRET_ACCESS_KEY` / `PROD_R2_SECRET_ACCESS_KEY`, `DEV_R2_ENDPOINT` / `PROD_R2_ENDPOINT`, `DEV_R2_BUCKET` / `PROD_R2_BUCKET` | Upload the immutable bundle and latest aliases |
| `DEV_R2_PUBLIC_URL` / `PROD_R2_PUBLIC_URL` | CDN origin; must match the platform's `EIGENINFERENCE_R2_CDN_URL` |
| `DEV_COORDINATOR_URL` / `PROD_COORDINATOR_URL` | Registration target |
| `DEV_RELEASE_KEY` / `PROD_RELEASE_KEY` | Scoped `POST /v1/releases` credential matching `EIGENINFERENCE_RELEASE_KEY` |
| Unprefixed `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_PUBLIC_URL`, `COORDINATOR_URL`, `RELEASE_KEY`; variable `R2_BUCKET` | Legacy fallback only when the prefixed value is empty |
| `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD` | Developer ID Application certificate, Eigen Labs, Inc. (`SLDQ2GJ6TL`), imported into a temporary keychain |
| `PROVISIONING_PROFILE_BASE64` | Embedded profile, including `aps-environment=production` |
| `APPLE_ID`, `APPLE_APP_PASSWORD` | Apple notarization |

The [pinned platform configuration reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/server_config.go)
documents the release key/CDN contract; a missing CDN configuration returns
`503 not_configured`. Pinned platform references below preserve historical
contracts and are not evidence that a live deployment implements the latest
automatic-registration semantics.

## Steps

### 1. Check Source And Artifact Version

Update `ProviderCore.version` in
`provider-swift/Sources/ProviderCore/ProviderCore.swift` only for an authorized
release. The tag, source version and built binary must agree. Coordinate any
platform version/installer snapshot separately; no local backend constant or
installer-embedding check is a provider release input.

```bash
./scripts/check-release-version.sh
```

The script accepts an optional expected tag/version and reported binary string;
both must match the source. Retained-build recovery reads the original provider
source against its signed tag, not a backend display fallback. A missing latest
release row or stale platform snapshot is not fixed by silently bumping the CLI.

### 2. Compile Selected Changelog Fragments

Run `make changelog-check`, then preview selected fragments:

```bash
python3 scripts/changelog.py render --version X.Y.Z --date YYYY-MM-DD NAME.md ...
```

Names are basenames under `changelog.d/`; omitting them selects all pending
notes. Review tag-bound source inclusion, insert the rendered section above the
previous release in `CHANGELOG.md`, and remove only those fragments in the
release-preparation commit. Rendering itself neither edits history nor consumes
notes. Ordinary PRs never regenerate the root history; see
[contribution guidance](../../CONTRIBUTING.md#changelog-entries-with-less-merge-contention).
The pipeline takes its registered `changelog` from the annotated tag message,
not `CHANGELOG.md`; derive that message from the reviewed release entry. Keep
it to a short summary: the release API refuses registration bodies above
64 KiB, and that refusal comes only after signing and notarization.

### 3. Merge And Verify Release Preparation

Open the authorized release PR and require the retained component gates.
After merge, let **SDK 27 release preparation** finish on `master`, or dispatch
`.github/workflows/provider-release-cache.yml` on `master`. It runs optimized
compilation and SDK qualification on separate `blacksmith-12vcpu-macos-27`
runners with no signing/publication secrets. PR caches remain PR-scoped and do
not seed `master`.

Inspect each **SDK 27 build cache** summary and actual restore key. Compatible
prefix hits are useful even when the exact-hit output is false. Compiler, SDK,
dependency, checkout-path, environment or recipe changes require new compatible
products. The Metal compiler must execute successfully; a downloaded but
unregistered component is insufficient. See the
[local cache/toolchain contract](../developer/build.md#sdk-27-release-builds-and-caches)
and [SDK tests](../developer/test.md#sdk-27-release-qualification).

Caches can be saved after successful compilation even when later tests fail;
that does not authorize publication. GitHub caches are immutable and
[branch/tag scoped](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows#restrictions-for-accessing-a-cache).
Measure restore/save and full-job times; quotas can serialize the two lanes.

### 4. Tag And Push Production Source

Only after authorization, tag the reviewed merged source with its matching version:

```bash
git switch master
git pull --ff-only
git tag -s vX.Y.Z -m "vX.Y.Z - <one-line theme>

<reviewed release notes>"
git push origin vX.Y.Z
```

Substitute the actual version; `vX.Y.Z` is not a literal tag to publish. The
workflow accepts `v*.*.*` but rejects `-dev.` tags and retired `-swift` aliases.
`scripts/resolve-provider-release.sh` checks exact provider version parity before
job outputs, and trusted-source verification precedes secret-bearing jobs.
Never move an existing release tag to repair a failed run.

### 5. Select Dev Or Validation Mode When Needed

A push to `master` starts a dev release — and a staging release when the
`STAGING_ENABLED` repository variable is `'true'` — when it changes a path in the
caller's `on.push.paths` list: `provider-swift/**`, `libs/**`, the release
caller, the reusable workflow, the build action, or a script that the release
runs. The trigger, not an input, selects the lanes: the caller's `dev` and
`staging` jobs each call `release-provider.yml` and run in parallel in one GitHub
run (the `staging` job is skipped while `STAGING_ENABLED` is unset). They are different binaries — identity is compile-time, so a master
push runs two full build, sign, notarize and publish lanes. A plain matrix
cannot carry each lane's artifact id and digest across the dependent jobs, which
is why each lane is a separate call of the reusable workflow. Path filters do not
apply to tags, so tags publish production as before. One dev release and one
staging release run at a time (the caller's `release-dev` and `release-staging`
groups); a running release always completes, and when more merges arrive only
the newest waiting run of each lane continues.

To publish a dev release by hand:

```bash
gh workflow run release-swift.yml --ref master -f environment=dev
```

`version_override`, if supplied, must equal the source. Production without a
source-matching tag is refused, except the validated retained-build recovery
path below. Dev uses only `DEV_*` secrets: the `PROD_*` and legacy secret values
are empty in every job unless the resolved environment is `prod`. Dev creates no
GitHub Release and no tag. Dev uploads go only to the `DEV_R2_BUCKET` bucket and
the `DEV_R2_PUBLIC_URL` origin.

The optimized job sets `DARKBLOOM_RELEASE_ENVIRONMENT`. For `dev`,
`provider-swift/Package.swift` compiles `ProviderBuildEnvironment` with
`DARKBLOOM_ENV_DEV`; defaults are `wss://api.dev.darkbloom.dev/ws/provider` and
`https://models.darkbloom.ai`
(`provider-swift/Sources/ProviderBuildEnvironment/BuildEnvironment.swift`). Local
builds, tests and `qualify-sdk` retain production defaults. Config, CLI flags and
`DARKBLOOM_R2_CDN_URL` still override defaults. Dev/prod products have different
cache keys, and packaged smoke must report the selected build environment.

Every dev build has the version `X.Y.Z-dev.N`. `X.Y.Z` is the source
`ProviderCore.version` and `N` is the workflow run number. The release lane
writes this version into `ProviderCore.version` before it compiles, so
`darkbloom --version`, the app `Info.plist`, the registration and the R2 path all
show the `-dev.N` marker. SemVer puts `X.Y.Z-dev.N` below `X.Y.Z` and orders dev
builds by `N`, so a dev provider updates to each newer dev build. Production
versions never have a suffix. A dev `EIGENINFERENCE_MIN_PROVIDER_VERSION` must
use the dev form, for example `0.9.20-dev.0`, because `0.9.20` excludes every
`0.9.20-dev.N` build.

Install a dev provider only with `https://api.dev.darkbloom.dev/install.sh`. A
dev build uses the dev coordinator by default, and this installer binds
`[coordinator] url` in `provider.toml` (`scripts/install.sh`,
`bind_provider_coordinator`), so the provider and its updates use only the dev
coordinator. The
[pinned dev operations reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/dev-environment.md)
is historical; verify current endpoints with the platform owner.

#### Dev Build Identity

A dev build installs and runs beside a production provider on the same Mac.
The two installs do not share a path, a port, a launchd label or a keychain
item, and each command prints its own name in its help text. The table is a
generated copy of `provider-swift/identity/provider-identity.json`, the only
declaration of these values:

<!-- BEGIN provider identity: generated from provider-swift/identity/provider-identity.json by scripts/generate-provider-identity.py; do not edit -->

| Field | Production | Dev | Staging |
|---|---|---|---|
| `coordinatorHTTPURL` | `https://api.darkbloom.dev` | `https://api.dev.darkbloom.dev` | `https://api.staging.darkbloom.dev` |
| `coordinatorWebSocketURL` | `wss://api.darkbloom.dev/ws/provider` | `wss://api.dev.darkbloom.dev/ws/provider` | `wss://api.staging.darkbloom.dev/ws/provider` |
| `modelCDNURL` | `https://models.darkbloom.ai` | `https://models.darkbloom.ai` | `https://models.darkbloom.ai` |
| `cliName` | `darkbloom` | `darkbloom-dev` | `darkbloom-staging` |
| `enclaveName` | `darkbloom-enclave` | `darkbloom-enclave-dev` | `darkbloom-enclave-staging` |
| `appBundleName` | `Darkbloom.app` | `Darkbloom Dev.app` | `Darkbloom Staging.app` |
| `appDisplayName` | `Darkbloom` | `Darkbloom Dev` | `Darkbloom Staging` |
| `installDirectoryName` | `.darkbloom` | `.darkbloom-dev` | `.darkbloom-staging` |
| `configDirectoryName` | `.config/darkbloom` | `.config/darkbloom-dev` | `.config/darkbloom-staging` |
| `legacyConfigDirectoryNames` | `.config/eigeninference` | none | none |
| `launchAgentLabel` | `io.darkbloom.provider` | `io.darkbloom.provider.dev` | `io.darkbloom.provider.staging` |
| `watchdogAgentLabel` | `io.darkbloom.watchdog` | `io.darkbloom.watchdog.dev` | `io.darkbloom.watchdog.staging` |
| `logSubsystem` | `com.darkbloom.provider` | `com.darkbloom.provider.dev` | `com.darkbloom.provider.staging` |
| `serviceLogSubsystem` | `dev.darkbloom.provider` | `dev.darkbloom.provider.dev` | `dev.darkbloom.provider.staging` |
| `defaultLocalPort` | `8000` | `8001` | `8002` |
| `keychainServicePrefix` | `io.darkbloom` | `io.darkbloom.dev` | `io.darkbloom.staging` |
| `encryptedCacheNamespace` | `darkbloom` | `darkbloom-dev` | `darkbloom-staging` |
| `modelRevisionRef` | `main` | `darkbloom-dev` | `darkbloom-staging` |
| `releaseVersionMarker` | versions without it | `-dev.` | `-staging.` |

<!-- END provider identity -->

`scripts/generate-provider-identity.py` generates
`provider-swift/Sources/ProviderBuildEnvironment/Identity.generated.swift` (the
`BuildEnvironment` properties) and this table from the JSON.
`scripts/test-provider-identity.py` fails when a generated file, the Python
release tooling or the installer differs from the JSON. The release lane reads
the packaged names from the JSON through `scripts/provider_release_identity.py`.
It renames the SwiftPM products (`swiftProducts` in the JSON) when it packages a
dev app. The installer
selects the same names from the version that `/v1/releases/latest` returns
(`scripts/install.sh`, `select_provider_identity`). The installer must work as
`curl | bash`, so it keeps its own copy of the names; the test compares that copy
with the JSON.

These values are the same for both builds:

- The bundle identifier and code-signing identifier `io.darkbloom.provider`,
  and the keychain access group `SLDQ2GJ6TL.io.darkbloom.provider`. The
  Developer ID signature, the provisioning profile, notarization and App Attest
  check them. A different dev value does not match the signed bundle.
- The MDM profile identifiers. Each install accepts as its own only the profile
  from its own coordinator host (or its configured coordinator). It names the
  other install's profile and does not claim or remove it.
- The fan helper `io.darkbloom.fan-helper`, one system service for the Mac. It
  keeps one lease for each provider session and returns the fans to Auto only
  when no lease is live. `fan disable` and `fan uninstall` affect both installs
  and say so before they act. This is helper version 2 (`FanIPC.helperVersion`).
  A version 1 helper keeps one lease for the Mac, so the last provider to renew
  owns it. `fan status` and `doctor` report an older helper with the command
  that updates it, and `fan enable` does not replace a newer running helper
  with an older one. A provider built before this change does not have that
  check.
- The flat verifier copies `bin/darkbloom` and `bin/darkbloom-enclave` and the
  bundle file `darkbloom-bundle-macos-arm64.tar.gz`. The coordinator's release
  registration requires these names. Dev uploads go to the dev bucket under the
  `-dev.N` version.

These surfaces are shared, and an operator must know about them:

- Downloaded model weights (the Hugging Face hub cache) are shared on purpose.
  Each install selects its active revision with its own ref (`modelRevisionRef`):
  production uses `refs/main`, and a dev install without its own ref uses
  production's selection. `models remove` deletes the shared weights, so the
  other install loses them too. The encrypted KV cache is not shared
  (`encryptedCacheNamespace`).
- `DARKBLOOM_*` shell overrides. `start` copies the allowlisted variables
  (`LaunchAgent.passthroughEnvKeys`) from the shell that runs it into that
  install's LaunchAgent. Both installs read the same shell exports, so an export
  that is meant for one install also reaches the other the next time it is
  started from that shell.
- APNs (known limitation, pending a test with two installs on one Mac). Both
  installs have the bundle identifier `io.darkbloom.provider`, so they register
  the same push topic and receive the same device token
  (`provider-swift/Sources/darkbloom/ProviderAppKitHost.swift`,
  `provider-swift/Sources/ProviderCore/Apns/APNsBridge.swift`). apsd delivers each push to
  one process. A production code-identity challenge can therefore reach the dev
  process on the legacy path without App Attest. A separate dev bundle
  identifier and provisioning profile are necessary to remove this limitation.
- Unified memory. `doctor` warns when the other install's provider process is
  running, from that install's daemon state file. Model-fit estimates do not
  include the other install's models, so two serving providers can cause jetsam.

An install of an earlier dev build in `~/.darkbloom` does not move to the new
names. Its updater expects `Darkbloom.app`, so it cannot install a
`Darkbloom Dev.app` release. Install the dev provider again with the dev
`install.sh`.

#### Staging Build Identity

`staging` is a third build environment, listed in the identity table above
beside production and dev. It is the staging analog of dev: the same source,
its own install identity (`darkbloom-staging`, port `8002`, keychain prefix
`io.darkbloom.staging`, cache namespace `darkbloom-staging`), and its own
coordinator `wss://api.staging.darkbloom.dev/ws/provider`. It reads the shared
production model CDN like dev. A `X.Y.Z-staging.N` version selects the staging
identity (`scripts/install.sh`, `select_provider_identity`;
`scripts/provider_release_identity.py`). For `staging`,
`provider-swift/Package.swift` compiles `ProviderBuildEnvironment` with
`DARKBLOOM_ENV_STAGING`.

Staging **tracks main**, gated by the `STAGING_ENABLED` repository variable:
when it is `'true'`, a master push publishes a staging release in parallel with
the dev release (DBLM-771), signed with the same Developer ID as dev and prod —
staging is a normal Developer-ID dev-family release, not the self-signed build of
`release-dev-branch.yml`. A `X.Y.Z-staging.N` version carries the workflow run
number, like the dev lane's `X.Y.Z-dev.N`. Publish a staging build by hand with
the same version form (the flag gates the manual lane too):

```bash
gh workflow run release-swift.yml --ref master -f environment=staging
```

A staging run uses only `STAGING_*` secrets (`STAGING_R2_*`,
`STAGING_COORDINATOR_URL`, `STAGING_RELEASE_KEY`). These secrets and the staging
coordinator infra do not exist yet (a separate `darkbloom-devnet-infra` effort,
DBLM-771 infra PR 18). Until they do, leave `STAGING_ENABLED` unset (the default):
the caller's `staging` job is skipped, so a master push builds and publishes dev
only and never burns a second macOS build + notarization that would hard-fail at
staging publication for want of credentials. Turn staging publishing on by
setting the `STAGING_ENABLED` repository variable to `true` once that infra PR is
applied and the `STAGING_*` secrets exist. The dev lane is never gated — it
publishes on every qualifying master push. A push never selects prod:
`scripts/resolve-provider-release.sh` refuses prod on any non-tag trigger, so the
production signing identity stays tag-gated.

For a signed, notarized validation bundle without registration/publication:

```bash
gh workflow run release-swift.yml --ref master -f environment=dev -f validation_only=true
gh run download <run-id> --name darkbloom-signed-validation-<commit>-<attempt> --dir <new-directory>
```

Trusted-source/version checks and Apple credentials still apply. This mode skips
publication-secret resolution, R2 upload, registration and GitHub Release
creation; it does not attach a GitHub environment. The artifact contains the
final tarball and `darkbloom-validation-identity.json`: source/submodule pins,
archive/executable/metallib hashes, full SHA-256 CodeDirectory digest and SDK.
The older-OS job downloads those exact bytes on `blacksmith-12vcpu-macos-26`,
asserts the host is below macOS 27, verifies hashes/notarization and requires
the environment line plus all four runtime-smoke markers. Retention is 14 days.
Verify artifact identity before isolated model/restart tests; build success does
not establish persistence, real Apple functionality or fleet readiness.

#### Experimental Dev-Branch Lane (Dev Only, Self-Signed)

`.github/workflows/release-dev-branch.yml` builds a provider from any branch or
commit and publishes it to the dev coordinator without merging to master. It is
dispatch-only on `master`, so the credentialed publication logic runs the
reviewed master copy of every script; it checks out the chosen `ref` only to
compile and ad-hoc sign (`codesign -s -`), never reading a production secret or
the production Apple signing identity. The branch binary is compiled and signed
in a job that holds no secret, and is never run in a step that holds a
credential. The version is `X.Y.Z-dev.branch.<run>`, which
`scripts/check-release-version.sh` accepts and which stays distinct from the
master dev lane's `X.Y.Z-dev.<run>`.

```bash
gh workflow run release-dev-branch.yml --ref master -f ref=<branch>
```

The installer accepts an ad-hoc signature for pre-release versions: for a
version carrying `-dev.` or `-staging.`, `select_provider_identity` chooses a
relaxed designated requirement that keeps the bundle identifier
`io.darkbloom.provider` pinned but drops the Apple-anchor and team-OU clause
(`scripts/install.sh`, `verify_staged_app_signature`). Production versions keep
the full Apple-team requirement unchanged, and a prod coordinator is never
served a pre-release version. The installer extracts the release archive with
`/usr/bin/tar` under umask 022, so a restrictive caller umask cannot leave the
installed app owner-only; private state it creates elsewhere keeps its own modes
(`scripts/install.sh`, `install_bundle_atomically`). The dev coordinator also hashes the bundle rather
than inspecting the Apple signature, and `MIN_TRUST=self_signed` is a
device-attestation tier, not a code-signature tier.

The installer is a pinned provider-contract snapshot, so the dev coordinator
serves the relaxed installer only after the `darkbloom-platform` served copy is
re-snapshotted from the merged commit in a separate platform PR. Until that
re-snapshot lands, a fresh `darkbloom-dev` install still runs the old installer
and rejects the self-signed build. Because `/v1/releases/latest` orders by
`created_at`, publishing makes the branch build the latest dev release; an
existing install's self-updater may not downgrade to a lower run number, while a
fresh install takes the newest.

### 6. Sign, Stage And Register Exact Bytes

After `build-provider` and `qualify-sdk` succeed, `build-and-release` consumes
the source-bound unsigned artifact on `blacksmith-12vcpu-macos-27`. It does not
wait for an environment approval. Release SDK selection is SDK 27.0 / Apple
Swift 6.4, with `SDKROOT` covering compilation and linking; the final recorded
SDK must match. The checksum-pinned GitHub CLI is installed by
`scripts/install-macos-github-cli.sh` before downloads. Missing `gh` in an old
run is a tooling failure, not a model or notarization failure.

| Order | Operation |
|---|---|
| 1 | Verify source version, selected SDK and same-run unsigned artifact inventory/source/version |
| 2 | Import the temporary Developer ID keychain and validate the embedded profile/entitlements |
| 3 | Sign the canonical app with hardened runtime and preserve SwiftPM resources |
| 4 | Copy `darkbloom`, `darkbloom-enclave` and `mlx.metallib` into regular files under `bin/`; these verification copies support current and older updaters, not flat installation |
| 5 | Notarize, staple, rebuild/extract the final archive, run packaged smoke and compute final binary/archive/metallib and full CodeDirectory SHA-256 hashes |
| 6 | Run `scripts/provider-release-publication.py prepare` to retain exact registration payload, annotated-tag notes and source/run provenance |
| 7 | Retain `provider-publication-<SOURCE_SHA>-<SIGNING_ATTEMPT>` for 30 days; always remove the signing keychain |

All hashes describe final signed bytes. `scripts/install.sh` and self-update
verify the `bin/` files before installing the app; the external artifact verifier
also reads the regular-file executable. Keep this layout intact.

The Linux `stage-release` job downloads the exact artifact named by signing,
verifies identity/digest and uploads only the immutable bundle-digest R2 path.
It neither signs nor registers, changes aliases or publishes GitHub releases.
Signing has no R2 upload credentials. `publish-release` requires successful
staging and performs these operations in order:

| Order | Operation |
|---|---|
| 1 | Download/verify the retained signed artifact with its original producing run/attempt |
| 2 | Recheck signed tag, source/run/version/origin and bundle digest, then submit the retained `POST /v1/releases` payload |
| 3 | Wait boundedly for `/v1/releases/latest` to report that committed official build or a newer release, not an older cached response |
| 4 | Only if still latest, update both `releases/latest/darkbloom-bundle-macos-arm64.tar.gz` and the legacy `eigeninference-bundle` alias |
| 5 | For prod/tag, create or resume a GitHub draft, upload a missing asset, verify downloaded bytes and publish |

The payload contains `version`, `platform=macos-arm64`, `backend=mlx-swift`,
`binary_hash`, `bundle_hash`, `metallib_hash`, `code_directory_hash`,
`source_commit`, `ci_run_id`, `require_app_attest_qualification=true`, `url`
and `changelog`. The URL is the configured CDN followed by
`releases/v<VERSION>/artifacts/<BUNDLE_SHA256>/darkbloom-bundle-macos-arm64.tar.gz`.
Use the retained payload, never hand-reconstruct hashes. The
[pinned release-handler contract](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/releases/release_handlers.go)
documents artifact validation; it predates automatic identity registration.

The updated platform verifies the staged archive and records complete native
identity in its durable `AppAttestBuildQualification` registry before publication
through the revocation row-lock fence. Partial identity fails closed; conflicting
identity or permanent revocation returns 409, and unavailable policy returns 503.
Existing identity/audit records are preserved. No independent hardware report
or admin approval is needed for this normal path. The coordinator trusts source/run
provenance from the authenticated pipeline rather than independently verifying
GitHub. Official registration does not itself authorize a provider to serve.
Runtime Apple verification and matching official hashes remain required.

After commit, the platform refreshes binary/runtime policy and release caches.
Active releases retain their hashes during adoption; deactivation removes them
from the catalog. See the [runtime manifest](../architecture/security/attestation.md#runtime-manifest).

## Recovery

### Resume Signing From A Retained Unsigned Build

Use this only when build and SDK qualification passed but signing failed from
workflow tooling or runner setup. Keep the tag on its original candidate, merge
the tooling correction into trusted `master`, then dispatch with the exact source
run and successful build attempt:

```bash
gh workflow run release-swift.yml --ref master \
  -f environment=prod -f resume_run_id=<source-run-id> -f resume_run_attempt=<build-attempt>
```

`scripts/provider-release-resume.py` validates repository, workflow, push/tag
origin, current signed tag, source signature/version/ancestry, both successful
jobs and one unexpired immutable unsigned artifact. It refuses a run that already
retained a signed publication artifact. Resolver and downloader both check
identity; download verifies the GitHub ZIP digest before archive/inventory/source/
version/entitlement checks.

Recovery skips compilation and SDK qualification, not signing, notarization,
packaged smoke, R2 staging or official registration. `release-provenance.json`
distinguishes original build source/run from current signing workflow source/run.
The unsigned artifact expires after three days. Missing/expired bytes or changed
candidate source require a new build and reviewed tag. This path does not move
tags or infer that a rerun picks up new source.

### Retry Staging Or Publication

After a signed artifact is retained, rerun only failed downstream jobs from that
signing run. Preserve original bytes and producing attempt even if the workflow
attempt increments. Never rerun successful signing to retry publication: a new
signature changes identity. GitHub retry can repair an incomplete `starter`
placeholder but never overwrites completed mismatched assets or incomplete
already-published releases. Investigate those states and identity/revocation
conflicts rather than bypassing them with admin approval. Implementation:
`scripts/provider_release_github.py` (`publish_github_release`), with GitHub's
[release-asset API](https://docs.github.com/en/rest/releases/assets).

## Environment-Free Signing Validation

`.github/workflows/provider-signing-validation.yml` is a separate manual workflow
for a reviewed full `source_sha` and existing version. It has no environment
selector, registration, R2 upload, release, tag or deployment step; its token is
limited to `contents: read` and `actions: read`. The build checks source signature
and version, and a separate runner verifies the same-run unsigned artifact before
signing (`scripts/provider-signing-validation.py`).

Unpacking caps compressed and declared total member bytes at 2 GiB, individual
members at 512 MiB and count at 16,384. Unsafe links/paths, duplicate normalized
paths including case aliases, mismatched bundle/executable/version identity and
incorrect entitlements are refused. Profile validation checks team, access group,
production APNs, expiry and any declared application identifiers; either identifier
key, when present, must cover the provider. Conflicting/malformed declarations fail.

The signer uses the existing Apple secrets, checks the signed CLI's keychain group,
APNs and disabled debug-task entitlement, notarizes/staples, emits post-sign hashes
and always removes its keychain. Only explicit artifacts and non-secret diagnostics
are retained for three days. The workflow never runs the candidate CLI, helper,
model or server. Runtime smoke, installation and model correctness are separate
checks; this is not the release workflow's `validation_only` mode.

## Verification

After authorized publication, inspect the selected environment read-only:

```bash
COORD=https://api.darkbloom.dev
curl -fsS "$COORD/v1/releases/latest?platform=macos-arm64" | jq .
curl -fsS "$COORD/api/version" | jq .
curl -fsS "$COORD/v1/admin/releases" -H "Authorization: Bearer $ADMIN_KEY" | jq '.releases[] | {version, active, created_at}'
```

`/v1/releases/latest` selects the highest active semver for the platform, not the
last inserted row. No release row means 404; the display fallback on `/api/version`
does not repair installer/update discovery. Verify URL and all hashes, not version
alone. For separately authorized clean-Mac installation, verify installer hashes
and `darkbloom --version`; preserve existing provider workloads.

Auto-update checks the same latest endpoint after an initial five minutes and
every thirty minutes unless disabled by `auto_update=false` or
`DARKBLOOM_NO_UPDATE_CHECK`
(`provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift`). Monitor
platform release-policy acceptance and version adoption separately. Optional
signed-artifact tests should exercise restart/write-budget persistence, encrypted
inference, lifecycle/worker resumption and relevant model/media behavior without
claiming that CI/notarization proved those physical outcomes.

## Rollback

Rollback needs its own explicit authorization. A registered version is hash-pinned;
do not replace its bytes or re-register it with a different artifact.

1. Deactivate the bad release through the external admin API. In-use protection
   can return `409 release_in_use`; force removal can leave connected providers
   unroutable until downgrade, so it needs an explicit operator decision.
2. Verify that `/v1/releases/latest` selects the intended remaining active version
   and that its URL/hashes and current qualification remain valid. Runtime policy
   must retain needed older official builds during adoption.
3. Repoint both R2 convenience aliases to that exact verified version's immutable
   bundle-digest object. Do not assume a hardcoded previous version or use the
   older version-only object layout. Installers use the API's versioned URL;
   the aliases still serve legacy clients.
4. Adjust the GitHub release's public status and record the actual outcome.
   Fix forward with a new reviewed patch version, never overwritten signed bytes.

Permanent binary revocation is distinct from release deactivation. An authorized
platform administrator can use `POST /v1/admin/app-attest/builds/revoke`; registration
retries cannot undo its tombstone. Recover with another reviewed signed build,
not a deleted revocation row or relaxed runtime gate. The old admin build-approval
API remains a compatibility/recovery tool, not a normal release step.

## Related

- [Local builds and native resources](../developer/build.md)
- [Provider and SDK tests](../developer/test.md)
- [Pinned platform deployment reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/coordinator-deploy.md)
- [Pinned release-policy reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/release-policy-rollout.md)
- [Pinned release API reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/api-contracts.md)
