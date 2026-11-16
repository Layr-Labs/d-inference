### The last MDM code is removed from the provider

- `darkbloom unenroll` → 2 (or `--keep-serving`) no longer asks for administrator access to read the Mac's profiles. It names the old profile, "Darkbloom Provider Enrollment", with the server that `profiles status` reports, says to remove nothing if no profile has exactly that name, and opens System Settings, where you click Remove. The provider and the installer never run `profiles` through `sudo` and run no `profiles` command but the read-only status check.
- `darkbloom enroll` is no longer listed in `darkbloom --help`. It still runs and prints the App Attest setup steps, for older scripts that call it.
- The provider no longer reads or stores the coordinator's MDM-removal flag (`mdm_removal_ready`); a coordinator may keep sending it or drop it.
- Kept, to help remove the old profile: the one line in `start`, `status` and `doctor` while it is installed, and `unenroll` → 2.
