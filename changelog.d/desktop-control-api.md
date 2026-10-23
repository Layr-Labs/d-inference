### Desktop control API in the provider CLI

- Add `darkbloom desktop serve` and `darkbloom desktop ensure`, an authenticated loopback control API run as a user LaunchAgent (`io.darkbloom.desktop-api`). `ensure` replaces a stale or version-mismatched service, the service restarts itself after its binary is replaced, and `darkbloom stop --uninstall` removes it.
- Add `darkbloom desktop login` and `darkbloom desktop logout` for a separate, read-only dashboard session with bounded expiry. Sign-in prefers the scoped `desktop_account` device-code purpose and accepts an existing coordinator's standard grant; provider credentials, linkage and serving are never changed.
- Reject incompatible runtimes and streamed snapshots by protocol version, and refuse actions that need desktop commands an older installed runtime does not have.
