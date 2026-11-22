### Doctor: a pair set up before this Mac updated is a warning

- A pair that was stopped while its Macs updated keeps a saved setup that names the previous release's cluster worker until its next start sets it up again. `darkbloom doctor` reported that as `FAIL cluster localInstalledMetadata: Installed input identity or SHA-256 differs`.
- It is now a WARN that names the release, when the pinned worker is the one in the kept rollback copy and every other pinned file verifies. Anything else that differs stays a failure. `darkbloom cluster doctor` reports it as `warning` and exits 0.
- A pair left stopped across more than one update pins an older worker than the kept copy. It is a WARN too when the setup names this Darkbloom's own worker, signed with the same certificate, and every other pinned file verifies; the line then names no release. A worker that isn't signed so (foreign or changed), a setup naming another worker, or a build without the Developer ID, stays a failure.
