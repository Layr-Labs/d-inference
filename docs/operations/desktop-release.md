# Release The macOS Desktop App

> Last updated: 2026-10-26

Build, sign, notarize and publish the Darkbloom desktop app (`desktop-app/`) as a
GitHub Release. The workflow is `.github/workflows/release-desktop.yml`. It signs
with the same Eigen Labs Developer ID (team `SLDQ2GJ6TL`) and notarization
secrets as the [provider release](provider-release.md), and needs no other
credentials. Pushing a release tag publishes a public download and an update to
every installed app; only an authorized releaser does that.

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
   publishing. An outdated CLI is a warning here instead of an error.
2. **Bump the version** in `desktop-app/package.json` through a reviewed PR if
   this version was already released.
3. **Tag and push** from the reviewed `master` commit:

   ```bash
   git tag desktop-v0.1.0 <commit>
   git push origin desktop-v0.1.0
   ```

4. The workflow publishes Release `desktop-v0.1.0` with
   `Darkbloom-0.1.0-arm64.dmg`, `Darkbloom-0.1.0-arm64.zip` and `SHA256SUMS`,
   then points the [update feed](#the-update-feed) at it. The newest app is
   always at
   `https://github.com/Layr-Labs/d-inference/releases/download/desktop-latest/Darkbloom-arm64.dmg`;
   a specific version is at
   `https://github.com/Layr-Labs/d-inference/releases/download/desktop-v0.1.0/Darkbloom-0.1.0-arm64.dmg`.

## What the workflow verifies

Before anything is published:

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

The temporary signing keychain is deleted at the end of every run.

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

## Rollback

Delete the GitHub Release (and its tag) to stop new downloads; installed apps
keep working. Publish a fixed `desktop-vX.Y.(Z+1)` rather than replacing assets
of an existing release.

To stop a bad update from spreading, upload the previous release's
`latest-mac.yml` (and its zip, if it was deleted) to `desktop-latest`. Apps that
already updated stay on the bad version, because the updater never downgrades;
a fixed higher version reaches them.
