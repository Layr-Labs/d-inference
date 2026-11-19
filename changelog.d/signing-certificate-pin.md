### Signature checks require a Darkbloom signing certificate

- The installer, the self-updater and its rollback, `darkbloom fan enable`, the
  fan helper and the desktop app accept Darkbloom code only when a listed
  Developer ID certificate signed it
  (`DarkbloomSigningIdentity.certificateSHA1s`). Before, any Developer ID
  certificate of team `SLDQ2GJ6TL` passed.
- The fan helper is version 3. It accepts a provider only when a listed
  certificate signed it. `darkbloom fan status` and `darkbloom doctor` report
  an older helper, and `sudo darkbloom fan enable` replaces it. An older helper
  keeps working and still accepts any certificate of the team.
- A release that an unlisted certificate signed fails in the release workflow
  before upload.
- Not changed: the Sandbox add-on check, and the installer the coordinator
  serves until the platform updates its snapshot.
- A replacement certificate must be listed in a release the fleet has taken
  before it signs anything; see "Signing Certificates" in
  `docs/operations/provider-release.md`.
