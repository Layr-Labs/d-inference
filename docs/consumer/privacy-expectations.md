# Privacy Expectations

What Darkbloom's coordinator can and cannot see when you send an inference request.

## Threat Model Summary

- The **coordinator** runs in a Confidential VM (CVM) with hardware-encrypted memory.
- The **provider** runs on a provider's Apple Silicon Mac, bound to a Secure Enclave identity and code-identity attestation.
- The **provider** is the final decryption endpoint for prompts.

This document describes the hop-by-hop privacy model. For the encryption implementation details, see:

- Consumer → coordinator optional encryption: [`coordinator/api/sender_encryption.go`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/sender_encryption.go)
- Coordinator → provider mandatory encryption: [`coordinator/internal/e2e/e2e.go`](https://github.com/eigeninference/d-inference/blob/master/coordinator/internal/e2e/e2e.go) and [`coordinator/api/consumer.go:448-510`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L448-L510)
- Provider decryption and response encryption: [`provider-swift/Sources/ProviderCore/ProviderLoop.swift:959-1178`](https://github.com/eigeninference/d-inference/blob/master/provider-swift/Sources/ProviderCore/ProviderLoop.swift#L959-L1178)

## Hop-by-Hop Model

```text
┌─────────────┐     TLS + optional NaCl Box      ┌─────────────────┐     mandatory NaCl Box      ┌─────────────────┐
│   Consumer  │ ───────────────────────────────▶ │   Coordinator   │ ─────────────────────────▶ │    Provider     │
│  (your code)│                                  │  (CVM memory)   │                            │ (Secure Enclave │
└─────────────┘ ◀─────────────────────────────── └─────────────────┘ ◀────────────────────────── │  bound binary)  │
       ▲                  TLS + optional NaCl Box         ▲                    NaCl Box         └─────────────────┘
       │                                                   │
       └───────────────────────────────────────────────────┘
```

### Consumer → Coordinator

- Transport is **TLS** by default.
- Senders may additionally **NaCl Box-seal** the request body to the coordinator's long-lived X25519 public key, fetched from `GET /v1/encryption-key`.
- Wire format: `{"kid":"...","ephemeral_public_key":"<b64>","ciphertext":"<b64>"}` with `Content-Type: application/eigeninference-sealed+json`.
- Plaintext requests bypass sealing entirely.

Endpoint and middleware: [`coordinator/api/sender_encryption.go:93-199`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/sender_encryption.go#L93-L199).

### Inside the Coordinator

- The coordinator decrypts the request in CVM memory for routing and billing.
- It **does not log or retain prompt content**. The code path that parses the request only extracts `model`, `stream`, `messages`/`input`, and token-estimate fields needed for routing and billing ([`coordinator/api/inference_preprocess.go`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/inference_preprocess.go)).
- The coordinator never re-transmits the plaintext prompt to any party except the selected provider, and only after re-encrypting it.

### Coordinator → Provider

- Before forwarding, the coordinator **mandatorily** re-encrypts the request body to the selected provider's attested X25519 public key using a fresh ephemeral key pair per request.
- A provider without a public key is excluded from routing ([`coordinator/api/consumer.go:448-454`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L448-L454)).
- Encryption uses NaCl Box (X25519 + XSalsa20-Poly1305) for forward secrecy and authentication ([`coordinator/internal/e2e/e2e.go:48-82`](https://github.com/eigeninference/d-inference/blob/master/coordinator/internal/e2e/e2e.go#L48-L82)).

### Provider → Coordinator

- The provider encrypts response SSE chunks back to the coordinator's ephemeral X25519 public key.
- The coordinator decrypts responses in CVM memory and forwards them to the consumer.

Provider-side decryption/response encryption: [`provider-swift/Sources/ProviderCore/ProviderLoop.swift:959-1178`](https://github.com/eigeninference/d-inference/blob/master/provider-swift/Sources/ProviderCore/ProviderLoop.swift#L959-L1178).

## What the Coordinator Can See

| Data | Can the coordinator see it? | Notes |
|---|---|---|
| Prompt content | Yes, in CVM memory | Needed for routing; not logged or retained |
| Model ID | Yes | Required for routing |
| Sampling parameters (`temperature`, `max_tokens`, etc.) | Yes | Passed through to provider |
| Token counts | Yes | Used for billing |
| Request/response metadata | Yes | Timestamps, request IDs, provider IDs |
| Provider identity / attestation | Yes | Used for trust-based routing |
| Account balance and usage | Yes | Ledger records |

## What the Coordinator Cannot See

| Data | Reason |
|---|---|
| Prompt content at rest | Not persisted |
| Provider's private key | Stays in the provider's Secure Enclave |
| Provider's plaintext response | Decrypted only in CVM memory and re-sealed to the consumer when sender encryption is used |

## What the Provider Can See

The provider is the final decryption endpoint. By design it can see:

- The plaintext prompt.
- The plaintext response it generates.
- The sampling parameters and model configuration.

It cannot see:

- Your API key or Privy credentials.
- Your account balance.
- Other consumers' prompts or responses.

## Attestation Binding

Provider public keys are tied to Apple Secure Enclave identity and code-identity attestation. The coordinator verifies attestation before trusting a provider for routing ([`coordinator/attestation/attestation.go`](https://github.com/eigeninference/d-inference/blob/master/coordinator/attestation/attestation.go), [`coordinator/api/provider.go:2074`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/provider.go#L2074)). This means a prompt encrypted to a provider key is bound to a specific, attested binary instance.

## Sender Encryption Is Optional

Sender encryption is disabled when the coordinator has no configured X25519 key. In that environment the consumer → coordinator hop is TLS only. The coordinator → provider hop is always encrypted regardless of whether the consumer used sender encryption.

## Logging Policy

- Prompt content is never written to logs.
- Billing records contain token counts, model IDs, and costs, not prompt text.
- Request logs contain metadata such as model, token counts, latency, request ID, and provider ID.
