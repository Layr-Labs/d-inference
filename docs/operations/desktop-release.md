# Release The macOS Desktop App

> Last updated: 2026-11-18

Build, sign, notarize and publish the Darkbloom desktop app (`desktop-app/`) as a
GitHub Release. The workflow is `.github/workflows/release-desktop.yml`. It signs
with the same Eigen Labs Developer ID (team `SLDQ2GJ6TL`) and notarization
secrets as the [provider release](provider-release.md), and needs no other
credentials. Pushing a release tag publishes a public download and an update to
every installed app; only an authorized releaser does that. The tag must be a
signed annotated tag on a reviewed `master` commit ([source gate](#source-gate)).

## Versions

The app has its own version, independent of the CLI: `desktop-app/package.json`
`"version"`, released as tag `desktop-vX.Y.Z`. The tag must equal that version
or the workflow stops. A desktop release is never marked *Latest*, so the CLI
releases (`vX.Y.Z`) keep that slot.

## Prerequisite: a CLI with the desktop API

On first run the app installs the latest published CLI (the same
`/v1/releases/latest` its bundled installer reads) and drives it through
`darkbloom desktop`. The workflow refuses to publish while that CLI's tag has no
`provider-swift/Sources/darkbloom/Desktop/DesktopCommand.swift`. Release a CLI
from a `master` that includes the desktop app first.

## Steps

1. **Dry run.** Actions → *Release Desktop App* → *Run workflow* on `master`. It
   runs every build, signing, notarization and verification step and attaches
   `darkbloom-desktop-X.Y.Z` (DMG, zip, `SHA256SUMS`) to the run without
   publishing. An outdated CLI is a warning here instead of an error. A dry run
   on any other branch, or on a `master` commit that is no longer its head, stops
   in job `source` before anything is built.
2. **Bump the version** in `desktop-app/package.json` through a reviewed PR if
   this version was already released. The version is `X.Y.Z`.
3. **Tag and push** a signed annotated tag on the reviewed `master` commit:

   ```bash
   git tag -s desktop-v0.1.0 -m "Darkbloom for Mac 0.1.0" <commit>
   git push origin desktop-v0.1.0
   ```

   GitHub must show the tag as Verified. A lightweight or unsigned tag stops in
   job `source`.

4. The workflow publishes Release `desktop-v0.1.0` with
   `Darkbloom-0.1.0-arm64.dmg`, `Darkbloom-0.1.0-arm64.zip` and `SHA256SUMS`,
   then points the [update feed](#the-update-feed) at it. The newest app is
   always at
   `https://github.com/Layr-Labs/d-inference/releases/download/desktop-latest/Darkbloom-arm64.dmg`;
   a specific version is at
   `https://github.com/Layr-Labs/d-inference/releases/download/desktop-v0.1.0/Darkbloom-0.1.0-arm64.dmg`.

## Source gate

Job `source` runs first and holds no secret. It checks out `master` and runs
`scripts/provider-release-resume.py verify-desktop-source` from that checkout,
so the rule that admits a release is `master`'s copy
(`verify_desktop_source`, `scripts/provider_release_resume/api.py`). Every other
job needs `source` and checks out the commit it admitted.

| Trigger | Admitted when |
|---|---|
| Tag push | The tag is named `desktop-vX.Y.Z`, is an annotated tag that GitHub verifies, and points at the workflow's commit; that commit is verified and on `master`'s ancestry. The run publishes. |
| Manual dispatch | The run is on `refs/heads/master` and its commit is `master`'s current head, which is verified. The run is a dry run. |
| Anything else | Refused. |

The gate protects this reviewed workflow against mistakes; it is not a secret
boundary. A tag on another commit, or a dispatch on another branch, runs that
ref's own copy of `release-desktop.yml`, which could drop the gate while the
signing secrets are repository-wide. That boundary comes with
environment-scoped secrets and a tag ruleset (a later change).

## Jobs

Each job holds only what its code needs, and takes the previous job's output by
artifact id and digest (`scripts/provider-release-publication.py download`).
Jobs `sign`, `sign-dmg` and `publish` run in the `prod`
[GitHub environment](provider-release.md#github-environments): its deployment
policy must admit `refs/heads/master` and tags `desktop-v*`, and each of the
three jobs waits for its own approval when the environment has required
reviewers. `source`, `build` and `package` name no environment.

| Job | Runs | Holds |
|---|---|---|
| `source` | The source gate, the version check and the CLI compatibility check | No secret |
| `build` | `npm ci --ignore-scripts` and `npm run dist`: the unsigned app with the update feed embedded. It also signs two scratch copies ad hoc, one with `scripts/sign-desktop-app.py` and one with electron-builder's signer, and requires the same signature on every signed path (`scripts/test-sign-desktop-app.py`) | No secret |
| `sign` | `codesign` on the unsigned app (`scripts/sign-desktop-app.py`), then `notarytool` and `stapler`. No npm package is installed, and nothing the build produced is executed | The signing key for the `codesign` step; the notarization credentials for the `notarytool` step |
| `package` | `npm ci --ignore-scripts` and `electron-builder --prepackaged`: the DMG, the zip, its blockmap and `latest-mac.yml` from the signed app. electron-builder signs nothing in this mode | No secret |
| `sign-dmg` | `scripts/check-desktop-packages.sh`, then `codesign` on the DMG, `notarytool`, `stapler`, the feed restamp and the release verification. No npm package is installed | The signing key for the `codesign` step; the notarization credentials for the `notarytool` step |
| `publish` | `gh release create` and the update feed upload, on a tag only | `contents: write`; no Apple secret |

Both signing jobs import the certificate with
`scripts/import-signing-certificate.sh` and delete the keychain with
`scripts/remove-signing-keychain.sh` directly after their `codesign` step; the
rules are those of the provider release's
[signing key lifetime](provider-release.md#signing-key-lifetime). The app is
signed with the entitlements of `desktop-app/resources/entitlements.mac.plist`,
which local electron-builder builds use too (`entitlements`,
`desktop-app/electron-builder.ts`).

Before the DMG is signed, `scripts/check-desktop-packages.sh` requires that the
app inside the zip and the app inside the DMG verify, carry the notarization
ticket and have the code directory hash of the app that job `sign` signed, that
the zip holds only the app, and that the DMG holds only the app, the link to
`/Applications` and its layout files.

A release build (`DARKBLOOM_DESKTOP_RELEASE=1`) is unsigned by configuration:
`desktopBuildConfig` sets `identity: null` and `notarize: false`, whatever
certificates the machine has.

## What the workflow verifies

Before anything is published:

- The source gate above.
- The tag matches the package version, and the release doesn't already exist.
- The latest published CLI includes the desktop API.
- The app is signed by team `SLDQ2GJ6TL` (signed by fingerprint, not by display
  name) with the hardened runtime, has bundle ID `io.darkbloom.desktop` and the
  package version, and is notarized and stapled. `spctl` reports
  `Notarized Developer ID`.
- The DMG is signed by the same team, notarized and stapled, `spctl` reports
  `Notarized Developer ID` for it, and it passes `hdiutil verify`.
- The bundled CLI installer (`Contents/Resources/bootstrap/install-runtime.sh`)
  is present and parses.
- The app embeds the update feed URL (`Contents/Resources/app-update.yml`), and
  `latest-mac.yml` is for this version, offers the zip, and every entry's
  `sha512` and size match the files (`desktop-app/scripts/update-feed.mjs`).
- `SHA256SUMS` matches the DMG and the zip again in job `publish`, before the
  release is created.

## The update feed

Installed apps update themselves from Release `desktop-latest`, a prerelease
that is never marked *Latest*. Every release build embeds
`https://github.com/Layr-Labs/d-inference/releases/download/desktop-latest` as a
`generic` electron-updater feed (`app-update.yml`); a release build without one
is refused, because the URL is fixed at build time. Never rename or delete the
`desktop-latest` release: installs would stop finding updates.

On a tag, after Release `desktop-vX.Y.Z` is published, the workflow uploads to
`desktop-latest` the zip and its blockmap, a version-less copy of the DMG
(`Darkbloom-arm64.dmg`), and `latest-mac.yml` last, so the feed never offers a
zip that isn't there. The app checks at launch and every 4 hours, downloads in
the background, and installs when the user quits it. macOS installs an update
only when it's signed by the same Developer ID as the running app. The CLI
updates separately (`darkbloom update`).

Older versions' zips stay in `desktop-latest`; deleting them doesn't affect
installs.

## Not covered

- **Website download link.** Point it at `desktop-latest/Darkbloom-arm64.dmg`
  above.
- **Release qualification on real hardware**: see
  [desktop app release qualification](../developer/desktop-app.md#release-qualification).

## A publish that failed partway

If job `publish` created the GitHub Release but the feed upload failed, a rerun
stops at `gh release create` (the release exists). Upload the feed by hand from
the run's `darkbloom-desktop-X.Y.Z-<attempt>` artifact, in this order: the zip,
its blockmap and the DMG copy first, `latest-mac.yml` last, so no installed app
sees a feed that names a file not yet uploaded.

## Rollback

Delete the GitHub Release (and its tag) to stop new downloads; installed apps
keep working. Publish a fixed `desktop-vX.Y.(Z+1)` rather than replacing assets
of an existing release.

To stop a bad update from spreading, upload the previous release's
`latest-mac.yml` (and its zip, if it was deleted) to `desktop-latest`. Apps that
already updated stay on the bad version, because the updater never downgrades;
a fixed higher version reaches them.
