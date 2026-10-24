### Desktop app releases

- Add `release-desktop.yml`: a `desktop-vX.Y.Z` tag builds the macOS desktop app, signs it with the Eigen Labs Developer ID used for the CLI, notarizes and staples the app and DMG, verifies them, and publishes the DMG, zip and `SHA256SUMS` as a GitHub Release (not marked Latest). A manual run does the same as a dry run without publishing. Releases are refused while the latest published CLI lacks the `darkbloom desktop` API.
