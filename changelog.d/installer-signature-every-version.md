### The installer holds dev and staging releases to the production signature requirement

- `install.sh` now verifies a dev or staging release (a version carrying `-dev.` or `-staging.`) against the same requirement as a production release: Apple-anchored, identifier `io.darkbloom.provider`, team `SLDQ2GJ6TL`. Those releases are already signed with that Developer ID, so they install as before. A bundle that does not meet the requirement is refused and the existing install is left unchanged.
- The coordinators serve their own copy of the installer; this reaches `curl | bash` once that copy is updated.
