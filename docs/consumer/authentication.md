# Authentication

> Last updated: 2026-09-03 · commit `5d400cf75`

Every coordinator request authenticates with one header, `Authorization: Bearer <token>` (`extractBearerToken`, `coordinator/api/server.go`). The token is one of four things — an API key, a Privy session JWT, a device-flow provider token, or the admin key — and `requireAuth` decides which by shape: JWTs (starting `eyJ`) are verified with Privy, the admin key is compared in constant time, everything else is looked up as an API key. This page tells you how to obtain and manage each credential and which routes accept it. The per-route auth column is in [`../reference/api-contracts.md`](../reference/api-contracts.md).

## API keys

### Facts

| Property | Value | Source |
|---|---|---|
| Format | `sk-db-` + 64 hex characters (32 random bytes) | `KeyPrefix`, `GenerateRawKey` (`coordinator/store/apikey.go`) |
| Legacy format | Keys minted before the rename start with `eigeninference-` and remain valid; lookups are by hash, not prefix | `coordinator/store/apikey.go` |
| Key id | `key_` + hex, used in `/v1/keys/{id}` | `GenerateKeyID` |
| Display label | `sk-db-1a2b…c3d4` (prefix, four characters, last four) | `KeyLabel` |
| Storage | Only a hash is stored; the secret is returned once, by create and rotate | `handleCreateAPIKey`, `handleRotateAPIKey` (`coordinator/api/apikey_handlers.go`) |
| Cache | Key lookups are cached for `apiKeyCacheTTL` = 60 s, so revocation or a limit change takes up to a minute to apply everywhere | `coordinator/api/server.go` |
| Per-key settings | `name`, `limit_usd` + `limit_reset` (spend budget), `rpm_limit`, `itpm_limit`, `otpm_limit`, `allowed_models`, `expires_at`, `self_route_only`, `disabled` | `APIKeyResponse` (`coordinator/api/types/types.go`), `handleUpdateAPIKey` |
| Enforcement | `rpm_limit` → 429 before the account limiter (`applyKeyRPMLimit`); `allowed_models` → 403 `model_not_allowed` (`keyModelAllowed`); exhausted `limit_usd` → 402 (`reserveInferenceBalance`, `coordinator/api/inference_admission.go`) | `coordinator/api/server.go`, `coordinator/api/apikey_handlers.go` |

### Create a key

1. Sign in at `https://console.darkbloom.dev` with your email — the only Privy login method the console enables (`loginMethods: ["email"]`, `console-ui/src/components/providers/PrivyRealProvider.tsx`).
2. Open the API console page (`/api-console`, `console-ui/src/app/api-console/page.tsx`) and create a key; optionally set a budget, rate limits, an allowed-model list, or an expiry.
3. Copy the secret when it is shown. It is not retrievable later.

Equivalent API call with your Privy session token:

```bash
curl -s -X POST https://api.darkbloom.dev/v1/keys \
  -H "Authorization: Bearer $PRIVY_JWT" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci", "rpm_limit": 60, "allowed_models": ["<model id>"]}'
```

The response is `{"key": "sk-db-...", "data": {...APIKeyResponse}}` (`CreateAPIKeyResponse`).

### Manage keys

All management routes require a Privy JWT (`requirePrivyAuth`); calling them with an API key returns 403 `forbidden`.

| Action | Call |
|---|---|
| List | `GET /v1/keys` → `{object: "list", data: [...]}` |
| Inspect one | `GET /v1/keys/{id}` |
| Change limits, name, models, expiry; disable | `PATCH /v1/keys/{id}` with any subset of the settings above |
| Rotate secret, keep settings | `POST /v1/keys/{id}/rotate` → new `key` |
| Revoke | `DELETE /v1/keys/{id}` |
| Inspect the key you are calling with | `GET /v1/key` — this one accepts the API key itself (`handleGetCallingKey`) |

`POST /v1/auth/keys` and `DELETE /v1/auth/keys` are the older one-key-per-account endpoints (`handleCreateKey`, `handleRevokeKey`); they still work but the `/v1/keys` family is the managed surface.

### Use a key

```bash
curl -s https://api.darkbloom.dev/v1/models -H "Authorization: Bearer sk-db-..."
```

API keys work on every route marked `key` in the contracts page — inference, `/v1/models`, balance and usage, referral reads, invite redemption, Stripe checkout. The coordinator does not read `x-api-key`; SDKs that send only that header (the Anthropic SDK's `api_key` option) must be configured to send a bearer token instead — see [`quickstart.md`](quickstart.md).

## Privy session JWT

The console signs you in with Privy (email only, in an in-page modal — `/login` redirects to `/`, `console-ui/src/proxy.ts`); the resulting JWT can be used directly as a bearer token. `requireAuth` verifies it (`privyAuth.VerifyToken`) and resolves or creates the account user, so a JWT is accepted everywhere an API key is. The console itself sends the JWT only on management routes — keys, fleet, earnings, device approval, Stripe Connect — through its `/api/*` relay (`managementHeaders`, `console-ui/src/lib/http/proxy-client.ts`); for chat, balance and usage it uses the `sk-db-…` console key it provisions on first login with `POST /v1/auth/keys` (`provisionConsoleKey`, `console-ui/src/hooks/useAuth.ts`). Some routes require the JWT:

| Routes requiring a Privy JWT (`requirePrivyAuth`) | With an API key you get |
|---|---|
| `POST`/`DELETE /v1/auth/keys`, all of `/v1/keys*` | 403 `forbidden` |
| `GET /v1/me/summary`, `GET /v1/me/providers`, `GET /v1/me/self-route-models`, `DELETE /v1/me/providers/{id}` | 403 `forbidden` |
| `POST /v1/device/approve` | 403 `forbidden` |
| `POST /v1/billing/stripe/dashboard`, `DELETE /v1/billing/stripe/account` | 403 `forbidden` |

A second group accepts `requireAuth` but then insists on a resolved account user (`requirePrivyUser`, `coordinator/api/billing_handlers.go`): `PUT`/`DELETE /v1/pricing`, `POST /v1/referral/register`, `POST /v1/referral/apply`, `POST /v1/billing/stripe/onboard`, `GET /v1/billing/stripe/status`, `POST /v1/billing/withdraw/stripe`, `GET /v1/billing/stripe/withdrawals`. A Privy JWT or an API key that belongs to a Privy account passes; the admin key and unlinked legacy keys get 401 `auth_error`.

## Device-code flow (provider CLI)

`darkbloom login` links a machine to your account with an RFC 8628 device-code exchange ([`../provider/cli-reference.md`](../provider/cli-reference.md)). What the CLI does, so you can recognise it or drive it yourself:

1. `POST /v1/device/code` (no auth) → `{device_code, user_code, verification_uri, expires_in: 900, interval: 5}` (`handleDeviceCode`, `coordinator/api/device_auth.go`). `verification_uri` is the console's `/link` page.
2. You open `verification_uri` (`console-ui/src/app/link/page.tsx`), sign in with Privy, and enter `user_code`. The page posts to the console's same-origin `/api/device/approve` relay, which forwards `POST /v1/device/approve` with your JWT (`console-ui/src/app/link/DeviceLinkForm.tsx`, `console-ui/src/app/api/device/approve/route.ts`; `handleDeviceApprove`); the code is bound to your account. Errors: 404 `invalid_code`, 409 `already_used`, 410 `expired_code`.
3. The CLI polls `POST /v1/device/token` with `{"device_code"}` every `interval` seconds (`handleDeviceToken`). While unapproved it gets 200 `{"status": "authorization_pending"}`; after approval 200 `{"status": "authorized", "token": "eigeninference-pt-...", "account_id": "..."}`; after `DeviceCodeExpiry` (15 minutes) 410 `expired_token`; an unknown code is 404 `invalid_grant`.

The `token` is a **provider token**, stored on the machine and labelled `device-<user_code>` in your account. It authorises that machine to earn for your account and to be targeted by self-route requests ([`../provider/self-route.md`](../provider/self-route.md)); it is not a consumer API key and does not authenticate inference requests.

## Admin key

`EIGENINFERENCE_ADMIN_KEY` (`AdminKey`, `coordinator/api/server_config.go`) is a single operator secret. Presented as a bearer it passes `requireAuth` as the synthetic account `admin`, bypasses the request-rate limiters, and satisfies the in-handler checks on `/v1/admin/*` (`isAdminAuthorized`, `coordinator/api/release_handlers.go`; `requireAdminKey`, `coordinator/api/invite_handlers.go`). Those routes cover pricing defaults, user roles and fee overrides, manual credits and rewards, invite codes, releases, drain, profiler exports, and the encrypted state export. A Privy user whose email is on the admin list can reach the subset of admin routes that are wrapped in `requireAuth`; the rest are admin-key only. Consumers never need it; where it lives and how it is rotated is an operations topic — see [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md).

## Failure reference

| Response | Meaning |
|---|---|
| 401 `authentication_error` "missing credentials" | No `Authorization` header, or not `Bearer` |
| 401 `authentication_error` "invalid Privy token" | JWT failed verification |
| 401 `authentication_error` "invalid API key" | Unknown, disabled, expired or revoked API key |
| 401 `auth_error` | Route needs an account user and the credential has none |
| 403 `forbidden` | API key on a Privy-only route, or non-admin on an admin route |
| 403 `model_not_allowed` | Model outside the key's `allowed_models` |
| 402 `insufficient_funds` / `insufficient_quota` | Account balance or key budget exhausted |
| 429 `rate_limit_exceeded` + `Retry-After` | Key `rpm_limit`, account limiter, or token limits |
