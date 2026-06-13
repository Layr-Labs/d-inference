# App Attest device binding — design (issue #328)

Status: **design / spike-gated.** Implementation is blocked on (a) a macOS 27
device to validate the spike and (b) the fleet reaching macOS 27. This document
records the problem, why the obvious fixes fail, and the App Attest design so the
build is fast once the spike (docs/spikes/appattest/) confirms feasibility.

## Problem

The MDA SIP routing gate (#302 / PR #327) verifies the provider's **self-asserted**
attestation serial, not one cryptographically rooted to the connection's
Secure-Enclave key. A malicious owner with a second, genuinely-SIP-on enrolled
Mac can serve inference from a SIP-off box that claims the clean device's serial:
the coordinator's MDM/MDA round-trips (keyed by the claimed serial) hit the clean
Mac and return a genuine SIP-on attestation, so the SIP-off connection routes.
The live per-connection SE challenge proves the SIP-off box holds the SE key it
registered, but nothing binds that key to the claimed serial.

## Why the obvious fixes fail (researched, high-confidence)

1. **mTLS proof-of-possession of the managed ACME identity — NOT viable.** A
   third-party macOS CLI cannot obtain or use the `com.apple.security.acme`
   HardwareBound identity as a client cert. Apple's Device Management engineer:
   *"Third party apps and processes cannot access the identities that device
   management installs into the data protection keychain"*; `AllowAllAppsAccess`
   works only for non-hardware-bound keys. Running as root does not change it.
   The provider's WebSocket uses a bare `URLSession(.default)` with no client
   cert, and cannot present the managed identity.
2. **Read the device-attest-01 cert's permanent-identifier SAN — moot.** Even
   reading the validated serial (the SAN, not the CSR-controlled CN) doesn't
   help, because the ACME key isn't the connection key and the app can't wield
   it. The coordinator-only ACME serial check (prototyped + reverted in #327)
   was also non-functional: the served profile mints a P-384 key the Secure
   Enclave can't hardware-bind (SE is P-256-only; fleet is 0% acme_verified).
3. **No device-ID attestation on Apple.** There is no public macOS API for a
   third-party app to obtain an Apple-signed attestation binding an
   app-generated SE key to the device **serial**. This is the well-known gap.

The X-Ssl-Client-* / ACME→TrustHardware path in the coordinator is therefore
dead (0% functional) AND spoofable (no proxy mTLS, no header strip — open
T-022/SEC-005). It does not bind device identity and should be removed/neutralized
as part of this fix (App Attest supersedes it).

## The fix: App Attest (macOS 27)

App Attest (`DCAppAttestService`) became available on **macOS 27** (WWDC 2026). On
macOS it requires **Full Security + SIP-on**, and it binds an app-generated key to
*genuine Apple hardware running the genuine, unmodified app*. That is a **stronger**
property than the serial for our purpose: we don't need *which* device — we need
*SIP-on + genuine Darkbloom code*. A SIP-off box, or one running modified code,
**cannot** produce a valid App Attest attestation/assertion, so it cannot pass the
gate. The attestation is anonymous (no serial) — which is fine.

### Flow

Provider (macOS 27, signed .app + App Attest entitlement):
1. `DCAppAttestService.shared.generateKey` → `keyID` (a fresh SE-backed key).
2. `attestKey(keyID, clientDataHash: H(coordinator_challenge))` → CBOR attestation.
   Send `{keyID, attestation}` to the coordinator once per connection.
3. For each per-connection challenge nonce, `generateAssertion(keyID,
   clientDataHash: H(nonce ‖ ctx))` → assertion; send it.

Coordinator:
1. Verify the attestation: x5c chains to **Apple's App Attest Root CA**; the
   `rpId` hash equals our **App ID** (Team+bundle); the nonce in the
   authenticatorData credCert matches the challenge we issued; extract + store
   the attested public key + initial counter for `keyID`.
2. Verify each assertion: signature over `H(nonce ‖ ctx)` by the stored public
   key; counter strictly increases.
3. Gate: a connection routes private text under enforcement only if it has a
   valid App-Attest attestation + a fresh valid assertion over the current
   challenge. Per-connection, in-memory, never persisted (like the MDA verdict).

### Why this closes the attack

- App Attest success ⟹ Full Security + SIP-on (Apple-enforced on macOS 27). So a
  routable connection is provably SIP-on — the property #302 wanted — rooted in
  Apple, not self-asserted.
- App Attest binds to the genuine app (Team+bundle, Apple-signed). A modified
  binary (the SIP-off attacker's worker) cannot attest. So the attacker cannot
  present a valid attestation from a SIP-off/modified box, and cannot relay one
  from a clean box because the assertion is keyed to *this connection's* App
  Attest key + *this challenge*.
- No serial is needed; the "second clean Mac" oracle no longer helps.

## Open questions the spike must resolve (docs/spikes/appattest/)

1. **Developer-ID eligibility.** App Attest is keyed to an App ID. Does our
   Developer-ID (non-App-Store) provider `.app` (which already embeds a
   provisioning profile) qualify with the App Attest capability, or is App
   Attest effectively App-Store-only? `aa_attest` answers this.
2. **SIP-on implication.** Confirm `attestKey` succeeds only under Full
   Security + SIP-on (test SIP-on = OK; SIP-off = failure). The SIP-off failure
   *is* the security property.
3. **Curve/key params** and entitlement/provisioning specifics.

## Rollout

- macOS-27-gated. Until the fleet is on 27, providers can't attest → the gate
  must stay in **grace** (measure + log, never deroute), same shape as the MDA
  and APNs gates. Enforcement (`*_ENFORCE_AFTER`) flips only when the fleet is on
  27 and attesting.
- Supersedes + removes the dead/spoofable ACME-header path.

## Protocol / component changes (once the spike confirms feasibility)

- Protocol: register message carries `{appAttestKeyID, appAttestObject}`;
  challenge response carries `appAttestAssertion`. Mirror in
  `provider-swift/.../Protocol/` and `coordinator/protocol/`.
- Coordinator: an App Attest verifier (CBOR + x5c → Apple App Attest Root CA +
  rpId/nonce/counter), a per-connection `AppAttestVerified` gate field, and the
  gate clause in `providerSupportsPrivateTextLocked` behind a grace→enforce
  deadline. Remove the ACME-header trust path.
- Provider-swift: App Attest key gen/attest at startup; assertion per challenge.

## Residual until macOS 27

Documented in docs/threat-model.yaml (TB-005). Strong compensating controls
remain: MDM enrollment, SIP-on/Full-Security MDA attestation, fresh epoch nonce,
the live SE challenge, and the two-enrolled-device bar.
