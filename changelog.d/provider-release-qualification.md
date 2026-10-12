### Automatic official provider release registration

- Trusted CI tests, builds, signs and notarizes, then automatically registers the exact official build through the existing scoped release API before publication. Per-release hardware qualification and manual approval are no longer prerequisites; runtime Apple proof, receipt verification and permanent revocation remain enforced.
- Require verified signed annotated production tags in reviewed master ancestry and trusted master for dev/manual/recovery runs. Release jobs use existing repository secrets without environment approval attachments; shared security settings are unchanged. CI and repository writers are trusted for build identity, not proof that runtime Apple APIs work.
- Deploy the matching platform persistence change first. Publication retries reuse immutable signed artifacts without rebuilding or re-signing. No new endpoint, signing authority, hardware service, provisioning or automatic version bump is introduced.
