### Cluster pairing: the link key moves to the Keychain (security)

- A two-Mac pairing's link key is now kept in this Mac's Keychain; an earlier release's copy moves there at the first start of this release.
- After a restart, the pair links once someone has logged in to the Mac; `darkbloom cluster status` says so, and the pair resumes by itself after the login.
- Rolling back to 0.10.12 with `darkbloom update --rollback` (or an automatic rollback) keeps the pair working; a 0.10.12 installed by hand asks to pair the Macs again.
