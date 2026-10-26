# Release The macOS Desktop App

> Last updated: 2026-10-26

Build, sign, notarize and publish the Darkbloom desktop app (`desktop-app/`) as a
GitHub Release. The workflow is `.github/workflows/release-desktop.yml`. It signs
with the same Eigen Labs Developer ID (team `SLDQ2GJ6TL`) and notarization
secrets as the [provider release](provider-release.md), and needs no other
credentials. Pushing a release tag publishes a public download; only an
authorized releaser does that.

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
   `Darkbloom-0.1.0-arm64.dmg`, `Darkbloom-0.1.0-arm64.zip` and `SHA256SUMS`.
   The stable download URL is
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

The temporary signing keychain is deleted at the end of every run.

## Not covered

- **App auto-update.** No update feed is configured (`DARKBLOOM_DESKTOP_UPDATE_URL`),
  so the app doesn't update itself; users download a new DMG. The CLI still
  updates itself with `darkbloom update`.
- **Website download link.** Point it at the release asset URL above once a
  release exists.
- **Release qualification on real hardware**: see
  [desktop app release qualification](../developer/desktop-app.md#release-qualification).

## Rollback

Delete the GitHub Release (and its tag) to stop new downloads; installed apps
keep working. Publish a fixed `desktop-vX.Y.(Z+1)` rather than replacing assets
of an existing release.
