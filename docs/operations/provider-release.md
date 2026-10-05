# Release a provider version

> Last updated: 2026-10-03

Runbook for shipping a new `darkbloom` provider CLI: bump the two version
constants, land the changelog, push a `vX.Y.Z` tag, approve the `prod`
environment, and let [`.github/workflows/release-swift.yml`](../../.github/workflows/release-swift.yml)
build, sign, notarize, retain, stage and register the bundle. The coordinator
re-downloads artifacts and requires independent App Attest qualification before
activating a production release. Staging/publication failures retry the retained
artifact; GitHub and R2 publication are separate recoverable steps.

The macOS signing and older-OS smoke jobs install the checksum-pinned GitHub CLI
with `scripts/install-macos-github-cli.sh` before downloading retained artifacts.
A `gh: command not found` error in an older run is runner setup failure before
artifact verification, not a failed model test or notarization rejection. A
retry of that old workflow still uses its original source. For an unchanged
candidate with successful build and SDK qualification, merge the tooling fix
and use the retained unsigned recovery path below.

The **0.9.17** candidate separates normal model selection from Autopilot's
verified cached inventory using protocol 3. Version preparation does not publish
the release; tag only the reviewed merged commit and qualify the retained signed
artifact before production registration. Validate a one-model selection with
additional cached models: waiting/shadow enrollment must not load those models,
change preload or memory policy, or expose them as serving models in My Macs.
Check explicit overrides, scheduled windows, and selected-model successor updates.
An older coordinator keeps ordinary selected-model serving while protocol 3 waits;
a compatible coordinator restores full separate-inventory shadow planning.
A live lease alone must not load anything: an explicit placement command owns
its target publication and memory-reserve transition. See the
[Autopilot rollout gates](model-autopilot.md).

Released **0.9.16** repairs enrolled-daemon status, graceful lifecycle
control and watchdog health observation. Its schema-1 state files write detailed
Autopilot data under `autopilot_state`, leaving the old optional `autopilot` key
absent so a still-running 0.9.15 watchdog can read the candidate heartbeat. New
readers accept both layouts. Qualify the upgrade with consent already recorded:
confirm status, graceful restart and promotion after the full stabilization
window, including when the watchdog process predates the update. A newer release
can recover machines that quarantined 0.9.15 without overriding quarantine.
Also verify a busy model update produces a prompt retry message during inventory
verification and preserves the running daemon and recorded selection.

The **0.9.15** release added automatic idle native MiMo
calibration through the actual serving engine; see
[calibration behavior](../architecture/first-content-routing.md#automatic-mimo-calibration).
On the exact signed artifact, verify short/4k phase observations reach capacity
heartbeats, customer requests on any model preempt calibration until real
retirement, original deadlines remain anchored, and probe work is excluded from
served-request/token counters. Compare utilization and capacity/deadline
refusals under real traffic without expanding memory or concurrency limits.

It retains native MiMo text-prefix SSD caching enabled by default since the
0.9.14 candidate; the exact model identities and rollback controls are in
[prefix-cache policy](../architecture/prefix-cache.md#mimo-complete-state).
Qualify the exact signed build with an ordinary launchd configuration: record a
cold text request, a useful repeated-prefix donation and an authenticated SSD
restore, including target/assistant output correctness and memory headroom.
Verify image, audio and video requests still complete through the joint native
path without reporting media-prefix reuse. Set `DARKBLOOM_MIMO_COMPLETE_PREFIX=0`
and rerun the replacement `darkbloom start` flow, preserving the selected models
and existing start options, then repeat with `DARKBLOOM_PREFIX_CACHE=0`.
Replacement start drains the old process, rewrites its plist from the current
shell environment and starts the provider; `darkbloom restart` reuses the saved
plist and does not apply newly exported variables. Verify each replacement
provider serves cold, then unset both overrides and repeat replacement start
to restore the model default. RAM
retention and experimental paging/rectangular verification stay off for this
qualification. The source change does not qualify those runtime results.

The MiMo memory/media fixes carried forward from 0.9.13 are collected in
[`CHANGELOG.md`](../../CHANGELOG.md). Qualify the signed build
on a 256 GiB host both with MiMo alone and with another model resident:
confirm a positive usable token budget, successful inference, bounded memory
pressure, and correct concurrency reduction or load refusal when grants shrink.
Include base64 PNG, EXIF JPEG, silent H.264 MP4 and combined image/video
requests through the authenticated API. Include the standard PCM8/22050 Hz audio
case and the OpenRouter MP4 with stereo AAC audio; verify native audio
tokenization, generation and reservation cleanup. Check both on/off
`chat_template_kwargs.thinking` aliases and tool-return reasoning history.
Deploy the matching coordinator prompt normalizer before enabling the new
request shapes across the provider fleet.
Compare 30- and 300-source-frame clips
with the same sampled frame count; record actual peak process memory and usable
KV headroom, and confirm terminal reservation cleanup. Local tiny-weight
inference and decoder tests cover the path but do not qualify the full artifact.
The source change does not itself establish those live-serving results.
Cache rollout steps are in [`cache-routing-rollout.md`](cache-routing-rollout.md).
The 0.9.10 rollout order below applies unchanged: the new inference-request
field is optional in both directions. The version bump prepares the source for
the provider bundle. Publication and coordinator deployment remain separate
operations; the bump alone does not change the registered release returned by
`GET /v1/releases/latest`.

For cache-recovery qualification, exercise foreground downloads and background
prefetch with a dangling model-directory symlink: the original link is retained
as a hidden sibling, and verified weights publish into the selected cache.
Confirm valid external-directory links still receive downloads. See
[model download behavior](../provider/cli-reference.md#darkbloom-models-download-id).

Keep `ProviderCore.version` in
`provider-swift/Sources/ProviderCore/ProviderCore.swift` as the concise release
identity. Record release history in `CHANGELOG.md`;
`scripts/check-release-version.sh` checks parity with the coordinator display
fallback before packaging.
The release Metal cache namespace also binds the prepared downloadable compiler's
binary SHA, so an exact outer-cache hit cannot prevent publishing a library built
with a newly installed Metal component.

Production publication requires independent [durable App Attest build qualification](app-attest-build-qualification.md). Signing retains immutable bytes and a qualification template; a separate Linux staging job uploads those retained bytes to R2, and the Linux publication job verifies approval before release registration, R2 latest aliases and GitHub publication. Retry only the failed publication job after approval, preserving the original signed artifact. Deploy the matching coordinator first; the existing release key cannot approve builds.

### 0.9.10 rollout order

1. Merge the version bump, then verify Release Integrity, Provider Tests,
   Provider SDK Tests, Provider Prompt Parity,
   Coordinator Tests, E2E Integration Tests, and both SDK 27 release-preparation
   lanes on the final source. Build-cache success and a source version bump are
   neither signed-bundle qualification nor publication.
2. Verify the updated console is live **before** the coordinator swap. The new
   owner UI accepts either coordinator response, but old browser bundles call
   `score.toFixed()` and cannot consume the new response without a reload.
   The new public model-demand view reports unavailable against the old
   coordinator; after the swap it can have partial or no publishable history.
   Do not infer zero demand from an empty panel.
3. Prepare the human-approved coordinator swap using
   [the coordinator runbook](coordinator-deploy.md). Pin the current image digest
   and new `master` commit, check database locks, and account for startup creation
   of `app_attest_key_rotations`, `model_demand_requests`,
   `model_demand_hourly`, `model_demand_collection`, and the hourly rollup
   trigger. Coordinator-driven dead-key rotation defaults to a 100% account
   cohort; an approved staged rollout can set
   `EIGENINFERENCE_APP_ATTEST_KEY_ROTATION_PERCENT=10` **before** the swap and
   raise it only after observing rotation and fresh-key verification. No env or
   production mutation is performed by this release PR.
4. Deploy the coordinator before 0.9.10 providers use the new
   `models_replace` / `models_replace_ready` / `models_replace_resumed` contract.
   The swap disconnects the in-process provider registry. Confirm the exact
   `/health.build_commit`, continuing 0.9.9 release registration, 0.9.9
   provider reconnection and completed encrypted requests; separately compare
   authorization for the previously serving cohort, App Attest and legacy
   verification, APNs push replies, rotation outcomes, queueing, and 5xx.
   Preserve existing build approvals and rollback image. The additive demand
   tables remain after a coordinator rollback; collection starts only with
   qualifying new observations and public history is delayed and suppressed.
5. Tag the reviewed merged source as `v0.9.10`. Let the release workflow build,
   sign, notarize and stage immutable bytes. This may overlap coordinator
   preparation, but hold production publication until the upgraded coordinator
   and exact-artifact qualification are ready.
6. Qualify that signed bundle on macOS 27 and a supported older macOS. Exercise
   App Attest authorization and failure diagnostics, dead-key and enrollment
   recovery, APNs proof refresh after a release reconnect, live model switching
   with its same-session routing receipt, and explicit model-cache selection
   without moving existing stores. Verify encrypted inference, local serving,
   streaming and non-streaming drain, restart, scheduled windows, and terminal
   accounting on the exact signed artifact. Use an isolated qualification
   coordinator before production registration: registration advances the fleet
   updater, not a canary-only channel. Record the evidence using the
   [build qualification runbook](app-attest-build-qualification.md); the prod
   tag workflow does not run the older-macOS validation-only job.
7. Approve the exact 0.9.10 build and **Publish qualified signed release**.
   Registration, R2 latest aliases and GitHub publication must all complete
   using the retained signed bytes. Keep earlier build approvals active during
   adoption. Verify `/v1/releases/latest`, install/update metadata, actual
   completed requests by version, authorization cohorts, switch receipts,
   App Attest freshness, disconnects, and earnings. Console publication and
   provider publication are separate operations.

The drain implementation lives in `provider-swift/Sources/darkbloom/ServiceDrain.swift`
(`ServiceDrain`) and `coordinator/internal/provider/session/provider_completion_barrier.go`
(`providerCompletionBarrier`). See [CLI lifecycle behavior](../provider/cli-reference.md)
for normal timeout and explicit-force semantics.

### Flash resource recovery rollout

The 0.9.6 candidate fixes the native Qwen Metal resource lookup inside the signed app. Keep resources in `Contents/Resources`; do not repair an installed signed bundle by copying files into its root. Require `qwen4-metal-resources-runtime-smoke: ok` from the staged and final extracted app. After publication, verify a real Flash model load, a completed request, and a positive live token budget separately.

Deploy the coordinator containing the native SSD-offload capacity accounting and the `qwen3.8-flash-next` provider floor of 0.9.6 as a separately approved operation. An older coordinator can understate cold capacity; fixing app resources alone does not deploy that accounting. Preserve the advertised 262144-token context and the physical memory guards.

### MDM-optional onboarding candidate

The installer and `darkbloom enroll` select App Attest setup on macOS 27+ without
requesting an MDM profile. Older macOS keeps legacy enrollment and sees the
upgrade/upcoming deactivation notice. Follow the
[MDM-optional rollout runbook](mdm-optional-rollout.md) to coordinate the embedded
installer, signed provider, setup page and serving cohort. A disabled or
unqualified coordinator leaves new macOS 27+ providers pending; the notice does
not activate serving or retire legacy verification.

### App Attest recovery rollout

Follow [the App Attest rollout runbook](app-attest-rollout.md). The release
retains APNs/MDM and the existing OS floor. The fixed provider alone does not
reactivate shadow checks; the coordinator also needs the explicit cohort settings.

The optimized `runtime-smoke` command must emit the App Attest callback,
Gemma configuration and paged-kernel success markers. The release workflow
checks these before signing and after extracting the final notarized archive.
The signed `app-attest-callback-v1` capability marker makes the installer and
self-updater require the callback success marker while preserving acceptance
of older bundles without that capability. See `AppAttestRuntimeSmoke.run` in
`provider-swift/Sources/ProviderAppAttest/AppAttestRuntimeSmoke.swift`.

Final notarization, install/update and older-OS APNs/MDM qualification remain
release checks. The local [crash investigation](../reports/2026-09-14-app-attest-release-disconnects.md)
is evidence for the original callback-timer defect, not proof that every fleet
cohort has passed the expanded replacement policy.

### Previous provider-only 0.9.2 rollout

A coordinator binary upgrade is not required solely to register 0.9.2. The
0.9.1 coordinator already validates and stores the release, refreshes active
binary/metallib trust, preserves other active releases and serves the new
version through `GET /v1/releases/latest`. `LatestProviderVersion` is a display
fallback, not an exact-version admission pin (`coordinator/api/releases/release_handlers.go`,
`HandleRegisterRelease`; `coordinator/api/server.go`, `SyncBinaryHashes` and
`SyncRuntimeManifest`).

The 0.9.2 assistant transition uses existing slot state `reloading`, capacity
quotes and 503 `slot_state` refusals; accepted requests keep their old engine
until the swap (`provider-swift/Sources/ProviderCore/ProviderLoop+MTPDrain.swift`,
`beginMTPUpgradeDrain` and `rejectIfDrainingForMTP`). It can temporarily reduce
Gemma capacity. Rollout jitter spreads attempts but does not guarantee fleet
headroom. Coordinator warm-pool headroom changes are a separate deployment.

Before fleet publication, complete the outstanding checks in the
[0.9.2 rollout review](../reports/2026-09-10-provider-092-rollout-review.md)
on the exact signed candidate against the existing coordinator. Verify mixed
0.9.1/0.9.2 trust, real requests during assistant download/drain/swap, cache
identity changes and restart. Preserve existing cache-routing controls: local
Gemma SSD reuse does not enable coordinator holder selection, and HF-first
assistant downloads require the separate catalog metadata update.

After an approved provider-only publication, verify the registered version
and actual inference separately. `/health` should retain the previous
coordinator `build_commit`; its build `version` can remain 0.9.1 while
`/v1/releases/latest` returns 0.9.2. Registration exposes the release to
provider auto-update; it is not a limited canary rollout by itself.

For App Attest coexistence, both signing workflows prepare optional profile-authorized grants while retaining APNs. Follow the [shadow packaging contract](../reference/app-attest-shadow.md#packaging-and-qualification); a missing grant is an explicit coverage gap, not permission to remove existing verification.

## Prepare and check release caches

1. After merging release inputs, let **SDK 27 release preparation** complete on
   `master`, or dispatch `.github/workflows/provider-release-cache.yml` on
   `master`. It runs optimized compilation and SDK qualification on separate
   `blacksmith-12vcpu-macos-27` runners, with no signing secrets or publication steps. This seeds
   caches in the default branch's scope, which release tags can restore. PR
   validation caches stay isolated to their PR and do not seed `master`.
   Pipeline shutdown changes run these lanes on their PR as well; the
   [shutdown drain regression](../developer/test.md#sdk-27-release-qualification)
   must pass before retrying a release that failed that assertion.
2. Inspect each lane's **SDK 27 build cache** summary. It reports exact hits and
   the actual Swift restore key; a compatible prefix restore is useful even when
   the exact-hit output is false. Swift and Rust caches are toolchain-specific;
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
[build cache contract](../developer/build.md#sdk-27-release-builds-and-caches) and
[SDK qualification checks](../developer/test.md#sdk-27-release-qualification).

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
[`coordinator-deploy.md`](coordinator-deploy.md).

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

- `provider-swift/Sources/ProviderCore/ProviderCore.swift` — `public static let version = "0.9.15"`
- `coordinator/api/server.go` — `var LatestProviderVersion = "0.9.15"`

```bash
./scripts/check-release-version.sh          # provider == coordinator, semver
./scripts/sync-install-embed.sh check       # coordinator/api/install.sh == scripts/install.sh
```

`check-release-version.sh` accepts an optional expected version
(`check-release-version.sh v0.9.15`) and an optional reported string from a
built binary (`darkbloom 0.9.15` or `0.9.15`); the workflow calls it in all
three forms. CI job "Release Integrity" runs the two commands above on every
push.

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
"Provider SDK Tests", "Provider Prompt Parity",
"Coordinator Tests", and "E2E Integration Tests" must be green. The release
workflow re-runs `scripts/verify-prompt-parity.sh` itself, so a prompt-contract
change that is not fixture-synced will fail the release, not just CI.

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
wrapper. Python 3.12.10 and checksum-verified Rust/CMake bootstraps are explicit;
the older-OS validation job pins `blacksmith-12vcpu-macos-26` so it cannot drift
to macOS 27. Blacksmith hosts the protected signing jobs and receives their
existing signing credentials after environment approval. Publication remains a
separate protected Linux job. See the [runner and cache contract](../developer/build.md#sdk-27-release-builds-and-caches).
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
as described in [build qualification](app-attest-build-qualification.md#steps).
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
`coordinator/api/releases/release_handlers.go`; unknown fields are rejected) contains:

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
  platform (`GetLatestRelease` in `coordinator/store/postgres/`, ordered by
  `releaseVersionGreater` in `coordinator/store/`), not the
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
  `coordinator/api/server.go` via `registry.ProviderCountByVersion`) converge
  over the next hour.
- If the release-policy gate is enforced, confirm evidence for the new binary
  hash is accepted: see
  [`release-policy-rollout.md`](release-policy-rollout.md)
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
- [`coordinator-deploy.md`](coordinator-deploy.md) — shipping the coordinator half of a version bump.
- [`release-policy-rollout.md`](release-policy-rollout.md) — how registered releases feed the routing gate.
- [`../reference/api-contracts.md`](../reference/api-contracts.md) — `/v1/releases/latest`, `/api/version` shapes.
