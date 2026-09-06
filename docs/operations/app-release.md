# Darkbloom App Release Runbook

> Last updated: 2026-09-06 · commit `ab992bef4`

Use this runbook to package and qualify the SwiftUI **Darkbloom** macOS app
(`DarkbloomApp`) with its provider CLI. The public app zip and the legacy
verifier/self-update tar share one provider version and release approval gate.

## When to use

Use for a combined GUI/CLI release or its rollback. For checkout-local debug
builds and fixture previews, follow [Build](../developer/build.md#6-native-macos-app);
for automated checks, follow [Test](../developer/test.md#native-macos-app).
Production releases require explicit human approval for the specific operation
per [the operations rules](README.md).

## Prerequisites

- Familiarity with `.github/workflows/release-swift.yml` (build → sign →
  notarize → upload → register), `scripts/bundle-macos-app.sh` (app assembly),
  and `scripts/install.sh` (end-user install).
- Release-sensitive invariants from `AGENTS.md`: SHA-256 hashes are computed
  **after** signing; the provisioning profile must authorize
  `keychain-access-groups = SLDQ2GJ6TL.io.darkbloom.provider` and
  `aps-environment = production` for the **provider CLI**; installs break if no
  release row is registered (`GET /v1/releases/latest` → 404).

### Bundle id: `io.darkbloom.provider`

The release app's `CFBundleIdentifier` stays `io.darkbloom.provider` — the id
of the legacy CLI-wrapper bundle. Candidates `ai.darkbloom.app` /
`dev.darkbloom.app` were rejected because four contracts already pin
`io.darkbloom.provider`:

1. `provider-swift/Sources/ProviderCore/Update/DarkbloomCodeSignature.swift` —
   the provider **self-updater** refuses any downloaded bundle whose
   designated requirement is not `identifier "io.darkbloom.provider"`.
2. `scripts/install.sh` `DARKBLOOM_DESIGNATED_REQUIREMENT` — pinned as an
   exact-match line by `scripts/test-install-atomic.sh`.
3. The embedded provisioning profile (`PROVISIONING_PROFILE_BASE64`)
   authorizes the restricted entitlements of the co-bundled CLI against this
   app id; the APNs topic defaults to it server-side
   (`cmd/coordinator/main.go`).
4. `docs/threat-model.yaml` documents the identity under this id.

Changing it is a multi-component security migration (new App ID + profile +
coordinator topic default + self-updater constant + install.sh pin), hence
explicitly out of scope for the app first-classing. The *dev* app
(`script/build_and_run.sh`, unsigned) keeps `dev.darkbloom.app` so a dev
build never shadows a signed install. The release bundling script stamps the
release id into `Contents/Info.plist`.

### Versioning: the app has no version of its own

Both the outer GUI and nested provider app set `CFBundleShortVersionString`
and `CFBundleVersion` to the provider release version. The release job runs
`scripts/check-release-version.sh` against `ProviderCore.version`.

Justification: the app is a co-bundled payload of the provider release. The
public zip and registered tar contain the same signed app bytes, and managed
installs are installed, self-updated, hash-verified, and rolled back **as one
unit**. Consumers of the version (install.sh, `darkbloom update`,
`GET /v1/releases/latest`, the console UI) read the single registered release
row; a divergent app version would need new coordinator schema and split hash
contracts for zero user-visible benefit. The app has no independent release
cadence.

### CLI co-bundling and managed-path validation

The GUI is a CLI wrapper: the `DarkbloomApp` target in
`provider-swift/Package.swift` depends only on `ProviderCoreFoundation`.
Inference, runtime capability detection, and provider lifecycle policy stay in
the CLI and `ProviderCore`; the GUI does not link MLX.

`provider-swift/Sources/DarkbloomApp/Services/DarkbloomCLILocator.swift`
(`SystemDarkbloomCLILocator.locate`) accepts `DARKBLOOM_CLI_PATH` in DEBUG
builds only. Otherwise it uses `ManagedCLIPathValidator` to validate
`~/.darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom`.
The shared `ManagedProviderCLIPathValidator` walks real directories and the
regular executable with `O_NOFOLLOW`, then rechecks their identities. A legacy
regular `Contents/MacOS/darkbloom` is accepted only when the helper is absent;
a malformed helper cannot trigger that fallback. There is no launching-bundle,
installer-symlink, or PATH fallback. LaunchAgent and watchdog paths use this
real managed executable, keeping services out of Downloads and temporary
extraction directories. Layout constants live in
`provider-swift/Sources/ProviderCoreFoundation/ManagedProviderInstallLayout.swift`;
the descriptor checks live beside it in `ManagedProviderCLIPathValidator.swift`.

A direct download relocates to that canonical bundle before interactive
setup. The app creates `~/Applications/Darkbloom.app` as a convenience symlink
when doing so will not replace unrelated content. The shell installer uses
the same canonical app path. A debug GUI staged by `script/build_and_run.sh`
contains no CLI and uses the validated managed CLI unless explicitly
overridden in DEBUG; its runtime actions therefore affect that real install.

### Direct app relocation and writable updates

Before SwiftUI starts onboarding or any launchd action, a production app with
bundle id `io.darkbloom.provider` checks its location. A managed or previously
relocated install at `~/.darkbloom/Darkbloom.app` continues in place. A launch
from Downloads, temporary extraction, `/Applications`, or the user-visible
symlink is resolved and, when necessary, copied with `/usr/bin/ditto` to a
same-volume staging path under `~/.darkbloom`, checked for matching bundle id,
executable, and version, then validated with
`codesign --verify --deep --strict`. While holding the shared install lock, the
app fully synchronizes every staged regular file, hashes the complete candidate
and predecessor trees, atomically publishes a synchronized
`~/.darkbloom/.app-relocation-transaction.json`, and then uses a same-directory
atomic rename or `RENAME_SWAP`. Recovery accepts only the recorded inode
identity and content hash at each endpoint: it deterministically completes a
known transition and refuses every ambiguous combination without moving live
content.
An unrelated canonical destination is retained exactly once as
`Darkbloom.app.foreign-<id>`. The convenience symlink is created or repaired
only when doing so cannot replace an unrelated file or app. The app opens the
verified canonical destination and terminates the source instance; failure
shows an installation error and never continues provider setup from the
disposable path. Unsigned `dev.darkbloom.app` builds never relocate, and the
debug-only `DARKBLOOM_SKIP_APP_RELOCATION=1` seam supports harnesses without
creating a production bypass.

When the canonical destination is an owned signed app, relocation parses
`CFBundleShortVersionString` and `CFBundleVersion` as strict SemVer, requires
the two fields to agree semantically, and compares them before creating a
directory or staging a copy. Equal-version repair and upgrades are allowed;
an older downloaded source is rejected so the live app cannot fall behind
SelfUpdater's durable installed-version record. Direct app relocation, the
shell installer, and SelfUpdater serialize through the same persistent
`~/.darkbloom/.app-install.lock` kernel lock. One-shot installers then acquire
the legacy `recovery/update.lock` second so they also exclude provider versions
released before the shared lock existed. Lock files are never unlinked; the
kernel releases ownership on exit or crash without PID-based stale takeover.
The shell path applies the same monotonic version rule and journals its final
rename transaction in one atomically published, disk-synchronized manifest.
App and `bin/` directory identities make rollback restart-safe even if recovery
itself is interrupted; unrecognized content created after a crash is preserved.
The next installer rolls back an interrupted pre-commit swap or finishes cleanup
after a committed swap. Legacy flat bundles are rejected once `Darkbloom.app`
exists because they carry no authenticated app version. Concurrent valid app
installers therefore finish at the highest version instead of letting the last
stale copy win. SelfUpdater and the shell installer both refuse to mutate while
the app-relocation journal remains; only DarkbloomApp can recover that journal,
under the same kernel lock.

The sole downgrade override exists for the one-machine recovery procedure
below. It remains signature-pinned and refuses to run while
`~/.darkbloom/recovery/state.json` exists, so an operator cannot leave a newer
SelfUpdater record attached to older live bytes:

```bash
~/.darkbloom/bin/darkbloom stop
if [ -d ~/.darkbloom/recovery ]; then
  mv ~/.darkbloom/recovery \
    ~/.darkbloom/recovery.before-manual-rollback-"$(date +%Y%m%d-%H%M%S)"
fi
DARKBLOOM_ALLOW_APP_DOWNGRADE=1 \
  "/path/to/prior/Darkbloom.app/Contents/MacOS/DarkbloomApp"
```

Keep the archived recovery directory as evidence; do not restore it over the
older installation. The override does not admit ad-hoc signatures, bypass
notarization, or alter the normal monotonic updater policy.

The single persistent app path is compatible with the updater: for the
bundled CLI, `SelfUpdater.installRoot(forExecutablePath:)` uses
`ManagedProviderInstallLayout.outerAppURL(forExecutableURL:)` to recognize both
the nested helper and legacy flat app paths and return writable `~/.darkbloom`.
The helper's own `Contents` directory is never the update root. LaunchAgent
setup therefore records a stable CLI path only after relocation. The downloaded source remains
outside the managed path; once handoff succeeds, users should open the
installed app and may delete the source rather than later reopening a stale
extracted release.

### Signing sequence

The CLI is the main executable of
`Contents/Helpers/DarkbloomProvider.app`. That helper has its own `Info.plist`
and embedded provisioning profile, with identifier `io.darkbloom.provider`
and the same version/profile as the outer app. The outer GUI identifier stays
unchanged; its main executable is `DarkbloomApp`.

Sign in this order (`.github/workflows/release-swift.yml`):

| Component | Identifier / entitlements | Action |
|---|---|---|
| Outer `Contents/Helpers/darkbloom-fan-helper` | `io.darkbloom.fan-helper`; no provider entitlements | Sign the dormant opt-in helper |
| Provider helper's `Contents/MacOS/mlx.metallib` | Derived identifier; no provider entitlements | Sign the canonical kernel library |
| Provider helper's `Contents/MacOS/darkbloom-enclave` | Derived identifier; `provider-swift/entitlements-enclave.plist` | Sign the canonical enclave helper |
| `DarkbloomProvider.app` / main `darkbloom` | `io.darkbloom.provider`; `provider-swift/entitlements.plist` | Sign and seal the helper with its profile and real runtime resources |
| Outer `Contents/MacOS/{mlx.metallib,darkbloom-enclave}` | Copies of the signed canonical files | Copy with `ditto`, preserving metallib signature attributes and byte parity; do not re-sign the copies |
| `Darkbloom.app` / main `DarkbloomApp` | `io.darkbloom.provider`; `scripts/entitlements.plist` (network only) | Sign and seal the outer GUI last |

The outer `Contents/MacOS/darkbloom` is exactly the relative symlink
`../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom`. Sign the real helper
app, never the alias. Hash payloads only after signing.

The [September 5 signing qualification report](../reports/2026-09-05-macos-app-signing-qualification.md)
records the observed failure of the earlier raw nested CLI: even with matching
identifier, profile, and certificate, deep/strict signature verification passed
but `--version` was killed with exit 137. Making the same CLI a bundle's main
executable ran successfully. The new helper layout passed direct and alias
launches and, with colocated signed kernels/resources, Gemma and Paged runtime
smoke. This replaces the earlier profile-matching assumption; it does not prove
persistent Secure Enclave keys or APNs attestation. Those checks, notarization,
Gatekeeper, and MDM remain separate release gates below.

### Distribution layout

Human-facing GitHub release asset `Darkbloom-macOS-arm64.zip`:

```text
Darkbloom.app/                         # the only top-level item
  Contents/                            # layout below
```

This zip is created with `ditto` **after** notarization and stapling. The
pre-staple `/tmp/darkbloom-notarization-submission.zip` is only input to Apple
notarytool and must never be uploaded.

Before archiving, the workflow removes `com.apple.macl` from the staged outer
app. Local launch probes can attach this host-specific access metadata; it does
not belong in a release. The archive retains the metallib’s `com.apple.cs.*`
signature attributes and the strict preflight continues to reject unrelated
metadata (`.github/workflows/release-swift.yml`, bundle and notarization steps).

Legacy coordinator/self-update asset
`darkbloom-bundle-macos-arm64.tar.gz`:

```text
./bin/{darkbloom, darkbloom-enclave, mlx.metallib}   # regular verifier copies of signed payloads
./Darkbloom.app/
  Contents/
    Info.plist                       # id io.darkbloom.provider; main DarkbloomApp; release version
    embedded.provisionprofile        # same profile as the provider helper
    MacOS/
      DarkbloomApp                    # GUI main; network entitlements
      darkbloom -> ../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom
      darkbloom-enclave               # regular copy of signed helper payload
      mlx.metallib                    # regular copy, including signature attributes
    Helpers/
      darkbloom-fan-helper            # dormant opt-in root helper
      DarkbloomProvider.app/
        Contents/
          Info.plist                 # id io.darkbloom.provider; main darkbloom; same version
          embedded.provisionprofile
          MacOS/{darkbloom,darkbloom-enclave,mlx.metallib}  # real regular runtime payloads
          Resources/
            *.bundle/                # real SwiftPM bundles, including pagedattention.metal
            darkbloom-runtime-capabilities/paged-kernel-v1
    Resources/
      Chivo-{Regular,Medium}.ttf
      DarkbloomProvider_DarkbloomApp.bundle/  # compiled GUI default.metallib
      *.bundle/                      # retained outer SwiftPM resources
      darkbloom-runtime-capabilities/{paged-kernel-v1,fan-helper-v1}
```

### Tar expansion safety contract

The registered tar is treated as hostile structure even after its SHA-256
matches. The coordinator, `scripts/install.sh`, and Swift `SelfUpdater`
independently walk every raw tar header before extraction with the same limits:

| Bound | Limit | Rationale |
|---|---:|---|
| Compressed archive | 2 GiB | Enforced while shell and Swift downloads stream, then rechecked before parsing; over 10× the roughly 170 MiB signed bundle |
| Total decompressed tar stream | 4 GiB | Includes headers, payloads, padding, end markers, and the zero trailer; ample room above the current sub-1-GiB expanded app |
| Raw headers | 16,384 | Includes PAX/GNU metadata headers, bounding inode and parser work |
| Archive path | 4,096 bytes | Matches the portable filesystem path envelope |
| Path component | 255 bytes | Matches the APFS component ceiling |
| One metadata payload | 1 MiB | Supports long paths and Apple metadata without unbounded parser allocation |

Portable ASCII paths, regular files, and directories are allowed, plus one
symlink: `Darkbloom.app/Contents/MacOS/darkbloom` must target exactly
`../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom`, with an empty payload
and a regular nested target in the same archive. No alternate spelling, extra
symlink, hard link, linked ancestor, or linked runtime resource is accepted.
Bounded per-entry PAX metadata and GNU long-name records are understood; sparse
encodings (including GNU, SCHILY, LIBARCHIVE, and `SUN.holesdata`), devices,
FIFOs, alternate file-type metadata, absolute/traversing paths, regular-file
paths ending in `/`, duplicate or case-conflicting names, and file/descendant
conflicts are rejected. Declared sizes use checked octal/base-256/PAX parsing,
so negative or overflowing sizes fail before payload reads. GNU long names
permit only a NUL terminator, never a newline alias. Two zero end blocks and a
block-aligned all-zero trailer are required and counted toward the expanded
limit.

Release registration downloads the exact versioned object, verifies its bundle
hash, performs this complete raw-header walk, and hashes `bin/darkbloom` during
the same pass before saving the release row. The shell installer uses only
base-macOS `/usr/bin/perl` and `/usr/bin/gzip`; `SelfUpdater` performs its own
Swift header walk over a system-gzip stream. Both complete preflight before
invoking `/usr/bin/tar`.

Nested payload validation also requires matching outer/helper metadata and
profiles, regular colocated runtime resources, and signed-byte parity: the
nested CLI matches `bin/darkbloom` (the outer alias points to it); enclave and
metallib bytes agree across inner, outer, and `bin/` copies. Hashing opens the
real nested files through no-follow paths. Legacy regular layouts remain
supported. The canonical readers are `coordinator/api/release_archive.go`
(`validateReleaseArchive`), `coordinator/api/release_artifact.go`,
`scripts/install.sh`, and
`provider-swift/Sources/ProviderCore/Update/ReleaseArchivePreflight.swift` /
`ProviderAppLayout.swift`.

### Upgrade-reader compatibility

Qualify the exact installed updater, served installer, and coordinator reader
against the new tar before rollout. Earlier app-preview readers that reject
all symlinks may need the updated installer. Do not prescribe a bridge release
for every provider: the verified `origin/master` snapshot in the signing report
does not contain the app branch's strict `ReleaseArchivePreflight.swift`.
Deployed legacy readers must be qualified separately; absence of that file is
not an upgrade test. Record each starting version and reader revision, then
verify update, launch, and rollback with the final signed artifact.

## Steps (human-approved release operator)

1. Prepare the release candidate and run `make app-check` and
   `make provider-test`. From
   `provider-swift/`, confirm `swift build -c release --product DarkbloomApp`
   builds, then from the repo root run
   `scripts/test-install-atomic.sh`,
   `scripts/test-release-archive-safety.sh`,
   `scripts/test-install-nested-provider.sh`, and
   `scripts/test-macos-app-unsigned-debug-lifecycle.sh` locally. The last
   command is intentionally an unsigned DEBUG lifecycle smoke, not a signing
   or relocation qualification.
2. Cut the release the usual way (tag `vX.Y.Z` for prod, or
   `workflow_dispatch` for dev). The workflow additionally: builds
   `DarkbloomApp`, assembles via `scripts/bundle-macos-app.sh`, signs the
   provider helper and outer GUI in the order above, submits a temporary
   pre-staple zip to Apple,
   staples the accepted app, rebuilds both final distribution archives, hashes
   them, uploads both to versioned release storage, exposes both as GitHub
   assets for production tags, and registers only the legacy tar in the
   coordinator release row. Before its first extraction or upload, the exact
   final tar passes `scripts/install.sh --preflight-release-archive`.
3. Review the job log's new guards: bundle DR pinned to
   `io.darkbloom.provider`, CLI signing id pinned, GUI binary free of
   restricted entitlements, and the extracted final zip passing payload,
   version, codesign, stapler, Gatekeeper, and runtime-smoke checks.

## Verification

### Product flow and session verification

Use live services in a development environment with the matching CLI, then
repeat the applicable checks on the signed dev release. Fixture previews are
for presentation review only. Record the artifact/version, model, endpoint,
and observed result for live checks. Keep earlier full-suite results separate
from later focused checks; neither qualifies an assembled signed candidate.

1. On a fresh app launch, choose **Open your studio**. Confirm that Studio,
   Library, Network, and This Mac open with **Set up network sharing** still
   available in the workspace menu. Browsing
   does not start the engine, enroll the Mac, or persist network setup
   completion (`provider-swift/Sources/DarkbloomApp/Stores/AppFlowStore.swift`,
   `exploreProduct`). Existing fresh, running hardware-trusted provider
   evidence can bootstrap an already configured Mac
   (`provider-swift/Sources/DarkbloomApp/Stores/AppFlowBootstrapEvidence.swift`,
   `canOpenProductWithoutOnboarding`); browsing is not that evidence. Select
   **Network**: it opens `network-overview`, explains the network, links to the
   web console, and shows **Share this Mac’s compute** with setup or provider
   controls. Local Studio use remains independent of network enrollment
   (`provider-swift/Sources/DarkbloomApp/Views/Product/StudioNavigation.swift`,
   `StudioSection.destination`;
   `provider-swift/Sources/DarkbloomApp/Views/Product/Network/NetworkIntroductionView.swift`,
   `NetworkIntroductionView`; and
   `provider-swift/Sources/DarkbloomApp/Views/Product/Overview/ProviderOverviewView.swift`,
   `ProviderOverviewView`).
2. Choose **Set up network sharing** and exercise readiness → account → enrollment →
   model preparation/start → live trust verification. Leave setup and resume
   it, including after relaunch. The normalized draft and completion flag
   persist in UserDefaults; leaving setup cancels pending work and returns to
   the prior welcome/product phase. Only verified completion clears the draft
   (`AppFlowStore.completeOnboarding` and
   `provider-swift/Sources/DarkbloomApp/Stores/AppFlowPreferences.swift`,
   `UserDefaultsAppFlowPreferences`). A CLI launch or service failure must not
   be presented as a failed hardware-security check.
3. Refresh Models and Diagnostics without changing provider configuration or
   starting inference. Check the machine-readable contracts below. Runtime
   eligibility comes from the CLI's canonical policy before the app considers
   RAM fit. For catalog entries, absent/unknown eligibility stays unknown and
   blocks runtime actions; it is not inferred from the model name or RAM.
   **Use in Chat** selects a model and opens Studio without starting it
   (`provider-swift/Sources/DarkbloomApp/Stores/ModelLibraryStore.swift`,
   `selectModel`,
   `provider-swift/Sources/DarkbloomApp/Models/ModelLibrarySnapshotMapping.swift`,
   `rows`, and
   `provider-swift/Sources/DarkbloomApp/Views/Product/ProductShellView.swift`).
   An explicit choice absent from the running endpoint blocks Send instead
   of silently using the old model. Ending an owned session to switch models
   is a separate user action (`ChatModelHandoff` in
   `provider-swift/Sources/DarkbloomApp/Views/Product/Chat/ChatModelHandoff.swift`).
4. In Chat, verify connection checking against a trusted local discovery
   record and its live process identity. The catalog check sends no prompt;
   an advertised model is not proof of residency or inference. Send a real
   prompt separately and verify streamed content, stop/retry behavior, and an
   unavailable selected model. Leave Chat and return: the transcript, draft,
   model choice, and in-app history remain; leaving the view stops an active
   response. **New Chat** archives the current transcript/draft for restoration
   during this app session. Quit/relaunch starts with empty chat state:
   prompts are not written to disk by `ChatStore`
   (`provider-swift/Sources/DarkbloomApp/Stores/ChatStore.swift`,
   `reset` / `restoreConversation`, and
   `provider-swift/Sources/DarkbloomApp/Models/ChatSession.swift`,
   `ChatConversation`). Product destination restoration uses `SceneStorage`, not
   transcript persistence.
5. Start an installed model directly in Studio, then open **Connect your tools**
   from the workspace menu to check Local API independently. Existing endpoint
   observation is read-only. **Start model** invokes
   `darkbloom start --local --model <id> --no-replace` through
   `provider-swift/Sources/DarkbloomApp/Services/LocalAPIStartContract.swift`
   (`LocalAPIStartCommand`). The CLI atomically refuses both an occupied kernel
   lock and a still-live legacy owner before signaling that owner or creating
   credentials; see [the start contract](../provider/cli-reference.md#darkbloom-start).
   Check that a competing provider remains running with its owner record and
   endpoint intact. An older CLI must reject the flag without a retry that
   drops it. Local startup skips automatic config migration, and the app's
   exact command does not change idle policy, schedule, or launchd settings.
   Confirm successful startup from the owned child's authenticated endpoint,
   then check that navigation retains the foreground session and that
   readiness belongs to that exact child and requested model. Ending the local session cancels only the owned process; application
   quit waits for it to exit and stays open if shutdown cannot be confirmed.
   Quitting never stops an externally discovered provider
   (`provider-swift/Sources/DarkbloomApp/Stores/LocalAPIStartController.swift`,
   `shutdown`, and
   `provider-swift/Sources/DarkbloomApp/App/DarkbloomAppDelegate.swift`,
   `applicationShouldTerminate`). These session records are not a persisted
   auto-restart setting.
6. Open the menu bar with no local session, an app-owned session, and an
   externally managed endpoint. Verify separate **Local AI** and
   **Darkbloom network** sections and **Open Studio** / **Open Network** routes.
   **End session** appears only for the owned child; opening or closing the
   popup must not stop shared monitoring. Failed or incomplete endpoint probes
   must not display a ready session, and a running/verified idle provider must
   not imply active inference or routable capacity
   (`provider-swift/Sources/DarkbloomApp/Views/MenuBar/ProviderMenuBarView.swift`,
   `ProviderMenuBarView`;
   `provider-swift/Sources/DarkbloomApp/Views/MenuBar/ProviderMenuBarLocalPresentation.swift`,
   `ProviderMenuBarLocalPresentation`; and
   `provider-swift/Sources/DarkbloomApp/Views/MenuBar/ProviderMenuBarNetworkPresentation.swift`,
   `ProviderMenuBarNetworkPresentation`). Check that network setup/start/restart
   is blocked while the app owns a local session, pause/restart confirmations
   retain their scope, scheduled-off state offers no generic start override,
   and preview runtime actions stay disabled
   (`provider-swift/Sources/DarkbloomApp/Views/MenuBar/ProviderMenuBarSetupView.swift`,
   `ProviderMenuBarSetupView`; and
   `provider-swift/Sources/DarkbloomApp/Views/MenuBar/ProviderMenuBarProviderControls.swift`,
   `request` / `canPerform`). Quit copy must explain that owned local sessions
   end while the network provider runs independently.
7. Check My Macs and Contributions with a linked account, signed-out state,
   and failed refresh. Missing or stale account data must remain distinct
   from an empty fleet, and late results after sign-out must not restore the
   previous account's inventory
   (`provider-swift/Sources/DarkbloomApp/Stores/MyMacsStore.swift`,
   `refresh` / `signOut`).

Read-only app queries can probe hardware and fetch public/account endpoints.
Explicit onboarding/download plans can hash staged download files; normal
Library catalog browsing does not. “Read-only” does not mean offline or no subprocess.
Keep these queries separate from explicit setup, download/remove, schedule,
and provider lifecycle actions.

| Query | Contract and source |
|---|---|
| `darkbloom doctor --json` | One diagnostic report; `Doctor.run` in `provider-swift/Sources/darkbloom/DoctorCommand.swift` uses `migrateOnDisk: false`. A valid report can accompany a failing exit status. `--clear-backend-guard` is a separate mutating action. |
| `darkbloom models list --json --all` | All disk inventory, independent of enabled-model and available-memory filters; non-migrating snapshot (`provider-swift/Sources/darkbloom/ModelsCommand.swift`, `Models.List.listedModels`). |
| `darkbloom models catalog --json --include-runtime-eligibility` | Library's lightweight envelope: `models`, per-ID `runtime_eligibility`, and empty `download_plans`; never calls the storage planner (`provider-swift/Sources/darkbloom/ModelsCommand.swift`, `Models.Catalog.makePlanOutput`). Actual download admission remains a fresh per-model plan. |
| `darkbloom models catalog --json --include-download-plans` | `models`, `download_plans`, and per-ID `runtime_eligibility` (`eligible`, `ineligible`, `unknown`, each with `reason`). Plain `catalog --json` remains an array. `ModelsCatalogRuntimeEligibility` in `provider-swift/Sources/darkbloom/ModelsCatalogOutput.swift` calls `ModelRuntimeRequirements.evaluate`; no app-owned policy table. |
| `darkbloom earnings --json` | Account earnings with this Mac's identity resolved from authenticated account mappings and matching daemon identity, without reading a raw hardware serial (`provider-swift/Sources/darkbloom/CurrentEarningsIdentity.swift`, `resolveCurrentEarningsIdentity`). |
| Local endpoint catalog probe | Read `~/.darkbloom/local.json`, validate kernel PID/start identity, then `GET /v1/models`; it does not launch serving or submit a prompt (`provider-swift/Sources/DarkbloomApp/Stores/ChatEndpointSession.swift`, `validate` / `resolveModel`). |

### Local-start regression coverage

The source contract has focused tests in
`provider-swift/Tests/DarkbloomCLITests/LocalStartContractTests.swift`
(`appLaunchArguments`, `requiresLocalMode`, `networkDefaultIsUnchanged`) and
`provider-swift/Tests/ProviderCoreTests/NonReplacingProviderLockTests.swift`
(`occupiedOwnerIsPreserved`). The lock test covers both kernel-lock and
legacy-owner refusal, no termination signal, owner-record preservation, and
successful acquisition once the owner exits.

These suites are outside `make app-unit-test`'s app/Foundation filter; they
belong to `make provider-test`. Record their actual execution results alongside
the app lifecycle tests. Source inspection and automated checks do not replace
the live inference and signed-artifact checks below.

### Hermetic unsigned lifecycle coverage

The normal macOS CI step named **Test unsigned debug app fresh-user lifecycle**
runs `scripts/test-macos-app-unsigned-debug-lifecycle.sh`. It assembles an
unsigned DEBUG bundle in an isolated temporary home, uses the DEBUG-only
relocation bypass, and proves the exact welcome window plus ready install
state. It does **not** establish actual inference, APNs/profile authorization,
Developer ID signing, notarization, stapling, Gatekeeper acceptance, signed
relocation, or production readiness. `make app-check` likewise covers unit
contracts and fixture bundle assembly, not these live release gates.

### Signed artifact qualification (no signing secrets required)

Once the protected release job has produced a real post-staple app or public
zip, qualify that artifact without modifying it:

```bash
./scripts/qualify-signed-macos-app.sh \
  --expected-version 0.8.0 \
  /path/to/Darkbloom-macOS-arm64.zip
```

The command extracts zips only into a temporary directory, then requires the
pinned Developer ID requirements, hardened runtime, strict deep signature,
stapled notarization ticket, Gatekeeper acceptance, matching semantic bundle
versions, the shipping APNs/keychain profile contract, GUI entitlement
separation, and required sealed resources. It has no ad-hoc or fake-notary
mode. The release workflow runs the same command against the exact public zip
before upload, keeping the operator checklist aligned with CI.

The qualifier also executes the real signed helper's `--version` and
`runtime-smoke`, using the workflow's Gemma latch inputs. These prove launch
and packaged Gemma/Paged kernel execution for that artifact, not model
inference, persistent Secure Enclave key reuse, APNs, MDM, or relocation.
Complete those live checks below; a passing signature alone never substitutes
for launching the signed CLI.

After the **dev** release (before any prod tag):

1. CI-final checks in the `Notarize bundle` step extract the exact
   `Darkbloom-macOS-arm64.zip` asset and run `spctl --assess`,
   `stapler validate`, `codesign --verify --deep --strict`, identity/version
   checks, completeness checks, and runtime smoke against that extracted app.
2. On a clean Mac, download the versioned dev object at
   `<resolved-dev-R2-public-url>/releases/v<VERSION>/Darkbloom-macOS-arm64.zip`,
   unzip it in Downloads, and double-click the app there. Confirm the source
   instance installs and reopens `~/.darkbloom/Darkbloom.app`, creates
   `~/Applications/Darkbloom.app` as a symlink to that canonical app without
   replacing unrelated content, then confirm Go Online writes
   `~/.darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom`
   to the LaunchAgent and watchdog. Neither service should persist an alias.
3. Separately run `curl -fsSL <dev-coordinator>/install.sh | bash`. Confirm the
   managed install succeeds, the helper has the real CLI/enclave/metallib and
   runtime resources, and the outer CLI is the exact compatibility alias.
4. **Persistent identity and attestation:** run
   `~/.darkbloom/bin/darkbloom start` and `darkbloom doctor`. Verify persistent
   Secure Enclave key reuse across provider restarts, successful APNs code
   identity, and MDM/MDA enrollment evidence in the coordinator. An AMFI launch
   or kernel-smoke pass does not establish hardware trust.
5. Self-update the managed `~/.darkbloom` install from the previous release to
   the new bundle (the self-updater's
   pinned requirement must accept it), then next update cycle forward.
6. Launch the managed GUI (`open ~/.darkbloom/Darkbloom.app`): window appears, the app
   drives the co-bundled CLI (start/stop works, daemon state renders).
7. Legacy handling: pre-seed `~/.darkbloom/Darkbloom.app` from (a) a previous
   install (id `io.darkbloom.provider`) → replaced in place; (b) a foreign app
   (any other id, no Info.plist, a regular file, or a symlink) → preserved at
   `~/.darkbloom/Darkbloom.app.foreign-<timestamp>` with a warning;
   (c) an unsigned dev build (id `dev.darkbloom.app`) → replaced. Separately
   pre-seed `~/Applications/Darkbloom.app` with the correct symlink, a stale
   symlink, and unrelated content; confirm only a Darkbloom-owned symlink is
   repaired and unrelated content is left untouched.
8. Interactive TTY install offers `open`; piped `curl | bash` prints the
   `open` hint only.

## Rollback

- **Pending candidate:** SelfUpdater's verified-predecessor machinery performs
  the automatic rollback after failed startup validation. This is the normal,
  state-consistent rollback path.
- **Whole release:** deactivate the bad release row (`scripts/admin.sh releases
  deactivate <version>`) to stop further uptake. Re-registering an older row
  does not make the monotonic self-updater downgrade already-promoted hosts.
  Use a fixed strictly newer release for fleet recovery.
- **One machine on a promoted bad release:** use the explicit signed-app
  procedure in **Direct app relocation and writable updates**. It stops the
  watchdog/provider, archives stale recovery state, and opts into exactly one
  signed downgrade. Do not merely double-click an old app: the default guard
  rejects it by design.
- **Failed single-machine install:** install.sh's atomic swap restores the
  previous app dir on any failure; the foreign-bundle path never deletes user
  files.
- **CLI intact if the GUI misbehaves:** every control path (LaunchAgent,
  `darkbloom start/stop/status`, attestation) bypasses the app entirely; the
  GUI is a client of the CLI, not a dependency of serving.
- **Emergency unpublish:** removing the release row stops all updates and new
  installs (installer + self-update read `/v1/releases/latest`), which is the
  existing misuse-breaker behavior — re-register a known-good release to
  restore service.
- **Direct-download app:** direct downloads become managed installs at
  `~/.darkbloom/Darkbloom.app`, so release deactivation and candidate rollback
  protect them exactly like Terminal installs. Arbitrary downgrade remains an
  explicit one-machine recovery, never an automatic relocation.

## Related

- [Signing qualification, 2026-09-05](../reports/2026-09-05-macos-app-signing-qualification.md) — controls, retained probe artifacts, and remaining release gates.
- [Build](../developer/build.md#6-native-macos-app) — checkout GUI staging and launch-script options.
- [Test](../developer/test.md#native-macos-app) — app unit, bundle fixture, and unsigned lifecycle checks.
- [Provider release](provider-release.md) — version synchronization, release registration, and provider release procedure. `scripts/check-release-version.sh` keeps `LatestProviderVersion` and `ProviderCore.version` aligned; the GUI bundle uses that same resolved version.
- [Provider CLI reference](../provider/cli-reference.md) — provider commands and configuration.
