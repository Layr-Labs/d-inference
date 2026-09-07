package api

import (
	_ "embed"
	"io"
	"net/http"
	"strings"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// routes mounts all HTTP and WebSocket handlers.
func (s *Server) routes() {
	// Install script — served from the generated embed with the coordinator URL
	// substituted per environment.
	s.mux.HandleFunc("GET /install.sh", func(w http.ResponseWriter, r *http.Request) {
		rendered := strings.ReplaceAll(string(installScript), installScriptPlaceholder, s.resolveBaseURL(r))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		io.WriteString(w, rendered)
	})

	// Health check — no auth required.
	s.mux.HandleFunc("GET /health", s.operations.HandleHealth)
	// Aggregate exact-cache rollout health. Contains no provider/model/account
	// identity and is safe for canary automation.
	s.mux.HandleFunc("GET /v1/cache/status", s.inference.HandleExactCacheStatus)

	// Readiness probe — no auth required. Reports graceful-drain state so load
	// balancers and the deploy script treat a draining coordinator as not-ready
	// (503) and can wait for inflight==0 before restart. See drain.go (DAR-327).
	s.mux.HandleFunc("GET /readyz", s.operations.HandleReadyz)

	// Provider WebSocket — no API key auth (providers authenticate differently).
	s.mux.HandleFunc("GET /ws/provider", s.providers.HandleProviderWS)

	// Key management — requires interactive Privy session (API keys rejected
	// to prevent self-replication from a leaked key).
	s.mux.HandleFunc("POST /v1/auth/keys", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.keys.HandleCreateKey)))
	s.mux.HandleFunc("DELETE /v1/auth/keys", s.access.RequirePrivyAuth(s.keys.HandleRevokeKey))

	// Multi-key management (OpenRouter-shaped CRUD). One account may own many
	// named, individually-limited keys. Management requires an interactive
	// Privy session so a leaked inference key can't enumerate or mint keys.
	s.mux.HandleFunc("GET /v1/keys", s.access.RequirePrivyAuth(s.keys.HandleListAPIKeys))
	s.mux.HandleFunc("POST /v1/keys", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.keys.HandleCreateAPIKey)))
	s.mux.HandleFunc("GET /v1/keys/{id}", s.access.RequirePrivyAuth(s.keys.HandleGetAPIKey))
	s.mux.HandleFunc("PATCH /v1/keys/{id}", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.keys.HandleUpdateAPIKey)))
	s.mux.HandleFunc("DELETE /v1/keys/{id}", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.keys.HandleDeleteAPIKey)))
	s.mux.HandleFunc("POST /v1/keys/{id}/rotate", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.keys.HandleRotateAPIKey)))
	// Metadata for the calling key (OpenRouter parity) — API key auth.
	s.mux.HandleFunc("GET /v1/key", s.access.RequireAuth(s.keys.HandleGetCallingKey))

	// Consumer endpoints — API key auth required + per-account rate limit.
	// Inference endpoints are wrapped in sealedTransport so senders can opt into
	// sender→coordinator encryption by setting Content-Type:
	// application/eigeninference-sealed+json (see sender_encryption.go).
	// rateLimitConsumer is chained inside requireAuth so the accountID is in
	// context. Read-only endpoints (GET /v1/models) skip rate limiting since
	// they're cheap and clients poll them.
	// drainGate is the OUTERMOST wrapper: while the coordinator is draining for a
	// restart/upgrade it rejects NEW inference requests with 429+Retry-After
	// before any auth/decrypt work, and otherwise counts the request as in-flight
	// so /readyz can report when it's safe to shut down (DAR-327 Phase 1).
	//
	// IMPORTANT: ANY future provider-routed inference endpoint (e.g.
	// /v1/audio/transcriptions, /v1/images/generations, /v1/embeddings) MUST also
	// be wrapped in s.drainGate(...). An ungated route won't 429 during drain and,
	// because it isn't counted in httpInflight, won't be seen by WaitForInflightZero
	// — so a graceful shutdown could cut it off mid-flight. Add new dispatch routes
	// here, gated, alongside the four below.
	s.mux.HandleFunc("POST /v1/chat/completions", s.operations.DrainGate(s.access.RequireAuth(s.access.RateLimitConsumer(s.inference.SealedTransport(s.inference.HandleChatCompletions)))))
	s.mux.HandleFunc("POST /v1/responses", s.operations.DrainGate(s.access.RequireAuth(s.access.RateLimitConsumer(s.inference.SealedTransport(s.inference.HandleChatCompletions))))) // Responses API — same handler, auto-detects input vs messages
	s.mux.HandleFunc("POST /v1/completions", s.operations.DrainGate(s.access.RequireAuth(s.access.RateLimitConsumer(s.inference.SealedTransport(s.inference.HandleCompletions)))))
	s.mux.HandleFunc("POST /v1/messages", s.operations.DrainGate(s.access.RequireAuth(s.access.RateLimitConsumer(s.inference.SealedTransport(s.inference.HandleAnthropicMessages)))))
	s.mux.HandleFunc("GET /v1/models", s.access.RequireAuth(s.catalog.HandleListModels))
	// Dedicated OpenRouter provider feed — pure OpenRouter schema, no Darkbloom metadata.
	s.mux.HandleFunc("GET /v1/models/openrouter", s.access.RequireAuth(s.catalog.HandleListModelsOpenRouter))
	// OpenAI "retrieve model" — {id...} matches slashed HuggingFace-style ids;
	// the literal /v1/models/openrouter and /v1/models/capacity routes win.
	s.mux.HandleFunc("GET /v1/models/{id...}", s.access.RequireAuth(s.catalog.HandleGetModel))

	// Sender encryption — public key publication for sender→coordinator E2E.
	// Optional: senders may use this to encrypt request bodies; plaintext path
	// continues to work unchanged when this header isn't set.
	s.mux.HandleFunc("GET /v1/encryption-key", s.inference.HandleEncryptionKey)

	// MDM webhook — MicroMDM sends command responses here.
	s.mux.HandleFunc("POST /v1/mdm/webhook", s.trust.HandleMDMWebhook)

	// Payment endpoints — API key auth required.
	s.mux.HandleFunc("GET /v1/payments/balance", s.access.RequireAuth(s.billingHTTP.HandleBalance))
	s.mux.HandleFunc("GET /v1/payments/usage", s.access.RequireAuth(s.billingHTTP.HandleUsage))

	s.mux.HandleFunc("GET /v1/provider/account-earnings", s.access.RequireAuth(s.billingHTTP.HandleAccountEarnings))

	// Account-scoped provider dashboard.
	s.mux.HandleFunc("GET /v1/me/providers", s.access.RequirePrivyAuth(s.accounts.HandleMyProviders))
	s.mux.HandleFunc("GET /v1/me/token-promotions", s.access.RequirePrivyAuth(s.inference.HandleMyModelTokenPromotions))
	s.mux.HandleFunc("POST /v1/me/token-promotions/claim", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.inference.HandleMyModelTokenPromotions)))
	s.mux.HandleFunc("GET /v1/admin/token-promotions", s.inference.HandleAdminModelTokenPromotions)
	s.mux.HandleFunc("PUT /v1/admin/token-promotions", s.inference.HandleAdminModelTokenPromotions)
	s.mux.HandleFunc("GET /v1/me/summary", s.access.RequirePrivyAuth(s.accounts.HandleMySummary))
	// Alias-aware owned live-model ids for the console's self-route key picker.
	s.mux.HandleFunc("GET /v1/me/self-route-models", s.access.RequirePrivyAuth(s.accounts.HandleMySelfRouteModels))
	// Ownership-checked hard delete of a retired/offline machine's record(s).
	s.mux.HandleFunc("DELETE /v1/me/providers/{id}", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.accounts.HandleDeleteMyProvider)))

	// MDM enrollment — generates the per-device .mobileconfig (SCEP + MDM).
	// No auth needed — trust comes from MDM SecurityInfo verification after
	// enrollment, not from possession of the profile.
	s.mux.HandleFunc("POST /v1/enroll", s.trust.HandleEnroll)

	// Attestation status — public, no auth needed. Raw device identity and MDA
	// certificates remain coordinator-private because the leaf embeds serial/UDID.
	s.mux.HandleFunc("GET /v1/providers/attestation", s.trust.HandleProviderAttestation)

	// Capacity snapshot — no auth needed. Upstream routers poll this.
	s.mux.HandleFunc("GET /v1/models/capacity", s.catalog.HandleModelsCapacity)

	// Platform stats — no auth needed. Frontend dashboard uses this.
	s.mux.HandleFunc("GET /v1/stats", s.reporting.HandleStats)

	// Public leaderboard + network totals — no auth, pseudonymized,
	// 5-min/1-min cache.
	s.mux.HandleFunc("GET /v1/leaderboard", s.reporting.HandleLeaderboard)
	s.mux.HandleFunc("GET /v1/network/totals", s.reporting.HandleNetworkTotals)
	s.mux.HandleFunc("GET /v1/network/series", s.reporting.HandleNetworkSeries)
	s.mux.HandleFunc("GET /v1/network/model-demand", s.reporting.HandleModelDemand)

	// Provider version check — no auth needed. Providers call this to check for updates.
	s.mux.HandleFunc("GET /api/version", s.releases.HandleVersion)

	// Releases — versioned provider binary distribution.
	s.mux.HandleFunc("POST /v1/releases", s.releases.HandleRegisterRelease)     // scoped release key (GitHub Action)
	s.mux.HandleFunc("GET /v1/releases/latest", s.releases.HandleLatestRelease) // public (install.sh)

	// Device authorization flow — providers link to user accounts.
	s.mux.HandleFunc("POST /v1/device/code", s.device.HandleDeviceCode)   // no auth — provider not yet authenticated
	s.mux.HandleFunc("POST /v1/device/token", s.device.HandleDeviceToken) // no auth — polls with device_code secret
	// Device approve issues a long-lived provider→account linking token —
	// same risk class as /v1/auth/keys, so financial-tier limit applies.
	// Uses requirePrivyAuth to reject API keys (interactive session only).
	s.mux.HandleFunc("POST /v1/device/approve", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.device.HandleDeviceApprove)))

	// --- Billing endpoints (Stripe payments + referrals) ---

	// Stripe — financial limiter on session creation (creates a checkout
	// intent, hits external API). Read-only status endpoint not throttled.
	s.mux.HandleFunc("POST /v1/billing/stripe/create-session", s.access.RequireAuth(s.access.RateLimitFinancial(s.billingHTTP.HandleStripeCreateSession)))
	s.mux.HandleFunc("POST /v1/billing/stripe/webhook", s.billingHTTP.HandleStripeWebhook) // no auth — Stripe signs it
	s.mux.HandleFunc("GET /v1/billing/stripe/session", s.access.RequireAuth(s.billingHTTP.HandleStripeSessionStatus))

	// Wallet balance
	s.mux.HandleFunc("GET /v1/billing/wallet/balance", s.access.RequireAuth(s.billingHTTP.HandleWalletBalance))

	// A single bank withdrawal experience, with separate payout lifecycles.
	s.mux.HandleFunc("POST /v1/billing/stripe/quote", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.payouts.HandleGlobalPayoutQuote)))
	s.mux.HandleFunc("POST /v1/billing/stripe/global/webhook", s.payouts.HandleGlobalPayoutWebhook)
	// Stripe Payouts (Connect Express) — bank/card withdrawals.
	s.mux.HandleFunc("POST /v1/billing/stripe/onboard", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.payouts.HandleStripeOnboard)))
	s.mux.HandleFunc("GET /v1/billing/stripe/status", s.access.RequireAuth(s.payouts.HandleStripeStatus))
	s.mux.HandleFunc("POST /v1/billing/withdraw/stripe", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.payouts.HandleStripeWithdraw)))
	s.mux.HandleFunc("GET /v1/billing/stripe/withdrawals", s.access.RequireAuth(s.payouts.HandleStripeWithdrawals))
	// requirePrivyAuth (not requireAuth): both of these are account-management
	// operations — a leaked inference API key must not be able to detach the
	// user's payout account, nor mint a dashboard session that can point their
	// earnings at a different bank account.
	//
	// The dashboard route additionally carries rateLimitFinancial: every call
	// is a live Stripe POST that mints a credential, so an authenticated
	// session must not be able to loop it and burn the platform's Stripe
	// request capacity. Chained INSIDE requirePrivyAuth because the limiter
	// keys on the account ID the auth middleware puts in the request context.
	s.mux.HandleFunc("POST /v1/billing/stripe/dashboard", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.payouts.HandleStripeDashboardLink)))
	s.mux.HandleFunc("DELETE /v1/billing/stripe/account", s.access.RequirePrivyAuth(s.payouts.HandleStripeUnlink))
	s.mux.HandleFunc("POST /v1/billing/stripe/connect/accounts/webhook", s.payouts.HandleStripeConnectAccountsWebhook)
	s.mux.HandleFunc("POST /v1/billing/stripe/connect/webhook", s.payouts.HandleStripeConnectWebhook) // no auth — Stripe signs it

	// Pricing — GET is public, PUT/DELETE require auth
	s.mux.HandleFunc("GET /v1/pricing", s.billingHTTP.HandleGetPricing)                               // public
	s.mux.HandleFunc("PUT /v1/pricing", s.access.RequireAuth(s.billingHTTP.HandleSetPricing))         // provider sets own prices
	s.mux.HandleFunc("DELETE /v1/pricing", s.access.RequireAuth(s.billingHTTP.HandleDeletePricing))   // revert to default
	s.mux.HandleFunc("PUT /v1/admin/pricing", s.access.RequireAuth(s.billingHTTP.HandleAdminPricing)) // platform sets defaults

	// Admin account management (service-role + per-account platform fee)
	s.mux.HandleFunc("PUT /v1/admin/users/role", s.access.RequireAuth(s.accounts.HandleAdminSetUserRole))
	s.mux.HandleFunc("PUT /v1/admin/users/platform-fee", s.access.RequireAuth(s.accounts.HandleAdminSetUserPlatformFee))

	// Admin model registry (manifest-backed). The legacy supported_models CRUD
	// (bare GET/POST/DELETE /v1/admin/models) was removed; the model_registry is
	// the single source of truth. Use register + the per-model action endpoints.
	s.mux.HandleFunc("POST /v1/admin/models/register", s.catalog.HandleRegisterModel)
	// OpenRouter-only feed aliases clone a standard alias while exposing custom
	// provider id, marketplace slug, and Hugging Face identity.
	s.mux.HandleFunc("GET /v1/admin/models/openrouter-aliases", s.catalog.HandleOpenRouterAliasList)
	s.mux.HandleFunc("POST /v1/admin/models/openrouter-aliases", s.catalog.HandleOpenRouterAliasUpsert)
	s.mux.HandleFunc("DELETE /v1/admin/models/openrouter-aliases/{aliasID}", s.catalog.HandleOpenRouterAliasDelete)
	// Public model aliases (stable names → concrete builds). More-specific
	// patterns take precedence over the POST /v1/admin/models/ subtree below.
	s.mux.HandleFunc("GET /v1/admin/models/aliases", s.catalog.HandleModelAliasList)
	s.mux.HandleFunc("POST /v1/admin/models/aliases", s.catalog.HandleModelAliasUpsert)
	s.mux.HandleFunc("DELETE /v1/admin/models/aliases/{aliasID}", s.catalog.HandleModelAliasDelete)
	s.mux.HandleFunc("POST /v1/admin/models/", s.catalog.HandleAdminModelRegistryAction)
	s.mux.HandleFunc("GET /v1/admin/releases", s.releases.HandleAdminListReleases) // admin key or Privy admin
	s.mux.HandleFunc("POST /v1/admin/app-attest/revoke", s.trust.HandleAdminAppAttestRevoke)
	s.mux.HandleFunc("GET /v1/admin/app-attest/builds", s.access.RequireAuth(s.releases.HandleAdminAppAttestBuilds))
	s.mux.HandleFunc("POST /v1/admin/app-attest/builds", s.access.RequireAuth(s.releases.HandleAdminAppAttestBuilds))
	s.mux.HandleFunc("POST /v1/admin/app-attest/builds/revoke", s.access.RequireAuth(s.releases.HandleAdminAppAttestBuildRevoke))
	s.mux.HandleFunc("DELETE /v1/admin/releases", s.releases.HandleAdminDeleteRelease) // admin key or Privy admin

	// Historical admin state export (DAR-70) — streams the TEE-sealed /data
	// archive used for the completed EigenCloud migration. Always registered, but
	// inert (404) unless EIGENINFERENCE_STATE_EXPORT_ENABLED=true; admin-gated;
	// encrypted to an age recipient by default. Auth + output protection are
	// enforced inside the handler.
	s.mux.HandleFunc("GET /v1/admin/state-export", s.operations.HandleAdminStateExport)

	// Admin CLI auth — Privy email OTP for getting admin tokens without a browser.
	s.mux.HandleFunc("POST /v1/admin/auth/init", s.access.HandleAdminAuthInit)     // no auth (sends OTP)
	s.mux.HandleFunc("POST /v1/admin/auth/verify", s.access.HandleAdminAuthVerify) // no auth (returns token)

	// Public model catalog — providers and install script fetch this
	s.mux.HandleFunc("GET /v1/models/catalog", s.catalog.HandleModelCatalog)
	s.mux.HandleFunc("GET /v1/models/catalog/manifest/", s.catalog.HandleModelCatalogManifest)
	s.mux.HandleFunc("GET /v1/models/catalog/", s.catalog.HandleModelCatalogItem)

	// Runtime manifest — providers and users can inspect accepted runtime hashes.
	s.mux.HandleFunc("GET /v1/runtime/manifest", s.releases.HandleRuntimeManifest)

	// Payment methods info
	s.mux.HandleFunc("GET /v1/billing/methods", s.billingHTTP.HandleBillingMethods) // no auth needed

	// Referral mutations require an interactive session, not a linked API key.
	// The financial limiter runs after authentication; stats/info are read-only.
	s.mux.HandleFunc("POST /v1/referral/register", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.billingHTTP.HandleReferralRegister)))
	s.mux.HandleFunc("POST /v1/referral/apply", s.access.RequirePrivyAuth(s.access.RateLimitFinancial(s.billingHTTP.HandleReferralApply)))
	s.mux.HandleFunc("GET /v1/referral/stats", s.access.RequireAuth(s.billingHTTP.HandleReferralStats))
	s.mux.HandleFunc("GET /v1/referral/info", s.access.RequireAuth(s.billingHTTP.HandleReferralInfo))

	// Invite codes (admin)
	// Invite code creation accepts amount_usd and produces a credit-bearing
	// code; redemption is already financial-tier so the issuance side must
	// match (otherwise an admin-key holder could spam codes anyway, but
	// keeping symmetry).
	s.mux.HandleFunc("POST /v1/admin/invite-codes", s.access.RequireAuth(s.access.RateLimitFinancial(s.accounts.HandleAdminCreateInviteCode)))
	s.mux.HandleFunc("GET /v1/admin/invite-codes", s.access.RequireAuth(s.accounts.HandleAdminListInviteCodes))
	s.mux.HandleFunc("DELETE /v1/admin/invite-codes", s.access.RequireAuth(s.accounts.HandleAdminDeactivateInviteCode))

	// Invite code redemption (user) — credits the redeemer's balance, so
	// it's a financial-tier endpoint.
	s.mux.HandleFunc("POST /v1/invite/redeem", s.access.RequireAuth(s.access.RateLimitFinancial(s.accounts.HandleRedeemInviteCode)))

	// Admin credit & reward
	s.mux.HandleFunc("POST /v1/admin/credit", s.access.RequireAuth(s.billingHTTP.HandleAdminCredit))
	s.mux.HandleFunc("POST /v1/admin/reward", s.access.RequireAuth(s.billingHTTP.HandleAdminReward))

	// Explicit provider log reports
	s.mux.HandleFunc("POST /v1/provider/log-report", s.access.RequireAuth(s.operations.HandleUploadLogReport))
	s.mux.HandleFunc("GET /v1/admin/log-reports/{id}", s.access.RequireAuth(s.operations.HandleGetLogReport))

	// Metrics snapshot (admin only)
	s.mux.HandleFunc("GET /v1/admin/metrics", s.operations.HandleAdminMetrics)
	s.mux.HandleFunc("GET /v1/admin/base-rewards", s.billingHTTP.HandleAdminBaseRewards)

	// Network utilization snapshot (admin only) — handler enforces admin auth
	// internally via requireAdminKey.
	s.mux.HandleFunc("GET /v1/admin/utilization", s.reporting.HandleAdminUtilization)

	// Graceful drain toggle (admin only) — sets the coordinator into drain mode
	// before a restart/upgrade so new inference requests get 429 while in-flight
	// ones finish. Wrapped with requireAuth (the SAME pattern as the other
	// isAdminAuthorized/requireAdminKey endpoints, e.g. invite codes) so a Privy
	// admin JWT is parsed into the request context AND the admin key is accepted
	// as a pseudo-account; handleAdminDrain then authorizes via isAdminAuthorized
	// (admin key OR Privy admin). Registered before the /v1/ catch-all. Note:
	// /readyz stays unauthenticated. See drain.go (DAR-327 Phase 1).
	s.mux.HandleFunc("GET /v1/admin/autopilot", s.access.RequireAuth(s.handleAdminAutopilot))
	s.mux.HandleFunc("GET /v1/admin/autopilot/inventory", s.access.RequireAuth(s.handleAdminAutopilotInventory))
	s.mux.HandleFunc("POST /v1/admin/autopilot", s.access.RequireAuth(s.handleAdminAutopilot))
	s.mux.HandleFunc("POST /v1/admin/drain", s.access.RequireAuth(s.operations.HandleAdminDrain))

	// Routing telemetry (admin-gated; metadata only — no prompt/response content).
	// Browse as JSON or stream a CSV/NDJSON download for offline analysis.
	// See docs/design/routing-telemetry-and-calibration.md §6. Handlers
	// enforce admin auth internally via requireAdminKey.
	s.mux.HandleFunc("GET /v1/admin/routes", s.observation.HandleAdminRoutes)
	s.mux.HandleFunc("GET /v1/admin/routes/export", s.observation.HandleAdminRoutesExport)
	s.mux.HandleFunc("GET /v1/admin/profiles", s.observation.HandleAdminProfiles)
	s.mux.HandleFunc("GET /v1/admin/request-outcomes", s.observation.HandleAdminRequestOutcomes)
	s.mux.HandleFunc("GET /v1/admin/profiles/export", s.observation.HandleAdminProfilesExport)
	s.mux.HandleFunc("GET /v1/admin/snapshots", s.observation.HandleAdminSnapshots)
	s.mux.HandleFunc("GET /v1/admin/snapshots/export", s.observation.HandleAdminSnapshotsExport)
	s.mux.HandleFunc("GET /v1/admin/rejections", s.observation.HandleAdminRejections)
	s.mux.HandleFunc("GET /v1/admin/rejections/export", s.observation.HandleAdminRejectionsExport)

	// Catch-all for unimplemented OpenAI-compatible endpoints.
	// Registered last (old-style pattern) so explicit method+path routes
	// take precedence. Any /v1/* path not handled above gets a structured
	// JSON error instead of the mux default text/plain 404.
	s.mux.HandleFunc("/v1/", httpx.UnimplementedEndpoint)
}
