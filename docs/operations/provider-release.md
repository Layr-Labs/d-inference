# Release A Provider Version

> Last updated: 2026-10-28

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

`ProviderCore.version` is prepared as `0.10.4`, a patch release over `v0.10.3`.
A Qwen 3.5, 3.6 or 3.8 request with a JSON `response_format` and no thinking
control answers without thinking, and on `qwen3_5` and `qwen3_5_moe` text
requests without tools the answer is grammar-constrained. Qwen3.5-9B,
Qwen3.5-35B-A3B, Qwen3.6-35B-A3B and MiMo-V2.6-Flash advertise forced
`tool_choice`. A request that restored a Qwen native recurrent complete
checkpoint writes its later checkpoints as deltas. A signed local add-on such
as the Darkbloom Sandbox can hold the provider, which stays connected, leaves
routing and unloads its models.
`darkbloom status` and `darkbloom doctor` say why a connected provider gets no
coordinator work, the provider re-registers a connection the coordinator leaves
unauthorized, and a stalled coordinator reconnect fails after 30 seconds and
retries. `darkbloom stop` finishes without a coordinator session,
`darkbloom status` says what its served counts cover, and `darkbloom switch`
scans the configured model cache. The MLX pins are unchanged from 0.10.3. The
entry also records desktop app, CI, landing and documentation changes that build
no provider artifact. See the [`v0.10.4` changelog entry](../../CHANGELOG.md)
for the full scope.

Before tagging `v0.10.4`:

- Confirm that the tagged commit still pins `libs/mlx-swift` to `4926d3d9` and
  `libs/mlx` and the nested `mlx` to `31f550af`, the heads of the mlx-swift and
  mlx branches `hotfix/0.10.2-jit-nax-dsplit`, and `libs/mlx-swift-lm` to
  `aee6ebb6`, the head of SDK `main`. Neither fork's `main` contains its pinned
  commit, so keep both hotfix branches.
- With those pins the tag build's `metallib_hash` should equal v0.10.3's
  `6ccc62966bb452b767fbd7261175b06c7653259a25f657524f1c1ef71f556d45`. The
  `bin/mlx.metallib` in the `v0.10.2` bundle, built before 0.10.3's MLX fix
  (C++ only), has the same hash. A different hash needs an explanation, such as
  a changed Metal toolchain.

Roll out in this order; each step is a separate approval:

1. Shortly before the tag, deploy a `darkbloom-platform` coordinator that
   includes [darkbloom-platform#516](https://github.com/Layr-Labs/darkbloom-platform/pull/516),
   [#491](https://github.com/Layr-Labs/darkbloom-platform/pull/491) and
   [#541](https://github.com/Layr-Labs/darkbloom-platform/pull/541). #516's
   prompt sidecar plans a Qwen JSON `response_format` without thinking, as
   0.10.4 renders it. While a provider and the coordinator disagree, that
   provider's Qwen JSON requests without a thinking control fail their cache
   receipts with `prompt_anchor_mismatch`, and each failure quarantines its
   cache affinity for the whole model for up to 10 minutes; serving is
   unaffected. #491 repeats a refusal every 5 seconds while App Attest serving
   is on, and #541 tells a legacy Mac when its first passing challenge
   authorizes it; 0.10.4's `Traffic:` line and re-registration act only on
   that current evidence.
2. Tag `v0.10.4` ([step 4](#4-tag-and-push-production-source)).
3. The platform snapshots its provider contracts from the tagged commit
   (`python3 scripts/provider-contracts.py snapshot <tag commit>`), sets
   `LatestProviderVersion` to `0.10.4` in the coordinator's
   [`server.go`](https://github.com/Layr-Labs/darkbloom-platform/blob/5ba280d89aa5e9bd4fbf05e0dfa848059cd3b585/coordinator/api/server.go)
   in the same change and adds the revision row to its
   [provider-contract reference](https://github.com/Layr-Labs/darkbloom-platform/blob/5ba280d89aa5e9bd4fbf05e0dfa848059cd3b585/docs/reference/provider-contracts.md).
   Of the snapshotted inputs, only `contracts/provider/ProviderCore.swift`
   should change: the prompt vectors are unchanged since `a8556957`, the
   revision the platform already pins. `LatestProviderVersion` is a fallback
   and does not gate publication.

No provider-version floor is needed. Coordinators send forced `tool_choice` only
to providers that advertise it, and only 0.10.4 providers advertise it for those
four models. The add-on hold's coordinator side,
[darkbloom-platform#514](https://github.com/Layr-Labs/darkbloom-platform/pull/514),
is already in production.

0.10.2's remaining enablement steps do not wait for this tag and still apply;
each is a separate approval:

1. Add GLM-5.3-Flash's tuple to the coordinator's cache-routing allowlist. GLM's
   SSD reuse was qualified on a signed `0.10.1` provider, and the coordinator
   must include request normalization v9.
2. After the fleet converges on `0.10.3` or later, list `logprobs` in
   GLM-5.3-Flash's catalog row. Once a signed `0.10.3` or later build also
   restores Nemotron 3.5 Super's SSD checkpoints after a restart, add Super's
   tuple to the allowlist and list `logprobs` in Super's catalog row.

Catalog changes, allowlist changes and model registration are separate
approvals. This preparation does not tag, register, upload, deploy or enable
anything.

Platform evidence, inspected on 2026-10-27 (recheck before tagging):

| Claim | Source |
|---|---|
| Production runs platform `master` `2acffb5c`, which includes darkbloom-platform#514 and #464's `0.10.2` logprobs floors but not #516, #491 or #541 | `/health` `build_commit`; [`modelarch/logprobs.go` at `2acffb5c`](https://github.com/Layr-Labs/darkbloom-platform/blob/2acffb5c301547b085b846adbc2a3fed95fafb2c/coordinator/internal/modelarch/logprobs.go) (`LogprobsMinimumProviderVersion`); #514 merged as `6259c9dc`, #516 as `5a779a11`, #491 as `809d2366` and #541 as `6beb8514` |
| #516 plans a Qwen JSON `response_format` without thinking | [`normalize.rs` at `5a779a11`](https://github.com/Layr-Labs/darkbloom-platform/blob/5a779a113b3874bf06f597f6c4107a4d08103a6f/coordinator/promptsidecar/src/normalize.rs) (`template_additional_context`) and [`response_format.rs`](https://github.com/Layr-Labs/darkbloom-platform/blob/5a779a113b3874bf06f597f6c4107a4d08103a6f/coordinator/promptsidecar/src/response_format.rs) (`requires_json_output`) |
| A `prompt_anchor_mismatch` quarantines the provider's cache capability for that model: 60 s, doubling on repeats up to 10 min | [`registry/cache_quarantine.go` at `2acffb5c`](https://github.com/Layr-Labs/darkbloom-platform/blob/2acffb5c301547b085b846adbc2a3fed95fafb2c/coordinator/registry/cache_quarantine.go) (`CacheQuarantineCommit.Apply`) and [`cachetracker/proofs.go`](https://github.com/Layr-Labs/darkbloom-platform/blob/2acffb5c301547b085b846adbc2a3fed95fafb2c/coordinator/internal/registry/cachetracker/proofs.go) (`ProofFenceBase`, `ProofFenceMax`) |
| #491 repeats an unauthorized connection's `trust_status` every 5 s while App Attest serving is on; #541 sends one when a verdict changes its `authorization.path` | [`serving_diagnostic.go` at `6beb8514`](https://github.com/Layr-Labs/darkbloom-platform/blob/6beb851488e08b3fc950b46f5002a502c4fcc9d4/coordinator/appattest/service/serving_diagnostic.go) (`startUnauthorizedStatusRefresh`) and [`trust/status.go`](https://github.com/Layr-Labs/darkbloom-platform/blob/6beb851488e08b3fc950b46f5002a502c4fcc9d4/coordinator/api/provider/trust/status.go) (`notifyServingAuthorizationChange`) |
| The provider-contract snapshot pins d-inference `a8556957`, and its 34 inputs equal those of this preparation except `ProviderCore.swift` | [`contracts/provider/manifest.json` at `5ba280d8`](https://github.com/Layr-Labs/darkbloom-platform/blob/5ba280d89aa5e9bd4fbf05e0dfa848059cd3b585/contracts/provider/manifest.json) (`source_revision`) |
| Forced tool choice goes only to advertising providers | [`registry/tool_constraints.go` at `2acffb5c`](https://github.com/Layr-Labs/darkbloom-platform/blob/2acffb5c301547b085b846adbc2a3fed95fafb2c/coordinator/registry/tool_constraints.go) (`providerSupportsToolConstraintLocked`) |
| A model without an allowlisted tuple gets no cache routing | [`cache-routing-rollout.md` at `9d44e01e`](https://github.com/Layr-Labs/darkbloom-platform/blob/9d44e01eb0d4f6052f2be471b8107b94754c5c3e/docs/operations/cache-routing-rollout.md) ("Add GLM-5.3-Flash", "Add Nemotron 3.5 Super") |
| `LatestProviderVersion` must equal the snapshotted `ProviderCore.version` | [`provider_version_sync_test.go` at `5ba280d8`](https://github.com/Layr-Labs/darkbloom-platform/blob/5ba280d89aa5e9bd4fbf05e0dfa848059cd3b585/coordinator/tests/api/provider_version_sync_test.go) (`TestLatestProviderVersionMatchesProviderCore`) |

`v0.10.3` was [published on 2026-10-26](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.3)
from `3ddd11ce8d7204cc5aadefd2050376c583da4ff8`, `v0.10.2` was
[published on 2026-10-26](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.2)
from `f9d1af3d0d3e1838974a5cfdff0a08142977b45e`, `v0.10.1` was
[published on 2026-10-24](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.1)
from `9034a5a0f3526dec83ab6384e5264db595cb7549`, and `v0.10.0` was
[published on 2026-10-23](https://github.com/Layr-Labs/d-inference/releases/tag/v0.10.0)
from `1ef9c89f465ba1299b4938c2b0359e9ae33ed454`. Publication does not establish
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
breaks and paragraph spacing remain unchanged.

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
`qualify-sdk` sets `DARKBLOOM_RELEASE_ENVIRONMENT: prod`, so its tests see
production defaults on every branch: on `dev`, an unset value compiles the dev
identity (`provider-swift/Package.swift`). Config, CLI flags and
`DARKBLOOM_R2_CDN_URL` still override defaults. Dev/prod products have different
cache keys, and packaged smoke must report the selected build environment.

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
| Source gate | Job `resolve-env` runs master's copy of `scripts/provider-release-resume.py verify-source`. The gate must accept a `refs/heads/dev` push for environment `dev`; until master carries that change, the lane fails at the gate. |
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

Review is not enforced on `dev` today. Its rules are required signatures and the
"Darkbloom PR access control" ruleset, which lets only the accounts on that
ruleset's bypass list create or update a ref. Because a dev push gets the
Developer ID signature, `dev` needs a pull_request rule before the lane runs. A
repository administrator adds that rule.

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
| 6 | Dev only: compute the [cluster runtime facts](#dev-cluster-runtime-facts) from the final archive |
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
| 5 | For prod/tag, create or resume a GitHub draft, upload a missing asset, verify downloaded bytes and publish |

The payload contains `version`, `platform=macos-arm64`, `backend=mlx-swift`,
`binary_hash`, `bundle_hash`, `metallib_hash`, `code_directory_hash`,
`source_commit`, `ci_run_id`, `require_app_attest_qualification=true`, `url`
and `changelog`. A dev payload also contains `cluster_runtime`; a prod or
staging payload never does. The URL is the configured CDN followed by
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

### Dev Cluster Runtime Facts

A dev release registers the cluster runtime facts of its final signed app as
`cluster_runtime`. The dev coordinator derives its cluster approvals from them;
the block format and its rules are in the
[configuration reference](../reference/configuration.md#cluster-runtime-facts-of-a-dev-release).
The step `Compute dev cluster runtime facts from the final signed app` of job
`build-and-release` runs only when the environment is `dev`:

1. It runs after notarization, stapling and the final-archive checks, and before
   `prepare`.
2. It reads no secret. It removes the two secret-derived values in the job's
   `GITHUB_ENV` (`r2_public_url`, `coordinator_url`) and deletes the signing
   keychain before any release code runs. The step fails unless the keychain
   file is gone and `security find-identity -v -p codesigning` no longer lists
   `$DEVELOPER_ID`. The release CLI runs with an empty environment (`env -i`).
3. It checks the archive against `BUNDLE_HASH` and extracts it into a new folder.
   Steps 4 to 6 are `scripts/provider-cluster-runtime-facts.sh`.
4. The final CLI prints the build's model list:
   `darkbloom-dev cluster runtime-facts --list-release-models`. The list holds
   every model with a cluster stage adapter and a passing pair qualification
   record in the build (`ClusterRuntimeApprovalFacts.releaseModels`).
5. `scripts/provider-cluster-runtime-models.py` reads the public model catalogs
   of the dev and prod coordinators and fetches, for each listed artifact, the
   `manifest.json` encodings the provider reads (CDN and coordinator) and
   `config.json` from the CDN. It never reads weights. It fails when a listed
   model has no metadata.
6. The final CLI computes the facts:
   `cluster runtime-facts --app <app> --release-candidates <folder>
   --require-model Qwen3.5-9B --require-model glm-5.3-flash`. The app's own
   worker describes each candidate (`--describe-runtime`). The step fails when a
   listed model has no candidate that the worker describes as that model, or
   when a required model is missing. One exception holds until the GLM manifest
   repin lands: when the worker refuses every candidate of `glm-5.3-flash`
   (`registered_glm53_flash`, `ClusterRuntimeApprovalFacts.softReleaseModels`),
   the block leaves it out, and the step writes a `::warning::` annotation and a
   step-summary line with the model, its runtime ID and the reason. A fetch or
   integrity failure of `glm-5.3-flash` still fails the step.
7. `prepare --cluster-runtime <file>` adds the block to `release-payload.json`.
   `validate` refuses a dev payload without a valid block, a block whose derived
   approval IDs (`release/<version>/<model>/s<1|2>`) exceed 128 bytes, and a
   prod or staging payload with a block.

Before merge, the release lane of the pull-request build (workflow
`SDK 27 release preparation`, job `SDK 27 release`, step
`Describe the qualified cluster models with the built app`) runs the same
script on the unsigned app it built, so a pull request that changes the facts
code shows that its worker describes every qualified model. That build is not
signed and publishes nothing.

To compute the facts of an installed or downloaded app by hand, give the models
explicitly:

```bash
darkbloom cluster runtime-facts --app /Applications/Darkbloom.app \
  --model Qwen3.5-9B=/path/to/Qwen3.5-9B-folder
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
