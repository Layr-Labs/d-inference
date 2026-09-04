# Quickstart: first request in five steps

> Last updated: 2026-09-04 · commit `075d37a91`

Get an API key from the console, list the models your key can use, and make your first chat completion against `https://api.darkbloom.dev` — first with `curl`, then from the OpenAI and Anthropic SDKs. For developers integrating the API; each step is one action. Route details for everything used here are in [`../reference/api-contracts.md`](../reference/api-contracts.md).

## Prerequisites

- An email address. Email is the only console login method (`loginMethods: ["email"]`, `console-ui/src/components/providers/PrivyRealProvider.tsx`); there is no wallet or social login. The Privy account it creates is what your API keys, balance and usage attach to.
- Credit on the account. A chat completion reserves its worst-case cost before dispatch and is refused with a 402 when the balance cannot cover it; deposit first with [`billing.md`](billing.md).
- `curl` and `jq` for the shell steps; Python with the `openai` or `anthropic` package for the SDK steps.

## Steps

### 1. Sign in to the console

Open `https://console.darkbloom.dev` and sign in with your email address.

### 2. Create an API key

Open the API console page (`/api-console`, `console-ui/src/app/api-console/page.tsx` — not Settings) and create a key. The console calls `POST /v1/keys` with your Privy session through its same-origin `/api/keys` relay (`console-ui/src/app/api/keys/route.ts`; `handleCreateAPIKey`, `coordinator/api/apikey_handlers.go`). The secret starts with `sk-db-` and is shown once — copy it now; its exact shape and how it is stored are in [`../reference/api-contracts.md#api-key-shapes`](../reference/api-contracts.md#api-key-shapes). If you lose it, rotate or create another ([`authentication.md`](authentication.md)).

Export it for the commands below:

```bash
export DARKBLOOM_API_KEY="sk-db-..."
```

### 3. Verify the key and pick a model

```bash
curl -s https://api.darkbloom.dev/v1/models \
  -H "Authorization: Bearer $DARKBLOOM_API_KEY" | jq '.data[] | {id, context_length, input_modalities, supported_features}'
```

A 200 with a `data` array confirms the key works (`handleListModels`, `coordinator/api/models_endpoints.go`). The `id` values are the model names to send; they are aliases maintained in the coordinator's database, so the list is authoritative and this page does not repeat it. Field meanings are in [`models.md`](models.md).

Pick one id and export it:

```bash
export MODEL="<an id from the list>"
```

### 4. Make a chat completion

```bash
curl -s https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer $DARKBLOOM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$MODEL"'",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 64
  }'
```

The body is an OpenAI `chat.completion` object whose `model` field echoes the alias you sent and whose `usage` has `prompt_tokens`, `completion_tokens`, `total_tokens`. Response headers `X-Provider-Id`, `X-Provider-Attested` and `X-Timing` tell you which machine served it and how long each coordinator stage took (`writeCommittedProviderHeaders`, `coordinator/api/response_metadata.go`).

Expect a short delay before the first byte: the coordinator sends nothing until a provider has produced content, so it can still fail over or return a real error status in the meantime (`commitFirstContent`, `coordinator/api/dispatch.go`).

### 5. Stream the response

```bash
curl -N https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer $DARKBLOOM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$MODEL"'",
    "messages": [{"role": "user", "content": "Count from 1 to 10."}],
    "stream": true
  }'
```

You receive `text/event-stream` frames, one `data: {...}` chunk per provider token group, a final frame carrying `usage` and `finish_reason`, then exactly one `data: [DONE]`. There are no keepalive comments; silence means no token has been produced yet (`handleStreamingResponseWithFirstChunk`, `coordinator/api/consumer.go`).

### 6. Use the OpenAI SDK

The OpenAI clients append `/chat/completions` to the base URL, so point them at `/v1`:

```python
from openai import OpenAI

client = OpenAI(base_url="https://api.darkbloom.dev/v1", api_key=DARKBLOOM_API_KEY)
resp = client.chat.completions.create(
    model=MODEL,
    messages=[{"role": "user", "content": "Say hello in one sentence."}],
)
print(resp.choices[0].message.content)
```

`client.models.list()` and `client.responses.create(...)` also work: they hit `GET /v1/models` and `POST /v1/responses`, both registered routes. Endpoints the coordinator does not implement (embeddings, moderations, files) return a structured 404 from the `/v1/` catch-all (`handleUnimplementedEndpoint`, `coordinator/api/server.go`).

### 7. Use the Anthropic SDK

The Anthropic clients append `/v1/messages` to the base URL, so point them at the bare host. The coordinator reads credentials only from `Authorization: Bearer` (`extractBearerToken`, `coordinator/api/server.go`) and ignores `x-api-key`, so pass the key as the SDK's bearer `auth_token`, not as `api_key`:

```python
import anthropic

client = anthropic.Anthropic(base_url="https://api.darkbloom.dev", auth_token=DARKBLOOM_API_KEY)
msg = client.messages.create(
    model=MODEL,
    max_tokens=64,
    messages=[{"role": "user", "content": "Say hello in one sentence."}],
)
print(msg.content[0].text)
```

Requests land on `POST /v1/messages` (`handleAnthropicMessages`, `coordinator/api/consumer.go`) and are translated to the same pipeline as chat completions.

## Verify

- Step 3 returned 200 with a non-empty `data` array.
- The step 4 response is a `chat.completion` object whose `model` echoes the alias you sent, whose `usage` is populated, and which carries an `X-Provider-Id` header.
- `GET /v1/payments/usage` with the same bearer lists the request and its `cost_micro_usd` ([`billing.md`](billing.md#3-read-your-balance-and-usage)).

To display network activity, read `GET /v1/stats`, `GET /v1/network/totals`,
or `GET /v1/network/series`. If one returns 503 `service_unavailable`, keep
your last displayed value and retry later; do not replace it with zero.
Successful empty windows are valid data. The [public stats contract](../reference/api-contracts.md#public-stats-and-health-5)
defines refresh intervals, maximum cached staleness, and window aliases.

## Troubleshooting

| Response | Cause | Fix |
|---|---|---|
| 401 `authentication_error` | `Authorization: Bearer` header missing, or the key is unknown, disabled, expired or revoked | Re-export the key; create or rotate one in the console ([`authentication.md`](authentication.md)) |
| 402 | Balance or key budget cannot cover the worst-case reservation ([payment-required taxonomy](../architecture/billing.md#payment-required-responses)) | Deposit, or lower `max_tokens` ([`billing.md`](billing.md)) |
| 403 `model_not_allowed` | The key was created with an `allowed_models` list that excludes this model | Pick an id from the list, or `PATCH` the key ([`authentication.md`](authentication.md)) |
| 404 `model_not_found` | The `model` is not an id that `GET /v1/models` returns | Use an id from step 3 ([`models.md`](models.md)) |
| 503 `model_unavailable` (no `Retry-After`) | No routable provider for the model right now | Retry later, or pick another model ([`models.md`](models.md)) |
| 429 `rate_limit_exceeded` with `Retry-After` | Key `rpm_limit`, the account limiter, or the token-per-minute limits | Wait `Retry-After` seconds ([`../reference/api-contracts.md`](../reference/api-contracts.md#error-envelope-and-status-codes)) |
| Silence before the first byte | Expected: nothing is sent until a provider has produced content (`commitFirstContent`) | Wait; a real error status can still arrive |

## Related

- Balance and top-ups: `GET /v1/payments/balance` and [`billing.md`](billing.md). The platform fee is stated once, in [`../architecture/billing.md#invariants`](../architecture/billing.md#invariants).
- Key limits, rotation, Privy-only routes: [`authentication.md`](authentication.md).
- Verifying which machine answered and checking its signature: [`verification.md`](verification.md).
- What the coordinator does with your prompt: [`privacy-expectations.md`](privacy-expectations.md).
- Error codes and `Retry-After` behaviour: [`../reference/api-contracts.md`](../reference/api-contracts.md).
