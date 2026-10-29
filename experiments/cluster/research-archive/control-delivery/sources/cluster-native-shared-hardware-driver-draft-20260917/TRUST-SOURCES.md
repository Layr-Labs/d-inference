Source findings are from the pinned repository files in `context-pins.json`:

- `coordinator/api/provider.go`: real Provider IDs are generated per WebSocket; real attestation/code gates and staged/cached MDA chain handling stay authoritative.
- `coordinator/registry/verified_pair_membership.go`: current hardware, Apple MDA, SE binding, code freshness, release generation/application evidence and heartbeat/connection gates are checked before the atomic hold.
- `coordinator/mdm/mdm.go`: `LookupDevice` is a serial-filtered read-only device query; SecurityInfo and DevicePropertiesAttestation use existing bound command callbacks. No command is issued by this driver.
- `coordinator/store/interface_domains.go` and `postgres.go`: real prior chains are retrieved by serial; exported private records must remain evidence candidates and undergo current same-key verification.
- `provider-swift/.../PersistentEnclaveKey.swift`: the existing signer uses the entitled persistent v2 SE key. A new ephemeral key or an unsigned binary cannot stand in for this identity.
- `ProviderLoop+Trust.swift` and `DaemonStateFile.swift`: the existing safe signer correlation is the persisted public `attestation_public_key`, encoded with snake_case. The two observed stale files lacked it; no keychain credentials or private key bytes were read.
- `CoordinatorClient+Connection.swift`: the original connection uses Network.framework URL endpoints and TLS; the private option preserves the existing policies and URL host and scopes only the anchor input.

Apple's documented behavior supports the application-scoped anchor design: [Configuring a Trust](https://developer.apple.com/documentation/security/configuring-a-trust) and [SecTrustSetAnchorCertificatesOnly](https://developer.apple.com/documentation/security/sectrustsetanchorcertificatesonly(_:_:)). Anchor changes affect only the referenced trust object. Local SDK Security headers were also read; no exceptions API or verification date override is used.

Actual read-only evidence is separate from source claims. The existing public feed proves no target identity without an exact signer-key join. User-approved MDM enrollment is narrower than current verified hardware/code/MDA eligibility. The root-owned failed administrative trust installation and rollback are preserved outside this package; this candidate does not report OS-default trust or mutate that state.
