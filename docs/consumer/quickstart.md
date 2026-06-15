# Consumer Quickstart

Send your first request to Darkbloom's OpenAI-compatible API.

## Prerequisites

- A Darkbloom account. Sign up at [console.darkbloom.dev](https://console.darkbloom.dev).
- An API key. Create one in **Settings → API Keys** in the console, or via `POST /v1/keys` authenticated with a Privy JWT (see [authentication.md](authentication.md)).

## Base URL

```text
https://api.darkbloom.dev/v1
```

## Authentication

Send a Bearer token in the `Authorization` header. `requireAuth` accepts **either** an API key (`sk-db-...`) **or** a Privy JWT (`eyJ...`), but the console/web flows require Privy and sensitive key-management endpoints reject API keys entirely ([`coordinator/api/server.go:1776-1888`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/server.go#L1776-L1888)).

```bash
curl -H "Authorization: Bearer YOUR_API_KEY" \
     https://api.darkbloom.dev/v1/models
```

## Your First Request

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.darkbloom.dev/v1",
    api_key="YOUR_API_KEY",
)

response = client.chat.completions.create(
    model="gemma-4-26b",  # use the ID returned by GET /v1/models
    messages=[{"role": "user", "content": "Hello, Darkbloom!"}],
    stream=True,
)

for chunk in response:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")
```

### cURL

```bash
curl -X POST https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-26b",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

### Anthropic Messages API

```python
import anthropic

client = anthropic.Anthropic(
    base_url="https://api.darkbloom.dev/v1",
    api_key="YOUR_API_KEY",
)

response = client.messages.create(
    model="gemma-4-26b",
    max_tokens=1024,
    messages=[{"role": "user", "content": "Hello!"}],
)
```

## Available Models

Models are loaded from the coordinator's DB-backed model registry, not hardcoded in the consumer docs. The authoritative list is always:

```bash
GET /v1/models
```

You can also use the provider-facing catalog at `GET /v1/models/catalog`. Aliases such as `gemma-4-26b` may resolve to different concrete builds over time; the consumer endpoint hides build details and exposes only the public alias ([`coordinator/api/model_alias_handlers_test.go:956-962`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/model_alias_handlers_test.go#L956-L962)).

## Pricing

Darkbloom uses per-token pricing. Platform-set model prices are returned by `GET /v1/pricing`; if no platform price is configured, the fallback is **$0.05 per 1M input tokens** and **$0.20 per 1M output tokens** ([`coordinator/payments/pricing.go:24-29`](https://github.com/eigeninference/d-inference/blob/master/coordinator/payments/pricing.go#L24-L29)). Every charged request has a **$0.0001** (100 micro-USD) minimum ([`coordinator/payments/pricing.go:31-32`](https://github.com/eigeninference/d-inference/blob/master/coordinator/payments/pricing.go#L31-L32)).

During public alpha the platform fee is **0%**, so providers keep 100% of the per-token revenue ([`coordinator/payments/pricing.go:39-43`](https://github.com/eigeninference/d-inference/blob/master/coordinator/payments/pricing.go#L39-L43)).

Requests routed to your own provider machine via self-route are not charged. See [self-route](../provider/self-route.md).

## Next Steps

- [API Contracts](../reference/api-contracts.md) — endpoint details and request/response schemas
- [Authentication](authentication.md) — API keys, Privy JWTs, and per-key limits
- [Billing](billing.md) — deposits, usage, and balance
- [Models](models.md) — how the model catalog works
- [Privacy Expectations](privacy-expectations.md) — what the coordinator can and cannot see
