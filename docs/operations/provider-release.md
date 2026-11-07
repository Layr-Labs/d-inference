# Release A Provider Version

> Last updated: 2026-11-07

Build, sign, notarize and publish an explicitly authorized provider artifact.
The pipeline registers its exact official identity through the external platform
API; no backend build or deployment runs here. Source ownership changes do not
authorize releases, infrastructure or hosting changes.

## When To Use

Use `.github/workflows/release-swift.yml` for a production version tag, a
staging publication, or a signed validation bundle. Build, SDK qualification,
signing, R2 staging and publication are separate jobs. Staging/publication
failures retry the retained artifact rather than rebuilding or re-signing it.

A push to `master` that changes the provider or its release tooling publishes a
staging release when the `STAGING_ENABLED` repository variable is `true`
(DBLM-771: staging tracks main). While that variable is unset, a master push
publishes nothing. A `vX.Y.Z` tag publishes production. No path of this workflow
publishes a dev release. DevNet runs the d-inference `dev` branch from end to
end: its dev releases come from `.github/workflows/release-dev-branch.yml`.

`.github/workflows/release-swift.yml` is the thin caller that routes each trigger
to at most one environment lane. The reusable `.github/workflows/release-provider.yml`
runs the resolve, build, qualification, signing, R2 staging and publication
chain for one environment. To find the newest dev release, read
`https://api.dev.darkbloom.dev/v1/releases/latest`.

`ProviderCore.version` is prepared as `0.10.10`, a patch release over `v0.10.9`.
It adds `darkbloom waitlist` and first-setup approval gates for Darkbloom
Sandbox and `darkbloom cluster`, ported from #1742 onto `master` (the feature
PR #1850). Nothing else changes from v0.10.9: the serving engine, the
pair setup, the models, the toolchain (Xcode 27.2 / SDK 27.2 / Swift 6.4.2) and
the MLX pins are v0.10.9's. Both Macs of a pair must run 0.10.10, and a pair on
0.10.9 updates itself
([updating Darkbloom on the pair](../provider/two-mac-cluster.md#updating-darkbloom-on-the-pair)).
See the [`v0.10.10` changelog entry](../../CHANGELOG.md) for the full scope.

Before tagging `v0.10.10`:

- Confirm the tagged commit keeps the release toolchain: `mise.toml` has
  `swift = "6.4.2"`, `release-provider.yml` sets
  `DARKBLOOM_PROVIDER_TOOLCHAIN: release` and asserts
  `build_sdk_version == '27.2'`, `scripts/check-date-comparisons.py` passes, and
  the release build runs `scripts/check-provider-weak-imports.py`.
- Confirm the pins `libs/mlx` and the nested `mlx` `72dffa2d`,
  `libs/mlx-swift` `c633d221` and `libs/mlx-swift-lm` `32f5c744`, as v0.10.9.
  The tag build's `metallib_hash` should equal v0.10.9's
  `5b97893cc20e6e9651edf3284d970488af9a9bdd64820231e95fee760eec70ac`.
- `PROD_CLUSTER_RUNTIME_ENABLED` is `true`, so this tag registers a cluster
  runtime facts block. Run the release's facts step read-only on the exact tag
  tree (`scripts/provider-cluster-runtime-facts.sh <app> darkbloom prod <new folder>`
  on an unsigned app staged as the build job stages it). It must exit 0 and
  match v0.10.9's block in models, grants and qualifications.
- Catalog room: production holds 24 approvals from v0.10.8 and 24 from v0.10.9.
  This release adds 2 per model of its block (24 for 12 models), so v0.10.8's
  approvals are left out: pairs still on 0.10.8 stop serving through Darkbloom
  until they update, and the coordinator logs `release cluster approvals
  omitted` for v0.10.8.
- The tagged commit is on `master` and verified, holds `ProviderCore.version`
  `0.10.10`, keeps the plain-build default `prod`, and its `changelog.d/` holds
  only `README.md`.

Roll out in this order; each step is a separate approval:

1. Production platform: 0.10.10's registration needs nothing new. The waitlist
   routes (darkbloom-platform #627) are independent: without them the first
   setups go on as in 0.10.9. Confirm production's `/health` `build_commit`
   and that no coordinator swap overlaps this release's publication.
2. Merge into `master`, each squash-merged after its approval: the waitlist
   feature PR, then this preparation. Let SDK 27 release preparation pass on
   `master`.
3. Re-run the facts dry run on the tag tree.
4. Tag `v0.10.10` on this preparation's squash commit
   ([step 4](#4-tag-and-push-production-source)). After registration, check
   `GET /v1/cluster/approvals` for `release/0.10.10/<model>/s<1|2>` beside
   v0.10.9's, and that `release cluster approvals omitted` names v0.10.8.
5. Pairs on 0.10.9 update themselves at their update slot, or at once with
   `darkbloom update` on each Mac. Single Macs update by themselves.
6. The platform snapshots its provider contracts from the tagged commit and
   sets `LatestProviderVersion` to `0.10.10`.

Catalog changes, allowlist changes and model registration are separate
approvals. This preparation tags, deploys and enables nothing.

`v0.10.9` was [published on 2026-11-05](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.9)
from `95cc1ca37533aa860f1948bde0d6ec9c36a6bd4a`, `v0.10.8` was
[published on 2026-11-04](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.8)
from `e8f3d53f6d49c66232ea4cd270b84c2aa4df01f0`, `v0.10.7` was
[published on 2026-11-03](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.7)
from `7512eeeae0682b120f3d86abbc712861bdbf2bda`. Publication does not establish
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

## Archive Extraction Permissions

Installer and self-update archive extraction use a child-local `umask 022` so
ordinary release modes, including the fan helper's required `0755`, survive a
provider started with `umask 077`. The caller's private-state mask is unchanged.
Hash, signature, runtime-capability and atomic replacement checks still run;
extraction does not enable tar's full-permissions or unsafe-path options.
Coordinate the platform-served installer snapshot separately before publication.

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
`release_changelog` in `scripts/provider-release-publication.py` removes only
Git's identified signature suffix and trims outer whitespace. Internal line
breaks and paragraph spacing remain unchanged. The GitHub release page, unlike
the registered `changelog`, shows the whole `CHANGELOG.md` section of the tag
and every pull request of the release
([GitHub release notes](#github-release-notes)).

### 3. Merge And Verify Release Preparation

Open the authorized release PR and require the retained component gates.
After merge, let **SDK 27 release preparation** finish on `master`, or dispatch
`.github/workflows/provider-release-cache.yml` on `master`. It runs optimized
compilation and SDK qualification on separate `blacksmith-12vcpu-macos-27`
runners with no signing/publication secrets. PR caches remain PR-scoped and do
not seed `master`. Only pull-request runs can use Darkbloom Sandboxes, under
[CI runner routing](../developer/build.md#ci-runner-routing); `master` and
dispatched runs always use these Blacksmith runners.

The qualification lane prepares the bounded MiMo HTTP image fixtures before
the full provider suite, including on cache hits. Keep that preparation as a
separate step so its environment reaches the tests. See the
[fixture recipe](../developer/test.md#mimo-regression-fixtures) for local runs.

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

### 5. Select Staging Or Validation Mode When Needed

A push to `master` starts a staging release when the `STAGING_ENABLED`
repository variable is `'true'` and the push changes a path in the caller's
`on.push.paths` list: `provider-swift/**`, `libs/**`, the release caller, the
reusable workflow, the build action, or a script that the release runs. The
trigger, not an input, selects the lane: the caller's `staging` job calls
`release-provider.yml` (the job is skipped while `STAGING_ENABLED` is unset). A
plain matrix cannot carry each lane's artifact id and digest across the
dependent jobs, which is why each lane is a separate call of the reusable
workflow. Path filters do not apply to tags, so tags publish production as
before. One staging release runs at a time (the caller's `release-staging`
group); a running release always completes, and when more merges arrive only
the newest waiting run continues.

A master push does not publish a dev release, and the dispatch has no `dev`
environment choice. The caller's `dev` job runs only for a dispatched signed
validation build (below), and `scripts/resolve-provider-release.sh` refuses a
dev publication from master and a master push routed to dev. DevNet gets its
provider releases from the d-inference `dev` branch through
`.github/workflows/release-dev-branch.yml`.

The source gate on `master` admits a push to `dev` for the `dev` environment
only. `verify_workflow_source` (`scripts/provider_release_resume/api.py`)
requires a GitHub-verified commit on `dev` ancestry and refuses `staging`, `prod`
and a missing environment. `resolve-env` runs this gate from `master`, and then
runs `scripts/resolve-provider-release.sh` from the pushed commit. The resolver
stamps `X.Y.Z-dev.branch.N` (`N` is the run number). It refuses a dev push routed
to another environment and a push from any other branch. A dev build signs with
the same Developer ID as staging and prod.

Before upload, `build-and-release` checks the final archived app against the
designated requirement of the provider self-updater
(`DarkbloomCodeSignature.designatedRequirement`): Apple anchor, identifier
`io.darkbloom.provider`, team `SLDQ2GJ6TL`. A dev build meets the same
requirement as a production build, so only the production registration and the
production release key keep a dev build out of production.

`version_override`, if supplied, must equal the source. Production without a
source-matching tag is refused, except the validated retained-build recovery
path below. A dev lane reads the shared Apple signing secrets and only the
`DEV_*` publication secrets: the `PROD_*` and legacy secret values are empty in
every job unless the resolved environment is `prod`. Dev creates no GitHub
Release and no tag. Dev uploads go only to the `DEV_R2_BUCKET` bucket and the
`DEV_R2_PUBLIC_URL` origin.

The optimized job sets `DARKBLOOM_RELEASE_ENVIRONMENT`. For `dev`,
`provider-swift/Package.swift` compiles `ProviderBuildEnvironment` with
`DARKBLOOM_ENV_DEV`; defaults are `wss://api.dev.darkbloom.dev/ws/provider` and
`https://models.darkbloom.ai`
(`provider-swift/Sources/ProviderBuildEnvironment/BuildEnvironment.swift`).
`qualify-sdk-shard` sets `DARKBLOOM_RELEASE_ENVIRONMENT: prod`, so its tests see
production defaults on every branch: on `dev`, an unset value compiles the dev
identity (`provider-swift/Package.swift`). Config, CLI flags and
`DARKBLOOM_R2_CDN_URL` still override defaults. Dev/prod products have different
cache keys, and packaged smoke must report the selected build environment.

Every run except a dev push builds master's source. Before the build, job
`resolve-env` runs `scripts/provider-build-default.py --branch master`. The run
stops if the plain-build default in `provider-swift/Package.swift` is not `prod`.

A dev release from a dev push has the version `X.Y.Z-dev.branch.N`, and a
master validation build has `X.Y.Z-dev.N`. `X.Y.Z` is the source
`ProviderCore.version` and `N` is the workflow run number. The release lane
writes this version into `ProviderCore.version` before it compiles, so
`darkbloom --version`, the app `Info.plist`, the registration and the R2 path all
show the dev marker. SemVer puts `X.Y.Z-dev.branch.N` below `X.Y.Z` and orders
dev-branch builds by `N`. The dev coordinator ranks releases with
`ReleaseVersionGreater`, not SemVer, until [darkbloom-platform#551](https://github.com/Layr-Labs/darkbloom-platform/pull/551) is
deployed (see the Dev-Branch Lane section). Production versions never have a
suffix. A dev `EIGENINFERENCE_MIN_PROVIDER_VERSION` must
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
item, and each command prints its own name in its help text. That includes the
two-Mac cluster: each install keeps its own pairing, cluster setup, service
lock and observability files in its own folders (`ClusterUserPaths`), its
cluster service's login job carries `clusterServiceLabelPrefix`, its per-user
cluster locks are named after `cliName`, and the ports its pair uses on the
cable add `clusterPortOffset` (`ClusterCablePorts`). Shared on purpose: the
models, the cable port setup, the sweep of cluster processes whose parent is
gone, and the range the pair's local API port is chosen from (8000 to 8020). The
table is a generated copy of
`provider-swift/identity/provider-identity.json`, the only declaration of these
values:

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
| `clusterServiceLabelPrefix` | `io.darkbloom.cluster-service.` | `io.darkbloom.cluster-service.dev.` | `io.darkbloom.cluster-service.staging.` |
| `logSubsystem` | `com.darkbloom.provider` | `com.darkbloom.provider.dev` | `com.darkbloom.provider.staging` |
| `serviceLogSubsystem` | `dev.darkbloom.provider` | `dev.darkbloom.provider.dev` | `dev.darkbloom.provider.staging` |
| `defaultLocalPort` | `8000` | `8001` | `8002` |
| `clusterPortOffset` | `0` | `10` | `20` |
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
with the JSON. Every command it prints uses the selected `cliName`, through its
last line, `Next: ~/.<cliName>/bin/<cliName> start --opencode`; the platform
serves its own snapshot of the script, so a change to these lines reaches
`curl | bash` only once that snapshot is updated.

Right after selecting the identity, the installer refuses a **new** install on
macOS 26 or earlier (`require_supported_macos`) before downloading the bundle, so a
release never reaches a Mac that can't become a new provider. An existing install
of the same identity can still be updated or repaired.

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
  `-dev.branch.N` version.

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
when it is `'true'`, a master push publishes a staging release (DBLM-771),
signed with the same Developer ID as dev and prod —
staging is a normal Developer-ID dev-family release, as is the dev-branch build
of `release-dev-branch.yml`. A `X.Y.Z-staging.N` version carries the workflow run
number, like a dev build's `X.Y.Z-dev.branch.N`. Publish a staging build by hand with
the same version form (the flag gates the manual lane too):

```bash
gh workflow run release-swift.yml --ref master -f environment=staging
```

A staging run uses only `STAGING_*` secrets (`STAGING_R2_*`,
`STAGING_COORDINATOR_URL`, `STAGING_RELEASE_KEY`). These secrets and the staging
coordinator infra do not exist yet (a separate `darkbloom-devnet-infra` effort,
DBLM-771 infra PR 18). Until they do, leave `STAGING_ENABLED` unset (the default):
the caller's `staging` job is skipped, so a master push builds and publishes
nothing and never burns a macOS build + notarization that would hard-fail at
staging publication for want of credentials. Turn staging publishing on by
setting the `STAGING_ENABLED` repository variable to `true` once that infra PR is
applied and the `STAGING_*` secrets exist. A push never selects prod:
`scripts/resolve-provider-release.sh` refuses prod on any non-tag trigger, so the
production signing identity stays tag-gated.

For a signed, notarized validation bundle without registration/publication:

```bash
gh workflow run release-swift.yml --ref master -f validation_only=true
gh run download <run-id> --name darkbloom-signed-validation-<commit>-<attempt> --dir <new-directory>
```

The dispatch runs the caller's `dev` lane instead of the chosen environment, and
the `staging` and `prod` lanes do not run. Trusted-source/version checks and
Apple credentials still apply. This mode skips
publication-secret resolution, R2 upload, registration and GitHub Release
creation; it does not attach a GitHub environment. The artifact contains the
final tarball and `darkbloom-validation-identity.json`: source/submodule pins,
archive/executable/metallib hashes, full SHA-256 CodeDirectory digest and SDK.
The older-OS job downloads those exact bytes on `blacksmith-12vcpu-macos-26`,
asserts the host is below macOS 27, verifies hashes/notarization and requires
the environment line plus all four runtime-smoke markers. Retention is 14 days.
Verify artifact identity before isolated model/restart tests; build success does
not establish persistence, real Apple functionality or fleet readiness.

#### Dev-Branch Lane (Dev Only)

Dev builds dev, and master builds master. A push to the d-inference `dev` branch
starts `.github/workflows/release-dev-branch.yml`. A master push and a release
tag run `release-swift.yml`. No workflow dispatches a build of another branch,
and the dev-branch lane has no `workflow_dispatch`.

`release-dev-branch.yml` is only a caller. Its one job checks
`github.ref == 'refs/heads/dev'` and calls the reusable `release-provider.yml`
with `environment: dev` and `secrets: inherit`. The reusable workflow runs the
same chain as every release lane: the source gate, the build, the SDK
qualification, Developer ID signing, notarization and stapling, R2 staging and
registration on the dev coordinator. A dev-branch build therefore has the same
signature as a master build and passes the same checks: the fan-helper
requirement of `scripts/install.sh` and the self-updater's
`DarkbloomCodeSignature` production requirement. The push trigger uses the
`paths:` list of the `release-swift.yml` master push, with
`release-dev-branch.yml` in place of `release-swift.yml`.

| Item | Dev-branch lane |
|---|---|
| Version | `X.Y.Z-dev.branch.<run>`, stamped by `scripts/resolve-provider-release.sh` and accepted by `scripts/check-release-version.sh` |
| Source gate | Job `resolve-env` runs master's copy of `scripts/provider-release-resume.py verify-source`, which accepts a `refs/heads/dev` push for environment `dev` only. |
| Signing and notarization secrets | `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `PROVISIONING_PROFILE_BASE64`, `APPLE_ID`, `APPLE_APP_PASSWORD`, read only in job `build-and-release` |
| Publication secrets | `DEV_R2_*`, `DEV_COORDINATOR_URL`, `DEV_RELEASE_KEY` |
| GitHub environment | None. All of these are repository secrets. |
| Serialization | Workflow group `release-dev-branch`; publication group `provider-publication-dev` |

`secrets: inherit` passes every repository secret to the reusable workflow. For
environment `dev` it reads only the secrets in the table; it reads a `PROD_*`,
`STAGING_*` or unprefixed publication secret only behind an
`environment == 'prod'` or `environment == 'staging'` guard.
`scripts/test-release-dev-branch.py` pins this.

To retry, follow [Retry Staging Or Publication](#retry-staging-or-publication):
re-run failed jobs only after the signing job passed, and push a new commit to
rebuild. The `release-dev-branch` group does not cancel a running run, but a
newer dev push cancels a run that is still pending in the group.

Because a dev push gets the Developer ID signature, pull requests into `dev`
need one approving review and land as merge commits (ruleset "Dev pull
requests"). `dev` also requires signed commits, and the "Darkbloom PR access
control" ruleset lets only the accounts on its bypass list create or update a
ref.

The dev coordinator can still hold `X.Y.Z-dev.<run>` releases from the master
dev lane; `0.10.4-dev.224` is the latest dev release on 2026-10-28.
`/v1/releases/latest` returns the active release that `ReleaseVersionGreater`
ranks highest. That comparison is not SemVer: it reads each dot-separated part of
the version as an integer, so a non-numeric part such as `branch` counts as 0. It
uses `created_at` only to break a tie on the same version
([`ReleaseVersionGreater` at `fb6aaa9e`](https://github.com/Layr-Labs/darkbloom-platform/blob/fb6aaa9e58c8795987dd832ecb5b98925c9ffbae/coordinator/internal/store/shared/release_version.go);
[`GetLatestRelease` at `fb6aaa9e`](https://github.com/Layr-Labs/darkbloom-platform/blob/fb6aaa9e58c8795987dd832ecb5b98925c9ffbae/coordinator/store/postgres/releases.go)).
Until the coordinator ranks releases by SemVer:

- At a lower base version than an existing `-dev.<run>` release, that release
  stays latest. The dev-branch build is registered, but the publication does not
  advance the latest aliases.
- At an equal base version, `X.Y.Z-dev.<run>` ranks above
  `X.Y.Z-dev.branch.<run>`, so the existing release stays latest. The
  publication script then waits for a latest version that does not come, and the
  `publish-release` job fails after it registers the release.
- At a higher base version, the newest dev-branch build is latest.

When the coordinator ranks by SemVer 2.0, an alphanumeric identifier ranks above
a numeric one in the same position. Then `X.Y.Z-dev.branch.<run>` ranks above
`X.Y.Z-dev.<run>`, and the newest dev-branch build at the highest base version is
latest.

An existing install's self-updater may not downgrade to a lower version, while a
fresh install takes the latest.

### 6. Sign, Stage And Register Exact Bytes

After `build-provider` and `qualify-sdk` succeed, `build-and-release` consumes
the source-bound unsigned artifact on `blacksmith-12vcpu-macos-27`. It does not
wait for an environment approval. `qualify-sdk` passes only when all five
`qualify-sdk-shard` jobs pass and together executed the full provider suite.
Release SDK selection is SDK 27.2 / Apple Swift 6.4.2 (Xcode 27.2), with `SDKROOT` covering
compilation and linking; the final recorded SDK must match. Before the
handoff, the release lane runs `scripts/check-provider-weak-imports.py` on every
built binary. It refuses a binary that imports Foundation's back-deployed
`Date.>=` or `Date.<=`, which pre-release macOS 27.2 builds lack
([build guide](../developer/build.md#sdk-27-release-builds-and-caches)). The
checksum-pinned GitHub CLI is installed by
`scripts/install-macos-github-cli.sh` before downloads. Missing `gh` in an old
run is a tooling failure, not a model or notarization failure.

| Order | Operation |
|---|---|
| 1 | Verify source version, selected SDK and same-run unsigned artifact inventory/source/version |
| 2 | Import the temporary Developer ID keychain and validate the embedded profile/entitlements |
| 3 | Sign the canonical app with hardened runtime and preserve SwiftPM resources |
| 4 | Copy `darkbloom`, `darkbloom-enclave` and `mlx.metallib` into regular files under `bin/`; these verification copies support current and older updaters, not flat installation |
| 5 | Notarize, staple, rebuild/extract the final archive, run packaged smoke and compute final binary/archive/metallib and full CodeDirectory SHA-256 hashes |
| 6 | Compute the [cluster runtime facts](#cluster-runtime-facts) from the final archive, show them in the job summary and retain them as a run artifact |
| 7 | Run `scripts/provider-release-publication.py prepare` to retain exact registration payload, original annotated-tag notes without the signature suffix, and source/run provenance |
| 8 | Retain `provider-publication-<SOURCE_SHA>-<SIGNING_ATTEMPT>` for 30 days; always remove the signing keychain |

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
| 5 | For prod/tag, create or resume a GitHub draft with the [release notes](#github-release-notes), upload a missing asset, verify downloaded bytes and publish |

The payload contains `version`, `platform=macos-arm64`, `backend=mlx-swift`,
`binary_hash`, `bundle_hash`, `metallib_hash`, `code_directory_hash`,
`source_commit`, `ci_run_id`, `require_app_attest_qualification=true`, `url`
and `changelog`. It also contains `cluster_runtime` only when that environment's
`*_CLUSTER_RUNTIME_ENABLED` variable is `true`
([cluster runtime facts](#cluster-runtime-facts)). The URL is the configured CDN followed by
`releases/v<VERSION>/artifacts/<BUNDLE_SHA256>/darkbloom-bundle-macos-arm64.tar.gz`.
Use the retained payload, never hand-reconstruct hashes. The
[release handler, pinned at the platform `dev` merge that accepts `cluster_runtime`](https://github.com/Layr-Labs/darkbloom-platform/blob/df61dd6f93714b4458d0eef3125c377087c08b52/coordinator/api/releases/release_handlers.go)
validates the artifact, records the build identity and reads the block strictly
(`registry.ParseReleaseClusterRuntime`); a coordinator without that change
refuses the field (`DisallowUnknownFields`).

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

### GitHub Release Notes

Only a prod (tag) publication creates a GitHub release; dev, DevNet dev-branch
and staging publications register with their coordinator and create none.
`publish_github_release` creates the draft with the body that
`scripts/provider_release_notes.py` writes, not with GitHub's generated notes,
which list only the pull requests merged into `master` between two tags. A
squash promotion of `dev` into `master` (0.10.7's #1754) appears there as one
pull request, and the `dev` pull requests it carried are missing.

The body has four parts:

1. The header that `prepare` retained: source, runs, hashes and install.
2. **What's new in vX.Y.Z**: the version's `CHANGELOG.md` section at the tag,
   with upgrade and rollout notes and every entry. The `— candidate
   (unpublished)` heading and its "Prepared on" line are left out.
3. **Pull requests in this release**: one line per pull request, with its title,
   author and link, in merge order. They come in two groups: the pull requests
   merged into `dev` that reached `master` with a promotion, then the ones merged
   directly into `master`. Commits without a pull request are listed after them.
   Release pull requests are named once on their own line, not listed: the
   promotions, the release preparation and merges of `master` into `dev`.
4. The compare link from the previous release tag.

The script reads the release's contents from Git, not from a date window:

- **The carried `dev` commit.** For a release tag, this is the newest commit of
  `dev`'s first-parent chain that the release contains. The tag contains it
  after a merge-commit promotion. After a squash promotion, the promotion's head
  contains it: GitHub keeps `refs/pull/<N>/head` after the merge, and the script
  fetches it read-only. A release with no promotion of its own, such as a
  hotfix, carries what the release before it carried. The script looks back
  four releases for it. After more than four releases in a row without a
  promotion, it uses what the tag itself contains, and the next release can
  list again pull requests that an earlier release listed.
- **Promotions are found by their history, not their titles.** A pull request
  on `master`'s first-parent chain is a promotion when its head (the merge
  commit's second parent, or the squash's `refs/pull/<N>/head`) holds a `dev`
  first-parent commit that `master` did not have. If GitHub no longer had a
  squash promotion's head, the notes would list it as a pull request merged
  directly into `master` and leave out its `dev` pull requests, with no
  warning. A preparation whose head holds `dev` commits is named as the
  preparation, and the `dev` pull requests are listed as reaching `master`
  with it.
- **The `dev` pull requests** are the first-parent commits of `dev` after the
  commit that the previous release carried, up to the one this release carries.
  They are `Merge pull request #N` merges and squashed `(#N)` subjects. A `dev`
  pull request merged after the promoted snapshot was cut waits for the next
  release, even if it merged before the tag.
- **The preparation** is the commit that adds the version's `CHANGELOG.md`
  heading. **A sync** is a merge into `dev` that brings `master`'s first-parent
  commits and no commits of its own. A sync with its own fixes is listed as a
  `dev` pull request.
- **Titles and authors** come first from GitHub's GraphQL API, in one query per
  100 pull requests. A `(#N)` that GitHub names an issue is listed as a commit
  without a pull request. Titles and commit subjects show as typed: HTML, links
  and emphasis in them are escaped, and a code span stays code.
- **Without GitHub's API, titles come from git.** The `publish-release` token
  has only `contents: write` and `actions: read`, so GitHub can refuse the
  lookup ("Resource not accessible by integration"); any GraphQL error other
  than an unknown number also counts. Every pull request is then still listed:
  - **Titles.** GitHub writes a merge commit as `Merge pull request #N from
    <branch>`, a blank line, then the title, so the first line of its body is
    the title. A squash commit's subject is the title and ` (#N)`. Both are the
    title when the pull request merged: a title edited later, or a commit
    message edited at the merge, shows as git has it.
  - **Authors are commit authors**, and are shown only where a GitHub noreply
    address (`[<ID>+]<login>@users.noreply.github.com`) names the login. The
    address is the author's of the pull request's oldest own commit, or for a
    squash, the squash commit's. Other addresses name no GitHub account, so the
    line has no author. The newest commit of a branch is not used: it is often
    someone else's merge of `dev`.
  - **The warning.** The job logs a warning that the titles came from git, with
    GitHub's error. `--git-titles` produces the same body on request.
  - **Measured on v0.10.7.** Git lists the same 48 pull requests. 47 titles equal
    GitHub's; #1691's squash subject keeps a parenthetical that its title later
    lost. 34 authors are shown, all equal to GitHub's, and 14 are left out. The
    newest branch commit would have named the wrong author for 18 of the 45
    `dev` pull requests.

GitHub refuses a body over 125,000 characters. When the body is longer, it
keeps the upgrade and rollout notes and links the entries in `CHANGELOG.md` at
the tag. The pull request list is always kept. By then the registration and the
latest aliases are published. A generation failure therefore does not stop the
GitHub release: the job logs a warning with git's or GitHub's error, and the
body says that the generated part is missing.

To check the notes for a published release, or to preview them before the tag,
run the script read-only. It prints what it excluded and why on standard error:

```bash
python3 scripts/provider_release_notes.py --tag vX.Y.Z --output notes.md
# Before the promotion merges: a local squash of the snapshot onto master stands in for the tag.
python3 scripts/provider_release_notes.py --tag vX.Y.Z --target <local squash commit> \
  --previous <previous tag> --pull-head <promotion PR>=<snapshot head> --output notes.md
```

Publishing corrected notes for an existing release (`gh release edit vX.Y.Z
--notes-file notes.md`) is a production change; it needs the release owner's
approval.

### Cluster Helpers

The release ships the two-Mac cluster's helpers inside the app:
`Darkbloom.app/Contents/Helpers/darkbloom-cluster-worker` (the rank a cluster
member launches) and `darkbloom-cluster-plan` (the placement tool), with the
`mlx.metallib` and `pagedattention.metal` they load beside themselves. On the
release lane `.github/actions/provider-release-build/action.yml` builds them
with `scripts/build-cluster-helpers.sh` against the same source-matched Metal
library as the provider and checks the copy is byte-identical;
`scripts/provider-signing-validation.py stage --cluster-helpers` copies them
into the unsigned app and refuses an artifact without them. Signing runs
`scripts/sign-cluster-helpers.sh` before the app itself is signed: Developer ID,
hardened runtime, timestamp, their own identifiers and the network-only
entitlements of `provider-swift/entitlements-cluster-worker.plist`. After
notarization, `provider-signing-validation.py cluster-helpers --app` and
`sign-cluster-helpers.sh --verify` check the final archived bytes. The app's
`Info.plist` carries `NSLocalNetworkUsageDescription`, so macOS asks for Local
Network once for the signed identity and keeps the approval across updates and
reboots ([always on](../provider/cluster-always-on.md)). The
environment-free signing workflow builds, stages, signs and verifies the helpers
the same way. An owner signing a local build runs the same script with the
Developer ID identity, then signs and notarizes the app as the workflow does.

### Cluster Runtime Facts

Each signed release can carry the cluster runtime facts of its final app as
`cluster_runtime` in its `POST /v1/releases` payload. A coordinator that
accepts the block derives from it that build's cluster approvals, their
pair-serving grants (without one no pair of GLM-5.3-Flash or Qwen3.8-27B forms:
[why](../architecture/inference.md#cluster-runtime-facts-of-an-installed-app)),
and the parity qualifications (public traffic) of the models the build declares
public (`ClusterPublicModels`: GLM-5.3-Flash, Qwen3.8-27B, MiMo-V2.6-Flash and
Gemma 4 26B QAT in pipeline and tensor parallel, MiMo-V2.6-Flash also in its
speculative pipeline, the owner's decisions of 2026-10-31 and 2026-11-03,
[evidence](../reports/2026-10-31-public-cluster-models.md)). No operator posts
approvals, grants or public qualifications per build. A coordinator applies the
qualifications to each declared family on any Apple silicon pair: the declared
placement names the evidence, not a limit, and GLM-5.3-Flash's schedule 2
entries are inert because its runtime serves only the serial schedule
([details](../reference/configuration.md#cluster-runtime-facts)). The block
format and its rules are in the same reference.

Every lane (dev branch, staging, prod) runs the step
`Compute cluster runtime facts from the final signed app` of job
`build-and-release`:

1. It runs after notarization, stapling and the final-archive checks, and before
   `prepare`.
2. It reads no secret. It removes the two secret-derived values in the job's
   `GITHUB_ENV` (`r2_public_url`, `coordinator_url`) and deletes the signing
   keychain before any release code runs. The step fails unless the keychain
   file is gone and `security find-identity -p codesigning` no longer lists
   `$DEVELOPER_ID`.
3. It checks the archive against `BUNDLE_HASH` and extracts it into a new
   folder. Steps 4 to 6 are `scripts/provider-cluster-runtime-facts.sh`; the
   app's own CLI runs with an empty environment (`env -i`), so the public
   declaration and the qualification records are those of the build being
   released.
4. The final CLI prints the build's model list:
   `<cli> cluster runtime-facts --list-release-models`. It holds every model
   with a cluster stage adapter and a passing pair qualification record in the
   build (`ClusterRuntimeApprovalFacts.releaseModels`).
5. `scripts/provider-cluster-runtime-models.py --environment <env>` reads the
   public catalog and model CDN of the lane's environment, the ones its app
   reads (`provider-swift/identity/provider-identity.json`). For each listed
   artifact it fetches the `manifest.json` encodings the provider reads (CDN,
   then coordinator) and `config.json` from the CDN, never weights, and saves
   the catalog entry's `id` and `input_modalities` beside them
   (`catalog.json`). A listed model that catalog does not have is left out and
   named in the job summary. Any other fetch or integrity failure fails the
   step.
6. The final CLI computes the facts:
   `<cli> cluster runtime-facts --app <app> --release-candidates <folder>`. The
   app's own worker describes each candidate (`--describe-runtime`); every
   catalog model ID of a listed artifact that it describes as the listed model
   gets one entry, with its pair-serving grant. A declared model gets one
   parity qualification per declared family and schedule; a tensor-parallel
   envelope admits the media its catalog entry lists, a pipeline's text only. A
   declared pipeline whose `config.json` has no layer count is left out and
   named on standard error, in the job log. One artifact can be two registered
   models that only the manifest tells apart (production lists `gemma-4-26b`
   and `gemma-4-26b-8bit` for one artifact): a catalog model ID whose
   candidates the worker describes only as another registered model is that
   model's, so it is left out and named on standard error too. The step fails
   when the worker describes no candidate of a catalog model ID of a listed
   artifact at all, when no model is left, or when an ID a coordinator would
   derive exceeds 128 bytes.

The steps `Show the cluster runtime facts` and `Retain the cluster runtime facts`
then write the block (or the failure) to the job summary and upload
`cluster-runtime-<environment>-<SOURCE_SHA>-<ATTEMPT>` (30 days), in every lane
and whether or not the block is sent.

Whether the payload carries the block is decided by one repository variable per
environment. The job reads it as `CLUSTER_RUNTIME_SEND`, which is `true` only
when the run registers a release and the variable is set to `true` (GitHub
compares the strings case-insensitively, so `True` counts too):

| Variable | Lane | Unset or not `true` | `true` |
|---|---|---|---|
| `DEV_CLUSTER_RUNTIME_ENABLED` | dev branch (`release-dev-branch.yml`) | The payload is byte for byte the same as without this feature; a failure of the facts step only warns (`continue-on-error`) and the release continues | `prepare --cluster-runtime <file>` adds the block; a failure of the facts step fails the release before staging and registration |
| `STAGING_CLUSTER_RUNTIME_ENABLED` | staging (`release-swift.yml`, master push) | as above | as above |
| `PROD_CLUSTER_RUNTIME_ENABLED` | prod (`release-swift.yml`, tag) | as above | as above |

Staging publication is refused today ("Unknown publication environment": no
staging coordinator yet), so `STAGING_CLUSTER_RUNTIME_ENABLED` takes effect once
staging publishes. `validate` (in `prepare`, `stage` and `publish`) accepts a valid block in any
environment and refuses an invalid one, and one whose derived IDs
(`release/<version>/<model>/s<1|2>`, `<approval ID>/grant` for a model with a
grant, and `<approval ID>/q<n>` for each parity qualification) exceed 128
bytes. It also refuses a payload whose registration body (the bytes
`POST /v1/releases` sends, block included) exceeds the coordinator's 64 KiB
limit (`MaxReleaseRegisterBodyBytes`), so an oversized body stops before
staging. `prepare` also refuses a block file that is not canonical, and
registration sends the block in that canonical form (a body without the block
is sent exactly as before).

With the variable set to `true`, a failure of the facts step stops the release
before `prepare`, so nothing is staged or registered. Fix the cause (for
example a catalog or CDN outage) and re-run the failed job, or first set the
variable to anything but `true` to release without the block; for a tag, sign
again with
[Resume Signing From A Retained Unsigned Build](#resume-signing-from-a-retained-unsigned-build).

Turn a variable on only after the coordinator of that environment accepts the
block (darkbloom-platform#643); a coordinator that does not accept it yet must
never receive it. It derives approvals from the block only with
`EIGENINFERENCE_CLUSTER_PAIR_APPROVALS_FROM_RELEASES=true`. Public cluster
routing also needs `EIGENINFERENCE_CLUSTER_PUBLIC_ROUTING=true` on that
coordinator, and a coordinator behind a TLS-terminating proxy attaches members
only through `EIGENINFERENCE_CLUSTER_PAIR_TRUSTED_TLS_PROXIES`.

Before a release with the block registers, make sure the coordinator's catalog
has room. It holds at most 64 approvals (the operator's per-build and per-model
approvals included), 64 pair-serving grants and 256 parity qualifications. A
release adds 2 approvals per model of its block (and up to 2 grants and 8
qualifications per model). Releases are taken newest first, each whole: a
release that would pass a bound is left out, so older releases' entries drop
first, and the operator's entries are never displaced
([`NativeRuntimeCatalogWithReleases`](https://github.com/Layr-Labs/darkbloom-platform/blob/df61dd6f93714b4458d0eef3125c377087c08b52/coordinator/registry/cluster_release_approvals.go)).
When the catalog is short, prune the hand-posted per-build approvals of retired
builds. After the first registration, check the coordinator log: the warning
`release cluster approvals omitted` names a release left out and why, and
`cluster pair catalog replaced` reports `approvals` and `omitted_releases`;
`GET /v1/cluster/approvals` lists the derived `release/<version>/<model>/s<1|2>`
approvals. On DevNet on 2026-10-31 the coordinator served 26 approvals (25
per-model and 1 per-build) and the catalog listed 4 models, so each dev-branch
release adds 8 approvals: the 4 newest releases fit (58 of 64) and a fifth is
left out. Check the production catalog the same way before
`PROD_CLUSTER_RUNTIME_ENABLED` is set.

Rollout order:

1. The platform change merges to the platform's `dev`, and DevNet deploys it.
2. A person makes room in DevNet's catalog, if needed, and sets
   `DEV_CLUSTER_RUNTIME_ENABLED=true`.
3. This change merges to `dev`. The next dev-branch release registers with the
   block; check the coordinator log for an omitted release. A pair registers by
   itself after it updates.
4. Production follows in this order, without waiting for a DevNet proof; each
   step is a separate approval:
   1. The production coordinator deploys with darkbloom-platform#643 and
      migration 58, and with `EIGENINFERENCE_CLUSTER_PAIR_APPROVALS_FROM_RELEASES=true`,
      `EIGENINFERENCE_CLUSTER_PAIR_TRUSTED_TLS_PROXIES=127.0.0.1,::1` and
      `EIGENINFERENCE_CLUSTER_PUBLIC_ROUTING=true` in its settings.
      `EIGENINFERENCE_CLUSTER_PAIRS` stays unset, so approvals derived from
      releases are the only source. Its `/health` `build_commit` must be that
      revision.
   2. A person checks the production catalog's room and sets
      `PROD_CLUSTER_RUNTIME_ENABLED=true`.
   3. The release tag follows.
   4. After the registration, `GET /v1/cluster/approvals` lists the release's
      derived approvals, `release/0.10.6/<model>/s<1|2>` for 0.10.6, and the
      coordinator log has no `release cluster approvals omitted` for it. The
      pair-serving grants (`<approval ID>/grant`) and parity qualifications
      (`<approval ID>/q<n>`) derived beside them are not on that list: a pair
      that forms under a derived approval shows its qualification as
      `qualification_id` in its owner's
      [`GET /v1/me/cluster-pairs`](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/api-contracts.md#owner-cluster-views).

   Keep the order. A coordinator without #643 refuses a registration that
   carries the block, so the release fails after signing. A version whose
   first registration carries no block never gains one: a re-registration must
   repeat the stored block, and the coordinator answers any other with 409
   `cluster_runtime_conflict`. So if 0.10.6 registers while
   `PROD_CLUSTER_RUNTIME_ENABLED` is not `true`, it derives no approvals at
   all, and only a later version can carry the block.

To compute the facts of an installed or downloaded app by hand, give the models
explicitly. Run that app's own CLI, so the public declaration and the records
are that build's. A model given by hand has no catalog entry, so a declared
model's request envelope then admits text only:

```bash
"/Applications/Darkbloom.app/Contents/MacOS/darkbloom" cluster runtime-facts \
  --app /Applications/Darkbloom.app --model Qwen3.5-9B=/path/to/Qwen3.5-9B-folder
```

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

Deactivation stops new installs only: a Mac already on the bad release stays on
it, because the updater never installs an older version. A provider who needs
the previous release on a Mac now runs `darkbloom update --rollback` there
([roll back](../provider/installation.md#roll-back-to-the-previous-release)). It
restores the release the updater kept when it installed the bad one and
quarantines the bad one on that Mac, contacts no coordinator, and leaves
automatic updates on, so the fixed patch version installs normally.

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

The cluster service LaunchAgent must include `AssociatedBundleIdentifiers`
for the installed app. Verify the normal `darkbloom cluster` flow after both
setup terminals exit, including leases and an outbound follower connection on
each Mac. A foreground CLI check does not qualify background Local Network
access. Keep the signing identity consistent across builds and retain final
post-signing executable hashes.
