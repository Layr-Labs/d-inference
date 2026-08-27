# Verifying Provider Attestation

Consumers can inspect privacy-redacted provider trust status.

## Public attestation endpoint

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

The response includes each provider's opaque connection ID, Secure Enclave
public key, hardware class, security posture, and coordinator-verified MDM/MDA
status. It deliberately excludes hardware serial numbers, UDIDs, and raw Apple
MDA certificates. Apple's MDA leaf certificate embeds those identifiers, so
publishing the chain would disclose them even if the JSON fields were removed.

## What verification tells you

- `hardware` trust means the coordinator verified MDM security posture and the
  Apple MDA certificate chain before admitting the provider at hardware trust.
- `self_signed` trust means the provider sent a SE-signed attestation and is
  passing periodic challenge-response, but has not completed MDM/MDA.
- `none` means no attestation was provided.

The coordinator performs Apple certificate-chain and serial cross-checks
privately. Consumers receive the resulting status, not the identity-bearing
certificate material.

## Per-response proof

Inference responses expose the provider's Secure Enclave public key and signed
response receipt without exposing its device serial. Consumers can verify that
receipt against the published key.

The same consumer-safe provider fields (`provider_id`, `provider_attested`,
`provider_trust_level`, `attestation_se_public_key`, timing) are always on
the `X-Provider-*` / `X-Timing` headers. City/region GeoIP of the serving
provider is included only in the opt-in JSON `metadata.location` object
(no coordinates, no raw IP). To read these from an OpenAI SDK that does not
surface custom headers, send `metadata_details: true` (or
`X-Darkbloom-Metadata-Details: true`) on `POST /v1/chat/completions` and read
the JSON `metadata` object. See [`api-contracts.md`](../reference/api-contracts.md).

## Code-identity attestation

The strongest production gate is APNs-based code-identity attestation. It is
not exposed as a separate consumer-visible field today, but it gates whether a
provider is eligible for private-tier routing. See
[`architecture/decisions/apns-code-attestation.md`](../architecture/decisions/apns-code-attestation.md).
