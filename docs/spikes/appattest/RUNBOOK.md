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
1. Does a **Developer-ID** (non-App-Store) app get a valid attestation, or does
   `attestKey` reject it (App-ID/profile gating)?  → decides if the provider
   .app is eligible at all.
2. Does `attestKey` succeed **only** under Full Security + SIP-on (WWDC 2026
   claim)? Test SIP-on (expect OK) and, if feasible, SIP-off (expect failure) —
   that failure *is* the security property we want.
3. Capture `ATTESTATION_B64` + `CHALLENGE_B64` and verify server-side that the
   CBOR x5c chains to Apple's **App Attest Root CA** and the rpId == our App ID.

## Status
- macOS 27 is required; confirmed `isSupported=false` on macOS 26.5.1 (laptop)
  and the fleet/M5 box is on 26.x. Need a macOS-27 box online + SSH-reachable.
