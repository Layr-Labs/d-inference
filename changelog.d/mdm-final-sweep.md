### Remaining MDM wording removed

- `darkbloom doctor` shows the `darkbloom mdm profile` row only while the old
  Darkbloom enrollment profile is installed, and `doctor --support` no longer
  prints an `mdm enrolled` line.
- The installer, setup guidance and the macOS upgrade warning no longer mention
  MDM. The old-profile notice and `darkbloom unenroll` choice 2 are unchanged.
- `doctor` and `status` explain the coordinator's current `SE attestation verified`
  reason; the two older MDM-era reason strings are shown verbatim if an old
  coordinator still sends them.
