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
2. `attestKey(keyID, clientDataHash: SHA256(coordinator_challenge ‖ K_pub))`
   → CBOR attestation. Send `{keyID, attestation, K_pub}` once per connection.
   Binding `K_pub` (the provider's E2E X25519 public key) into the clientData is
   what ties the attestation to the key that gates plaintext.
3. For each per-connection challenge nonce, `generateAssertion(keyID,
   clientDataHash: SHA256(nonce ‖ K_pub))` → assertion; send it. (Plus the
   existing `E_K(nonce)` round-trip to prove live possession of `K`'s private
   half on this connection.)

Coordinator verifier (per Apple's "Validating Apps That Connect to Your Server",
adjusted for macOS — get these exact, they are easy to get wrong):
1. CBOR-decode; require `fmt == "apple-appattest"`.
2. Verify the `x5c` chain to **Apple's App Attest Root CA**; check cert validity.
3. **Nonce:** compute `nonce = SHA256(authData ‖ SHA256(clientData))` and compare
   it to the value in the credCert extension **OID 1.2.840.113635.100.8.2** —
   NOT "credCert contains the raw challenge". `clientData` here is
   `challenge ‖ K_pub`, binding the attestation to this connection's `K`.
4. **rpId:** `SHA256(rpId)` must equal `authData.rpIdHash`. On **macOS the rpId
   uses the app's signing identifier**, not `TeamID.bundleID` — pin the exact
   value observed in the spike.
5. **SIP/Full-Security policy:** check the `aclBlob` extension **OID
   1.2.840.113635.100.8.6** against Apple's documented Full-Security + SIP-on
   access-policy hash. This — not chain/nonce success — is what makes a verified
   attestation imply SIP-on. Also verify the env/aaguid (`appattest` prod vs
   `appattestdevelop`) and `apple_validation_category` (`6` = Developer ID).
6. Bind the public key: `keyID == SHA256(attested EC public key)`; store the key
   + `counter == 0` (initial) for this connection.
7. Per assertion: signature over `SHA256(authData ‖ clientDataHash)` by the stored
   key; `counter` strictly greater than the last seen; `rpIdHash` matches.
8. Challenges: high-entropy, purpose-bound, per-connection, TTL'd, consumed once
   on BOTH success and failure.
9. Gate: a connection routes private text under enforcement only with a fully
   verified attestation (incl. the aclBlob policy) bound to the `K` advertised on
   this connection, a proven `E_K(nonce)`, and a fresh valid assertion.
   Per-connection, in-memory, never persisted (like the MDA verdict).

### Why a naive "sign the challenge" design does NOT close it (codex review, round 3)

A fresh per-connection challenge stops *replay* but NOT *live relay*. If the
coordinator only requires "an App-Attest key signed this challenge," the two-Mac
attacker wins: `M_dirty` (SIP-off, modified) opens the real WebSocket, relays the
challenge to `M_clean` (genuine app, SIP-on), `M_clean` produces a valid
attestation/assertion, `M_dirty` forwards it. The counter still increments
monotonically (it's `M_clean`'s real counter) and the one-time challenge still
matches (it's live). App Attest here is just a **remote signing oracle** — it
proves "a genuine app somewhere signed these bytes," not "the process holding
this connection is that genuine app." This is the same class of bug as a
detached attestation; a fresh nonce is necessary but not sufficient.

### What actually closes it: bind the attestation to the E2E decryption key K

The fix is channel/transport binding via the key that already gates plaintext —
the provider's X25519 E2E key `K` (consumer prompts are sealed to `K`; only the
provider process holding `K`'s private half can decrypt). Bind the App Attest
proof to `K`:

- The App Attest assertion's `clientDataHash` covers the provider's **public K**
  (the exact key advertised on this connection) plus a per-connection,
  TTL'd, one-time coordinator challenge. The coordinator additionally proves
  liveness of `K` with the existing `E_K(nonce)` round-trip (see
  apns-code-attestation-design.md) so the connection demonstrably holds `K`'s
  private half.
- **All routed inference stays sealed to `K`** (already true today).

Now relay is *pointless*, not just hard: if `M_dirty` relays `M_clean`'s genuine
App-Attest proof, the coordinator binds the connection to whatever `K` the
genuine app vouched for — and the genuine app only ever vouches for **its own**
`K_clean` (it signs over the key it generated). Prompts are then sealed to
`K_clean`, which only `M_clean` can open. `M_dirty` becomes a dumb pipe that
never sees plaintext — which defeats the attacker's actual goal (reading
plaintext on a SIP-off box). The work is served by a genuine, SIP-on app, exactly
as intended. A SIP-off box that wants the plaintext itself must bind its own
`K_dirty`, which requires a valid App-Attest proof for `K_dirty` from a SIP-off /
modified process — which App Attest refuses to produce.

- App Attest success (fully verified, incl. the `aclBlob` policy check below)
  ⟹ genuine, unmodified app on Full Security + SIP-on hardware — rooted in
  Apple, not self-asserted. No device serial is needed.

This makes the design an extension of the existing APNs code-identity work
(E_K(nonce) + continuous sealing to K), with App Attest supplying the
Apple-rooted "genuine app + SIP-on" proof of the keyholder.

## Open questions the spike must resolve (docs/spikes/appattest/)

1. **Developer-ID eligibility.** App Attest is keyed to an App ID. Does our
   Developer-ID (non-App-Store) provider `.app` (already a signed/notarized
   bundle with an embedded provisioning profile) qualify with the App Attest
   capability + production env, yielding `apple_validation_category == 6`
   (Developer ID)? The App Attest entitlement docs don't yet list macOS, so treat
   this as **unproven, spike-gated**, not solved.
2. **SIP-on implication via aclBlob.** Confirm the attestation's `aclBlob` (OID
   1.2.840.113635.100.8.6) carries the Full-Security + SIP-on policy hash under
   SIP-on, and that it differs / `attestKey` fails under SIP-off / Reduced
   Security. The SIP-off difference *is* the security property — and the check is
   on the aclBlob, not mere attestKey success.
3. **Channel binding feasibility.** Can the genuine app derive a TLS exporter for
   its own connection (to bind the proof to the transport), or must we rely on
   the `K_pub`-in-clientData + `E_K(nonce)` + seal-to-K binding (the planned
   approach)? Confirm `K_pub` can be threaded into `attestKey`/`generateAssertion`
   clientData.
4. **The relay test (the one that matters).** Two boxes: `M_dirty` holds the real
   coordinator connection, `M_clean` runs the genuine app as a signing oracle.
   Verify that binding to `K` makes the relay pointless (plaintext stays on
   `M_clean`) and that `M_dirty` cannot bind its own `K_dirty` without a valid
   SIP-on attestation.
5. **Verifier negative corpus + assertion mechanics.** `generateAssertion`
   verification; replay / stale / out-of-order / counter-race; a corpus mutating
   each required field (bad x5c, wrong rpId, wrong nonce, wrong aclBlob, reused
   counter) must all be rejected.
6. **Curve/key params**, entitlement/provisioning specifics, and per-connection
   **rate-limit** behavior (App Attest may throttle attestations).

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
