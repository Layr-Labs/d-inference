### Desktop release source gate and job separation

- A desktop release starts only from a signed annotated `desktop-vX.Y.Z` tag
  whose commit is verified and on `master`'s ancestry. A dry run is a dispatch
  on `master`'s head. `master`'s copy of the source gate decides, before any
  other job runs.
- The release runs in six jobs: `source`, `build`, `sign`, `package`,
  `sign-dmg` and `publish`. `npm ci --ignore-scripts`, `npm run dist` and
  electron-builder run in jobs without a secret. The two signing jobs install no
  npm package and run nothing the build produced; they sign with `codesign`,
  the app through `scripts/sign-desktop-app.py`, and hold the key for that step
  alone.
- Each job takes the previous job's output by artifact id and digest. The DMG
  is signed only after `scripts/check-desktop-packages.sh` finds the signed app
  unchanged in the zip and the DMG.
- `publish` is the only job with `contents: write`, and no checkout keeps the
  workflow token.
- A release build (`DARKBLOOM_DESKTOP_RELEASE=1`) is unsigned by configuration
  and needs no credential. Every signer, the release's and electron-builder's,
  uses the entitlements of `desktop-app/resources/entitlements.mac.plist`.
- Release tags must now be signed and annotated:
  `git tag -s desktop-vX.Y.Z -m "..." <commit>`.
- No release or dry run has gone through this workflow yet. The unsigned build,
  the packaging of a prepackaged app, the signer (ad hoc, against
  electron-builder's signer) and the package check were run locally; signing
  with the Developer ID and notarization were not.
