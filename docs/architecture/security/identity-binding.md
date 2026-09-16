# Identity binding

> Last updated: 2026-09-15 · commit `56da3a668`

A provider connection carries five identities — a Secure Enclave P-256 key, an
X25519 process key `K`, an APNs device token, an Apple device identity
(serial, UDID), and an account — and a consumer carries one (a Privy DID).
This page lists every binding between them and the check that enforces it, so
that "the prompt was decrypted by the attested process on the enrolled Mac
owned by this account" is a chain of verified links rather than an assumption.

## Context

Each identity is produced by a different party and can be swapped
independently: the SE key by the Mac, `K` by every provider process start, the
APNs token by the OS, the device identity by Apple, the account by the
operator. [`attestation.md`](./attestation.md) decides how much to trust the
connection; [`encryption.md`](./encryption.md) seals the prompt to `K`. Neither
means anything unless `K` is provably the key of the process that also holds
the SE key, on the device Apple says it is, linked to the account that gets
paid. That is what the bindings below establish.

## Mechanism

```mermaid
flowchart LR
    SE["SE P-256 key<br/>(Secure Enclave, keychain label<br/>io.darkbloom.provider.attestation-signing.v2)"]
    K["X25519 process key K<br/>(NodeKeyPair.generate per process)"]
    BIN["Signed provider binary<br/>(Team ID, io.darkbloom.provider, aps-environment)"]
    TOK["APNs device token"]
    DEV["Apple device identity<br/>(serial, UDID)"]
    ACCT["Account (account_id)"]
    DID["Consumer Privy DID"]

    SE -->|"B1 blob.encryptionPublicKey == register.public_key<br/>Verifier.VerifyRegistration"| K
    SE -->|"B2 challenge signature every 5m<br/>verifySignatures"| SE
    K -->|"B3 nonce sealed to K, delivered by APNs to the entitled bundle,<br/>signed by the SE key · handleCodeAttestationResponse"| BIN
    TOK -->|"B3 same token as at challenge time<br/>GrantProcessCodeAttested"| BIN
    SE -->|"B4 MDA FreshnessCode == SHA-256(SE pubkey) or leaf serial == blob serial<br/>SetMDAProofIfHardwareBound"| DEV
    DEV -->|"B5 serial → UDID → SecurityInfo agrees with the blob<br/>Verifier.VerifySecurityInfo"| SE
    ACCT -->|"B6 register.auth_token → GetProviderToken → provider.AccountID"| K
    DID -->|"B7 ES256 JWT, static PEM key, iss privy.io, aud app id<br/>VerifyToken → GetOrCreateUser"| ACCT
```

### The identities

| Identity | Produced by | Lifetime | Code |
|---|---|---|---|
| SE P-256 signing key | `PersistentEnclaveKey.loadOrCreateVerified`: keychain-backed Secure Enclave key, access group `SLDQ2GJ6TL.io.darkbloom.provider`, label `io.darkbloom.provider.attestation-signing.v2` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so challenge signing works with the screen locked); keys under the legacy label `io.darkbloom.provider.attestation-signing.v1` are migrated. Fallback: `SecureEnclaveIdentity.createEphemeral` (CryptoKit `SecureEnclave.P256.Signing.PrivateKey`, lost at exit); `darkbloom-enclave-cli` always uses the ephemeral form | Persistent per Mac and signing identity; per process on the fallback path | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift`; `provider-swift/Sources/ProviderCore/Security/SecureEnclaveIdentity.swift`; `provider-swift/Sources/ProviderCore/ProviderLoop.swift` (`createAttestationSigner`); `provider-swift/Sources/darkbloom-enclave-cli/EnclaveCLI.swift` |
| X25519 process key `K` | `NodeKeyPair.generate()` in the `ProviderLoop` initialiser (libsodium CSPRNG); legacy on-disk key files are purged | One provider process | `provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift`; `provider-swift/Sources/ProviderCore/ProviderLoop.swift` |
| APNs device token | macOS, for the signed bundle with `aps-environment`; sent as `register.apns_device_token` with `register.apns_environment` | Until the OS rotates it | `provider-swift/Sources/ProviderCore/Apns/APNsBridge.swift`; `coordinator/protocol/registration.go` (`RegisterMessage`) |
| Apple device identity | `serialNumber` inside the SE-signed blob (self-reported, SE-signed); serial and UDID inside the MDA leaf certificate (Apple-signed); UDID from the MicroMDM device record | Device lifetime | `coordinator/attestation/attestation.go` (`AttestationBlob`); `coordinator/attestation/mda.go` (`OIDDeviceSerialNumber`, `OIDDeviceUDID`); `coordinator/mdm/devices.go` (`LookupDevice`) |
| Account | `account_id` created by `GetOrCreateUser` for a Privy DID; attached to a provider through a device-linked provider token | Account lifetime | `coordinator/auth/privy.go`; `coordinator/api/accounts/device_approval.go`, `coordinator/api/accounts/device_tokens.go` |
| Provider ID | `uuid.New()` per WebSocket connection — a session handle, never an identity | One connection | `coordinator/api/provider.go` (`handleProviderWS`) |

### The bindings

| # | Binding | Proof | Enforced by |
|---|---|---|---|
| B1 | `K` ↔ SE key | The registration blob, signed by the SE key, carries `encryptionPublicKey`; it must equal `register.public_key`. A mismatch invalidates the attestation (and untrusts under a binary-hash policy) | `coordinator/providercontrol/verification/registration.go` (`Verifier.VerifyRegistration`) |
| B2 | SE key ↔ live process | Every `DefaultChallengeInterval` = 5m the process signs `nonce + timestamp` and the canonical status payload with the SE key; verified against the **registration** key, never one in the reply | `coordinator/providercontrol/challenge/signature.go` (`verifySignatures`); `coordinator/attestation/attestation.go` (`VerifyChallengeSignature`, `VerifyStatusSignature`) |
| B3 | `K` ↔ SE key ↔ signed binary ↔ APNs token | The code-identity nonce is NaCl-Box-sealed to `K` (only the `K` holder opens it), delivered through APNs to the bundle with App ID `io.darkbloom.provider` and Team ID (only that binary receives it), and returned signed by the SE key. The grant is refused if `K` or the token changed since the challenge; persisted proofs record `(se_pubkey, apns_token, node_public_key, binary_hash)` and authorise only a resume challenge, never a grant; old same-process proofs additionally require code-verified continuity, not hardware-only liveness | `coordinator/providercontrol/codeidentity/response.go` (`HandleResponse`); `coordinator/registry/code_evidence.go` (`GrantProcessCodeAttested`); `coordinator/providercontrol/codeidentity/reuse.go` (`reuseAttestation`) |
| B4 | SE key ↔ Apple device | `DeviceAttestationNonce` = SHA-256 of the SE public key string; Apple echoes it as `FreshnessCode` in the leaf. The registry attachment gate requires `hardware` and accepts a matching SE-key digest or blob serial. Before that gate, cached reuse requires the matching digest; fresh verification with a known SE key rejects a missing or mismatching digest, so serial equality alone cannot satisfy that caller | `coordinator/mdm/device_attestation.go` (`RequestDeviceAttestation`); `coordinator/attestation/mda.go` (`VerifyMDADeviceAttestation`); `coordinator/registry/device_evidence.go` (`SetMDAProofIfHardwareBound`); `coordinator/providercontrol/verification/mda_reuse.go` (`Verifier.AttachCachedMDA`); `coordinator/providercontrol/verification/mda.go` (`Verifier.VerifyMDA`) |
| B5 | blob serial ↔ MDM device ↔ posture | The blob's `serialNumber` selects the MicroMDM device (`LookupDevice` → UDID); the device's own `SecurityInfo` must report SIP on and `SecureBootLevel == "full"`, and both must equal the blob's `sipEnabled` / `secureBootEnabled` | `coordinator/mdm/security_info.go` (`VerifyProviderWithUDIDObserver`); `coordinator/providercontrol/verification/security_info.go` (`Verifier.VerifySecurityInfo`) |
| B6 | provider ↔ account | `register.auth_token` is looked up by SHA-256 hash (`GetProviderToken`); on success `provider.AccountID = token.AccountID` and the stable fault key is rebound. An invalid token logs a warning and leaves the provider unlinked | `coordinator/providercontrol/session/registration.go` (`register`); `coordinator/store/contracts/keys.go` (`hashKey`); `coordinator/registry/provider_attestation.go` (`RebindStableFaultKey`) |
| B7 | consumer ↔ account | `Authorization: Bearer <Privy access token>` verified as below; the JWT subject (Privy DID) maps to an account via `GetOrCreateUser` | `coordinator/api/requestauth/privy_session.go` (`RequirePrivyAuth`); `coordinator/api/requestauth/bearer.go` (`BearerToken`); `coordinator/auth/privy.go` (`VerifyToken`, `GetOrCreateUser`) |
| B8 | durable evidence ↔ device | Trust-reuse rows are keyed by SE public key and carry `serial`, `mda_udid`, posture bits and generations; reuse refuses `serial_mismatch`, `missing_identity`, `no_device_evidence` | `coordinator/store/contracts/trust_reuse.go` (`ProviderTrustReuse`); `coordinator/providercontrol/trustreuse/reuse.go` (`TryReuse`) |

### Stable identity for coordinator state

Reconnects, reputation, fault ejection, and stored trust must follow the
machine, not the session UUID.

| Use | Key | Code |
|---|---|---|
| Stored provider record lookup on registration | `serialNumber` from the fresh blob first, then `"sekey:" + <SE public key>` | `coordinator/providercontrol/verification/registration.go` (`Verifier.VerifyRegistration`) |
| Fault / reputation key | `serial:<serial>` → `sekey:<SE key>` → `acct:<account_id>` → `""` (valid attestation required for the first two; the account fallback is safe because `AccountID` comes from the authenticated token, never from the blob) | `coordinator/registry/fault_identity.go` (`stableProviderIdentityLocked`) |
| Trust reuse, code-identity proofs, push budgets | SE public key (plus token hash for budgets) | `coordinator/providercontrol/trustreuse/evidence.go` (`record`); `coordinator/providercontrol/codeidentity/state.go` (`deviceState`) |

### Device-code account linking

RFC 8628-style flow owned by `Controller` in `coordinator/api/accounts/` and
`provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` (`darkbloom login`).

| Step | Endpoint / value | Code |
|---|---|---|
| 1 | `POST /v1/device/code` (no auth, body capped at `maxControlPlaneBodyBytes`) → `{device_code, user_code, verification_uri, expires_in, interval}`. `device_code` = 32 random bytes hex; `user_code` = 8 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789` formatted `XXXX-XXXX`; `expires_in` = `DeviceCodeExpiry` and `interval` = `DeviceCodePollInterval` ([api-contracts](../../reference/api-contracts.md#device-code-flow-3)); `verification_uri` = `EIGENINFERENCE_CONSOLE_URL` + `/link`, else `<scheme>://<host>/link` | `coordinator/api/accounts/device_codes.go`: `Controller.DeviceCode`, `generateUserCode` |
| 2 | Operator signs in to the console and submits the code: `POST /v1/device/approve {user_code}` behind `requirePrivyAuth` and `rateLimitFinancial`; code normalised to upper-case; errors `invalid_code`, `expired_code`, `already_used`; success → `ApproveDeviceCode(device_code, account_id)` | `coordinator/api/accounts/device_approval.go`: `Controller.ApproveDevice` |
| 3 | CLI polls `POST /v1/device/token {device_code}` (no auth; the secret is the code): `200 {status: "authorization_pending"}` while pending; `invalid_grant` when unknown; `expired_token` after `DeviceCodeExpiry` or once consumed; on approval `200 {status: "authorized", token, account_id}` | `coordinator/api/accounts/device_tokens.go`: `Controller.DeviceToken` |
| 4 | Token = the provider token whose shape is under [api-contracts](../../reference/api-contracts.md#device-code-flow-3); the store keeps `ProviderToken{TokenHash, AccountID, Label: "device-" + user_code, Active}`; the CLI writes the token to `~/.darkbloom/auth_token` with mode `0600` | `Controller.DeviceToken`; `AuthTokenStore` |
| 5 | The daemon sends it as `register.auth_token` (binding B6) | `coordinator/providercontrol/session/registration.go` (`register`) |
| Logging | `device code created {user_code, expires_in}`, `provider token issued {account_id, user_code}`, `device approved {user_code, account_id, email}` at `Info` — never the `device_code` or the token | `coordinator/api/accounts/device_codes.go`, `coordinator/api/accounts/device_approval.go`, `coordinator/api/accounts/device_tokens.go` |

### Consumer identity: Privy JWT verification

| Property | Value | Code |
|---|---|---|
| Configuration | `EIGENINFERENCE_PRIVY_APP_ID`, `EIGENINFERENCE_PRIVY_APP_SECRET`, and the verification key as `EIGENINFERENCE_PRIVY_VERIFICATION_KEY` (PEM; literal `\n` sequences are expanded) or `EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE`; both app ID and key are required | `coordinator/auth/config.go`; `coordinator/auth/privy.go` (`NewPrivyAuth`) |
| Key | A single **static** PEM `SubjectPublicKeyInfo` parsed with `x509.ParsePKIXPublicKey`; must be ECDSA. There is no JWKS fetch and no key rotation without a restart | `coordinator/auth/privy.go` (`NewPrivyAuth`) |
| Token checks | Algorithm exactly `ES256`; issuer `privy.io`; audience = app ID; standard `exp`/`nbf` via `jwt.RegisteredClaims`; non-empty `sub` | `coordinator/auth/privy.go` (`VerifyToken`) |
| Result | `sub` is the Privy DID (`did:privy:…`); `GetOrCreateUser` looks it up or creates `User{AccountID: uuid, PrivyUserID, Email}` after fetching details from `https://auth.privy.io/api/v1/users/<did>` with Basic auth `app_id:app_secret` and `Privy-App-Id` | `coordinator/auth/privy.go` (`GetOrCreateUser`, `fetchUserDetails`) |
| Admin email OTP | `InitEmailOTP` and `VerifyEmailOTP` encode email/code with typed JSON serialization before calling Privy; quotes, backslashes and control characters remain inside their string fields | `coordinator/auth/privy.go` |
| Failure | Missing header → `401 authentication_error "missing credentials"`; bad token → `401 authentication_error "invalid Privy token"` | `coordinator/api/requestauth/privy_session.go` (`RequirePrivyAuth`) |

### Consumer API-key snapshots

`requireAuth` captures the local auth-cache generation before calling
`AuthenticateKey`. `storeAPIKeyCache` publishes the positive or negative result
only if that generation still matches under the cache mutex. Key update,
delete and rotation invalidate before and after their store mutation; legacy
raw-token revocation invalidates after success. A delayed old lookup cannot
restore a disabled key, obsolete limits, or a negative result for a re-enabled
key (`coordinator/api/requestauth/key_cache.go`, `coordinator/api/accounts/keys_legacy.go`).

An already-running request may finish with the key record it read before the
mutation. Invalidation is local to the coordinator handling the mutation;
other processes and direct store edits rely on the ordinary cache TTL. Provider
device-login token lookups remain uncached (`requireAuth`).

## Invariants

1. The provider's X25519 key is accepted only if the SE-signed blob names it as `encryptionPublicKey` — `coordinator/providercontrol/verification/registration.go` (`Verifier.VerifyRegistration`).
2. All challenge and code-identity signatures are checked against the registration-time SE key — `coordinator/providercontrol/challenge/signature.go` (`verifySignatures`), `coordinator/providercontrol/codeidentity/response.go` (`HandleResponse`).
3. Code identity is granted only if `K` and the APNs token are unchanged since the challenge was issued — `coordinator/registry/code_evidence.go` (`GrantProcessCodeAttested`).
4. An MDA chain is attached only when it binds this SE key or the blob's serial, and only on a `hardware` connection — `coordinator/registry/device_evidence.go` (`SetMDAProofIfHardwareBound`).
5. Hardware posture is taken from the device selected by the blob's serial and must agree with the blob — `coordinator/providercontrol/verification/security_info.go` (`Verifier.VerifySecurityInfo`).
6. `AccountID` is set only from a valid device-linked token, never from anything in the attestation blob — `coordinator/providercontrol/session/registration.go` (`register`), `coordinator/registry/fault_identity.go` (`stableProviderIdentityLocked`).
7. Provider tokens and API keys are stored and looked up by SHA-256 hash only — `coordinator/store/contracts/keys.go` (`hashKey`), `coordinator/api/accounts/device_tokens.go` (`Controller.DeviceToken`).
8. Privy tokens are accepted only with `ES256`, issuer `privy.io`, and the configured audience, under the static configured key — `coordinator/auth/privy.go` (`VerifyToken`).
9. The provider UUID is never used as an identity for trust, reputation, or reuse — `coordinator/registry/fault_identity.go` (`stableProviderIdentityLocked`).

## Failure modes

| Failure | Effect | Code |
|---|---|---|
| Provider restarts | New `K`; B1 re-established by the fresh blob; old-process continuity cannot transfer to the new key. Resume requires a recent APNs proof and an approved application-evidence transition, otherwise a new push | `coordinator/providercontrol/codeidentity/reuse.go` (`reuseAttestation`) |
| Persistent SE key unusable (keychain locked, poisoned) | `loadOrCreateVerified` repairs once, else ephemeral fallback: a new SE identity, so stored trust, code proofs, and MDA binding start over | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift`; `provider-swift/Sources/ProviderCore/ProviderLoop.swift` |
| APNs token rotates | `CodeAttested` cleared; push budget re-keyed (at most once per `budgetClearCooldown` = 20m) | `coordinator/providercontrol/codeidentity/push_rotation.go` (`rotateLoopAndClearPushBudget`) |
| Blob serial does not match any MicroMDM device | `device-not-found`; stays `self_signed`; retried | `coordinator/providercontrol/verification/security_info.go` (`Verifier.VerifySecurityInfo`) |
| MDA leaf serial ≠ blob serial and nonce does not bind the SE key | `mda_verified` stays false | `coordinator/registry/device_evidence.go` (`SetMDAProofIfHardwareBound`) |
| Invalid or revoked provider token | Warning logged; provider connects unlinked (no account, no owner self-route, no payouts) | `coordinator/providercontrol/session/registration.go` (`register`) |
| Privy key rotated upstream | Every consumer token fails `401` until the coordinator is restarted with the new PEM | `coordinator/auth/privy.go` |
| Device code expired or reused | `expired_token` / `already_used`; operator reruns `darkbloom login` | `coordinator/api/accounts/device_approval.go`, `coordinator/api/accounts/device_tokens.go` |

## Code map

| Concern | File (symbol) |
|---|---|
| SE key lifecycle | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` (`loadOrCreateVerified`, `defaultLabel`, `defaultAccessGroup`); `provider-swift/Sources/ProviderCore/Security/SecureEnclaveIdentity.swift` (`createEphemeral`); `provider-swift/Sources/ProviderCore/ProviderLoop.swift` (`createAttestationSigner`) |
| `K` lifecycle | `provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift` (`generate`, `purgeLegacyFiles`) |
| Blob ↔ `K` binding | `coordinator/providercontrol/verification/registration.go` (`Verifier.VerifyRegistration`); `coordinator/attestation/attestation.go` (`AttestationBlob`) |
| Code identity | `coordinator/providercontrol/codeidentity/response.go` (`HandleResponse`); `coordinator/providercontrol/codeidentity/reuse.go` (`reuseAttestation`); `coordinator/providercontrol/codeidentity/persistence.go` (`persistCodeAttestation`); `coordinator/registry/code_evidence.go` (`GrantProcessCodeAttested`) |
| MDA binding | `coordinator/mdm/device_attestation.go` (`RequestDeviceAttestation`); `coordinator/attestation/mda.go`; `coordinator/registry/device_evidence.go` (`SetMDAProofIfHardwareBound`); `coordinator/providercontrol/verification/mda_reuse.go` (`Verifier.AttachCachedMDA`) |
| MDM posture binding | `coordinator/mdm/devices.go` (`LookupDevice`); `coordinator/mdm/security_info.go` (`VerifyProviderWithUDIDObserver`); `coordinator/providercontrol/verification/security_info.go` (`Verifier.VerifySecurityInfo`) |
| Stable identity | `coordinator/registry/fault_identity.go` (`stableProviderIdentityLocked`); `coordinator/registry/provider_attestation.go` (`RebindStableFaultKey`); `coordinator/registry/provider_restore.go` (`RestoreProviderState`) |
| Account linking | `coordinator/api/accounts/device_codes.go`, `coordinator/api/accounts/device_tokens.go`, `coordinator/api/accounts/device_approval.go` (`Controller.DeviceCode`, `Controller.DeviceToken`, `Controller.ApproveDevice`, `DeviceCodeExpiry`, `DeviceCodePollInterval`); `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` (`AuthTokenStore`) |
| Consumer identity | `coordinator/auth/privy.go` (`NewPrivyAuth`, `VerifyToken`, `GetOrCreateUser`); `coordinator/auth/config.go`; `coordinator/api/requestauth/privy_session.go` (`RequirePrivyAuth`) |

| API-key cache publication | `coordinator/api/requestauth/key_cache.go` (`lookup`, `store`, `invalidateAll`); `coordinator/api/requestauth/middleware.go` (`RequireAuth`) |

## Related

- [`attestation.md`](./attestation.md) — the trust levels and flags these bindings feed.
- [`encryption.md`](./encryption.md) — what is sealed to `K`.
- [`enrollment.md`](./enrollment.md) — how the device becomes addressable by serial in MicroMDM.
- [`../../provider/attestation.md`](../../provider/attestation.md) — `darkbloom login`, `darkbloom enroll`, and reading the resulting status.
