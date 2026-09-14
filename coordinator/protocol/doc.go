// Package protocol defines JSON messages shared by the coordinator and providers.
//
// Application frames carry a type discriminator. messages.go owns that vocabulary;
// provider_message.go owns ProviderMessage decoding and the streamed-chunk fast
// path. Message records are grouped by their purpose:
//
//   - registration.go: machine identity, capabilities and registration.
//   - heartbeat.go and backend_capacity.go: liveness, counters and live capacity.
//   - inference.go: requests, encrypted payloads, chunks and terminal results.
//   - models.go: advertised inventory, downloads and desired-model commands.
//   - prefix_cache.go: negotiated capabilities and attempt-bound cache receipts.
//   - attestation.go and runtime_status.go: challenge proofs and trust feedback.
//   - capacity.go: request-shape probes and capacity quotes.
//   - profile.go and telemetry files: bounded operational observations.
//
// Signed attestation and terminal profile fields retain json.RawMessage where
// callers require the original bytes. Inference payloads may carry plain JSON or
// X25519/NaCl-box ciphertext; encryption and trust enforcement belong to callers.
package protocol
