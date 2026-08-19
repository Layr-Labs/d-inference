# Darkbloom App Release Runbook

How the SwiftUI **Darkbloom** macOS app (`DarkbloomApp`) ships as the primary
human download in the provider release: one version and approval gate, with a
public app zip plus a legacy verifier/self-update tar registered with the
coordinator. Production releases remain human-approved per
[README.md](README.md) safety rule 1 — this document describes what the
approved operator executes and verifies, not an automated path.

## Prerequisites

- Familiarity with `.github/workflows/release-swift.yml` (build → sign →
  notarize → upload → register), `scripts/bundle-macos-app.sh` (app assembly),
  and `scripts/install.sh` (end-user install).
- Release-sensitive invariants from `AGENTS.md`: SHA-256 hashes are computed
  **after** signing; the provisioning profile must authorize
  `keychain-access-groups = SLDQ2GJ6TL.io.darkbloom.provider` and
  `aps-environment = production` for the **provider CLI**; installs break if no
  release row is registered (`GET /v1/releases/latest` → 404).

## Decisions (and why)

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

`CFBundleShortVersionString` = `CFBundleVersion` = the provider release
version, resolved by the same job that runs `scripts/check-release-version.sh`
(source of truth: `ProviderCore.version`).

Justification: the app is a co-bundled payload of the provider release. The
public zip and registered tar contain the same signed app bytes, and managed
installs are installed, self-updated, hash-verified, and rolled back **as one
unit**. Consumers of the version (install.sh, `darkbloom update`,
`GET /v1/releases/latest`, the console UI) read the single registered release
row; a divergent app version would need new coordinator schema and split hash
contracts for zero user-visible benefit. The app has no independent release
cadence.

### CLI co-bundling and the locator order

`DarkbloomCLILocator` resolves the `darkbloom` binary in this order:

1. `DARKBLOOM_CLI_PATH` (dev/test override)
2. `<own bundle>/Contents/MacOS/darkbloom` — **release layout**
3. `~/.darkbloom/bin/darkbloom` — installer symlink
4. `/usr/local/bin/darkbloom`, `/opt/homebrew/bin/darkbloom`

For a direct download, the app first relocates itself to the canonical
`~/.darkbloom/Darkbloom.app`; probe 2 then runs the co-bundled CLI from that
stable, user-writable location without requiring a separate install. The app
also creates `~/Applications/Darkbloom.app` as a user-visible symlink when it
can do so without replacing an unrelated item. After install.sh places the
combined app at the same canonical path, probe 2 and probe 3 resolve to **the
same bytes** (`bin/darkbloom` is a symlink into the bundle) - probe 2 merely
short-circuits. An unsigned dev
build contains no co-bundled CLI, so probe 2 misses and the installed CLI
(probe 3) wins: dev launches keep talking to the production-signed daemon.

### Direct app relocation and writable updates

Before SwiftUI starts onboarding or any launchd action, a production app with
bundle id `io.darkbloom.provider` checks its location. A managed or previously
relocated install at `~/.darkbloom/Darkbloom.app` continues in place. A launch
from Downloads, temporary extraction, `/Applications`, or the user-visible
symlink is resolved and, when necessary, copied with `/usr/bin/ditto` to a
same-volume staging path under `~/.darkbloom`, checked for matching bundle id,
executable, and version, then validated with
`codesign --verify --deep --strict` before an atomic destination swap. An
unrelated canonical destination is retained as
`Darkbloom.app.foreign-<id>`. The convenience symlink is created or repaired
only when doing so cannot replace an unrelated file or app. The app opens the
verified canonical destination and terminates the source instance; failure
shows an installation error and never continues provider setup from the
disposable path. Unsigned `dev.darkbloom.app` builds never relocate, and the
debug-only `DARKBLOOM_SKIP_APP_RELOCATION=1` seam supports harnesses without
creating a production bypass.

The single persistent app path is compatible with the updater: for the
bundled CLI, `SelfUpdater.installRoot(forExecutablePath:)` walks out of
`Contents/MacOS` to writable `~/.darkbloom`. LaunchAgent setup therefore
records a stable CLI path only after relocation. The downloaded source remains
outside the managed path; once handoff succeeds, users should open the
installed app and may delete the source rather than later reopening a stale
extracted release.

### Signing sequence (what changed and what to double-check)

Nested code is signed before the bundle, exactly as before, with one identity
change:

| Component | Identifier | Entitlements | Note |
|---|---|---|---|
| `Contents/Helpers/darkbloom-fan-helper` | `io.darkbloom.fan-helper` (explicit) | none | unchanged |
| `Contents/MacOS/mlx.metallib` | derived | none | unchanged |
| `Contents/MacOS/darkbloom-enclave` | derived | `provider-swift/entitlements-enclave.plist` | unchanged |
| `Contents/MacOS/darkbloom` (CLI, now nested) | **`io.darkbloom.provider` (explicit pin — NEW)** | `provider-swift/entitlements.plist` (keychain group + `aps-environment=production`) | was the bundle's main executable before |
| `Contents/MacOS/DarkbloomApp` (main executable) | derived from Info.plist → `io.darkbloom.provider` | `scripts/entitlements.plist` (network only) | **NEW** |
| `Darkbloom.app` bundle | — | `scripts/entitlements.plist` | seals everything |

Two verified facts relax two historical assumptions:

- **Duplicate identifiers inside one bundle are fine.** Main executable and
  nested CLI both resolve to `io.darkbloom.provider`;
  `codesign --verify --deep --strict` accepts this layout (verified locally
  with ad-hoc signatures on the exact structure).
- **codesign no longer derives the CLI's identifier.** When the CLI stopped
  being the bundle's main executable, `codesign` would have derived a
  basename-style identifier. The explicit `--identifier` pin in
  `release-swift.yml` plus a release-workflow guard
  (`CLI_SIGNING_ID != io.darkbloom.provider` → fail) keeps the identity stable.

#### Remaining assumption (verify on the dev release, before prod)

The embedded provisioning profile (placed at
`Contents/embedded.provisionprofile`) must authorize the CLI's restricted
entitlements — `keychain-access-groups` + `aps-environment=production` — now
that the CLI is **nested** code instead of the bundle's main executable.
Expectation: matching is by profile `application-identifier`
(`SLDQ2GJ6TL.io.darkbloom.provider` or wildcard) against the **requesting
process's signing identifier**, which the CLI keeps. The historical CI comment
("profile match only works for the main bundle executable") came from the
enclave helper carrying `application-identifier` with a *derived* (non-matching)
identifier — the CLI's pin removes the mismatch, it does not remove the need
for an end-to-end check:

- codesign/notary cannot prove profile authorization; AMFI evaluates it at
  process spawn. A failed match is **silent**: the provider falls back to
  ephemeral SE keys (reduced trust) and APNs attestation fails.
- Dev-release verification (below) therefore includes a live attestation run
  from the co-bundled CLI.

## Layout

Human-facing GitHub release asset `Darkbloom-macOS-arm64.zip`:

```text
Darkbloom.app/                         # the only top-level item
  Contents/                            # layout below
```

This zip is created with `ditto` **after** notarization and stapling. The
pre-staple `/tmp/darkbloom-notarization-submission.zip` is only input to Apple
notarytool and must never be uploaded.

Legacy coordinator/self-update asset
`darkbloom-bundle-macos-arm64.tar.gz`:

```text
./bin/{darkbloom, darkbloom-enclave, mlx.metallib}   # flat verifier copies (regular files; coordinator hashes bin/darkbloom)
./Darkbloom.app/
  Contents/
    Info.plist                       # CFBundleIdentifier io.darkbloom.provider, CFBundleExecutable DarkbloomApp, version = release version
    embedded.provisionprofile        # authorizes CLI restricted entitlements
    MacOS/
      DarkbloomApp                   # SwiftUI main executable (signed: scripts/entitlements.plist)
      darkbloom                      # provider CLI (signed: provider ents, --identifier io.darkbloom.provider)
      darkbloom-enclave              # SE attestation helper (signed: enclave ents)
      mlx.metallib                   # GPU kernels (signed before the bundle)
    Helpers/darkbloom-fan-helper     # dormant opt-in root helper (sealed, 0755)
    Resources/
      Chivo-{Regular,Medium}.ttf     # app fonts
      DarkbloomProvider_DarkbloomApp.bundle/   # app resources incl. compiled default.metallib (SpatialField shader)
      *.bundle/                      # SwiftPM runtime bundles (incl. mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal)
      darkbloom-runtime-capabilities/{paged-kernel-v1,fan-helper-v1}
```

## Steps (human-approved release operator)

1. Land source changes; confirm `swift build -c release --product DarkbloomApp`
   builds, then run `scripts/test-bundle-macos-app.sh` and
   `scripts/test-install-atomic.sh` locally.
2. Cut the release the usual way (tag `vX.Y.Z` for prod, or
   `workflow_dispatch` for dev). The workflow additionally: builds
   `DarkbloomApp`, assembles via `scripts/bundle-macos-app.sh`, signs app-clone
   + CLI per the table above, submits a temporary pre-staple zip to Apple,
   staples the accepted app, rebuilds both final distribution archives, hashes
   them, uploads both to versioned release storage, exposes both as GitHub
   assets for production tags, and registers only the legacy tar in the
   coordinator release row.
3. Review the job log's new guards: bundle DR pinned to
   `io.darkbloom.provider`, CLI signing id pinned, GUI binary free of
   restricted entitlements, and the extracted final zip passing payload,
   version, codesign, stapler, Gatekeeper, and runtime-smoke checks.

## Verification

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
   `~/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom` to the LaunchAgent.
3. Separately run `curl -fsSL <dev-coordinator>/install.sh | bash`. Confirm the
   managed install succeeds and `~/.darkbloom/Darkbloom.app` contains all three
   MacOS binaries.
4. **Attestation end-to-end (the nested-CLI profile assumption):**
   `~/.darkbloom/bin/darkbloom start`, then confirm in the coordinator that the
   provider registers with full trust (APNs code identity + persistent
   Secure Enclave key, not the ephemeral fallback). Also `darkbloom doctor`.
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

- **Whole release:** the app rolls back with the provider. Preferred lever:
  deactivate the bad release row (`scripts/admin.sh releases deactivate
  <version>`) and re-register the previous bundle + hashes (CI re-run of the
  earlier tag, or the existing admin flow). `darkbloom update` then moves the
  fleet back; the self-updater's predecessor-verification machinery accepts
  the previous bundle because its identity pin is unchanged.
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
  `~/.darkbloom/Darkbloom.app`, so release deactivation and normal updater
  rollback protect them exactly like Terminal installs. For a one-machine
  recovery, stop Darkbloom and open the prior stapled app once so relocation
  atomically replaces the canonical app; verify the `~/Applications` symlink,
  then select Go Online again only if the LaunchAgent needs to be rewritten.

## Version-display sync rule (`LatestProviderVersion`)

Unchanged, and now broader: the fallback constant in
`coordinator/api/server.go` is the *display* floor for the whole bundle —
provider CLI **and** app — when no release row exists. The app reports its
`CFBundleShortVersionString` (== release version), so the sync rule still
holds: keep `LatestProviderVersion` == `ProviderCore.version`;
`scripts/check-release-version.sh` enforces the pair at release time; the
app cannot drift because it is stamped from the same resolved `VERSION`.
