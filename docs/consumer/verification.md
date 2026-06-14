# Verifying Provider Attestation

Consumers and operators can independently verify provider attestation state.

## Public attestation endpoint

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

Returns, per provider:

- Secure Enclave P-256 public key,
- hardware info (chip, model, serial, system volume hash),
- security state (SIP, SecureBoot, ARV, SE),
- MDM verification status,
- Apple MDA certificate chain (base64 DER),
- MDA-extracted properties (serial, UDID, OS version, SepOS version).

## Verify the MDA chain yourself

1. Download Apple's Enterprise Attestation Root CA from
   [apple.com/certificateauthority](https://www.apple.com/certificateauthority/).
2. Decode the `mda_cert_chain_b64` certificates from base64 to DER.
3. Verify the cert chain against Apple's root CA using any x509 library.
4. Check that the serial number in the Apple cert matches the provider's
   self-reported attestation.

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
