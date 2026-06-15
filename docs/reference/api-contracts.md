# Consumer API Contracts

Dry reference for Darkbloom's public HTTP API. The code is the source of truth; canonical routes are wired in [`coordinator/api/server.go`](../../coordinator/api/server.go) and implemented in [`coordinator/api/consumer.go`](../../coordinator/api/consumer.go). Response shapes are defined in [`coordinator/api/types/types.go`](../../coordinator/api/types/types.go).

## Base URL

```
https://api.darkbloom.dev/v1
```

## Authentication

All `/v1/*` endpoints (except those marked public below) require one of:

| Credential | Header | Use case |
|---|---|---|
| API key | `Authorization: Bearer <API_KEY>` | Programmatic inference and read-only account calls |
| Privy JWT | `Authorization: Bearer <JWT>` | Interactive console operations (key mgmt, billing) |
| Admin key | `Authorization: Bearer <ADMIN_KEY>` | Admin endpoints |

API keys are resolved via [`requireAuth`](../../coordinator/api/server.go). JWTs are verified first when they start with `eyJ`; otherwise the token is treated as an API key or admin key ([`server.go:1776-1888`](../../coordinator/api/server.go)).

## Privacy model

The public API uses a three-hop privacy model. Do not use imprecise marketing phrasing; cite these hops:

| Hop | Encryption | Notes |
|---|---|---|
| Consumer → coordinator | TLS; optional NaCl Box (X25519 + XSalsa20-Poly1305) | `GET /v1/encryption-key`, `Content-Type: application/eigeninference-sealed+json`; see [`sender_encryption.go`](../../coordinator/api/sender_encryption.go) |
| Coordinator → provider | Mandatory per-request NaCl Box to provider's attested X25519 public key | Implemented in [`internal/e2e/e2e.go`](../../coordinator/internal/e2e/e2e.go) and dispatched in [`consumer.go:448-510`](../../coordinator/api/consumer.go) |
| Provider → coordinator | Response SSE chunks encrypted back to coordinator's ephemeral X25519 key | Provider-side implementation in `provider-swift` |

The coordinator decrypts consumer bodies in its Confidential VM memory for routing and billing but does not log or retain prompt content. The provider is the decryption endpoint for prompts and is bound to Apple Secure Enclave identity / code-identity attestation.

## Inference endpoints

### `POST /v1/chat/completions`

OpenAI-compatible chat completions. Handler: [`handleChatCompletions`](../../coordinator/api/consumer.go), route at [`server.go:1413`](../../coordinator/api/server.go).

#### Request body

| Field | Type | Required | Notes |
|---|---|---|---|
| `model` | string | yes | Public alias (e.g. `gemma-4-26b`) or concrete build id |
| `messages` | array | yes, unless `input` is used | Standard OpenAI chat messages; also accepts multimodal content parts |
| `stream` | bool | no | Default `false`; streams SSE when `true` |
| `max_tokens` / `max_completion_tokens` / `max_output_tokens` | integer | no | Bound applied by coordinator if omitted; see "Token bounds" below |
| `temperature` | number | no | Passed through to the provider |
| `top_p` | number | no | Passed through to the provider |
| `tools` | array | no | Tool-bearing requests are gated to providers that pass template rendering |
| `tool_choice` | string / object | no | |
| `response_format` | object | no | `json_object`, `json_schema` |
| `stop` | string / array | no | |
| `seed` | integer | no | |
| `provider_serial` / `provider_serials` | string / array | no | Darkbloom-specific routing allowlist; stripped before forwarding |
| `n` | integer | no | **Rejected if > 1** ([`consumer.go:1323-1327`](../../coordinator/api/consumer.go)) |

The raw body is passed through to the provider to preserve fields that the coordinator does not parse ([`consumer.go:1296-1298`](../../coordinator/api/consumer.go)).

#### Response (non-streaming)

[`ChatCompletionResponse`](../../coordinator/api/types/types.go):

```json
{
  "id": "chatcmpl-<request_id>",
  "object": "chat.completion",
  "created": 1699999999,
  "model": "gemma-4-26b",
  "choices": [...],
  "usage": {
    "prompt_tokens": 15,
    "completion_tokens": 8,
    "total_tokens": 23,
    "completion_tokens_details": { "reasoning_tokens": 0 }
  },
  "se_signature": "...",
  "response_hash": "..."
}
```

#### Response (streaming)

`Content-Type: text/event-stream`. Each event is a JSON `chat.completion.chunk`. The coordinator appends a single `data: [DONE]` terminator and may splice in `se_signature` / `response_hash` on the terminal usage chunk. See [`consumer.go:1614-1865`](../../coordinator/api/consumer.go).

### `POST /v1/responses`

Responses API surface. Shares the same handler as chat completions and is auto-detected by the presence of `input` instead of `messages` ([`server.go:1414`](../../coordinator/api/server.go), [`consumer.go:1377`](../../coordinator/api/consumer.go)). Internally lowered to chat-completions format before dispatch ([`responsesRequestToChatCompletions`](../../coordinator/api/consumer.go)).

### `POST /v1/completions`

Legacy completions endpoint. Route at [`server.go:1415`](../../coordinator/api/server.go).

### `POST /v1/messages`

Anthropic Messages API compatible endpoint. Route at [`server.go:1416`](../../coordinator/api/server.go).

## Model listing endpoints

### `GET /v1/models`

Returns active models with OpenRouter-shaped pricing and a Darkbloom metadata block. Response type: [`ModelListResponse`](../../coordinator/api/types/types.go). Route at [`server.go:1417`](../../coordinator/api/server.go).

### `GET /v1/models/openrouter`

Pure OpenRouter provider feed with no Darkbloom metadata. Response type: [`OpenRouterModelsResponse`](../../coordinator/api/types/types.go). Route at [`server.go:1419`](../../coordinator/api/server.go).

### `GET /v1/models/{id}`

Retrieve a single model. Route at [`server.go:1422`](../../coordinator/api/server.go).

### `GET /v1/models/capacity`

Public capacity snapshot for upstream routers. No auth. Route at [`server.go:1456`](../../coordinator/api/server.go).

### `GET /v1/models/catalog`

Public model catalog for providers and the install script. No auth; cached 60 s. Route at [`server.go:1534`](../../coordinator/api/server.go).

### `GET /v1/models/catalog/manifest/{id}`

Returns the stored manifest for a model. Route at [`server.go:1535`](../../coordinator/api/server.go).

### `GET /v1/models/catalog/{id}`

Returns a single catalog model entry. Route at [`server.go:1536`](../../coordinator/api/server.go).

## Billing endpoints

All amounts are in **micro-USD** (1 USD = 1,000,000 micro-USD) unless otherwise noted.

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/v1/pricing` | GET | none | Platform prices per model |
| `/v1/payments/balance` | GET | API key / JWT | Account balance |
| `/v1/payments/usage` | GET | API key / JWT | Usage history |
| `/v1/billing/stripe/create-session` | POST | API key / JWT | Create Stripe Checkout session (min $0.50) |
| `/v1/billing/stripe/session` | GET | API key / JWT | Query session status |
| `/v1/billing/wallet/balance` | GET | API key / JWT | Wallet balance alias |
| `/v1/billing/methods` | GET | none | Supported payment methods |

Provider-facing earnings endpoints:

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/v1/provider/earnings` | GET | provider address | Per-provider earnings |
| `/v1/provider/node-earnings` | GET | provider_key or account | Per-node earnings |
| `/v1/provider/account-earnings` | GET | API key / JWT | Account-level earnings summary |

Routes defined at [`server.go:1433-1441`](../../coordinator/api/server.go) and [`server.go:1437-1441`](../../coordinator/api/server.go).

## Pricing endpoints

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/v1/pricing` | GET | none | Platform default prices |
| `/v1/pricing` | PUT | Privy JWT | Provider custom price override |
| `/v1/pricing` | DELETE | Privy JWT | Remove provider custom price |
| `/v1/admin/pricing` | PUT | admin | Set platform default price |

See [`billing_handlers.go:324-565`](../../coordinator/api/billing_handlers.go) and the detailed pricing model in [`pricing-model.md`](./pricing-model.md).

## Encryption endpoints

### `GET /v1/encryption-key`

Public. Returns the coordinator's long-lived X25519 public key and key id when sender→coordinator encryption is configured. Returns 503 when disabled. Implemented in [`sender_encryption.go:93-111`](../../coordinator/api/sender_encryption.go).

### Sealed request envelope

Set `Content-Type: application/eigeninference-sealed+json` on `POST` to the inference endpoints.

```json
{
  "kid": "<key id>",
  "ephemeral_public_key": "<base64 X25519 public key>",
  "ciphertext": "<base64: 24-byte nonce || NaCl box>"
}
```

See [`sender_encryption.go:13-33`](../../coordinator/api/sender_encryption.go).

## Rate limits

The coordinator applies layered rate limits configured at runtime:

| Layer | Limiter | Scope | Headers on success |
|---|---|---|---|
| Per-account RPM | `rateLimiter` | consumer inference | `x-ratelimit-*-requests` |
| Per-account ITPM/OTPM | `consumerTokenLimiter` / `serviceTokenLimiter` | consumer inference | `x-ratelimit-*-input-tokens`, `x-ratelimit-*-output-tokens` |
| Per-key RPM | `keyRPMLimiter` | consumer inference (key override) | — |
| Per-key ITPM/OTPM | `keyTokenLimiter` | consumer inference (key override) | `x-ratelimit-*-input-tokens`, `x-ratelimit-*-output-tokens` |
| Financial endpoints | `financialRateLimiter` | deposits, withdrawals, key/invite/referral mutations | — |
| Service accounts | `serviceRateLimiter` or bypass | `RoleService` accounts on inference | same as consumer/service tier |

Service accounts (`RoleService`) are set via `PUT /v1/admin/users/role`. Admin pseudo-account (`admin`) bypasses limiters.

Limiters are wired in [`server.go:342-429`](../../coordinator/api/server.go).

## Token bounds

If the consumer does not set a max-output bound, the coordinator injects one so the pre-flight balance reservation covers the generation. The fallback bound is `defaultMaxOutputTokens = 8192`; it is overridden by the model registry's `max_output_length` when present ([`consumer.go:1381-1407`](../../coordinator/api/consumer.go)).

## Routing headers

| Header | Meaning |
|---|---|
| `X-Darkbloom-Route` | `self` requests self-routing to an owned provider (free); see [`self-route`](../provider/self-route.md) |
| `X-Inference-Job-ID` | Provider-side job UUID for the winning attempt |
| `X-Timing` | Per-request latency decomposition (when emitted by middleware) |

## Error format

All errors follow the OpenAI error envelope:

```json
{
  "error": {
    "message": "...",
    "type": "invalid_request_error",
    "param": "model",
    "code": "model_unavailable"
  }
}
```

Common HTTP status codes:

| Status | Type / code | Meaning |
|---|---|---|
| 400 | `invalid_request_error` | Malformed request |
| 401 | `authentication_error` | Missing or invalid credentials |
| 402 | `insufficient_funds` / `insufficient_quota` | Balance or per-key cap too low |
| 403 | `forbidden` | Privy-required endpoint hit with API key |
| 404 | `not_found` / `model_not_found` | Unknown model or path |
| 429 | `rate_limit_exceeded` | Rate limit or all providers at capacity; `Retry-After` present |
| 503 | `service_unavailable` / `model_unavailable` | No eligible provider or model too large; `Retry-After` present |

## Unimplemented endpoints

Any `/v1/*` path not listed above returns a structured 404 from [`handleUnimplementedEndpoint`](../../coordinator/api/server.go) rather than a plaintext mux default.
