# Verifying provider attestation

> Last updated: 2026-09-03 · commit `5d400cf75`

How a consumer reads the coordinator's trust verdict about the provider that
served a request, and what that verdict does and does not prove. The verdict is
computed by the coordinator; consumers receive its result, never the
identity-bearing evidence behind it.

## Public attestation endpoint

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

`GET /v1/providers/attestation` needs no authentication and returns
`{"providers": [...]}` (`handleProviderAttestation`, `coordinator/api/provider.go`).
Each entry carries:

| Field | Meaning |
|---|---|
| `provider_id` | Opaque connection ID; also returned per response as `X-Provider-Id` |
| `chip_name`, `hardware_model`, `memory_gb`, `gpu_cores`, `models[]` | Hardware class and served models |
| `trust_level` | `none`, `self_signed`, or `hardware` (below) |
| `status` | `online`, `offline`, `untrusted`, … |
| `secure_enclave`, `sip_enabled`, `secure_boot_enabled`, `authenticated_root_enabled`, `system_volume_hash`? | Latest posture the coordinator verified |
| `se_public_key` | The provider's Secure Enclave P-256 public key (base64) |
| `mdm_verified` | `true` exactly when the live connection holds `hardware` |
| `acme_verified` | Deprecated, always `false`; kept on the wire for shipped decoders |
| `mda_verified`, `mda_os_version`?, `mda_sepos_version`? | Apple Managed Device Attestation result, surfaced only while the connection holds `hardware` |

Deliberately absent: hardware serial number, UDID, APNs device token, the raw
Apple MDA certificate chain (its leaf embeds serial and UDID in signed OIDs,
so publishing it would disclose them even with the JSON fields removed), and
the `code_attested` flag.

## What the levels mean

| `trust_level` | What it tells you |
|---|---|
| `hardware` | Apple's MDM subsystem on that Mac confirmed SIP and full Secure Boot in agreement with the provider's Secure-Enclave-signed attestation. MDM `SecurityInfo` is the only path to this level; the MDA certificate chain is not required for it |
| `self_signed` | The Secure-Enclave-signed attestation verified and the provider is passing the coordinator's periodic challenge, but there is no MDM confirmation yet |
| `none` | No verified attestation |

The grant and loss conditions for each level are tabulated in
[`../architecture/security/attestation.md#trust-levels`](../architecture/security/attestation.md#trust-levels);
the challenge cadence is in [Layer 2](../architecture/security/attestation.md#layer-2--periodic-challenge)
and the routing freshness window is
[`challengeFreshnessMaxAge`](../architecture/routing.md#challenge-freshness).

`mda_verified: true` adds that Apple issued a Managed Device Attestation whose
certificate chain verifies to the Apple Enterprise Attestation Root CA and
binds the provider's SE key (or serial) — proof of *which* genuine Apple device
holds the key. It is a flag on top of `hardware`, not a level, and it does not
gate routing ([Flag — Apple Managed Device Attestation](../architecture/security/attestation.md#flag--apple-managed-device-attestation)).

Public routing applies the coordinator's trust floor (`MinTrustLevel`, set by
[`EIGENINFERENCE_MIN_TRUST`](../reference/configuration.md#routing-admission-and-ttft))
plus every privacy gate (encrypted response chunks, coordinator-verified SIP,
required privacy capabilities, code identity once enforced), so a request you
send without self-routing is served only by a provider that passes all of them
([`../architecture/security/attestation.md`](../architecture/security/attestation.md#routing-gate)).

## Per-response signals

Once a provider has been committed to your request, the coordinator writes
these headers (`writeCommittedProviderHeaders`,
`coordinator/api/response_metadata.go`):

| Header | Value |
|---|---|
| `X-Provider-Id` | Connection ID; join with the endpoint above |
| `X-Provider-Trust-Level` | `none` / `self_signed` / `hardware` |
| `X-Provider-Attested` | `true` / `false` |
| `X-Provider-Encrypted` | `true` when the provider has a registered X25519 key (the mandatory coordinator → provider hop) |
| `X-Provider-Secure-Enclave` | `true` / `false` |
| `X-Provider-Mda-Verified` | `true`, present only when true |
| `X-Provider-Chip`, `X-Provider-Model` | Hardware class |
| `X-Attestation-Se-Public-Key` | The provider's SE P-256 public key (base64) |
| `X-Eigen-Sealed`, `X-Eigen-Sealed-Kid` | Present when you sealed the request; the body is sealed to your ephemeral key ([`../architecture/security/encryption.md`](../architecture/security/encryption.md)) |

There is **no** per-response signature or receipt: the coordinator does not
sign responses with the provider's SE key, and the headers are the
coordinator's assertion over TLS. What `X-Attestation-Se-Public-Key` lets you
do is pin: compare it with `se_public_key` from the public endpoint across
requests to confirm you are being served by the same attested identity.

Pre-commit errors (validation, capacity, availability) have no selected provider
and therefore no `X-Provider-*` headers.

### Reading the fields from an SDK

OpenAI SDKs generally hide custom headers. Send `metadata_details: true` in the
request body (or the header `X-Darkbloom-Metadata-Details: true`) on
`POST /v1/chat/completions` and the same values arrive in the JSON `metadata`
object: `provider_id`, `provider_attested`, `provider_trust_level`,
`provider_encrypted`, `provider_chip`, `provider_machine_model`,
`provider_secure_enclave`, `provider_mda_verified`,
`attestation_se_public_key`, `timing`, and `location`
(`coordinator/api/types/types.go`, `ChatCompletionMetadata`). `location` is
region/country-level GeoIP only — no city, coordinates, lookup source, or IP.
See [`../reference/api-contracts.md`](../reference/api-contracts.md).

## Code identity

The strongest production gate is APNs code-identity attestation: proof that the
process holding the provider's decryption key is the genuine, team-signed
Darkbloom binary. It is not a consumer-visible field, but once enforcement is
switched on (`APNS_ENFORCE_AFTER`) a provider without it is excluded from
private-text routing, so a served response implies it passed. See
[`../design/apns-code-attestation.md`](../design/apns-code-attestation.md) and
[`../architecture/security/attestation.md`](../architecture/security/attestation.md#flag--apns-code-identity).

## Related

- [`privacy-expectations.md`](./privacy-expectations.md) — what each party can see.
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — sealing your request and reading a sealed response.
- [`../provider/attestation.md`](../provider/attestation.md) — the same verdicts from the operator's side.
