### CI: release SDK qualification asks Darkbloom first; signing takes its input by artifact ID and digest

- The five "Qualify provider with SDK 27" shards and their gate moved into `release-qualify.yml`. Each release caller calls it from one job, `qualify`, with read-only permissions and no secrets, before its credentialed release call. The shards ask the Darkbloom plane on lane `release-qualify` (count 5, not in tag runs) and keep `blacksmith-12vcpu-macos-27` when the plane does not grant it. Until the sandbox approval lists the lane, the plane answers `lane_not_enabled`.
- Signing and the older-macOS smoke now take their input by the producing Blacksmith job's artifact ID, as staging and publication already did. They check the zip's SHA-256 against its digest before they read it, never by name. `provider-signing-validation.yml` does the same.
- Only the release lane saves the Metal library cache that release builds restore.
- A release now runs its build after qualification, not beside it: about 9 minutes longer.
