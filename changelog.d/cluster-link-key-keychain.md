### Cluster pairing: the link key in the Keychain

- A cluster pairing's link key is now kept in this Mac's data-protection Keychain, under the app's access group: readable by the signed Darkbloom app and its background services after the Mac's first unlock, on this Mac only, never synchronised or restored from a backup. A new pairing writes no key file.
- On the first run of this release, the `edge-<pin>.secret` file an earlier release kept in the pairing store moves into the Keychain: it is stored, read back and compared, then overwritten and removed. A crash at any step, or two processes at once, finish the move at the next read; a corrupt file is refused and left as it is.
- After a restart, until someone logs in to the Mac, the Keychain is locked: the pair doesn't link, and `darkbloom cluster status` says to log in once; the pair resumes by itself after the login. Unpairing deletes the key.
- Rolling back to 0.10.12 with `darkbloom update --rollback` (or any automatic rollback) writes the key back to the file that release reads, so the pair keeps working. A 0.10.12 installed by hand instead asks to pair the Macs again.
- `darkbloom cluster pair --status` says where each pairing's link key is kept. Development builds without the Keychain entitlement keep the file, as before.
