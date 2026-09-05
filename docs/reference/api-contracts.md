# HTTP API contracts

> Last updated: 2026-09-05 · commit `4d9811f7c`

The complete public HTTP surface of the coordinator, derived from the 105 `HandleFunc` registrations in `routes()` (`coordinator/api/server.go`), including the `/v1/` catch-all. Every route is listed once below with its handler symbol, authentication requirement, and rate-limit bucket; the second half of the page gives the wire shapes, headers, error table, SSE framing, limits, timeouts, and version-gate semantics that those routes share. For *why* the pipeline is built this way see [`../architecture/components/consumer.md`](../architecture/components/consumer.md); for the crypto model behind sealed transport see [`../architecture/security/encryption.md`](../architecture/security/encryption.md).

Production base URL: `https://api.darkbloom.dev`. Unless a file is named, handler symbols below live in `coordinator/api/server.go`.

The public model catalog optionally includes `hugging_face_artifact` for direct
provider downloads; the admin registration accepts the same object. See the
[registry artifact contract](model-registry-format.md#hugging-face-download-artifact).

## Conventions used in the route tables

**Auth column** — how the handler chain establishes identity. The only credential header is `Authorization: Bearer <token>` (`extractBearerToken`); the coordinator never reads `x-api-key`.

| Label | Mechanism | Symbol |
|---|---|---|
| `—` | No authentication | — |
| `key` | Bearer is an API key ([shape](#api-key-shapes); legacy `eigeninference-…` keys are also accepted), a Privy JWT, or the admin key. Missing or invalid → 401 `authentication_error` | `requireAuth` |
| `privy` | Bearer must be a Privy JWT. API keys → 403 `forbidden` | `requirePrivyAuth` |
| `user` | `key` or `privy` plus an in-handler check that a resolved account user is in the context (Privy JWT, or an API key linked to a Privy account). Admin key and unlinked legacy keys → 401 `auth_error` | `requirePrivyUser` (`coordinator/api/billing_handlers.go`) |
| `admin` | In-handler check: Bearer equals the admin key (`EIGENINFERENCE_ADMIN_KEY`), or the context holds a Privy user whose email is in the admin list. Otherwise 403 `forbidden`. When the route is registered *without* `requireAuth` no user is ever placed in the context, so only the admin key can pass; those rows say `admin-key` | `isAdminAuthorized` (`coordinator/api/release_handlers.go`), `requireAdminKey` (`coordinator/api/invite_handlers.go`), `isAdmin` (`coordinator/api/billing_handlers.go`) |
| `publishing` | `X-Darkbloom-Publishing-Key` header or Bearer equal to the bootstrap `MODEL_REGISTRY_PUBLISHING_KEY`, the admin key, or a publishing key stored in the DB | `requirePublishingAPIKey` (`coordinator/api/model_registry_handlers.go`) |
| `release` | Bearer equal to `EIGENINFERENCE_RELEASE_KEY`; otherwise 401 `unauthorized` | `handleRegisterRelease` (`coordinator/api/release_handlers.go`) |
| `stripe-sig` | Stripe webhook signature | `handleStripeWebhook` (`coordinator/api/billing_handlers.go`), `handleStripeConnectWebhook` (`coordinator/api/stripe_payouts_webhooks.go`) |
| `mdm-secret` | Webhook secret via `X-Webhook-Token` header or `?token=`; body capped at [`maxMDMWebhookBodyBytes`](#limits-and-validation) | `HandleMDMWebhook` |
| `ws` | Provider WebSocket handshake (enrollment credentials + attestation); see [`protocol-messages.md`](protocol-messages.md) | `handleProviderWS` (`coordinator/api/provider.go`) |

**Limiter column** — the rate-limit middleware in the chain. All limiters share one implementation, `rateLimitWithTier`, keyed by the authenticated account id (`consumerKeyFromContext`); the admin key bypasses it.

| Label | Behaviour | Symbol |
|---|---|---|
| `drain` | While draining, new inference requests get **429** `rate_limit_exceeded` with `Retry-After` set to [`coordinatorDrainRetryAfter`](#timeouts-and-constants) (written through `writeTokenRateLimited`) | `drainGate` (`coordinator/api/drain.go`) |
| `rpm` | Consumer tier: first the key's own `rpm_limit` (`applyKeyRPMLimit`), then the account limiter; service-role accounts use the elevated service limiter. Rejection → 429 `rate_limit_exceeded` (`code: rate_limit_exceeded`) with `Retry-After` and `X-RateLimit-Reset` | `rateLimitConsumer` |
| `fin` | Financial tier: the stricter limiter installed by `SetFinancialRateLimiter`, applied to every account regardless of role; same 429 shape | `rateLimitFinancial` |

Both tiers set `x-ratelimit-limit-requests`, `x-ratelimit-remaining-requests`, `x-ratelimit-reset-requests` on allowed *and* rejected responses (`setRequestRateLimitHeaders`). Limiter `Retry-After` values are clamped to `[DefaultRetryAfter, maxRetryAfter]` ([Timeouts and constants](#timeouts-and-constants)).

## Routes

### Inference (4)

All four share the chain `drainGate → requireAuth → rateLimitConsumer → sealedTransport → handler` and the pipeline in `coordinator/api/consumer.go`.

| Method | Path | Handler | Auth | Limiter | Notes |
|---|---|---|---|---|---|
| POST | `/v1/chat/completions` | `handleChatCompletions` (`coordinator/api/consumer.go`) | `key` | `drain`, `rpm`, token limits | OpenAI Chat Completions, streaming and non-streaming |
| POST | `/v1/responses` | `handleChatCompletions` — the same handler; it detects `input` (Responses) versus `messages` (Chat) | `key` | same | OpenAI Responses; lowered by `coordinator/promptcontract/endpoint_lower_responses.go`, streamed by `newResponsesStreamEmitter` (`coordinator/api/responses_stream.go`) |
| POST | `/v1/completions` | `handleCompletions` (`coordinator/api/consumer.go`) | `key` | same | Legacy text completions; response built by `coordinator/api/generic_endpoint_response.go`, streamed by `newGenericEndpointStreamEmitter` (`coordinator/api/generic_endpoint_stream.go`) |
| POST | `/v1/messages` | `handleAnthropicMessages` (`coordinator/api/consumer.go`) | `key` | same | Anthropic Messages; lowered by `coordinator/promptcontract/endpoint_lower_messages.go`, streamed by `newMessagesStreamEmitter` |

### Models and catalog (9)

| Method | Path | Handler | Auth | Limiter | Notes |
|---|---|---|---|---|---|
| GET | `/v1/models` | `handleListModels` (`coordinator/api/models_endpoints.go`) | `key` | — | `ModelListResponse`: public aliases plus un-aliased builds (`?include_builds=1` also lists hidden builds). With `X-Darkbloom-Route: self` or a `self_route_only` key it returns the account's own machines' models filtered by the key's `allowed_models`. Field reference in [`../consumer/models.md`](../consumer/models.md) |
| GET | `/v1/models/openrouter` | `handleListModelsOpenRouter` (`coordinator/api/openrouter_endpoint.go`) | `key` | — | `OpenRouterModelsResponse` projection |
| GET | `/v1/models/{id...}` | `handleGetModel` (`coordinator/api/models_endpoints.go`) | `key` | — | One `ModelEntry`; 404 `model_not_found` when neither a build id nor an alias matches |
| GET | `/v1/models/capacity` | `handleModelsCapacity` (`coordinator/api/capacity.go`) | `—` | — | Per-model provider capacity, cached 2 s |
| GET | `/v1/models/catalog` | `handleModelCatalog` (`coordinator/api/billing_handlers.go`) | `—` | — | Registry catalog; `?type=` selects the catalog kind, unknown → 400 |
| GET | `/v1/models/catalog/manifest/` | `handleModelCatalogManifest` (`coordinator/api/model_registry_handlers.go`) | `—` | — | Per-model manifest by path suffix |
| GET | `/v1/models/catalog/` | `handleModelCatalogItem` (`coordinator/api/model_registry_handlers.go`) | `—` | — | Single catalog item by path suffix |
| GET | `/v1/runtime/manifest` | `handleRuntimeManifest` | `—` | — | Hashes the coordinator accepts from provider runtimes: `{"configured":false}` or `{"configured":true,"python_hashes":{…},"runtime_hashes":{…},"template_hashes":{"<name>":[<sorted hashes accepted across active releases>]}}`; cached 1 min ([runtime manifest](../architecture/security/attestation.md#runtime-manifest)) |
| GET | `/v1/cache/status` | `handleExactCacheStatus` (`coordinator/api/exact_cache_status.go`) | `—` | — | Exact-cache status, cached for [`exactCacheStatusCacheTTL`](#timeouts-and-constants) |

### Authentication and API keys (10)

| Method | Path | Handler | Auth | Limiter | Notes |
|---|---|---|---|---|---|
| POST | `/v1/auth/keys` | `handleCreateKey` (`coordinator/api/apikey_handlers.go`) | `privy` | `fin` | Legacy mint: `CreateKeyResponse` `{api_key, account_id}` |
| DELETE | `/v1/auth/keys` | `handleRevokeKey` (`coordinator/api/apikey_handlers.go`) | `privy` | — | Body `{"key": "<api key>"}`; 400 `bad_request` otherwise; `RevokeKeyResponse` `{status}` |
| GET | `/v1/keys` | `handleListAPIKeys` (`coordinator/api/apikey_handlers.go`) | `privy` | — | `APIKeyListResponse` `{object: "list", data: [APIKeyResponse]}` |
| POST | `/v1/keys` | `handleCreateAPIKey` (`coordinator/api/apikey_handlers.go`) | `privy` | `fin` | `CreateAPIKeyResponse` `{key, data}`; `key` is the plaintext secret ([API key shapes](#api-key-shapes)) |
| GET | `/v1/keys/{id}` | `handleGetAPIKey` (`coordinator/api/apikey_handlers.go`) | `privy` | — | `APIKeyResponse` |
| PATCH | `/v1/keys/{id}` | `handleUpdateAPIKey` (`coordinator/api/apikey_handlers.go`) | `privy` | `fin` | Partial update, fields under [API key shapes](#api-key-shapes) |
| DELETE | `/v1/keys/{id}` | `handleDeleteAPIKey` (`coordinator/api/apikey_handlers.go`) | `privy` | `fin` | Revoke |
| POST | `/v1/keys/{id}/rotate` | `handleRotateAPIKey` (`coordinator/api/apikey_handlers.go`) | `privy` | `fin` | New secret, same settings |
| GET | `/v1/key` | `handleGetCallingKey` (`coordinator/api/apikey_handlers.go`) | `key` | — | The calling key's own `APIKeyResponse` |
| GET | `/v1/encryption-key` | `handleEncryptionKey` (`coordinator/api/sender_encryption.go`) | `—` | — | `{kid, public_key, algorithm: "x25519-nacl-box"}`, `Cache-Control: public, max-age=300`; 503 `encryption_unavailable` when sealing is not configured |

Lifecycle semantics: [`../consumer/authentication.md`](../consumer/authentication.md).

### Device-code flow (3)

| Method | Path | Handler | Auth | Limiter | Notes |
|---|---|---|---|---|---|
| POST | `/v1/device/code` | `handleDeviceCode` (`coordinator/api/device_auth.go`) | `—` | — | 200 `{device_code, user_code, verification_uri, expires_in, interval}` |
| POST | `/v1/device/token` | `handleDeviceToken` (`coordinator/api/device_auth.go`) | `—` | — | Body `{"device_code"}` (400 `invalid_request` if missing). 200 `{status: "authorization_pending"}` until approved; 200 `{status: "authorized", token, account_id}` once approved; 404 `invalid_grant`; 410 `expired_token` |
| POST | `/v1/device/approve` | `handleDeviceApprove` (`coordinator/api/device_auth.go`) | `privy` | `fin` | Body `{"user_code"}`. 404 `invalid_code`, 409 `already_used`, 410 `expired_code` |

Constants: `DeviceCodeExpiry` = 15 min (`expires_in: 900`), `DeviceCodePollInterval` = 5 (`interval`). The `token` is a **provider token** (`eigeninference-pt-` + 64 hex characters, labelled `device-<user_code>`; only its SHA-256 hash is stored) used by the provider CLI to link a machine to the account; it is not a consumer API key. The small-body cap [`maxControlPlaneBodyBytes`](#limits-and-validation) applies to these unauthenticated endpoints.

### Account, balance, usage and pricing (13)

| Method | Path | Handler | Auth | Limiter | Notes |
|---|---|---|---|---|---|
| GET | `/v1/payments/balance` | `handleBalance` (`coordinator/api/consumer.go`) | `key` | — | `BalanceResponse` `{balance_micro_usd, balance_usd, withdrawable_micro_usd, withdrawable_usd}` |
| GET | `/v1/payments/usage` | `handleUsage` (`coordinator/api/consumer.go`) | `key` | — | `UsageResponse` `{usage: [...]}`; recent history only ([retention](pricing-model.md#constants)) |
| GET | `/v1/billing/wallet/balance` | `handleWalletBalance` (`coordinator/api/billing_handlers.go`) | `key` | — | Wallet view of the ledger balance |
| GET | `/v1/billing/methods` | `handleBillingMethods` (`coordinator/api/billing_handlers.go`) | `—` | — | Which top-up methods are enabled |
| GET | `/v1/provider/earnings` | `handleProviderEarnings` (`coordinator/api/consumer.go`) | `—` | — | Legacy lookup by `?wallet=` query or `X-Provider-Wallet` header; `ProviderEarningsResponse` |
| GET | `/v1/provider/account-earnings` | `handleAccountEarnings` (`coordinator/api/billing_handlers.go`) | `key` | — | Earnings across the account's providers |
| GET | `/v1/me/summary` | `handleMySummary` (`coordinator/api/me_handlers.go`) | `user` | — | Console account summary; includes `latest_provider_version` |
| GET | `/v1/me/providers` | `handleMyProviders` (`coordinator/api/me_handlers.go`) | `user` | — | Machines linked to the account |
| GET | `/v1/me/self-route-models` | `handleMySelfRouteModels` (`coordinator/api/me_handlers.go`) | `user` | — | Models the account's own machines can serve |
| DELETE | `/v1/me/providers/{id}` | `handleDeleteMyProvider` (`coordinator/api/me_handlers.go`) | `user` | `fin` | Unlink a machine |
| GET | `/v1/pricing` | `handleGetPricing` (`coordinator/api/billing_handlers.go`) | `—` | — | Public price table; see [`pricing-model.md`](pricing-model.md) |
| PUT | `/v1/pricing` | `handleSetPricing` (`coordinator/api/billing_handlers.go`) | `user` | — | Provider sets its own prices |
| DELETE | `/v1/pricing` | `handleDeletePricing` (`coordinator/api/billing_handlers.go`) | `user` | — | Revert to defaults |

The four `/v1/me/*` routes are wrapped in `requirePrivyAuth`, so they are Privy-JWT only.

### Stripe, payouts and MDM (11)

| Method | Path | Handler | Auth | Limiter | Notes |
|---|---|---|---|---|---|
| POST | `/v1/billing/stripe/create-session` | `handleStripeCreateSession` (`coordinator/api/billing_handlers.go`) | `key` | `fin` | 502 `stripe_error` when Stripe rejects |
| POST | `/v1/billing/stripe/webhook` | `handleStripeWebhook` (`coordinator/api/billing_handlers.go`) | `stripe-sig` | — | Checkout events |
| GET | `/v1/billing/stripe/session` | `handleStripeSessionStatus` (`coordinator/api/billing_handlers.go`) | `key` | — | Poll a checkout session |
| POST | `/v1/billing/stripe/onboard` | `handleStripeOnboard` (`coordinator/api/stripe_payouts.go`) | `user` (Privy-only wrapper) | `fin` | Country-aware Connect or Global Payouts onboarding link |
| GET | `/v1/billing/stripe/status` | `handleStripeStatus` (`coordinator/api/stripe_payouts.go`) | `user` | — | Payout readiness; additive `payout_rail`, `payout_currency`, `countries`, `payouts_available` |
| POST | `/v1/billing/withdraw/stripe` | `handleStripeWithdraw` (`coordinator/api/stripe_withdraw.go`) | `user` (Privy-only wrapper) | `fin` | Global Payouts confirms a persisted `quote_id`; 409 `stripe_account_gone` / `stripe_account_recreate_required`; 502 `stripe_error` |
| GET | `/v1/billing/stripe/withdrawals` | `handleStripeWithdrawals` (`coordinator/api/stripe_payouts.go`) | `user` | — | Withdrawal history |
| POST | `/v1/billing/stripe/dashboard` | `handleStripeDashboardLink` (`coordinator/api/stripe_payouts.go`) | `user` (Privy-only wrapper) | `fin` | Express dashboard link |
| DELETE | `/v1/billing/stripe/account` | `handleStripeUnlink` (`coordinator/api/stripe_payouts.go`) | `user` (Privy-only wrapper) | — | Disconnect the Connect account |
| POST | `/v1/billing/stripe/connect/webhook` | `handleStripeConnectWebhook` (`coordinator/api/stripe_payouts_webhooks.go`) | `stripe-sig` | — | Connect events |
| POST | `/v1/billing/stripe/quote` | `handleGlobalPayoutQuote` (`coordinator/api/global_payouts_withdraw.go`) | `user` (Privy-only wrapper) | `fin` | `{amount_usd}` returns quote ID, local amount/currency/exponent, expiry and fee; no ledger debit. |
| POST | `/v1/billing/stripe/global/webhook` | `handleGlobalPayoutWebhook` (`coordinator/api/global_payouts_reconcile.go`) | `stripe-sig` (separate secret) | — | Reconciles the current outbound-payment state; does not consume Connect sweep events. |
| POST | `/v1/mdm/webhook` | `HandleMDMWebhook` | `mdm-secret` | — | Fleet enrollment webhook |

Ledger semantics, reservations and payouts: [`../architecture/billing.md`](../architecture/billing.md).

### Referral, invites and attestation roster (6)

| Method | Path | Handler | Auth | Limiter | Notes |
|---|---|---|---|---|---|
| POST | `/v1/referral/register` | `handleReferralRegister` (`coordinator/api/billing_handlers.go`) | `user` | `fin` | 400 `referral_error` on invalid input |
| POST | `/v1/referral/apply` | `handleReferralApply` (`coordinator/api/billing_handlers.go`) | `user` | `fin` | 400 `referral_error` |
| GET | `/v1/referral/stats` | `handleReferralStats` (`coordinator/api/billing_handlers.go`) | `key` | — | 404 `referral_error` when no referral record exists |
| GET | `/v1/referral/info` | `handleReferralInfo` (`coordinator/api/billing_handlers.go`) | `key` | — | 404 `referral_error` when no referral record exists |
| POST | `/v1/invite/redeem` | `handleRedeemInviteCode` (`coordinator/api/invite_handlers.go`) | `key` | `fin` | Redeem an invite code |
| GET | `/v1/providers/attestation` | `handleProviderAttestation` (`coordinator/api/provider.go`) | `—` | — | Public attestation roster; see [`../architecture/security/attestation.md`](../architecture/security/attestation.md) |

### Public stats and health (5)

| Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|
| GET | `/v1/stats` | `handleStats` (`coordinator/api/stats.go`) | `—` | Refresh every 30 s; preserve the UTC source observation time in `snapshot_at` (`time.RFC3339Nano`). Retain a successful body up to 5 min on refresh failure; 503 `service_unavailable` without an unexpired success |
| GET | `/v1/leaderboard` | `handleLeaderboard` (`coordinator/api/leaderboard.go`) | `—` | Cached 5 min (full) / 1 min (recent window) |
| GET | `/v1/network/totals` | `handleNetworkTotals` (`coordinator/api/network_totals.go`) | `—` | Totals refreshed every minute with the same 5 min safety TTL; 503 `service_unavailable` without an unexpired success; canonical windows `24h`, `7d`, `30d`, `all` (`1d` → `24h`, empty/`lifetime` → `all`) |
| GET | `/v1/network/series` | `handleNetworkSeries` (`coordinator/api/network_series.go`) | `—` | Time series, cached 1 min; 503 `service_unavailable` on a store error after a miss, with no failed result cached |
| GET | `/health` | `handleHealth` (`coordinator/api/consumer.go`) | `—` | `HealthResponse` `{status: "ok", draining, providers, version, build_commit, build_date}` |

A successful empty analytics window returns 200 with empty arrays or zero totals.
Query failures never publish a partial stats body. Cache behavior is implemented
by `coordinator/api/cache_refresher.go` (`computeCachedEntry`); the stats,
totals, and series handlers emit the 503 `service_unavailable` error envelope when no value is available.

### Release and install (5)

| Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|
| GET | `/install.sh` | inline closure in `routes()` rendering `installScript` with the coordinator URL from `resolveBaseURL` | `—` | Provider install script, `text/plain` |
| GET | `/api/version` | `handleVersion` (`coordinator/api/consumer.go`) | `—` | `VersionResponse` `{version, platform, backend, download_url, binary_hash, bundle_hash, metallib_hash, changelog}`; uses the newest active release in the store, else `LatestProviderVersion` |
| POST | `/v1/releases` | `handleRegisterRelease` (`coordinator/api/release_handlers.go`) | `release` | Register a release |
| GET | `/v1/releases/latest` | `handleLatestRelease` (`coordinator/api/release_handlers.go`) | `—` | Latest release record |
| GET | `/readyz` | `handleReadyz` (`coordinator/api/drain.go`) | `—` | 200 normally; 503 while draining |

Release publishing: [`../operations/provider-release.md`](../operations/provider-release.md).

### Enrollment and provider transport (3)

| Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|
| POST | `/v1/enroll` | `handleEnroll` (`coordinator/api/enroll.go`) | `—` (enrollment token in body) | Exchanges an enrollment token for provider credentials; see [`../architecture/security/enrollment.md`](../architecture/security/enrollment.md) |
| GET | `/ws/provider` | `handleProviderWS` (`coordinator/api/provider.go`) | `ws` | Provider WebSocket; message catalogue in [`protocol-messages.md`](protocol-messages.md) |
| POST | `/v1/provider/log-report` | `handleUploadLogReport` (`coordinator/api/log_report_handlers.go`) | `key` | Body capped at [`maxLogReportBodySize`](#timeouts-and-constants); 426 `upgrade_required` when `?serial=` names a provider below the minimum version |

### Telemetry (1)

| Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|
| POST | `/v1/telemetry/events` | `handleTelemetryIngest` (`coordinator/api/telemetry_handlers.go`) | `—` | Always **410 Gone** `telemetry_ingest_disabled`. Live telemetry is described in [`../architecture/telemetry.md`](../architecture/telemetry.md) |

### Admin (34)

| Method | Path | Handler | Auth | Notes |
|---|---|---|---|---|
| PUT | `/v1/admin/pricing` | `handleAdminPricing` (`coordinator/api/billing_handlers.go`) | `admin` | Platform default price table |
| PUT | `/v1/admin/users/role` | `handleAdminSetUserRole` (`coordinator/api/billing_handlers.go`) | `admin` | Role selects the consumer or service limiter |
| PUT | `/v1/admin/users/platform-fee` | `handleAdminSetUserPlatformFee` (`coordinator/api/billing_handlers.go`) | `admin` | Per-user fee override; fee policy in [`../architecture/billing.md#invariants`](../architecture/billing.md#invariants) |
| POST | `/v1/admin/models/register` | `handleRegisterModel` (`coordinator/api/model_registry_handlers.go`) | `publishing` | Publish a model build |
| POST | `/v1/admin/models/` | `handleAdminModelRegistryAction` (`coordinator/api/model_registry_handlers.go`) | `publishing` | Registry actions selected by path suffix |
| GET / POST | `/v1/admin/models/aliases` | `handleModelAliasList`, `handleModelAliasUpsert` (`coordinator/api/model_alias_handlers.go`) | `publishing` | Two registrations; upserts fan out `desired_models` (see [Version gating](#version-gating)) |
| DELETE | `/v1/admin/models/aliases/{aliasID}` | `handleModelAliasDelete` (`coordinator/api/model_alias_handlers.go`) | `publishing` | |
| GET / POST | `/v1/admin/models/openrouter-aliases` | `handleOpenRouterAliasList`, `handleOpenRouterAliasUpsert` (`coordinator/api/openrouter_alias_handlers.go`) | `publishing` | Two registrations |
| DELETE | `/v1/admin/models/openrouter-aliases/{aliasID}` | `handleOpenRouterAliasDelete` (`coordinator/api/openrouter_alias_handlers.go`) | `publishing` | |
| GET / DELETE | `/v1/admin/releases` | `handleAdminListReleases`, `handleAdminDeleteRelease` (`coordinator/api/release_handlers.go`) | `admin-key` | Two registrations |
| GET | `/v1/admin/state-export` | `handleAdminStateExport` (`coordinator/api/admin_state_export.go`) | `admin-key` | 404 unless `EIGENINFERENCE_STATE_EXPORT_ENABLED=true`; 412 `precondition_failed` without an encryption recipient. See [`../operations/state-export.md`](../operations/state-export.md) |
| POST | `/v1/admin/auth/init` | `handleAdminAuthInit` (`coordinator/api/release_handlers.go`) | `—` | Body `{"email"}`; starts a Privy email OTP for an admin email. 503 `not_configured` when Privy is not configured; 500 `otp_error` when sending fails |
| POST | `/v1/admin/auth/verify` | `handleAdminAuthVerify` (`coordinator/api/release_handlers.go`) | `—` | Verifies the OTP and returns a session token for the admin console |
| POST | `/v1/admin/invite-codes` | `handleAdminCreateInviteCode` (`coordinator/api/invite_handlers.go`) | `admin` (`fin`) | 409 `conflict` on code collision |
| GET / DELETE | `/v1/admin/invite-codes` | `handleAdminListInviteCodes`, `handleAdminDeactivateInviteCode` (`coordinator/api/invite_handlers.go`) | `admin` | Two registrations |
| POST | `/v1/admin/credit` | `handleAdminCredit` (`coordinator/api/billing_handlers.go`) | `admin` | Manual ledger credit |
| POST | `/v1/admin/reward` | `handleAdminReward` (`coordinator/api/billing_handlers.go`) | `admin` | Manual provider reward |
| GET | `/v1/admin/log-reports/{id}` | `handleGetLogReport` (`coordinator/api/log_report_handlers.go`) | `admin` | Fetch an uploaded provider log bundle |
| GET | `/v1/admin/metrics` | `handleAdminMetrics` | `admin-key` | Telemetry counters |
| GET | `/v1/admin/base-rewards` | `handleAdminBaseRewards` (`coordinator/api/base_rewards_handlers.go`) | `admin-key` | |
| GET | `/v1/admin/utilization` | `handleAdminUtilization` (`coordinator/api/admin_utilization.go`) | `admin-key` | |
| POST | `/v1/admin/drain` | `handleAdminDrain` (`coordinator/api/drain.go`) | `admin` | Start a drain; default grace [`DefaultDrainGrace`](#timeouts-and-constants) |
| GET | `/v1/admin/routes`, `/v1/admin/routes/export` | `handleAdminRoutes`, `handleAdminRoutesExport` (`coordinator/api/admin_telemetry.go`) | `admin-key` | Route records |
| GET | `/v1/admin/rejections`, `/v1/admin/rejections/export` | `handleAdminRejections`, `handleAdminRejectionsExport` (`coordinator/api/admin_telemetry.go`) | `admin-key` | Admission rejections; `could_have_served` is nullable: `null` means not evaluated. CSV uses an empty cell; `could_have_served=true|false` filters exclude unknowns. |
| GET | `/v1/admin/profiles`, `/v1/admin/profiles/export` | `handleAdminProfiles`, `handleAdminProfilesExport` (`coordinator/api/profiler_admin.go`) | `admin-key` | Request profiles; see [`../architecture/system-profiler.md`](../architecture/system-profiler.md) |
| GET | `/v1/admin/snapshots`, `/v1/admin/snapshots/export` | `handleAdminSnapshots`, `handleAdminSnapshotsExport` (`coordinator/api/profiler_admin.go`) | `admin-key` | |

### Catch-all (1)

| Pattern | Handler | Behaviour |
|---|---|---|
| `/v1/` | `handleUnimplementedEndpoint` | Any `/v1/*` request matching no registered method+path — including a wrong method on a real path — gets 404 `invalid_request_error` with message `endpoint <METHOD> <path> is not implemented` |

Total: 4 + 9 + 10 + 3 + 13 + 11 + 6 + 5 + 5 + 3 + 1 + 34 + 1 = **105 registrations**, matching `routes()`.

## Headers

### Read by the coordinator

| Header | Where | Meaning |
|---|---|---|
| `Authorization: Bearer <token>` | `extractBearerToken` | The only credential header; scheme match is case-insensitive |
| `X-Request-ID` | `loggingMiddleware` | Honoured if present, otherwise generated (`newRequestID`); echoed back and logged, never persisted |
| `Content-Type: application/eigeninference-sealed+json` | `sealedTransport` (`coordinator/api/sender_encryption.go`) | Switches the inference endpoint into sealed mode (`SealedContentType`) |
| `X-Darkbloom-Metadata-Details` | `applyMetadataDetailsRequest` (`coordinator/api/response_metadata.go`) | Requests the extended `metadata` object (`timing`, `location`) on chat completions; `?metadata=details` does the same |
| `X-Darkbloom-Route: self` / `prefer` | `resolveSelfRoutePolicy` (`coordinator/api/self_route.go`) | `self` restricts dispatch to the account's own machines; `prefer` tries them first and falls back to the fleet; see [`../provider/self-route.md`](../provider/self-route.md) |
| `X-Darkbloom-Publishing-Key` | `requirePublishingAPIKey` | Publishing credential for `/v1/admin/models/*` |
| `X-Provider-Wallet` | `handleProviderEarnings` | Wallet address for the legacy earnings lookup (fallback when `?wallet=` is absent) |
| `Stripe-Signature` | `handleStripeWebhook`, `handleStripeConnectWebhook` | Stripe webhook signature |
| `X-Webhook-Token` | `HandleMDMWebhook` | MDM webhook secret (or `?token=`) |
| `Origin` | `corsMiddleware` | Allowed origins default to `https://console.darkbloom.dev` plus localhost dev ports unless `EIGENINFERENCE_CONSOLE_URL` overrides |

### Set by the coordinator

| Header | Where | When |
|---|---|---|
| `X-Request-ID` | `loggingMiddleware` | Every response |
| `Retry-After` | `rateLimitWithTier`, `applyKeyRPMLimit`, `writeTokenRateLimited`, `drainGate`, `shedIfModelRejected`, `writeTTFTTooSlow`, `writeServiceUnavailable`, `runInferenceAdmission`, `selfRouteUnavailable`, `preContentTerminal`, the exhausted branch of `dispatchState.run` (`coordinator/api/dispatch.go`) | Every 429 (including the drain 429, [`coordinatorDrainRetryAfter`](#timeouts-and-constants)); 503 `service_unavailable`, `machine_offline` (30 s), `model_not_loaded` (15 s), and 503 `provider_error` from dispatch exhaustion. **Not** set on 503 `model_unavailable`, 502, or 504. Admission values come from `estimateRetryAfter` (`coordinator/api/consumer.go`), capped at [`maxDistressRetryAfter`](#timeouts-and-constants); a provider-forecast `feasible_after_ms` overrides it, clamped to 2–30 s |
| `X-RateLimit-Reset`, `x-ratelimit-limit-requests`, `x-ratelimit-remaining-requests`, `x-ratelimit-reset-requests` | `rateLimitWithTier`, `setRequestRateLimitHeaders` | Request-rate limited routes (`rpm`, `fin`); the first only on rejection |
| `x-ratelimit-limit-input-tokens`, `x-ratelimit-remaining-input-tokens`, `x-ratelimit-reset-input-tokens`, and the `-output-tokens` triple | `setTokenRateLimitHeaders` | Inference responses when token limits are configured |
| `X-Timing` | `writeTimingHeaderWithProfile` (`coordinator/api/profiler_dispatch.go`) | Committed inference responses. A JSON object with the `RequestTimingDetails` fields (`coordinator/api/types/types.go`): `parse_us`, `reserve_us`, `media_fetch_us`, `route_us`, `queue_us`, `encrypt_us`, `dispatch_us`, `provider_us`, plus profiler-only additive keys (`pre_handler_us`, `preflight_us`, `route_reserve_us`, `queue_pure_us`, `writer_us`, `socket_us`, `provider_ack_us`, `timing_anomaly`) |
| `X-Inference-Job-ID` | `writeInferenceJobIDHeader` (`coordinator/api/sse_response.go`) | Committed inference responses; the coordinator job id, which can differ from `X-Request-ID` across retries |
| `X-Provider-Id`, `X-Provider-Attested` (`true`/`false`), `X-Provider-Trust-Level`, `X-Provider-Chip`, `X-Provider-Model`, `X-Provider-Encrypted` (only when `true`), `X-Provider-Secure-Enclave` (when known), `X-Provider-Mda-Verified` (only when `true`) | `writeCommittedProviderHeaders` (`coordinator/api/response_metadata.go`) | Committed inference responses; the same facts as the `metadata` object |
| `X-Attestation-Se-Public-Key` | `writeCommittedProviderHeaders` | When the provider attested with a Secure Enclave key; see [`../consumer/verification.md`](../consumer/verification.md) |
| `X-Eigen-Sealed: true`, `X-Eigen-Sealed-Kid` | `sealingResponseWriter` (`coordinator/api/sender_encryption.go`) | Sealed-mode responses |
| `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive` | `writeSSEResponseHeader` (`coordinator/api/sse_response.go`) | Streaming responses, written at commit |
| `Cache-Control: public, max-age=300` | `handleEncryptionKey` | `/v1/encryption-key` |
| `Access-Control-Allow-*` | `corsMiddleware` | Methods `GET, POST, PUT, PATCH, DELETE, OPTIONS`; allowed request headers include `Authorization`, `Content-Type`, `X-Darkbloom-Metadata-Details` |

## Error envelope and status codes

Every error body has one shape (`errorResponse`, `writeJSON`, `withCode` in `coordinator/api/httputil.go`):

```json
{
  "error": {
    "message": "human-readable text",
    "type": "rate_limit_exceeded",
    "code": "rate_limit_exceeded",
    "param": "model"
  }
}
```

`code` mirrors `type` unless a handler overrides it (`withCode`, e.g. `payload_too_large`, `model_capability_unsupported`); `param` is present only when a handler names the offending field (`withParam`, e.g. `"model"` on `model_not_found`). Errors raised *after* a stream has committed cannot change the status line; they surface as a terminal SSE `error` event followed by `data: [DONE]` (`writeChatStreamTerminalError`, `coordinator/api/chat_metadata_stream.go`; `writeChatStreamProviderError`, `coordinator/api/consumer.go`).

| Status | `type` values | Raised by |
|---|---|---|
| 400 | `invalid_request_error`, `invalid_sealed_envelope`, `kid_mismatch`, `decryption_failed`, `invalid_request`, `bad_request`, `referral_error` | Body/JSON validation, `n > 1`, tool-choice and vision rules, inference-enforced `tool_choice` combined with images (`param: tool_choice`), sealed-envelope faults, device-code and key-management input, unknown catalog `?type=` |
| 401 | `authentication_error`, `auth_error`, `unauthorized` | Missing/invalid bearer (`requireAuth`, `requirePrivyAuth`), no account user (`requirePrivyUser`), release key |
| 402 | `insufficient_funds` (balance below the reservation), `insufficient_quota` (per-key spend cap); `code` is `insufficient_quota` for both | `reserveInferenceBalance` (`coordinator/api/inference_admission.go`); the per-cause table, including the provider-price 402, is [Payment-required responses](../architecture/billing.md#payment-required-responses) |
| 403 | `forbidden`, `model_not_allowed` | API key on a `privy` route; non-admin on an `admin` route; model outside the key's `allowed_models` (`keyModelAllowed`, `coordinator/api/apikey_handlers.go`) |
| 404 | `model_not_found`, `not_found`, `invalid_grant`, `invalid_code`, `referral_error`, `invalid_request_error` | Model or alias not in the catalog; unknown key id; device codes; `/v1/` catch-all; state export when disabled |
| 409 | `no_linked_machine`, `already_used`, `conflict`, `stripe_account_gone`, `stripe_account_recreate_required` | Self-route without a linked machine; device-approve replay; invite-code collision; Stripe Connect state |
| 410 | `telemetry_ingest_disabled`, `expired_token`, `expired_code` | [Telemetry endpoint](#telemetry-1); expired [device codes](#device-code-flow-3) |
| 412 | `precondition_failed` | State export without an encryption recipient |
| 413 | `invalid_request_error` (plain, or with `code: payload_too_large`) | Inference body over `maxInferenceBodyBytes` ([Limits and validation](#limits-and-validation); `parseInferencePrelude`); admission rejects a prompt no provider can accept (`runInferenceAdmission`) |
| 422 | `invalid_request_error` | Tool-constraint schema the parser cannot compile (`validateResolvedToolConstraintParser`, `coordinator/api/tool_constraints.go`) |
| 426 | `upgrade_required` | Log report from a provider below the minimum version |
| 429 | `rate_limit_exceeded`, `machine_busy` | `machine_busy`: self-route (`X-Darkbloom-Route: self`) when the owned machine is at capacity, with `Retry-After` (`preContentTerminal`, `coordinator/api/dispatch.go`). `rate_limit_exceeded`: key RPM, account RPM, input/output tokens per minute, coordinator drain (`Retry-After` = [`coordinatorDrainRetryAfter`](#timeouts-and-constants)), admission shedding, model-rejection shedding, fleet TTFT too slow, and dispatch exhausted on capacity: every attempt refused for capacity, no provider produced first content within the deadline (the coordinator's own pre-content timeout is reclassified from 504 by `classifyExhaustedStatus`, `coordinator/api/dispatch.go`), or the request fits no provider; always with `Retry-After` |
| 500 | `internal_error`, `server_error`, `auth_error`, `otp_error` | Store failures, token generation, account lookup, admin OTP delivery |
| 502 | `provider_error`, `stripe_error` | Provider returned an error or no usable output; Stripe API failures |
| 503 | `model_unavailable` (no `Retry-After`; may carry `code: model_capability_unsupported`), `service_unavailable`, `encryption_unavailable`, `machine_offline`, `model_not_loaded`, `billing_error`, `not_configured`, `provider_error` | No routable provider for the resolved model; no serving capacity (`writeServiceUnavailable`); sealing not configured; self-route machine states; ledger or Stripe not configured; Privy not configured for admin OTP; `/readyz` while draining; dispatch exhausted on a genuine provider 503; public stats/totals/series store failure with no usable cached body (see [public stats](#public-stats-and-health-5)) |
| 504 | `timeout`, `provider_error` | `timeout`: non-streaming only, `inferenceTimeout` elapsed after commit while waiting for the response or its usage. `provider_error`: dispatch exhausted on a **typed** provider 504 (`terminalCauseSafetyDeadline`, `terminalCauseBackpressureTimeout`; `isTypedTimeout504Cause`, `coordinator/api/terminal_cause.go`) |

When every dispatched provider rejects a request with the same deterministic client error (for example a chat template that cannot render the messages, or a body the provider caps), the provider's own 4xx status is passed through once as `invalid_request_error` with `code: model_capability` (or `payload_too_large`) rather than being retried or reclassified (`terminalClientError` handling in the exhausted branch of `dispatchState.run`, `coordinator/api/dispatch.go`).

A client that disconnects before commit receives nothing; the coordinator records status 499 internally and cancels the provider job (`sendProviderCancel`, `coordinator/api/consumer.go`).

## Inference request and response shapes

### Chat Completions request

Requests are decoded into a generic JSON object with `json.Number` preserved (`parseInferencePrelude`, `coordinator/api/inference_preprocess.go`), so fields the coordinator does not interpret pass through to the provider. Fields it does interpret:

| Field | Handling |
|---|---|
| `model` | Required. Alias or build id, resolved by `resolveRequestedModel` (`coordinator/api/consumer.go`); see [`../consumer/models.md`](../consumer/models.md) |
| `messages` (Chat) / `input` (Responses) | Required; missing → 400 |
| `stream` | SSE when `true`; the provider's usage chunk, when it sends one, is held and emitted at the end of the stream |
| `n` | Values above 1 → 400 `invalid_request_error` |
| `max_tokens`, `max_completion_tokens` | `max_completion_tokens` is mapped to `max_tokens`. An explicit value is passed through unchanged (not clamped); when none is set the coordinator fills in the output bound from [pricing-model.md → Formulas](pricing-model.md#formulas) (`ensureMaxTokensBound`, `coordinator/api/consumer.go`) |
| `stop` | A single string is normalised to a one-element array in `parseInferencePrelude` |
| `tools`, `tool_choice`, `parallel_tool_calls` | Schemas normalised by `NormalizeToolSchemas` (`coordinator/api/toolschema.go`); constraints validated by `validateToolConstraintPolicy` (`coordinator/api/tool_constraints.go`) |
| `response_format` | Passed through to the provider without coordinator validation |
| `reasoning`, `reasoning_effort` | Applied per model policy by `applyResolvedModelReasoningPolicy` (`coordinator/api/reasoning_request_policy.go`) |
| `provider` and other routing hints | Removed by `stripProviderRoutingFields` (`coordinator/api/request_introspection.go`) |
| `image_url` parts with `http(s)` URLs | Fetched by the coordinator before dispatch (`resolveRemoteMedia`, `coordinator/api/media_resolve.go`) |

### Chat Completions response (`ChatCompletionResponse`, `coordinator/api/types/types.go`)

```json
{
  "id": "chatcmpl-…",
  "object": "chat.completion",
  "created": 1725000000,
  "model": "<the model string you sent>",
  "choices": [
    { "index": 0,
      "message": { "role": "assistant", "content": "…",
                   "reasoning": "…", "reasoning_content": "…", "reasoning_details": [ … ],
                   "tool_calls": [ … ] },
      "finish_reason": "stop" }
  ],
  "usage": {
    "prompt_tokens": 12, "completion_tokens": 34, "total_tokens": 46,
    "prompt_tokens_details": { "cached_tokens": 0 },
    "completion_tokens_details": { "reasoning_tokens": 0 }
  },
  "se_signature": "…",
  "response_hash": "…",
  "metadata": { … }
}
```

`model` echoes the requested string, alias included (`buildNonStreamingResponse`, `coordinator/api/consumer.go`). `se_signature` and `response_hash` are present when the provider signed the response; verification is described in [`../consumer/verification.md`](../consumer/verification.md). `metadata` is `ChatCompletionMetadata`:

| Field | Type | Meaning |
|---|---|---|
| `provider_id` | string | Provider that served the request |
| `provider_attested` | bool | Attestation passed |
| `provider_trust_level` | string | Trust tier from attestation |
| `provider_encrypted` | bool | Coordinator→provider payload was end-to-end encrypted |
| `provider_chip`, `provider_machine_model`, `provider_secure_enclave`, `provider_mda_verified` | string / bool | Hardware facts from attestation |
| `attestation_se_public_key` | string | Secure Enclave public key used to sign |
| `job_id` | string | Coordinator job id (also `X-Inference-Job-ID`) |
| `timing` | `RequestTimingDetails` | Only with metadata details; the same fields as `X-Timing` |
| `location` | `ProviderApproxLocation` | Only with metadata details: `region`, `region_code`, `country`, `country_code`, `timezone` |

### Responses API

Bodies are lowered into the chat pipeline (`coordinator/promptcontract/endpoint_lower_responses.go`) and the provider's chat output is raised back into `ResponsesResponse` (`coordinator/api/types/types.go`): `id` (`resp_…`), `object`, `created_at`, `status`, `error`, `incomplete_details.reason`, `instructions`, `max_output_tokens`, `model`, `output[]`, `parallel_tool_calls`, `temperature`, `tool_choice`, `tools`, `top_p`, `metadata`, `usage` (`input_tokens`, `input_tokens_details.cached_tokens`, `output_tokens`, `output_tokens_details.reasoning_tokens`), `se_signature`, `response_hash`. Streams use `event:`-typed frames from `response.created` / `response.in_progress` through the item deltas to `response.completed` (or `response.incomplete` when truncated) and carry **no** `data: [DONE]` (`newResponsesStreamEmitter`, `coordinator/api/responses_stream.go`).

### Completions and Messages

`/v1/completions` and `/v1/messages` are lowered to the chat contract (`coordinator/promptcontract/endpoint_lower.go`, `coordinator/promptcontract/endpoint_lower_messages.go`); responses are re-shaped by `coordinator/api/generic_endpoint_response.go` and streams by `coordinator/api/generic_endpoint_stream.go`, which terminates with `data: [DONE]`.

## SSE framing

Built by `handleStreamingResponseWithFirstChunk` (`coordinator/api/consumer.go`), `coordinator/api/sse_response.go`, and `coordinator/api/chat_metadata_stream.go`; ordering guarantees come from the dispatch state machine in `coordinator/api/dispatch.go`.

1. **Deferred commit.** No status line, headers, or bytes are written until the first *content* chunk arrives from a provider (`commitFirstContent`). Until then the coordinator can still fail over to another provider or return a JSON error with a real status code (`preContentTerminal`, `coordinator/api/dispatch_terminal_write.go`). Clients see a delayed 200, never a 200 that turns into an error mid-preamble.
2. **Headers at commit**: `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`, `X-Inference-Job-ID` (`writeSSEResponseHeader`), plus `X-Timing` and the `X-Provider-*` headers.
3. **Each provider chunk** is forwarded as one `data: <json>\n\n` event after `normalizeSSEChunk` (`coordinator/api/consumer.go`); the coordinator does not re-tokenise or coalesce content. Chunks that arrive before commit are buffered (`chunkBufferSize` = 256).
4. **Usage and finish chunks are held.** A chunk that only carries `usage` (`parseUsageOnlyStreamChunk`) is held so the reasoning-token breakdown can be spliced in; the chunk carrying the terminal `finish_reason` (`parseFinishStreamChunk`) is held so it can be corrected to `length` against the authoritative token counts. Both are written after every content delta. `se_signature`, `response_hash` and opt-in `metadata` ride on the held usage chunk; when there is none they are emitted as one additional fully-shaped `chat.completion.chunk` (`newChatCompletionExtrasEvent`) immediately before termination. Every chunk's `model` is rewritten to the alias you sent (`rewriteChunkModel`).
5. **Termination**: exactly one `data: [DONE]\n\n`, written by the coordinator after every coordinator-appended event. Any `[DONE]` from the provider is stripped first (`stripSSEDoneEvents`). Responses streams end with `response.completed` / `response.incomplete` instead.
6. **No keepalives.** The coordinator never writes comment frames or pings; a silent stream means the provider has not produced a token. Before commit the first-content deadline bounds the silence (a miss is answered with 429 + `Retry-After`, see the status table); after commit `inferenceTimeout` bounds it (a terminal `error` event of type `timeout`).
7. **Errors after commit** are one `data: {"error": {...}}` event followed by `data: [DONE]`.
8. **Sealed mode** seals each SSE event individually (see below).

## Limits and validation

| Rule | Value / behaviour | Symbol |
|---|---|---|
| Global request body | 64 MiB ceiling on every request (`maxRequestBodyBytes`, `bodyLimitMiddleware`) | `coordinator/api/server.go` |
| Inference body | 16 MiB (`maxInferenceBodyBytes`) → 413 `invalid_request_error`; sealed bodies are read with the same cap (400 `invalid_request_error` when exceeded) | `parseInferencePrelude` (`coordinator/api/inference_preprocess.go`), `sealedTransport` (`coordinator/api/sender_encryption.go`) |
| Control-plane bodies | 64 KiB (`maxControlPlaneBodyBytes`) for enroll, device token, admin auth | `coordinator/api/server.go` |
| MDM webhook body | 1 MiB (`maxMDMWebhookBodyBytes`) | `HandleMDMWebhook` (`coordinator/api/server.go`) |
| `n` | Must be 1 | `handleChatCompletions` |
| `max_tokens` | `max_completion_tokens` → `max_tokens`; an explicit value is not clamped, a missing one is filled from the [output bound](pricing-model.md#formulas) | `ensureMaxTokensBound` |
| Prompt size at admission | 413 `payload_too_large` when the estimated prompt exceeds what the model's providers can accept | `runInferenceAdmission` (`coordinator/api/inference_admission.go`) |
| Catalog membership | Model resolved but absent from the routable catalog → 404 `model_not_found`, after the balance reservation is released | `handleChatCompletions` |
| Key allow-list | `model` not in the key's `allowed_models` → 403 `model_not_allowed` | `keyModelAllowed` |
| `tool_choice` | `"none"`, `"auto"`, `"required"`, or `{"type": "function", "function": {"name": …}}`; a named function must exist in `tools`; `required` or a named choice with no tools → 400 | `validateToolConstraintPolicy` |
| Tool schemas | Normalised to strict JSON Schema before dispatch; schemas the constraint parser cannot compile → 422 | `NormalizeToolSchemas`, `validateResolvedToolConstraintParser` |
| Vision | Image parts require a vision-capable model, otherwise 400; a vision model with no vision-capable provider online → 503 `model_unavailable` | `detectMediaRequirement` (`coordinator/api/request_introspection.go`), `visionToolsFailFast` (`coordinator/api/inference_preprocess.go`) |
| Remote images | `http(s)` `image_url` parts are gated before dispatch and fetched by the coordinator; the fetch is billed as media | `gateRemoteMediaPreDispatch`, `resolveRemoteMedia` (`coordinator/api/media_resolve.go`) |
| Inference-enforced `tool_choice` + images | `required` or a named `tool_choice` (modes that need provider-side constraint enforcement) together with image content → 400, `param: tool_choice`. `response_format` is not validated by the coordinator | `handleChatCompletions` |
| Token rate limits | Per-account input and output tokens per minute → 429 with `Retry-After` | `applyTokenRateLimitWithAdmission`, `writeTokenRateLimited` |
| Model shedding | A model currently rejecting → 429 with `Retry-After` from `estimateRetryAfter` | `shedIfModelRejected` |

## Timeouts and constants

| Constant | Value | Where | Effect |
|---|---|---|---|
| `inferenceTimeout` | 600 s | `coordinator/api/consumer.go` | Streaming: maximum silence between chunks (the timer resets on every chunk) → terminal SSE `error` event, type `timeout`. Non-streaming: total wait for the response → 504 `timeout` |
| `defaultFirstContentDeadlineBase` | the compiled default of [`EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS`](configuration.md#routing-admission-and-ttft) | `coordinator/api/consumer.go` | Fallback base of the request-absolute first-content deadline when the variable is unset. Deadline = `CoordinatorFirstContentDeadline(model, promptTokens, base)` = base + 1 ms per estimated prompt token, tightened per model by exact-model overrides (`coordinator/modelpolicy/first_content_deadline.go`, replaceable via `EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES`). Expiry before any content → 429 `rate_limit_exceeded` + `Retry-After` (the pre-content 504 is reclassified by `classifyExhaustedStatus`) |
| `preambleContentTimeout` | 90 s | `coordinator/api/consumer.go` | Cap from a provider's first preamble chunk (role delta / Responses lifecycle event, nothing written to the client yet) to its first content chunk; a provider that stalls after preamble fails over instead of holding the request for `inferenceTimeout`. Never exceeds the remaining first-content budget |
| `maxDispatchAttempts` | 64 | `coordinator/api/consumer.go` | Upper bound on provider attempts per request |
| `chunkBufferSize` | 256 | `coordinator/api/consumer.go` | Pre-commit chunk buffer per attempt |
| `apiKeyCacheTTL` | 60 s | `coordinator/api/server.go` | API-key lookups are cached; a revocation takes effect within one TTL |
| `coordinatorDrainRetryAfter` / `DefaultDrainGrace` | 3 s / 600 s | `coordinator/api/drain.go` | `Retry-After` on the drain 429; default drain window |
| `DeviceCodeExpiry` / `DeviceCodePollInterval` | see [Device-code flow](#device-code-flow-3) | `coordinator/api/device_auth.go` | Device-code lifetime and poll interval |
| `maxLogReportBodySize` | 10 MB | `coordinator/api/log_report_handlers.go` | Provider log upload cap |
| `degradedRouteEWMAThresholdMs` / `maxDistressRetryAfter` | 1000 ms / 60 s | `coordinator/api/consumer.go` | Input threshold and cap for `estimateRetryAfter` |
| `DefaultRetryAfter` / `maxRetryAfter` | 1 s / 60 s | `coordinator/ratelimit/ratelimit.go` | Clamp for limiter `Retry-After` |
| `exactCacheStatusCacheTTL` | 1 s | `coordinator/api/exact_cache_status.go` | `/v1/cache/status` cache |

## Version gating

Three distinct version values govern providers:

- `LatestProviderVersion = "0.8.16"` (`coordinator/api/server.go`) is the newest provider build the coordinator knows about. `handleVersion` (`/api/version`) and `/v1/me/summary` report the highest active release in the store and fall back to this constant when none is registered.
- `minProviderVersionForDesiredModels = "0.5.17"` (`coordinator/api/server.go`) is a **feature floor for the WebSocket `desired_models` message**: only Swift-runtime providers at or above it receive the message (`providerSupportsDesiredModels`, `fanOutDesiredModels` in `coordinator/api/model_alias_handlers.go`), because older decoders disconnect on unknown message types. It does not affect HTTP routes.
- `EIGENINFERENCE_MIN_PROVIDER_VERSION` (`MinProviderVersion`, `coordinator/api/server_config.go`; `SetMinProviderVersion`) is the **routing floor**: a provider that registers or re-attests below it stays connected but is marked not runtime-verified and excluded from routing (`coordinator/api/provider.go`, registration and `applyChallengeMinVersionPolicy`), and its log uploads get 426 `upgrade_required`.
- **Feature floors** exclude too-old providers from serving specific request traits rather than the whole model: tools require providers ≥ `0.6.3` (`capabilityVersionFloors`, `coordinator/registry/request_traits.go`); vision requests strip repetition-penalty fields for providers below `penaltySafeProviderVersion` = `0.6.7` (`coordinator/api/consumer.go`); reconnect attestation needs `minProviderVersionForReconnectAttestation` = `0.8.15` (`coordinator/api/provider.go`); servability gating uses `servabilityActivationFloorMinVersion` = `0.8.0` and `servabilityPerModelFloorMinVersion` = `0.8.16` (`coordinator/registry/servability.go`); private slot grants need `privateSlotGrantsMinVersion` = `0.7.5` (`coordinator/registry/pooled_admission.go`). When no provider clears the floor for a request, the client sees 503 `model_unavailable` (or 400 `param: tool_choice` when the fleet serves the model but no provider advertises the tool-constraint protocol).

A consumer never sees a version error directly; an under-served model surfaces as 503 `model_unavailable`.

## Sealed transport wire shape

Sealed mode hides request and response bodies from TLS-terminating intermediaries in front of the coordinator. It is opt-in per request and implemented in `coordinator/api/sender_encryption.go` (`handleEncryptionKey`, `sealedTransport`, `sealingResponseWriter`). The cryptographic construction and threat model are in [`../architecture/security/encryption.md`](../architecture/security/encryption.md); this section is only the wire contract.

1. `GET /v1/encryption-key` (no auth) returns `{ "kid": "…", "public_key": "<base64 32-byte X25519>", "algorithm": "x25519-nacl-box" }`.
2. Send the inference request with `Content-Type: application/eigeninference-sealed+json` and body

   ```json
   { "kid": "<kid from step 1>", "ephemeral_public_key": "<base64 32-byte X25519>", "ciphertext": "<base64: 24-byte nonce || NaCl box>" }
   ```

   `ciphertext` seals the ordinary JSON request body to the coordinator key with your ephemeral key. `kid` is optional but, when present, must match → otherwise 400 `kid_mismatch`; a malformed field → 400 `invalid_sealed_envelope`; authentication failure → 400 `decryption_failed`; sealing not configured → 503 `encryption_unavailable`. The decrypted body is then handled exactly like a plaintext request.
3. Responses carry `X-Eigen-Sealed: true` and `X-Eigen-Sealed-Kid: <kid>`. A non-streaming response has `Content-Type: application/eigeninference-sealed+json` and body `{ "kid": "…", "ciphertext": "…" }` whose plaintext is the normal JSON response. A streaming response keeps `Content-Type: text/event-stream`; every complete SSE event (split at `\n\n`, including the `data: [DONE]` frame) is sealed as a whole and re-emitted as `data: <base64 nonce || box>\n\n`, so the client decrypts each frame to recover the original event text.
4. Errors produced before the sealed layer runs (401, 429 including drain) are plain JSON.

## Device-code and API key shapes

### API key shapes

`APIKeyResponse` (`coordinator/api/types/types.go`): `id` (`key_<hex>`, `GenerateKeyID`), `name`, `label`, `disabled`, `limit_usd`, `limit_reset`, `usage_usd`, `remaining_usd`, `rpm_limit`, `itpm_limit`, `otpm_limit`, `allowed_models`, `self_route_only`, `expires_at`, `created_at`, `last_used_at`. The secret is `KeyPrefix` (`sk-db-`) + 64 hex characters (`GenerateRawKey`, `coordinator/store/apikey.go`), is returned only by create and rotate, and is stored only as its SHA-256 hash (`hashKey`, `coordinator/store/postgres.go`). `POST /v1/keys` and `PATCH /v1/keys/{id}` accept `name`, `limit_usd`, `limit_reset`, `rpm_limit`, `itpm_limit`, `otpm_limit`, `allowed_models`, `expires_at`, `self_route_only`; PATCH also accepts `disabled` (`coordinator/api/apikey_handlers.go`).

### Device code shapes

See the [Device-code flow](#device-code-flow-3) table for the three bodies. `verification_uri` is `<console>/link` when `EIGENINFERENCE_CONSOLE_URL` is set, else `<scheme>://<request host>/link` (`handleDeviceCode`).

## Code map

| Concern | Files |
|---|---|
| Route registration, middleware, request-id, CORS, admin/version constants | `coordinator/api/server.go`, `coordinator/api/server_config.go` |
| Inference pipeline | `coordinator/api/consumer.go`, `coordinator/api/inference_preprocess.go`, `coordinator/api/inference_admission.go`, `coordinator/api/request_introspection.go`, `coordinator/api/reasoning_request_policy.go`, `coordinator/api/dispatch.go`, `coordinator/api/dispatch_terminal_write.go`, `coordinator/api/inference_failure_class.go` |
| Endpoint lowering (Responses, Completions, Messages) | `coordinator/promptcontract/endpoint_lower.go`, `coordinator/promptcontract/endpoint_lower_responses.go`, `coordinator/promptcontract/endpoint_lower_messages.go`, `coordinator/api/generic_endpoint_response.go`, `coordinator/api/generic_endpoint_stream.go`, `coordinator/api/responses_stream.go` |
| SSE, timing and provider metadata | `coordinator/api/sse_response.go`, `coordinator/api/chat_metadata_stream.go`, `coordinator/api/response_metadata.go`, `coordinator/api/profiler_dispatch.go` |
| Tools, media, constraints | `coordinator/api/toolschema.go`, `coordinator/api/tool_constraints.go`, `coordinator/api/media_resolve.go` |
| Sealed transport | `coordinator/api/sender_encryption.go` |
| Models and catalog | `coordinator/api/models_endpoints.go`, `coordinator/api/concrete_model_entries.go`, `coordinator/api/openrouter_endpoint.go`, `coordinator/api/model_registry_handlers.go`, `coordinator/api/model_alias_handlers.go`, `coordinator/api/openrouter_alias_handlers.go`, `coordinator/api/capacity.go`, `coordinator/api/exact_cache_status.go` |
| Keys, device code, accounts | `coordinator/api/apikey_handlers.go`, `coordinator/store/apikey.go`, `coordinator/api/device_auth.go`, `coordinator/api/me_handlers.go` |
| Billing, Stripe, referral, invites | `coordinator/api/billing_handlers.go`, `coordinator/api/stripe_payouts.go`, `coordinator/api/stripe_withdraw.go`, `coordinator/api/stripe_payouts_webhooks.go`, `coordinator/api/invite_handlers.go`, `coordinator/api/base_rewards_handlers.go` |
| Stats | `coordinator/api/stats.go`, `coordinator/api/cache_refresher.go`, `coordinator/api/network_totals.go`, `coordinator/api/leaderboard.go`, `coordinator/api/network_series.go` |
| Release, enrollment, provider WS, log reports | `coordinator/api/release_handlers.go`, `coordinator/api/enroll.go`, `coordinator/api/provider.go`, `coordinator/api/log_report_handlers.go` |
| Drain, admin telemetry, profiler, state export, telemetry stub | `coordinator/api/drain.go`, `coordinator/api/admin_telemetry.go`, `coordinator/api/admin_utilization.go`, `coordinator/api/profiler_admin.go`, `coordinator/api/admin_state_export.go`, `coordinator/api/telemetry_handlers.go` |
| Shared types and helpers | `coordinator/api/types/types.go`, `coordinator/api/httputil.go`, `coordinator/ratelimit/ratelimit.go`, `coordinator/modelpolicy/first_content_deadline.go` |

### International withdrawal confirmation

For `payout_rail=global`, submit `{amount_usd, method:"standard", quote_id}` to the existing withdrawal endpoint. A confirmed quote returns its original withdrawal on retry. The response/history include `payout_rail`, `destination_amount`, `payout_currency` and `refunded`. Global states are `pending`, `processing`, `posted`, `failed`, `canceled` and `returned`; `posted` does not establish bank receipt. Quotes expire before first confirmation; an already-submitted withdrawal can still be checked with the same ID (`coordinator/api/global_payouts_withdraw.go`, `maybeGlobalWithdraw`).
