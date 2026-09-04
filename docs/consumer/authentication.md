# Authentication

> Last updated: 2026-09-03 · commit `5d400cf75`

How to obtain and manage each credential the coordinator accepts, and which routes take it. Every request authenticates with one header, `Authorization: Bearer <token>` (`extractBearerToken`, `coordinator/api/server.go`); the token is an API key, a Privy session JWT, a device-flow provider token, or the operator's admin key, and `requireAuth` decides which by shape — JWTs (starting `eyJ`) are verified with Privy, the admin key is compared in constant time, everything else is looked up as an API key. For API consumers and console users; the per-route auth column is in [`../reference/api-contracts.md`](../reference/api-contracts.md).

## Prerequisites

- An email address. Email is the only Privy login method the console enables (`loginMethods: ["email"]`, `console-ui/src/components/providers/PrivyRealProvider.tsx`).
- For step 5, a Mac with the provider CLI installed ([`../provider/installation.md`](../provider/installation.md)).

## Steps

### 1. Create an API key

1. Sign in at `https://console.darkbloom.dev` with your email.
2. Open the API console page (`/api-console`, `console-ui/src/app/api-console/page.tsx`) and create a key; optionally set a budget, rate limits, an allowed-model list, or an expiry.
3. Copy the secret when it is shown. It is returned only by create and rotate and is not retrievable later.

Equivalent API call with your Privy session token:

```bash
curl -s -X POST https://api.darkbloom.dev/v1/keys \
  -H "Authorization: Bearer $PRIVY_JWT" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci", "rpm_limit": 60, "allowed_models": ["<model id>"]}'
```

The response is `{"key": "sk-db-...", "data": {...APIKeyResponse}}` (`CreateAPIKeyResponse`). The secret starts with `sk-db-` (`KeyPrefix`, `coordinator/store/apikey.go`); its exact shape, the `id` format used in `/v1/keys/{id}`, and every per-key setting — `name`, `limit_usd` + `limit_reset` (spend budget), `rpm_limit`, `itpm_limit`, `otpm_limit`, `allowed_models`, `expires_at`, `self_route_only`, `disabled` — are specified in [`../reference/api-contracts.md#api-key-shapes`](../reference/api-contracts.md#api-key-shapes). `label` in the response masks the secret to its prefix, first four and last four characters (`KeyLabel`). Keys minted before the rename start with `eigeninference-` and remain valid, because lookups are by hash, not by prefix (`coordinator/store/apikey.go`).

The settings are enforced in the request prelude: `rpm_limit` → 429 before the account limiter (`applyKeyRPMLimit`, `coordinator/api/server.go`); `allowed_models` → 403 `model_not_allowed` (`keyModelAllowed`, `coordinator/api/apikey_handlers.go`); an exhausted `limit_usd` → 402 (`reserveInferenceBalance`, `coordinator/api/inference_admission.go`; the response taxonomy is in [`../architecture/billing.md#payment-required-responses`](../architecture/billing.md#payment-required-responses)).

### 2. Use the key

```bash
curl -s https://api.darkbloom.dev/v1/models -H "Authorization: Bearer sk-db-..."
```

API keys work on every route marked `key` in the contracts page — inference, `/v1/models`, balance and usage, referral reads, invite redemption, Stripe checkout. The coordinator does not read `x-api-key`; SDKs that send only that header (the Anthropic SDK's `api_key` option) must be configured to send a bearer token instead — see [`quickstart.md`](quickstart.md).

### 3. Manage keys

All management routes require a Privy JWT (`requirePrivyAuth`); calling them with an API key returns 403 `forbidden`.

| Action | Call |
|---|---|
| List | `GET /v1/keys` → `{object: "list", data: [...]}` |
| Inspect one | `GET /v1/keys/{id}` |
| Change limits, name, models, expiry; disable | `PATCH /v1/keys/{id}` with any subset of the settings above |
| Rotate secret, keep settings | `POST /v1/keys/{id}/rotate` → new `key` |
| Revoke | `DELETE /v1/keys/{id}` |
| Inspect the key you are calling with | `GET /v1/key` — this one accepts the API key itself (`handleGetCallingKey`) |

`POST /v1/auth/keys` and `DELETE /v1/auth/keys` are the older one-key-per-account endpoints (`handleCreateKey`, `handleRevokeKey`); they still work but the `/v1/keys` family is the managed surface. The coordinator caches key lookups (`coordinator/api/server.go`), so a revocation or a limit change takes up to [`apiKeyCacheTTL`](../reference/api-contracts.md#timeouts-and-constants) to apply everywhere.

### 4. Sign in with Privy and use the session JWT

The console signs you in with Privy (email only, in an in-page modal — `/login` redirects to `/`, `console-ui/src/proxy.ts`); the resulting JWT can be used directly as a bearer token. `requireAuth` verifies it (`privyAuth.VerifyToken`) and resolves or creates the account user, so a JWT is accepted everywhere an API key is. The console itself sends the JWT only on management routes — keys, fleet, earnings, device approval, Stripe Connect — through its `/api/*` relay (`managementHeaders`, `console-ui/src/lib/http/proxy-client.ts`); for chat, balance and usage it uses the `sk-db-…` console key it provisions on first login with `POST /v1/auth/keys` (`provisionConsoleKey`, `console-ui/src/hooks/useAuth.ts`). Some routes require the JWT:

| Routes requiring a Privy JWT (`requirePrivyAuth`) | With an API key you get |
|---|---|
| `POST`/`DELETE /v1/auth/keys`, all of `/v1/keys*` | 403 `forbidden` |
| `GET /v1/me/summary`, `GET /v1/me/providers`, `GET /v1/me/self-route-models`, `DELETE /v1/me/providers/{id}` | 403 `forbidden` |
| `POST /v1/device/approve` | 403 `forbidden` |
| `POST /v1/billing/stripe/dashboard`, `DELETE /v1/billing/stripe/account` | 403 `forbidden` |

A second group accepts `requireAuth` but then insists on a resolved account user (`requirePrivyUser`, `coordinator/api/billing_handlers.go`): `PUT`/`DELETE /v1/pricing`, `POST /v1/referral/register`, `POST /v1/referral/apply`, `POST /v1/billing/stripe/onboard`, `GET /v1/billing/stripe/status`, `POST /v1/billing/withdraw/stripe`, `GET /v1/billing/stripe/withdrawals`. A Privy JWT or an API key that belongs to a Privy account passes; the admin key and unlinked legacy keys get 401 `auth_error`.

### 5. Link a provider machine (device-code flow)

`darkbloom login` links a machine to your account with an RFC 8628 device-code exchange ([`../provider/cli-reference.md`](../provider/cli-reference.md)). What the CLI does, so you can recognise it or drive it yourself:

1. `POST /v1/device/code` (no auth) → `{device_code, user_code, verification_uri, expires_in, interval}` (`handleDeviceCode`, `coordinator/api/device_auth.go`); the code lifetime and poll interval are the constants `DeviceCodeExpiry` and `DeviceCodePollInterval` in [`../reference/api-contracts.md#device-code-flow-3`](../reference/api-contracts.md#device-code-flow-3). `verification_uri` is the console's `/link` page.
2. You open `verification_uri` (`console-ui/src/app/link/page.tsx`), sign in with Privy, and enter `user_code`. The page posts to the console's same-origin `/api/device/approve` relay, which forwards `POST /v1/device/approve` with your JWT (`console-ui/src/app/link/DeviceLinkForm.tsx`, `console-ui/src/app/api/device/approve/route.ts`; `handleDeviceApprove`); the code is bound to your account. Errors: 404 `invalid_code`, 409 `already_used`, 410 `expired_code`.
3. The CLI polls `POST /v1/device/token` with `{"device_code"}` every `interval` seconds (`handleDeviceToken`). While unapproved it gets 200 `{"status": "authorization_pending"}`; after approval 200 `{"status": "authorized", "token": "eigeninference-pt-...", "account_id": "..."}`; once `DeviceCodeExpiry` has passed, 410 `expired_token`; an unknown code is 404 `invalid_grant`.

The `token` is a **provider token**, stored on the machine and labelled `device-<user_code>` in your account. It authorises that machine to earn for your account and to be targeted by self-route requests ([`../provider/self-route.md`](../provider/self-route.md)); it is not a consumer API key and does not authenticate inference requests. The bindings behind the flow are in [`../architecture/security/identity-binding.md#device-code-account-linking`](../architecture/security/identity-binding.md#device-code-account-linking).

## Verify

- `GET /v1/key` with the new key returns its `APIKeyResponse` (`handleGetCallingKey`) — the one management read that accepts the API key itself.
- `GET /v1/keys` with the Privy JWT lists the key with `usage_usd`, `limit_usd` and `remaining_usd`.
- After `darkbloom login`, `darkbloom doctor` shows `account link` ✓ on the Mac and the machine appears in `GET /v1/me/providers` (Privy).

## Troubleshooting

| Response | Meaning | Fix |
|---|---|---|
| 401 `authentication_error` "missing credentials" | No `Authorization` header, or not `Bearer` | Send `Authorization: Bearer <token>`; the coordinator ignores `x-api-key` |
| 401 `authentication_error` "invalid Privy token" | JWT failed verification | Sign in again and use the fresh token |
| 401 `authentication_error` "invalid API key" | Unknown, disabled, expired or revoked API key | Create or rotate a key (steps 1 and 3) |
| 401 `auth_error` | Route needs an account user and the credential has none (admin key, unlinked legacy key) | Use a Privy JWT or an API key that belongs to a Privy account |
| 403 `forbidden` | API key on a Privy-only route, or non-admin on an admin route | Use the Privy JWT (step 4). Admin routes take the admin key (`EIGENINFERENCE_ADMIN_KEY`, `AdminKey`, `coordinator/api/server_config.go`), which passes `requireAuth` as the synthetic account `admin` and bypasses the request-rate limiters — an operator credential consumers never need ([route conventions](../reference/api-contracts.md#conventions-used-in-the-route-tables); rotation in [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md)) |
| 403 `model_not_allowed` | Model outside the key's `allowed_models` | Send an allowed id, or `PATCH /v1/keys/{id}` |
| 402 | Account balance or key budget exhausted; `error.type` is `insufficient_funds` or `insufficient_quota` ([taxonomy](../architecture/billing.md#payment-required-responses)) | Deposit, or raise the key's `limit_usd` ([`billing.md`](billing.md)) |
| 429 `rate_limit_exceeded` + `Retry-After` | Key `rpm_limit`, account limiter, or token limits | Wait `Retry-After` seconds; raise `rpm_limit` on the key if it is the binding limit |

## Related

- [`quickstart.md`](quickstart.md) — first request with `curl` and the SDKs.
- [`billing.md`](billing.md) — deposits, spend caps, and acting on a 402.
- [`../reference/api-contracts.md`](../reference/api-contracts.md) — per-route auth column, key shapes, device-code constants.
- [`../provider/cli-reference.md`](../provider/cli-reference.md) — `darkbloom login` / `logout`.
- [`../provider/self-route.md`](../provider/self-route.md) — what a linked machine lets you do.
- [`../architecture/security/identity-binding.md`](../architecture/security/identity-binding.md) — how tokens, keys and accounts are bound.
