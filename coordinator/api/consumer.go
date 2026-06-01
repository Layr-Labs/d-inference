package api

// Consumer-facing API handlers for the Darkbloom coordinator.
//
// This file implements the OpenAI-compatible HTTP endpoints that consumers
// use to send inference requests. The coordinator acts as a trusted routing
// layer between consumers and providers.
//
// Trust model:
//   The coordinator runs in a Confidential VM, providing hardware-encrypted
//   memory. Consumers may additionally sender-seal requests to the
//   coordinator's X25519 key. The coordinator decrypts for routing purposes
//   but never logs prompt content, then re-encrypts each request to the
//   selected provider's X25519 public key before forwarding over the
//   WebSocket. Providers are attested via Secure Enclave challenge-response.
//
// The consumer endpoints and helpers that formerly lived in this file have
// been split into focused per-domain files (all package api):
//   - inference_dispatch.go   dispatch tunables, TTFT helpers, speculative
//                             dispatch, and the public inference handlers
//                             (chat completions, completions, Anthropic messages)
//   - inference_stream.go     SSE streaming response writers
//   - inference_nonstream.go  non-streaming response assembly
//   - request_estimate.go     token estimation, max-token bounds, request
//                             field parsing helpers
//   - responses_translate.go  Responses API → chat completions translation
//   - response_normalize.go   SSE/complete response normalization
//   - response_build.go       response assembly from streamed chunks
//   - reservation.go          billing reservation top-ups and refunds
//   - models_handler.go       GET /v1/models
//   - account_handlers.go     health, version, balance, usage, earnings
//   - keys_handler.go         API key management
