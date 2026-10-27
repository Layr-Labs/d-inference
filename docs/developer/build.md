# Build The Provider And Landing

> Last updated: 2026-10-27

Build the provider, its source-matched native resources, and the independent
landing site from this repository. Backend, sidecar, console and admin builds
belong to the sibling platform repository.

## Prerequisites

Use sibling `Darkbloom/d-inference` and `Darkbloom/darkbloom-platform` checkouts.
Verify your remote and branch first; do not upload backend code here.
Install the versions in `mise.toml` and initialize recursive submodules:

```bash
mise install
git submodule update --init --recursive
```

Native provider builds require Apple Silicon and the Xcode/Metal toolchain
selected by `scripts/prepare-provider-release-toolchain.sh`. Do not substitute
an arbitrary prebuilt metallib or infer GPU qualification from compilation.
Keep separate worktrees/output directories for independent native builds;
never share an active Swift scratch path or another suite's GPU reservation.

After changing provider authorization summaries, rebuild the provider test
product before running the [authorization guidance tests](test.md#provider-authorization-guidance).
They exercise shared production decisions without invoking status/doctor's
host probes or native Apple operations; signed-release qualification remains
separate.

## Build

```bash
make provider-build
make landing-install landing-build
```

`make provider-build` builds Swift products and stages the metallib through
`scripts/fetch-metallib.sh`. The kernel source is nested under
`libs/mlx-swift/Source/Cmlx/mlx`, matching the Cmlx target. Top-level `libs/mlx`
is a separate dependency pin. Native resources must match the compiled host
library; a warm cache cannot waive that requirement.

The SDK has independent test products under `libs/mlx-swift-lm`; rebuild and
stage their resources as well as the provider test product when validating a
native runtime change. The SDK's `MiMoOpenRouter` media fixtures are test-only
resources, not provider product resources. MiMo provider fixture preparation
uses bounded synthetic weights; the genuine audio codec is a separately
hash-verified input. See [provider and SDK tests](test.md#provider-and-sdk).

Building the GLM5Next target, media, MTP and loader candidates does not
register the architecture with the model factories or provider. Follow the
[prerequisite test procedure](test.md#glm5next-prerequisite-tests); do not use a
successful SDK build as proof of the [complete integration](../design/glm53-flash-native.md).

The GLM official template uses numeric attribute access such as
`content.0.type`, which the pinned Swift-Jinja 2.3.6 does not parse. Builds use
the ordinary locked Swift-Jinja pin with no SwiftPM edit mode or dependency
patch. Our `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp` artifact instead ships a
separately identified template that writes those accesses as `[0]` subscripts.
Its derivation and equivalence evidence are in
`fixtures/prompt-contract/glm53-flash/`. Do not modify ignored build checkouts or
rewrite another artifact's template to hide the parser limitation.

The SSD test working-volume selector is runtime-only fixture configuration;
it does not change the provider cache or Swift/native build inputs. Rebuild
provider test products after fixture-source changes before using `--skip-build`,
then apply the optional directory override at execution time as documented in
[SSD test working volume](test.md#ssd-test-working-volume).

MiMo tool-schema regression checks require a rebuilt provider test product after
source changes. Reuse only an inactive, owned scratch directory with the selected
public gitlinks and locked package graph; record the resulting test executable
identity before any `--skip-build` selection. The [focused fixture recipe](mimo-prompt-fixtures.md#tool-schema-ingress-regressions)
uses metadata and scripted generation, not a substitute native runtime or a
binary copied from a different dependency composition.

Native checkpoint and live-attention precision changes require the matching
provider and SDK pins. Build both test products before the
[checkpoint-storage gates](test.md#native-inference-checkpoint-storage-qualification);
a new CLI alone does not update an old test binary or qualify a checkpoint format.

`landing/` has its own npm lockfile, configuration and API routes. It needs a
Next.js server runtime, not static file hosting. Follow its [README](../../landing/README.md)
for local development; keep production credentials out of builds and tests.

## Electron Desktop App

`make desktop-install`, `make desktop-build`, and `make desktop-package` build
and package the app without publishing. The frontend uses the Swift CLI's local
API. See [desktop development](desktop-app.md) for the isolated preview,
component boundary, and signed release qualification.

For a Developer ID signed desktop DMG with a bundled review API, follow the
[signed local preview procedure](desktop-app.md#signed-local-preview).
`desktop-app/scripts/package-preview.mjs` keeps this build separate from the
regular release app and verifies the bundled API's signing team.

`make desktop-api-test` exercises the real Swift control API against isolated
local fixtures (`scripts/test-desktop-api.py`). The fixture never starts a
serving provider or changes its credentials.

## SDK 27 Release Builds And Caches

Release compilation and SDK qualification use separate
`blacksmith-12vcpu-macos-27` runners. Signed validation's older-OS smoke uses
`blacksmith-12vcpu-macos-26`. The macOS 27 image is a public beta;
`scripts/prepare-provider-release-toolchain.sh` resolves its selected Xcode
after checkout and requires SDK 27.0 and Apple Swift 6.4. Its
`scripts/provider-release-swift.sh` wrapper keeps native SwiftPM compilation
and linking on that SDK. Ordinary development retains the package's Swift 6.3
minimum; release evidence must use the selected release toolchain.

Pinned Python 3.12.10 and checksum-verified CMake 3.31.12 provide missing build
tools. `scripts/prepare-metal-toolchain.py` requires a working compiler probe,
not merely a completed component download. It clears stale discovery state,
waits boundedly for registration, and uses Apple's component export/import
fallback. The specific transient asset-catalog download error gets at most
three attempts within the setup deadline; other failures remain fatal. It
never silently switches to an older Xcode.

Both release lanes call `.github/actions/provider-release-build/action.yml`.
Only optimized compilation transfers an unsigned app, its inventory, SwiftPM
resource bundles and matching metallib to signing. Qualification runs the
provider tests and isolated native gates; restoring a cache never skips them.
Signing verifies the source, version, SDK, inventory and entitlements before
importing its certificate. See [release qualification](test.md#sdk-27-release-qualification).

`scripts/provider-release-cache.py` separates optimized and qualification Swift
caches by compiler/SDK, architecture, absolute checkout/toolchain paths,
dependency pins and build recipe. `DARKBLOOM_RELEASE_ENVIRONMENT` also separates
dev and prod products. A source commit identifies an immutable generation;
compatible restore prefixes never cross these boundaries. The Metal cache
includes nested MLX source, compiler binary SHA and CMake recipe identity.

The cache's `snapshot-mtimes` and `restore-mtimes` commands restore timestamps
only for tracked files whose contents are unchanged. They do not restore source
contents or touch untracked files, links, Git metadata or paths outside the
checkout. Changed/new files rebuild. Runtime resources are restaged and verified
after restoration; archive caching is not permission to reuse stale resources.

`.github/workflows/provider-release-cache.yml` warms both lanes on relevant
`master` changes and release-plumbing PRs. PR caches do not seed `master`; tags
can restore default-branch caches but not another tag's cache. Successful
compilation can save objects even if later qualification fails, while publication
remains blocked. Runner quotas can serialize the two jobs; measure transfer,
build and whole-job time rather than promising a fixed release duration.

`scripts/stage-swiftpm-resource-bundles.sh` restores resource bundles alongside
the selected product without treating an old build-directory layout as a
resource authority. Keep its archive/path checks and source-matched staging;
see [resource and release tooling checks](test.md#focused-tooling-checks).

## CI Runner Routing

`.github/workflows/darkbloom-route.yml` chooses where read-only CI jobs run: a
Darkbloom Sandbox when its plane grants one, otherwise the job's Blacksmith
fallback. It runs on GitHub-hosted `ubuntu-24.04` with no token permissions or
checkout. Each routed job runs on `fromJSON(needs.route.outputs.routes)['<lane>']`.

| Workflow | Routed jobs | Fallback |
|---|---|---|
| `ci.yml` | `release-integrity`, `docs` | `blacksmith-4vcpu-ubuntu-2404` |
| `ci.yml` | `test-provider`, `test-provider-sdk`, `test-provider-parity` | `blacksmith-12vcpu-macos-27` |
| `docs-impact.yml` | `commit-signatures`, `docs-impact` | `blacksmith-4vcpu-ubuntu-2404` |
| `landing.yml`, `desktop.yml`, `nightly-linear-package.yml` | `check`, `frontend`, `test` | `blacksmith-4vcpu-ubuntu-2404` |
| `provider-release-cache.yml` | `warm`, pull requests only | `blacksmith-12vcpu-macos-27` |

Routing is off unless the repository variable `DARKBLOOM_ROUTING` is exactly
`on`. While it is off, and for pull requests from forks, every job keeps its
fallback and the plane is not contacted. When it is on, the route job sends one
`POST /v1/ci/routes` to `DARKBLOOM_SANDBOX_URL` (default
`https://api-sandbox.darkbloom.dev`) for the jobs that will run, retrying at
most once after a transient failure. It uses a grant only when the grant
repeats the exact Darkbloom labels for the job's profile. Errors, timeouts and
malformed replies keep the fallback; the plane never fails the route job.
Release, signing, publication, model registration, review automation,
`cache-swift` and `master` or dispatched cache warming keep literal Blacksmith
labels. The component classifier and the `Provider Tests` gate run on
`ubuntu-24.04`.

Jobs on Darkbloom Sandboxes use GitHub's Actions cache, not Blacksmith's
colocated cache, so their first runs start without cached build products.
Darkbloom Linux sandboxes are ARM64; the Blacksmith Linux fallback is x64. The
decision is fixed for the run: **Re-run failed jobs** reuses it, so turn routing
off and use **Re-run all jobs** to move a run back to Blacksmith. See the
[routing checks](test.md#focused-tooling-checks).

## Dev Build Identity

A dev release build (`DARKBLOOM_RELEASE_ENVIRONMENT=dev`) has its own install
identity, so it runs beside a production provider on the same Mac. A `staging`
release build (`DARKBLOOM_RELEASE_ENVIRONMENT=staging`) is a third environment
with the same shape as dev: its own `darkbloom-staging` identity and the staging
coordinator, built from the same source. It is dispatch-only and does not
publish until its infra and `STAGING_RELEASE_KEY` exist (see
[provider-release.md](../operations/provider-release.md)). The only declaration
of the values is `provider-swift/identity/provider-identity.json`.
`scripts/generate-provider-identity.py` generates the Swift `BuildEnvironment`
properties (`provider-swift/Sources/ProviderBuildEnvironment/Identity.generated.swift`)
and the table below from it; run the script after you change the JSON.
`scripts/test-provider-identity.py` fails when they differ. Local builds and
tests use the production values.

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

The code-signing identifier `io.darkbloom.provider` and the keychain access
group `SLDQ2GJ6TL.io.darkbloom.provider` are the same for both builds. The
Developer ID signature and the provisioning profile bind them, and notarization
and App Attest check them. Do not make them depend on the environment. The full
list is in
[Dev build identity](../operations/provider-release.md#dev-build-identity).

## App Attest Release Qualification

Build the local dispatch, worker and endpoint-resumption test targets through
`make provider-test`. Their loopback/software callback tests are not evidence
of Apple's service or a signed release. The
[native serving qualification](test.md#native-serving-qualification) entry is
compiled into the normal CLI but refuses without explicit opt-in and a verified
release app.

For physical diagnostics, use the separate
[local signed-app procedure](../../scripts/nativequalification/README.md#build-and-sign).
Freeze source and take exclusive ownership of its `.build` directory before
building. Do not replace the installed app or reuse a debug binary. The
default-off [worker selection](../reference/configuration.md#app-attest-worker-qualification)
also reaches background serving through the saved LaunchAgent plist;
diagnostic/fault flags are not forwarded. The staging helper neither publishes
nor notarizes, alters the installer/profile contract, or approves a build.

Use SDK 27 for Apple code-measurement extensions and set `SDKROOT` for both
compilation and linking. Verify the final executable's `LC_BUILD_VERSION` with
`xcrun vtool -show-build`, not merely the compiler's SDK argument. SDK 26 shadow
proofs do not establish replacement readiness. See the
[SDK and measurement contract](../reference/app-attest-shadow.md#macos-sdk-and-signed-code-measurements).
New source or diagnostic changes require new signed-artifact identity and
physical evidence; previous component, loaded-engine or Stage C passes do not
qualify a rebuilt binary, OS transition, reboot, update or fleet rollout.

After packaging the optimized provider with its resources, run:

```bash
DARKBLOOM_NO_UPDATE_CHECK=1 DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18 \
MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1 MLX_GATHER_QMM_EXPERT_SLICES=1 \
Darkbloom.app/Contents/MacOS/darkbloom runtime-smoke
```

A dev release packages `Darkbloom Dev.app/Contents/MacOS/darkbloom-dev`. Require
the environment line
`build-environment-runtime-smoke: <prod|dev> cli=<darkbloom|darkbloom-dev> coordinator=<url> cdn=<url>`
to match the release environment, plus all four markers:
`app-attest-callback-runtime-smoke: ok`,
`gemma-optimizations-runtime-smoke: ok`, `paged-kernel-runtime-smoke: ok`, and
`qwen4-metal-resources-runtime-smoke: ok`. The inherited MLX latches match
installer/updater launches. Callback completion and expiry use no Apple service
or Keychain item; this linked-binary smoke is not physical Apple qualification.

## Verify

For changes to the trusted PR reviewer, no provider build is required. Run the
offline Python suites in [threat-review verification](threat-model-review.md#verify)
and validate changed workflow YAML. The review workflow uploads content-free
failure diagnostics and last-request progress, including scanner and canonical
context revisions. After merge, new runs use current default-branch scanner code
and separately read the PR base threat model. Integration replays bounded exact
source from each model's own reviewed scope. Native Bedrock response-format
compatibility requires the bounded live smoke check in addition to offline tests.
The local lifecycle checks inject invalid analysis/acknowledgment, native usage
failures, concurrent state writes and failed final-result delivery. They verify
bounded recovery, retained findings and denial of incomplete/stale clearance;
a successful normal response alone does not test recovery.
CI admits source, selected depth and integration work from the actual batch plan,
with an emergency ceiling and a bounded deadline that leaves time for reporting.
Native workload defaults allow larger reviews and output; maintainers can lower
the dedicated call ceiling and output settings without a code change.
Normal depth routing sends critical batches directly to Sol and other risky or
uncertain batches to Opus. Full Sonnet coverage and integration remain; clean
support files avoid filename-only extra passes, and integration findings target
their cited batches. Global uncertainty retains the human-review handoff.
Paid manual dispatches and job reruns are disabled; incomplete final reviews
explicitly hand off to a human. See the verification guide for the exact limits.

Follow [test](test.md) for provider, SDK and public fixture checks. Build success
does not prove runtime parity, real Apple attestation, model quality or a release.
Provider signing/publication follows [the release runbook](../operations/provider-release.md).
That pipeline registers exact official build identity automatically; runtime
Apple verification remains separate, and release execution still needs explicit
human authorization. It uses trusted-source checks, not GitHub environment gates.

Changelog checks use Python's standard library. Run `make changelog-check` and
`make changelog-preview`; neither edits `CHANGELOG.md`. Only authorized release
preparation renders selected fragments into history. See
[contribution guidance](../../CONTRIBUTING.md#changelog-entries-with-less-merge-contention).

The public provider must build without backend source or a private checkout.
Private cross-implementation qualification remains a platform-owned gate, not
a hidden prerequisite fetched by the public build. See [ownership](navigation.md)
and the [immutable platform build reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/build.md).
That pinned reference is historical context, not current backend source authority.

## Troubleshooting

Use source-matched submodules, the documented Xcode SDK and fresh resources when
diagnosing native failures. Preserve cache identity checks; do not bypass them
to reuse incompatible artifacts. Run `make clean` only when its provider/landing
artifact removal is intended. Never erase live provider state as build cleanup.

Do not repair an old backend trigger by reintroducing backend build targets here.
Backend build and deployment configuration belongs in the platform repository.

## Flint native dependency build

1. Use `libs/mlx-swift-lm` at `65eaceb8b90bc65d01c2d2fb4a8801584f4ead7a`
   ([SDK #322](https://github.com/Layr-Labs/mlx-swift-lm/pull/322)) and
   `libs/mlx-swift` at `67dc752856ca3904e5de85b28e2f46ee3b182f62`.
2. Run `make provider-build`. It builds the metallib from the nested MLX source
   actually compiled by Cmlx. Preserve binary and metallib hashes with physical
   evidence; rebuilding tests alone does not refresh a release benchmark binary.
3. For Flint serving, select native live KV and native checkpoint precision,
   including when general configuration supplies `balanced` checkpoint storage:

   ```bash
   export DARKBLOOM_CBV2_KV_QUANTIZATION=native
   export DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION=native
   ```

   See [native Flint](../architecture/inference.md#native-flint) for the enforced
   precision contract. The official artifact remains unchanged; the provider
   executes in Swift/MLX without a Python inference process.

Verify with [Flint tests](test.md#flint-native-validation); see the
[SDK notices](../../libs/mlx-swift-lm/ThirdPartyNotices/Flint.md) for provenance.

## Nemotron Super component qualification

The [portable fixture harnesses](../../scripts/nemotron-qualification/README.md)
reproduce isolated native SDK/provider checks from the pinned gitlinks on a new
Apple Silicon machine. They include the original 88-shard checksum verifier and
require separate full-checkpoint admission/reservation calibration. Tiny fixture
passes do not qualify the shipping provider, MTP speed or full image support.

## Related

- [Provider and SDK tests](test.md)
- [Native ownership](navigation.md)
- [Serving-performance qualification](serving-performance-qualification.md)
- [Landing](../../landing/README.md)
