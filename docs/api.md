# Darkbloom API Reference

Base URL: `https://api.darkbloom.dev` (prod) · `https://api.dev.darkbloom.xyz` (dev)

The inference API is OpenAI-compatible — any OpenAI SDK works by changing the base URL to `https://api.darkbloom.dev/v1`. The Anthropic Messages API is also supported. Route wiring lives in `coordinator/api/server.go`.

## Authentication

| Method | Used by | How |
|--------|---------|-----|
| API key | Programmatic consumers | `Authorization: Bearer eigeninference-…` |
| Privy JWT | Console UI users | `Authorization: Bearer <privy-jwt>` |
| Device code (RFC 8628) | Provider machines | `darkbloom login` → user approves code on the web |
| Admin OTP / admin key | Admin endpoints | `POST /v1/admin/auth/init` → `verify` |

Endpoints marked **public** require no auth. `requireAuth` accepts either an API key or a Privy JWT; `requirePrivyAuth` requires a Privy JWT.

Darkbloom-specific response fields on chat completions: `provider_attested` (bool), `provider_trust_level` (string). Reasoning models surface `<think>` segments as `reasoning_content`. The `X-Timing` response header decomposes per-request latency (parse, reserve, route, queue, encrypt, dispatch, provider).

## Inference

| Endpoint | Auth | Description |
|----------|------|-------------|
| `POST /v1/chat/completions` | API key / JWT | OpenAI Chat Completions (streaming + non-streaming). Sealed transport to the provider. |
| `POST /v1/responses` | API key / JWT | OpenAI Responses API — same handler, auto-detects `input` vs `messages`. |
| `POST /v1/completions` | API key / JWT | Legacy text completions. |
| `POST /v1/messages` | API key / JWT | Anthropic Messages API. |

Supported sampling parameters (per model, see catalog): `temperature`, `top_p`, `top_k`, `frequency_penalty`, `presence_penalty`, `repetition_penalty`, `stop`, `seed`, `max_tokens`.

Errors: `429` with `Retry-After` when the fleet is at capacity; `503` when all providers serving a model are busy and the queue is full; queued requests time out rather than waiting indefinitely.

### Example

```python
from openai import OpenAI

client = OpenAI(base_url="https://api.darkbloom.dev/v1", api_key="eigeninference-...")
response = client.chat.completions.create(
    model="gpt-oss-20b",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
```

## Models

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /v1/models` | API key / JWT | OpenAI-style model list (alias IDs routable right now). |
| `GET /v1/models/openrouter` | API key / JWT | OpenRouter-shaped model list (pricing, context, modalities). |
| `GET /v1/models/catalog` | public | Full curated catalog: architecture, quantization, context/output limits, min RAM, file hashes, sampling params. |
| `GET /v1/models/catalog/{id}` | public | Single catalog entry. |
| `GET /v1/models/catalog/manifest/{...}` | public | R2 manifest passthrough used by providers for verified downloads. |
| `GET /v1/models/capacity` | public | Per-model live capacity: routable/warm/cold providers, aggregate TPS, queue depth, estimated TTFT, token budget. |
| `GET /v1/runtime/manifest` | public | Runtime (metallib) manifest for provider builds. |

## API Keys

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /v1/keys` | Privy | List API keys. |
| `POST /v1/keys` | Privy | Create key (name, limits). |
| `GET /v1/keys/{id}` | Privy | Get key metadata. |
| `PATCH /v1/keys/{id}` | Privy | Update name / ITPM / OTPM limits. |
| `DELETE /v1/keys/{id}` | Privy | Delete key. |
| `POST /v1/keys/{id}/rotate` | Privy | Rotate secret. |
| `GET /v1/key` | API key / JWT | Introspect the calling key. |
| `POST /v1/auth/keys` / `DELETE /v1/auth/keys` | Privy | Legacy create/revoke. |

## Billing & Payments

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /v1/payments/balance` | API key / JWT | Micro-USD balance. |
| `GET /v1/payments/usage` | API key / JWT | Usage history. |
| `GET /v1/pricing` | public | Per-model token prices (micro-USD per 1M tokens + display USD). |
| `PUT /v1/pricing` / `DELETE /v1/pricing` | API key / JWT | Provider sets/clears own prices. |
| `GET /v1/billing/methods` | public | Available deposit methods + referral share. |
| `POST /v1/billing/stripe/create-session` | API key / JWT | Stripe checkout session for deposits. |
| `GET /v1/billing/stripe/session` | API key / JWT | Checkout session status. |
| `POST /v1/billing/stripe/webhook` | Stripe-signed | Deposit webhook. |
| `GET /v1/billing/wallet/balance` | API key / JWT | Solana USDC deposit wallet balance. |
| `POST /v1/billing/stripe/onboard` | API key / JWT | Stripe Connect onboarding (payouts). |
| `GET /v1/billing/stripe/status` | API key / JWT | Connect account status. |
| `POST /v1/billing/withdraw/stripe` | API key / JWT | Withdraw earnings. |
| `GET /v1/billing/stripe/withdrawals` | API key / JWT | Withdrawal history. |
| `POST /v1/billing/stripe/connect/webhook` | Stripe-signed | Connect webhook. |

## Provider & Earnings

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /ws/provider` | provider token | Provider WebSocket (registration, heartbeats, attestation, relay). |
| `GET /v1/provider/earnings` | public | Network earnings summary. |
| `GET /v1/provider/node-earnings` | public | Per-node earnings. |
| `GET /v1/provider/account-earnings` | API key / JWT | Earnings for the calling account. |
| `GET /v1/me/providers` | Privy | Provider machines linked to the calling account. |
| `GET /v1/me/summary` | Privy | Account summary. |
| `POST /v1/provider/log-report` | API key / JWT | Upload sanitized provider log bundle. |

## Attestation, Enrollment & Devices

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /v1/providers/attestation` | public | Per-provider attestation: SE public key, hardware/security state, MDM status, Apple MDA cert chain (base64 DER). |
| `POST /v1/enroll` | public | MDM + ACME enrollment profile generation. |
| `POST /v1/mdm/webhook` | MicroMDM | MDM webhook ingest. |
| `GET /v1/encryption-key` | public | Coordinator X25519 public key (sealed client transport). |
| `POST /v1/device/code` | public | Start device-code flow (provider not yet authenticated). |
| `POST /v1/device/token` | public | Poll for token with `device_code`. |
| `POST /v1/device/approve` | Privy | Approve a device code, linking the machine to the account. |

## Network & Stats

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /health` | public | Liveness + connected provider count. |
| `GET /v1/stats` | public | Active providers, per-model provider counts, geographic distribution (city/region rollups, k-anonymity minimum), hardware totals. |
| `GET /v1/leaderboard` | public | Provider leaderboard. |
| `GET /v1/network/totals` | public | All-time jobs, tokens, earnings, active accounts. |
| `GET /api/version` | public | Latest provider bundle version, download URL, binary/bundle hashes. |

## Releases & Install

| Endpoint | Auth | Description |
|----------|------|-------------|
| `GET /install.sh` | public | Installer script (`curl -fsSL https://api.darkbloom.dev/install.sh \| bash`). |
| `GET /v1/releases/latest` | public | Latest signed release metadata. |
| `POST /v1/releases` | release key | Register a release (GitHub Actions). |

## Referrals & Invites

| Endpoint | Auth | Description |
|----------|------|-------------|
| `POST /v1/referral/register` | API key / JWT | Create a referral code. |
| `POST /v1/referral/apply` | API key / JWT | Apply a referral code. |
| `GET /v1/referral/stats` / `GET /v1/referral/info` | API key / JWT | Referral stats / config. |
| `POST /v1/invite/redeem` | API key / JWT | Redeem an alpha invite code. |

## Telemetry

| Endpoint | Auth | Description |
|----------|------|-------------|
| `POST /v1/telemetry/events` | provider | Allowlisted telemetry event ingest (no prompt/completion content accepted). |

## Admin (admin key or Privy admin role)

| Endpoint | Description |
|----------|-------------|
| `POST /v1/admin/auth/init` / `POST /v1/admin/auth/verify` | OTP admin auth. |
| `POST /v1/admin/models/register` | Register a model build. |
| `GET/POST /v1/admin/models/aliases`, `DELETE /v1/admin/models/aliases/{aliasID}` | Manage public model aliases (desired-build pointers). |
| `POST /v1/admin/models/{...}` | Registry actions (activate/retire builds). |
| `GET /v1/admin/releases` / `DELETE /v1/admin/releases` | Release management. |
| `POST /v1/admin/invite-codes` / `GET` / `DELETE` | Invite code management. |
| `POST /v1/admin/credit` / `POST /v1/admin/reward` | Ledger credits/rewards. |
| `PUT /v1/admin/users/role` / `PUT /v1/admin/users/platform-fee` | User role / per-account fee override. |
| `GET /v1/admin/log-reports` / `GET /v1/admin/log-reports/{id}` | Provider log reports. |
| `GET /v1/admin/metrics` | Admin metrics snapshot. |
| `GET /v1/admin/state-export` | Admin-gated state export (see [runbooks/dar70-state-export-runbook.md](runbooks/dar70-state-export-runbook.md)). |

Unmatched `/v1/*` paths return a structured `not_implemented` error.
