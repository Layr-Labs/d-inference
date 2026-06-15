# Coordinator

The coordinator is Darkbloom's control plane. It is a Go HTTP/WebSocket service that sits between consumers and provider nodes: it authenticates consumers, routes inference requests, verifies provider attestations, manages billing state, and relays encrypted traffic without learning prompt content.

Production runs in a Confidential VM (AMD SEV-SNP). The coordinator therefore decrypts traffic inside hardware-encrypted memory, but it is still a trust boundary: it sees routing metadata and plaintext bodies for the duration of a request and must not log or retain prompt content.

## Responsibilities

| Responsibility | Where it lives |
|---|---|
| OpenAI-compatible consumer HTTP API | `coordinator/api/consumer.go` |
| Provider WebSocket lifecycle + attestation challenges | `coordinator/api/provider.go` |
| Route/schedule requests across the fleet | `coordinator/registry/scheduler.go`, `coordinator/registry/registry.go` |
| Verify Secure Enclave + MDM attestations | `coordinator/attestation/attestation.go`, `coordinator/api/provider.go` |
| Optional sender→coordinator request encryption | `coordinator/api/sender_encryption.go`, `coordinator/internal/e2e/e2e.go` |
| Per-request coordinator→provider NaCl Box encryption | `coordinator/internal/e2e/e2e.go`, `coordinator/api/consumer.go` |
| Prepaid ledger, pricing, and usage accounting | `coordinator/payments/pricing.go`, `coordinator/billing/billing.go`, `coordinator/store/interface.go` |
| Rate limiting (RPM + ITPM/OTPM) | `coordinator/ratelimit/`, `coordinator/api/server.go` |
| Model registry, aliases, and public catalog | `coordinator/api/model_registry_handlers.go`, `coordinator/api/model_alias_handlers.go`; see [`../operations/model-registry.md`](../operations/model-registry.md) |
| Telemetry ingestion and Datadog forwarding | `coordinator/api/telemetry_handlers.go`, `coordinator/protocol/telemetry.go`, `coordinator/datadog/`; see [`../operations/telemetry.md`](../operations/telemetry.md) |
| ACME/MDM enrollment and APNs code-identity attestation | `coordinator/api/enroll.go`, `coordinator/mdm/`, `coordinator/apns/`, `coordinator/api/provider.go` |

## Key modules

### API layer (`coordinator/api/`)

`coordinator/api/server.go` wires the HTTP router and holds the `Server` struct. It is the single place where middleware ordering is visible:

```go
s.mux.HandleFunc("POST /v1/chat/completions",
    s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions))))
```

`requireAuth` accepts API keys (`x-api-key` / `Authorization: Bearer`) or Privy JWTs. `rateLimitConsumer` enforces per-account RPM/ITPM/OTPM limits. `sealedTransport` transparently decrypts bodies sent with `Content-Type: application/eigeninference-sealed+json` and re-seals responses.

`consumer.go` implements the request path: parse and normalize, resolve model aliases, reserve balance, select a provider, encrypt to the provider's X25519 key, and relay streaming SSE chunks back to the caller.

`provider.go` accepts outbound WebSocket connections at `GET /ws/provider`, handles registration, heartbeats, inference responses, attestation challenge responses, and the APNs code-identity round-trip.

### Registry and scheduler (`coordinator/registry/`)

`registry.go` is the in-memory fleet view. Each connected provider is a `registry.Provider` with fields for hardware, models, trust level, backend capacity, warm models, and pending requests.

`scheduler.go` implements request placement. The scheduler scores candidates using a cost model that accounts for slot state, queue depth, pending requests, token backlog, health metrics, and load-scaled decode TPS. Selection is in `ReserveProviderEx` (`scheduler.go:213`). The single routing chokepoint for private text traffic is `providerSupportsPrivateTextLocked` in `registry.go:311`.

### Attestation (`coordinator/attestation/`, `coordinator/api/provider.go`)

`attestation.go` verifies the P-256 ECDSA signature over the provider's attestation blob and checks minimum security requirements (Secure Enclave available, SIP enabled, Secure Boot enabled). The coordinator also issues periodic `attestation_challenge` messages (`provider.go:872`) and requires fresh SIP/Secure Boot confirmation. Three consecutive failures or any security downgrade marks the provider untrusted.

MDM-based hardware attestation is handled in `coordinator/mdm/` and `coordinator/apns/`. The coordinator can request Apple Device Attestation (MDA) certificates and verify them against Apple's Enterprise Attestation Root CA; see `coordinator/attestation/attestation.go` and `coordinator/api/provider.go:2078`.

### Encryption (`coordinator/internal/e2e/`, `coordinator/api/sender_encryption.go`)

`internal/e2e/e2e.go` implements NaCl Box (X25519 + XSalsa20-Poly1305) for coordinator↔provider traffic. The coordinator generates an ephemeral X25519 key per inference request, encrypts the request body to the provider's attested X25519 public key, and decrypts response chunks with the ephemeral private key.

`sender_encryption.go` implements optional sender→coordinator encryption. Consumers (or the console UI) fetch the coordinator's long-lived X25519 key from `GET /v1/encryption-key` and seal request bodies. The coordinator decrypts inside the CVM and re-seals responses to the sender's ephemeral key.

### Billing and payments (`coordinator/payments/`, `coordinator/billing/`, `coordinator/store/`)

`payments/pricing.go` defines the cost model: prices are stored in micro-USD per 1M tokens, with a per-request minimum charge of $0.0001 (100 micro-USD). Platform fee defaults to 0% during the public alpha (`payments/pricing.go:43`).

`billing/billing.go` orchestrates Stripe deposits and Stripe Connect Express payouts. The referral service is also in `coordinator/billing/`.

`store/interface.go` defines the `Store` interface, implemented by in-memory and PostgreSQL backends. The ledger records reservations, debits, credits, and refunds atomically.

## Privacy-relevant boundaries

The coordinator is a necessary trust boundary, but its visibility is intentionally limited:

- **Consumer → coordinator**: TLS by default; optional NaCl Box via `sender_encryption.go`. The coordinator decrypts for routing and billing but must not log or retain prompt content.
- **Coordinator → provider**: mandatory per-request NaCl Box to the provider's attested X25519 public key. The provider is the only endpoint that can decrypt the prompt.
- **Provider → coordinator**: response SSE chunks are encrypted back to the coordinator's ephemeral X25519 key (`e2e.go`). The coordinator decrypts, optionally re-seals for sender→coordinator encryption, and streams to the consumer.
- **Logging**: request logs contain model IDs, token counts, provider IDs, and trust metadata, not prompt text.

See also the canonical privacy model in [`../security/encryption.md`](../security/encryption.md) and the hop-by-hop details in `coordinator/api/sender_encryption.go` and `coordinator/internal/e2e/e2e.go`.

## Outdated claims corrected

- The old `ARCHITECTURE.md` described a reputation formula and hardcoded request limits that are no longer authoritative. Routing now uses the cost model in `coordinator/registry/scheduler.go` and capacity-driven admission.
- The old doc claimed providers support up to 4 concurrent requests. The Swift runtime reports live backend capacity (`protocol.BackendCapacity`) and the scheduler uses it; there is no global fixed concurrency cap.
- The old doc stated "EigenInference checks SIP before every inference request." The coordinator verifies SIP via the periodic attestation challenge and gating in `providerSupportsPrivateTextLocked`; it does not block individual requests with a fresh SIP probe.
- The old doc referenced a Python/inprocess-MLX backend. Only `mlx-swift` providers are routable today (`registry.go:344`).
