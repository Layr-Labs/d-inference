# Provider Attestation

> Last updated: 2026-10-09

Provider attestation binds keys and reported runtime identity to an approved
process. It does not prove model correctness, physical uniqueness, certified
RAM or guaranteed removal of plaintext from memory. External grant policy is
maintained in [platform attestation](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/security/attestation.md).

## Presentation and dispatch history

The provider and console report separate legacy and App Attest verdicts. A
cached display, successful registration or historical dispatch verdict is not
current permission. Follow [provider diagnostics](../../provider/attestation.md)
and the [authorization contract](../../reference/provider-authorization.md).

## Context

The operator controls the Mac; the provider must preserve its hardened runtime,
key ownership and request boundaries. The Secure Enclave signs evidence, but
MLX inference runs outside the enclave. Read the [privacy model](encryption.md)
before interpreting a trust badge as an information-flow guarantee.

## Mechanism

### Trust levels

Legacy `none`, `self_signed` and `hardware` labels describe distinct evidence.
Qualified App Attest serving is independent and does not set legacy MDA/APNs
flags. A provider may be authorized through one path without satisfying the
other. Failed or unavailable proof is not a successful authorization.

### Layer 1 — Secure Enclave registration blob

`AttestationBuilder` and `AttestationSigner` under
`provider-swift/Sources/ProviderCore/Security/` assemble and sign registration
evidence. `PersistentEnclaveKey.swift` owns the persistent hardware-bound key;
the X25519 transport key remains process-owned. Preserve key/endpoint binding
and the signed field order when changing the [protocol](../../reference/protocol-messages.md).

### Layer 2 — periodic challenge

Fresh challenge responses bind the received nonce to current evidence. Never
reuse a signed response across a new challenge or bypass verification because
the transport reconnected. Preserve cancellation, deadlines and key ownership.
The exact verifier and freshness policy live in the external platform.

### Runtime manifest

`provider-swift/Sources/ProviderCore/Security/BinaryHasher.swift` measures the
runtime using an anonymous source-matched metallib snapshot. Preserve the
documented snapshot validation and environment rules in the
[configuration reference](../../reference/configuration.md#runtime-metallib-snapshots).
File hashes alone do not prove the executed model's output.

### Layer 3 — MDM SecurityInfo (the `hardware` grant)

Legacy posture is independently evaluated by the platform. Device-reported
SIP/Secure Boot values and possession of a copied profile are not substitutes
for its verification. `AuthenticatedRootEnabled` remains informational, not
an enforced minimum requirement. See [enrollment](enrollment.md).

### Flag — Apple Managed Device Attestation

MDA device-certificate evidence is separate from process-code identity and from
App Attest. Do not collapse the flags in local presentation or claim MDA from a
generic signed registration. The platform owns Apple-chain verification.

### Flag — APNs code identity

The legacy APNs challenge binds an approved app to its provider keys. Preserve
the app's provisioning profile and signed artifact checks; a reported binary
hash alone is not the legacy code-identity mechanism. App Attest is a separate
path with its own availability and exact-build requirements.

### Routing gate

Only the external platform grants permission to receive private network work.
Registration, heartbeats, local health and shadow App Attest results do not
individually prove routability. Provider diagnostics must retain distinct denied,
pending, expired, revoked and unsupported states, rather than treating unknown
as success. No local docs or tests authorize a backend policy rollout.

### Trust status messages to providers

Consume typed trust status without publishing raw credentials, certificates or
Apple receipts. Keep code measurements, authorization and local health distinct.
For recovery, use the [operator procedure](../../provider/attestation.md), not
arbitrary Keychain deletion or employer-profile removal.

## Invariants

- Keep current endpoint/key binding, nonce freshness and exact signature bytes.
- Never infer a serving grant from shadow collection, a version string or a
  local status flag. Real Apple and exact signed-build qualification are separate.
- Preserve one-time key generation budgets and bounded uncertain-operation
  recovery in `provider-swift/Sources/ProviderAppAttest/`.
- Keep legacy and App Attest proof/presentation independent.

## Failure modes

Missing entitlement, unsupported OS, unavailable Apple service, failed proof,
expired qualification or an altered runtime can prevent authorization. Preserve
the actual failure category and retry policy. A local fixture or successful
compile does not override a denied external grant.

## Code map

| Responsibility | Source |
|---|---|
| Signed legacy evidence and hardware key | `provider-swift/Sources/ProviderCore/Security/` |
| Apple operation gates, credentials, transcripts and callbacks | `provider-swift/Sources/ProviderAppAttest/` |
| Wire contract | `provider-swift/Sources/ProviderCore/Protocol/` |
| Platform verifier and grant policy | [External source](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/appattest) |

## Related

- [Identity binding](identity-binding.md)
- [Coexisting trust paths](provider-trust.md)
- [App Attest protocol](../../reference/app-attest-shadow.md)
- [Release qualification](../../operations/provider-release.md)
