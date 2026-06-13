# App Attest feasibility spike — #328

Goal: confirm, on a **macOS 27** device, whether the Darkbloom provider (a
Developer-ID `.app`, not App Store) can use App Attest to bind its connection
key to a genuine, SIP-on, unmodified-app device — the candidate complete fix
for the self-asserted-serial gap.

## Step 1 — probe (any box; decisive)
    swiftc aa_probe.swift -o aa_probe && ./aa_probe
- macOS < 27 → `isSupported=false` → STOP (this is the current fleet state).
- macOS 27 → `isSupported=true` → go to Step 2.

## Step 2 — real attestation (needs a signed bundle + entitlement)
App Attest requires a bundle ID + the App Attest entitlement + a provisioning
profile granting the capability for that Team+bundle. Wrap aa_attest in a minimal
.app (reuse the provider's signing identity + a profile with App Attest enabled):
    swiftc aa_attest.swift -o AAttest.app/Contents/MacOS/AAttest
    codesign -f -s "Developer ID Application: <team>" \
      --entitlements aa.entitlements \
      --options runtime AAttest.app
    AAttest.app/Contents/MacOS/AAttest

## Make-or-break questions this answers
1. Does a **Developer-ID** (non-App-Store) notarized .app get a valid attestation
   with `apple_validation_category == 6`, or does `attestKey` reject it? → decides
   if the provider .app is eligible at all.
2. Does the attestation's **`aclBlob` (OID 1.2.840.113635.100.8.6)** carry the
   Full-Security + SIP-on policy under SIP-on, and differ / fail under SIP-off?
   That difference *is* the security property (do NOT rely on attestKey success
   alone — codex round-3 finding).
3. Capture `ATTESTATION_B64` + `CHALLENGE_B64`; verify server-side: CBOR
   `fmt==apple-appattest`, x5c → Apple App Attest Root CA, nonce =
   `SHA256(authData‖SHA256(clientData))` vs credCert OID 1.2.840.113635.100.8.2,
   `rpIdHash` (macOS uses the **signing identifier** — capture the exact value),
   keyID == SHA256(pubkey), counter==0.

## Beyond this minimal spike (required before building — codex round-3)
- **Two-Mac relay test (the one that matters):** M_dirty (real coordinator) +
  M_clean (genuine app as signing oracle). Confirm that binding the attestation
  to the provider's E2E key `K` makes the relay pointless (plaintext stays on
  M_clean) and M_dirty can't bind its own `K`. A fresh challenge stops replay,
  NOT live relay.
- `generateAssertion` verify + replay/stale/out-of-order/counter-race + a
  negative corpus mutating each required field (x5c, rpId, nonce, aclBlob, counter).
- TLS-exporter (channel binding) availability vs the `K_pub`-in-clientData +
  `E_K(nonce)` + seal-to-K approach.
- App Attest per-connection rate-limit behavior.

## Status
- macOS 27 is required; confirmed `isSupported=false` on macOS 26.5.1 (laptop)
  and the fleet/M5 box is on 26.x. Need a macOS-27 box online + SSH-reachable.
