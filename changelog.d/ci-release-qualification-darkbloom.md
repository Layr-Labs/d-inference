### CI: release SDK qualification shards ask Darkbloom first

- The five "Qualify provider with SDK 27" shards of every provider release (dev, staging and prod) now ask the Darkbloom plane for sandboxes on one lane, `release-qualify` (count 5). They keep `blacksmith-12vcpu-macos-27` when the plane does not grant the lane. Until the sandbox approval lists the lane, the plane answers `lane_not_enabled` and they stay on Blacksmith.
- The shards get no secret, no OIDC token and no signing keychain. The build, the qualification gate, signing, notarization, R2 staging, registration and the older-macOS smoke stay on Blacksmith.
- Signing now takes the unsigned build by its artifact ID and digest, not by its name, and only the release lane saves the Metal library cache that release builds restore.
