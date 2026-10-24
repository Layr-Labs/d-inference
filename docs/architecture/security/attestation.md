# Provider Attestation

> Last updated: 2026-10-13

Provider attestation binds keys and reported runtime identity to an approved
process. It does not prove model correctness, physical uniqueness, certified
RAM or guaranteed removal of plaintext from memory. External grant policy is
maintained in [platform attestation](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/security/attestation.md).

Current backend behavior is owned by the latest default branch of
`Layr-Labs/darkbloom-platform`. Immutable links here preserve reviewed evidence,
not current source or deployment state. No backend implementation is retained
in this repository. The [authorization reference](../../reference/provider-authorization.md)
describes the consumed contract; provider support does not activate platform policy.

## Provider connection control

`provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift` consumes
`app_attest_shadow`, `trust_status` and
connection invalidation independently of the ordered inference/model consumer.
These actor-isolated handlers do not await model work. A suspended model load
therefore does not postpone starting App Attest or writing received authorization
to daemon state. Connect, disconnect and stream termination clear the old local
grant and invalidate the previous App Attest task generation before subsequent
challenges are handled. Delayed model cleanup does not clear a replacement
connection's grant.

The existing App Attest client and Apple-operation admission still serialize
proof work. Cancellation cannot cancel Apple's underlying native call. Replies
use the originating-socket `AppAttestShadowReply` capability, which rechecks the
current transport immediately before submission. A late callback therefore
cannot send an old proof through a replacement connection even before the
reader consumes disconnect. See the [reply contract](../../reference/protocol-messages.md#app-attest-endpoint-resumption-candidate).
Local Apple success is not a completed outbound write or coordinator acceptance.
This dispatch change adds no retry, grace period or trusted lifetime; the
coordinator still verifies fresh evidence and enforces expiry and revocation.
Synchronous actor occupation, system suspension, Apple service availability and
transport failure remain separate availability limits.

The separate [endpoint-resumption candidate](../../reference/protocol-messages.md#app-attest-endpoint-resumption-candidate)
answers directly in `CoordinatorClient` using the fixed process key and a fresh
socket nonce. It does no Apple work and creates no local authorization. The
existing responsive `app_attest_shadow` and `trust_status` handling above is
unchanged. Only a matching platform implementation can use the custody response
with retained evidence; it must preserve original proof deadlines and current
authorization/revocation checks. Provider support alone is not deployment or
native qualification evidence.

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

Generic client-reported Apple API failures (`apple_error`) use bounded exchange recovery under the platform policy below. They are unknown observations, not verified security denials. Retrying neither creates a serving grant nor extends its deadline; fresh proof still passes applicable qualification, revocation and binding checks. Verified cryptographic or policy violations remain terminal.

Closed client diagnostics separate local availability failures and synthetic callback/proof failures from native DeviceCheck errors. The platform bounds them before archival and emits them only as evidence about a failed exchange. They do not enter `clientDataHash`, the verifier, or `EvaluateAuthorization`, so reporting a reason cannot grant serving.

The [reviewed platform authorization contract](https://github.com/Layr-Labs/darkbloom-platform/blob/20b821646acfbf0968d1c30239cb583eeb0fa2bc/docs/reference/provider-authorization.md) separates `EvaluateAuthorization` for basic serving from `EvaluateReceiptMonitoring`. Missing recurring receipt/risk evidence alone neither blocks otherwise qualified basic serving nor adds assertions; it withholds reward/MDM-removal readiness under the stricter receipt and decision-freshness checks. First authorization still requires a fresh cryptographically verified, durably accepted assertion, qualified build, non-revoked credential, bound identity and successful current administrative reads. Only an established exact identity may retain last-known policy within the [original proof and administrative ceilings](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#controls). Failed reads, status delivery, receipt monitoring and renewal/retry attempts cannot extend those ceilings. The pin records reviewed semantics, not current platform source or proof of deployment; provider protocol fields are unchanged.

Providers are adversarial ([`../../threat-model.yaml`](../../threat-model.yaml),
`ADV-001`). The legacy blob authenticates provider-supplied data with its embedded
P-256 public key; a valid self-signature alone does not prove Secure Enclave
provenance or the truth of its posture fields. MDM independently supplies
SecurityInfo, while APNs binds its entitled application identity to a challenge
answered by the endpoint and signing keys. App Attest adds Apple-verified key
and application evidence under the separate qualification policy. Its signed
app-origin hardware and runtime reports remain distinct from independent Apple
measurements. See [identity binding](identity-binding.md#app-attest-v3-endpoint-binding)
and [provider trust](provider-trust.md) for those limits. Sources:
[coordinator/attestation/attestation.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/attestation/attestation.go) (`VerifyJSON`),
[coordinator/appattest/verify.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/appattest/verify.go) (`Verifier.Attestation`, `Verifier.Assertion`),
and `provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift`
(`buildAttestation`).

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
