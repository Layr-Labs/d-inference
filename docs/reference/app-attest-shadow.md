# App Attest shadow protocol and observations

> Last updated: 2026-09-14 · commit `2f39698d2`

Reference for the optional App Attest exchange alongside APNs and MDM. Shadow evidence is stored and measured independently; it never changes provider trust, routing, rewards, or the minimum supported macOS version. The rollout decision is in [the coexistence plan](../design/app-attest-migration.md).

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `EIGENINFERENCE_APP_ATTEST_SHADOW` | `true` | Request shadow exchanges from providers advertising protocol 1; `false` sends no shadow requests. No enforcement mode exists. |
| `EIGENINFERENCE_APP_ATTEST_APP_ID` | `SLDQ2GJ6TL.io.darkbloom.provider` | Expected relying-party identity: team prefix plus macOS signing identifier. |
| `EIGENINFERENCE_APP_ATTEST_ENVIRONMENT` | `production` | Expected App Attest environment; only `production` and `development` are recognized. Invalid configuration records a shadow error without changing legacy verification. |

Code: `coordinator/api/app_attest_shadow_config.go` (`readAppAttestShadowConfig`), `coordinator/api/server_config.go` (`ReadServerConfig`). Direct `ServerConfig{}` construction leaves shadow disabled; the normal environment loader enables it by default.

## Wire exchange

`register.app_attest_protocol = 1` negotiates the feature. An older coordinator ignores it; an older provider receives no unknown frame. Each new frame uses `type = "app_attest_shadow"` and a nested `payload`. All actions carry a coordinator-generated random `session`; requests carry the expected `environment`.

| Direction | `payload.action` | Fields and behavior |
|---|---|---|
| Coordinator → provider | `prepare` | Check OS/API support, signed CDhash opt-in, and any explicit signed environment; retrieve or generate a key identifier off the serving loop. |
| Provider → coordinator | `ready` | `result`; on success, `key_id`. These are provider reports, not proof. |
| Coordinator → provider | `attest` | Unknown key only: `key_id`, one-time `challenge`. |
| Provider → coordinator | `attestation` | `result`, `key_id`, `challenge`, base64 `proof`. Verify Apple chain, nonce, identity, environment, credential/public key, and exact Mac ACL before inserting the shadow key. |
| Coordinator → provider | `assert` | Known key: `key_id`, `encrypted_challenge` sealed to the registered X25519 key. The plaintext challenge is omitted. |
| Provider → coordinator | `assertion` | The app decrypts with its own process key; returns `result`, `key_id`, recovered `challenge`, base64 `proof`. Verify signature/transcript and atomically advance the stored counter. |

Code: `coordinator/protocol/app_attest_shadow.go` (`AppAttestShadowPayload`), `provider-swift/Sources/ProviderAppAttest/ShadowProtocol.swift` (`AppAttestShadowPayload`).

The SHA-256 transcript encodes these UTF-8 strings in order, each preceded by its four-byte unsigned big-endian byte length: domain `darkbloom.app-attest.shadow.v1`, request action (`attest` or `assert`), session, environment, App Attest key ID, plaintext challenge, and the app's locally held X25519 public key. The provider never signs a caller-supplied endpoint key. Go/Swift tests pin an independently calculated transcript vector.

## Bounds and lifecycle

| Boundary | Behavior | Code |
|---|---|---|
| Initial spread | Random 0–29 seconds per negotiated connection | `coordinator/api/app_attest_shadow.go`, `run` |
| Outstanding work | One worker and two-message inbox per connection; four concurrent verify/store operations globally; excess work is dropped or reported busy | Same file, `offer`, `run` |
| Response deadline | 90 seconds; failure/timeout ends shadow work for that connection | Same file, `run` |
| Fresh assertions | Every 10 minutes after a verified assertion; reconnect starts a fresh exchange | Same file, `run` |
| Storage deadline | Two seconds per handling operation | Same file, `run` |
| Payload bounds | 48 KiB JSON frame, 32 KiB decoded proof; bounded CBOR depth, arrays, map entries; duplicate CBOR keys rejected | `coordinator/protocol/messages.go`, `DecodeProviderMessage`; `coordinator/appattest/verify.go` |
| Apple retries | Up to three attestation calls, with 2/8-second waits, only for server unavailable and with the same key/hash | `provider-swift/Sources/ProviderAppAttest/AppAttestShadowClient.swift`, `respond` |
| Key lifecycle | Keychain identifier and attested state persist across updates/reconnects; an invalid/unregistered key is replaced at most hourly; private key stays in Apple's service | Same file; `KeychainShadowKeyStorage.swift` |
| Cancellation | Connection cancellation stops delivery; late Apple callbacks cannot deliver into a new session generation | `provider-swift/Sources/ProviderCore/ProviderLoop+AppAttestShadow.swift` |

Failures are retried on a later provider reconnect, not by forcing reconnection. Unsupported devices keep serving under existing APNs/MDM policy. There is no shadow-triggered update, restart, enrollment change, or trust mutation.

## Observations

The coordinator emits `App Attest shadow observation` through its telemetry emitter, with `event = app_attest_shadow`. Logs include coordinator-assigned `provider_id`, random `shadow_session`, `stage`, `outcome`, duration, provider-reported OS/chip/build, inbox-drop count, and the contemporaneous legacy trust/code/MDA flags. Raw proofs, receipts, tokens, and certificates are excluded. Platform/build claims remain labelled as reports.

| Metric | Tags / meaning |
|---|---|
| `app_attest.shadow.events` | `mode:shadow`, `stage`, `outcome`; includes registration denominator, attempts, unsupported/error outcomes and verified evidence. |
| `app_attest.shadow.duration_ms` | Same tags; elapsed from the current shadow request. |
| `app_attest.shadow.metadata` | `result:matched`, `metadata_missing`, or `metadata_mismatch`; expected Developer ID launch category 6 and the registered provider version. |

`verified` establishes cryptographic validity and the required Mac ACL for an attestation, or signature/freshness/counter validity for an assertion. Missing or mismatched app-version/launch metadata is a separate observation, never silently promoted to an accepted release policy. A metadata match compares the app fields with registration; it does not establish membership in the approved-release catalog. Apple-originated fields are distinct from provider reports. Fraud-receipt polling is not implemented in this release.

`coordinator/appattest/authenticator.go` (`validationCategory`) accepts an unsigned CBOR integer fitting `uint32` or an exact four-byte little-endian byte string for `apple_validation_category_01`. It rejects other representations, including null; unknown numeric values remain unknown categories. This compatibility rule does not relax signature or Mac policy checks. See the [specification review](../reports/2026-09-14-app-attest-spec-review.md) and [proposed retirement policy](../design/app-attest-retirement.md) for evidence and remaining work.

Coverage analysis must count distinct provider/session identities, not raw event counts. Separate registration, preparation, key enrollment, and assertion populations. Group logs by reported OS/build/hardware; keep unsupported, unconfigured, disconnected, busy, timeout, invalid-proof, and dropped observations visible. Do not equate repeated assertions from one Mac with coverage of additional Macs. The database key table is not a coverage denominator: it contains successful enrollments only. Logs/metrics retain their existing telemetry retention and delivery limits.

## Storage

`app_attest_shadow_keys` stores key ID, owner binding, verified public key, app/environment metadata, monotonically increasing counter, and timestamps. The owner binds the authenticated registration account and existing SE identity. Insert conflicts do not overwrite ownership; conditional counter updates reject replay across concurrent connections and coordinator restarts. This table grants no provider trust and does not replace provider/rewards identity.

Code: `coordinator/store/app_attest_shadow.go` (`AppAttestShadowStore`), `postgres_app_attest_shadow.go`, `memory_app_attest_shadow.go`. Access uses `store.As` through decorators. The normal idempotent schema migration adds the table; existing tables and records are retained.

## Packaging and live acceptance

`scripts/prepare-app-attest-entitlements.py` preserves APNs production signing and existing keychain grants. It prepares the `CDhash` opt-in independently from the environment entitlement, preserving a granted string or array type and requesting only `CDhash`. The regenerated macOS Developer ID profile inspected on 2026-09-14 grants `com.apple.developer.devicecheck.app-attest-opt-in = ["CDhash"]` and no `appattest-environment`; that is sufficient to configure the local shadow attempt. If the profile also explicitly grants the production environment entitlement, the helper includes it; otherwise it does not manufacture one. Both provider release and signing-validation workflows use this helper and compare extracted signed entitlements against its result. A profile without the grant produces a legacy-compatible bundle; on a supported OS the client reports `not_configured`.

The real adapter checks macOS 27+, `DCAppAttestService.isSupported`, the app bundle, and the signed CDhash opt-in through `AppAttestEntitlementPolicy`. An explicit environment entitlement must match the requested environment; its absence does not determine the environment and does not block an attempt. The coordinator still verifies the environment from Apple-signed attestation evidence before recording success. Current SDK compilation and unit tests do not establish live Mac eligibility. Verify that the final additive signing/profile configuration still launches and completes APNs/MDM checks on existing supported macOS versions. The exact profile grants, launch mechanism, metadata extensions, and Apple acceptance require a physical macOS 27 Mac with the final signed app. No private daemon entitlement is manufactured. [Apple's macOS restrictions](https://developer.apple.com/forums/thread/836329) apply to shadow mode too.

## Validation

Run `go test ./coordinator/appattest ./coordinator/protocol ./coordinator/store ./coordinator/api -run 'TestAppAttest|TestValidationCategoryEncodings|TestAssertionAuthenticatesByteEncodedCategory'`, and repeat with `-race`. PostgreSQL tests require a disposable `DATABASE_URL`; the store harness truncates test tables. In `provider-swift`, run `swift test --filter 'AppAttestShadowTests|AppAttestEntitlementPolicyTests'`. Run `python3 scripts/test-app-attest-entitlements.py` and `python3 scripts/test-provider-signing-validation.py` for packaging controls.

The API coexistence test first proves a provider is eligible, processes failed and successful shadow evidence, checks authoritative state/capacity, and completes encrypted inference. Tests use private fixtures without allowing production root overrides. Live Mac, final signing/notarization, and production rollout remain separate acceptance results.
