# Verifying Provider Attestation

Consumers and operators can inspect provider attestation state through the public API.

## Public attestation endpoint

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

Returns, per provider:

- Secure Enclave P-256 public key,
- hardware info (chip, model, system volume hash),
- security state (SIP, SecureBoot, ARV, SE),
- MDM verification status,
- `mda_verified` boolean,
- MDA-extracted properties (UDID, OS version, SepOS version).

## MDA verification

The coordinator verifies the Apple MDA certificate chain internally against the
embedded Apple Enterprise Attestation Root CA. The raw MDA certificate chain is
not exposed publicly because the leaf certificate contains the device serial
number. Consumers see only the `mda_verified` boolean result.

## What verification tells you

- `hardware` trust means the device is genuine Apple hardware with SIP on and
  Secure Boot Full, verified by Apple's MDA certificate chain.
- `self_signed` trust means the provider sent a SE-signed attestation and is
  passing periodic challenge-response, but has not completed MDM/MDA.
- `none` means no attestation was provided.

## Code-identity attestation

The strongest production gate is APNs-based code-identity attestation. It is
not exposed as a separate consumer-visible field today, but it gates whether a
provider is eligible for private-tier routing. See
[`architecture/decisions/apns-code-attestation.md`](../architecture/decisions/apns-code-attestation.md).
