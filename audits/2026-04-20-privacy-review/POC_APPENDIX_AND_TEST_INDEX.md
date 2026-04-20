# POC Appendix And Regression-Test Index

Date: 2026-04-20

This appendix indexes the proof-backed findings produced during the Dark Bloom privacy review.

## Code Paths

Coordinator-side proof files:

- `coordinator/internal/api/privacy_poc_test.go`
- `coordinator/internal/registry/privacy_poc_test.go`

Provider-side proof locations:

- `provider/src/coordinator.rs`
- `provider/src/proxy.rs`

Supporting portability fixes required by the provider-side proof work:

- `provider/Cargo.toml`
- `provider/src/main.rs`

## Test Inventory

### Coordinator API proofs

File: `coordinator/internal/api/privacy_poc_test.go`

1. `TestPrivacyPOC_ProviderErrorPlaintextLeaksToClientAndLogs`
   - proves provider plaintext error content can reach both client responses and coordinator logs in the chat path

2. `TestPrivacyPOC_TranscriptionProviderErrorPlaintextLeaksToClient`
   - proves provider plaintext error content can reach transcription clients

3. `TestPrivacyPOC_ImageProviderErrorPlaintextLeaksToClient`
   - proves provider plaintext error content can reach image-generation clients

4. `TestPrivacyPOC_ValidSelfSignedAttestationMakesProviderImmediatelyRoutableAtSelfSignedFloor`
   - proves a valid self-signed provider becomes immediately routable when the minimum trust floor is lowered to `self_signed`

5. `TestPrivacyPOC_StoredHardwareTrustRestoresThroughRealRegistrationPath`
   - proves stored hardware-trust state can be restored through the real registration path and make the provider immediately hardware-routable

6. `TestPrivacyPOC_HandleChunkCopiesPlaintextIntoCoordinatorChannel`
   - proves plaintext response chunks are copied into coordinator-side channels before downstream delivery

### Coordinator registry proofs

File: `coordinator/internal/registry/privacy_poc_test.go`

7. `TestPrivacyPOC_OpenModeProviderBecomesRoutableWhenTrustFloorLowered`
   - proves Open Mode providers become routable if the global trust floor is lowered to `none`

8. `TestPrivacyPOC_RestoreProviderStateCanRegrantHardwareTrustImmediately`
   - proves restored provider state can immediately regrant hardware trust before fresh re-verification completes

9. `TestPrivacyPOC_RegisterDefaultsRuntimeVerifiedBeforeManifestChecks`
   - proves registration starts with `RuntimeVerified=true` before any manifest gate is applied

### Provider-side proofs

File: `provider/src/coordinator.rs`

10. `test_privacy_poc_plaintext_inference_request_without_encrypted_body_reaches_event_loop`
    - proves plaintext inference request fallback is still accepted

11. `test_privacy_poc_plaintext_transcription_request_without_encrypted_body_reaches_event_loop`
    - proves plaintext transcription request fallback is still accepted

12. `test_privacy_poc_plaintext_image_request_without_encrypted_body_reaches_event_loop`
    - proves plaintext image-generation request fallback is still accepted

File: `provider/src/proxy.rs`

13. `test_privacy_poc_transcription_failure_leaves_named_tmp_file_behind`
    - proves a failed transcription request can strand a named `/tmp/eigeninference-stt-<request_id>.wav` artifact

## Rerun Commands

Coordinator-side:

```bash
cd coordinator
go test ./internal/api -run TestPrivacyPOC_ -v
go test ./internal/registry -run TestPrivacyPOC_ -v
```

Provider-side:

```bash
cd provider
cargo test --no-default-features privacy_poc -- --nocapture
```

## Current Rerun Status

As of 2026-04-20:

- Coordinator-side Go proofs reran successfully in the local review environment.
- Provider-side Rust proofs also reran successfully in the local review environment after restoring a real local `pkgconf` binary and pointing Cargo at the local OpenSSL metadata via `PKG_CONFIG_PATH=/home/arya/.local/openssl-3.0.20/lib64/pkgconfig`.

That means:

- the proof set is currently rerunnable on this review machine
- the receiving team can run the commands above in their own normal dev environment without needing any custom harness beyond ordinary Go/Rust toolchains and OpenSSL discovery on Linux

## Suggested Regression Candidates

These are the strongest candidates to keep long-term once the intended privacy behavior is agreed:

1. plaintext error reflection should not reach client or coordinator logs
2. plaintext response chunks should not sit in coordinator-visible channels if coordinator blindness is intended
3. plaintext request fallback should be rejected if encrypted-only transport is intended
4. weaker trust states should not become routable merely through lowered floor + restored/default state unless explicitly intended
5. failure paths should not leave named temp artifacts containing sensitive staging data
