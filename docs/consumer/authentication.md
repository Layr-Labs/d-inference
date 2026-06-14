# Authentication

Darkbloom consumer endpoints support two credential types. Choose the one that matches your use case.

| Method | When to use | Accepted by |
|---|---|---|
| **API key** (`sk-db-...`) | Programmatic access, scripts, server-to-server calls | Inference, balance, usage, deposit-session creation |
| **Privy JWT** (`eyJ...`) | Interactive console/web session; creating or rotating API keys | Console UI and account-management endpoints |

The middleware is in [`coordinator/api/server.go:1776-1921`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/server.go#L1776-L1921).

## API Keys

API keys are the primary credential for programmatic access.

### Creating an API Key

You can create keys two ways:

1. **Console**: sign in at [console.darkbloom.dev](https://console.darkbloom.dev), go to **Settings → API Keys**, and click **Create API Key**.
2. **API**: `POST /v1/keys` authenticated with a **Privy JWT** (API keys cannot create other API keys).

```bash
curl -X POST https://api.darkbloom.dev/v1/keys \
  -H "Authorization: Bearer YOUR_PRIVY_JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Production API Key",
    "limit_usd": 10.00,
    "limit_reset": "monthly",
    "rpm_limit": 60
  }'
```

The raw secret is returned exactly once in the `key` field. The handler is [`coordinator/api/consumer.go:3396-3443`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L3396-L3443).

### Key Format

Raw keys are prefixed `sk-db-` followed by 64 hex characters ([`coordinator/store/apikey.go:14`](https://github.com/eigeninference/d-inference/blob/master/coordinator/store/apikey.go#L14)). Example:

```text
sk-db-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b
```

### Using an API Key

```bash
curl -H "Authorization: Bearer sk-db-..." \
     https://api.darkbloom.dev/v1/models
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.darkbloom.dev/v1",
    api_key="sk-db-...",
)
```

### Per-Key Controls

API keys support spend caps, rate limits, model allow-lists, and expiry. The create request body is defined in [`coordinator/api/consumer.go:3259-3269`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L3259-L3269):

| Field | Type | Description |
|---|---|---|
| `name` | string | Descriptive label |
| `limit_usd` | number | Spend cap in USD for the reset window |
| `limit_reset` | string | `none`, `daily`, `weekly`, `monthly` |
| `rpm_limit` | integer | Requests per minute ceiling |
| `itpm_limit` | integer | Input tokens per minute ceiling |
| `otpm_limit` | integer | Output tokens per minute ceiling |
| `allowed_models` | string[] | Models this key may call; empty = all |
| `self_route_only` | boolean | If true, every request is forced to the caller's own provider machine |
| `expires_at` | RFC 3339 | Optional key expiration |

A disabled or expired key fails authentication ([`coordinator/api/server.go:1857-1867`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/server.go#L1857-L1867)).

### Key Rotation

Rotate a key with `POST /v1/keys/{id}/rotate`. The old secret stops working immediately and a new secret is returned exactly once ([`coordinator/api/consumer.go:3622-3645`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L3622-L3645)).

```bash
curl -X POST https://api.darkbloom.dev/v1/keys/key_abc123/rotate \
  -H "Authorization: Bearer YOUR_PRIVY_JWT"
```

### Revocation

Delete a key permanently with `DELETE /v1/keys/{id}` ([`coordinator/api/consumer.go:3605-3620`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L3605-L3620)).

## Privy JWT (Interactive Sessions)

The web console uses Privy for authentication. Privy tokens are accepted by `requireAuth`, but several sensitive endpoints require `requirePrivyAuth` and explicitly reject API keys:

- `POST /v1/keys` and key mutation endpoints
- `POST /v1/device/approve`
- `POST /v1/billing/stripe/create-session` is rate-limited as a financial endpoint but accepts API keys for balance reads; deposit-session creation requires either auth path depending on caller.

Do not embed a Privy JWT in long-running server code; mint an API key instead.

## Account Identity

- A Privy-linked account has a stable `account_id`.
- An unlinked API key derives a non-secret legacy account identity from the key itself, so the raw secret is never stored as a balance identifier ([`coordinator/api/server.go:1874-1882`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/server.go#L1874-L1882)).

## Security Best Practices

- Never commit API keys to version control.
- Use environment variables for key storage.
- Rotate keys quarterly or on any suspected leak.
- Apply the smallest `allowed_models` list and lowest `limit_usd` that fit the workload.
- Use `self_route_only` for keys that should only hit your own provider hardware.

## Troubleshooting

| Issue | Likely Cause | Fix |
|---|---|---|
| `401 authentication_error` | Missing, revoked, or malformed token | Verify the key is active and the `Bearer` prefix is present |
| `403 forbidden` | Endpoint requires Privy JWT but an API key was supplied | Use a Privy access token |
| `402 insufficient_quota` | Per-key spend cap reached | Raise the key limit or use another key |
| `402 insufficient_funds` | Account balance too low for the reserved worst-case cost | Deposit credits or lower `max_tokens` |
