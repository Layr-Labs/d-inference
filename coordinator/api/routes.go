package api

import (
	"fmt"
	"io"
	"net/http"
	"strings"
)

// routes mounts all HTTP and WebSocket handlers.
func (s *Server) routes() {
	readinessAPI := s.readinessController()
	releaseAPI := s.newReleaseAPI()
	operations := s.newOperations()
	accountHandlers := s.accountController()
	modelCatalog := s.catalogController()
	billingHandlers := s.billingController()
	// Install script — served from the generated embed with the coordinator URL
	// substituted per environment.
	s.mux.HandleFunc("GET /install.sh", func(w http.ResponseWriter, r *http.Request) {
		rendered := strings.ReplaceAll(string(installScript), installScriptPlaceholder, s.resolveBaseURL(r))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		io.WriteString(w, rendered)
	})

	// Health check — no auth required.
	s.mux.HandleFunc("GET /health", s.handleHealth)
	// Aggregate exact-cache rollout health. Contains no provider/model/account
	// identity and is safe for canary automation.
	s.mux.HandleFunc("GET /v1/cache/status", s.handleExactCacheStatus)

	// Readiness probe — no auth required. Reports graceful-drain state so load
	// balancers and the deploy script treat a draining coordinator as not-ready
	// (503) and can wait for inflight==0 before restart. See drain.go (DAR-327).
	s.mux.HandleFunc("GET /readyz", readinessAPI.Ready)

	// Provider WebSocket — no API key auth (providers authenticate differently).
	s.mux.HandleFunc("GET /ws/provider", s.handleProviderWS)

	// Key management — requires interactive Privy session (API keys rejected
	// to prevent self-replication from a leaked key).
	s.mux.HandleFunc("POST /v1/auth/keys", s.requirePrivyAuth(s.rateLimitFinancial(accountHandlers.CreateLegacyKey)))
	s.mux.HandleFunc("DELETE /v1/auth/keys", s.requirePrivyAuth(accountHandlers.RevokeLegacyKey))

	// Multi-key management (OpenRouter-shaped CRUD). One account may own many
	// named, individually-limited keys. Management requires an interactive
	// Privy session so a leaked inference key can't enumerate or mint keys.
	s.mux.HandleFunc("GET /v1/keys", s.requirePrivyAuth(accountHandlers.ListKeys))
	s.mux.HandleFunc("POST /v1/keys", s.requirePrivyAuth(s.rateLimitFinancial(accountHandlers.CreateKey)))
	s.mux.HandleFunc("GET /v1/keys/{id}", s.requirePrivyAuth(accountHandlers.GetKey))
	s.mux.HandleFunc("PATCH /v1/keys/{id}", s.requirePrivyAuth(s.rateLimitFinancial(accountHandlers.UpdateKey)))
	s.mux.HandleFunc("DELETE /v1/keys/{id}", s.requirePrivyAuth(s.rateLimitFinancial(accountHandlers.DeleteKey)))
	s.mux.HandleFunc("POST /v1/keys/{id}/rotate", s.requirePrivyAuth(s.rateLimitFinancial(accountHandlers.RotateKey)))
	// Metadata for the calling key (OpenRouter parity) — API key auth.
	s.mux.HandleFunc("GET /v1/key", s.requireAuth(accountHandlers.GetCallingKey))

	// Consumer endpoints — API key auth required + per-account rate limit.
	// Inference endpoints are wrapped in sealedTransport so senders can opt into
	// sender→coordinator encryption by setting Content-Type:
	// application/eigeninference-sealed+json (see sender_encryption.go).
	// rateLimitConsumer is chained inside requireAuth so the accountID is in
	// context. Read-only endpoints (GET /v1/models) skip rate limiting since
	// they're cheap and clients poll them.
	// readinessAPI.Gate is the OUTERMOST wrapper: while the coordinator is draining for a
	// restart/upgrade it rejects NEW inference requests with 429+Retry-After
	// before any auth/decrypt work, and otherwise counts the request as in-flight
	// so /readyz can report when it's safe to shut down (DAR-327 Phase 1).
	//
	// IMPORTANT: ANY future provider-routed inference endpoint (e.g.
	// /v1/audio/transcriptions, /v1/images/generations, /v1/embeddings) MUST also
	// be wrapped in readinessAPI.Gate(...). An ungated route won't 429 during drain and,
	// because it isn't counted by readiness, won't be seen by WaitForInflightZero
	// — so a graceful shutdown could cut it off mid-flight. Add new dispatch routes
	// here, gated, alongside the four below.
	s.mux.HandleFunc("POST /v1/chat/completions", readinessAPI.Gate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions)))))
	s.mux.HandleFunc("POST /v1/responses", readinessAPI.Gate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions))))) // Responses API — same handler, auto-detects input vs messages
	s.mux.HandleFunc("POST /v1/completions", readinessAPI.Gate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleCompletions)))))
	s.mux.HandleFunc("POST /v1/messages", readinessAPI.Gate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleAnthropicMessages)))))
	s.mux.HandleFunc("GET /v1/models", s.requireAuth(modelCatalog.ListModels))
	// Dedicated OpenRouter provider feed — pure OpenRouter schema, no Darkbloom metadata.
	s.mux.HandleFunc("GET /v1/models/openrouter", s.requireAuth(modelCatalog.ListOpenRouterModels))
	// OpenAI "retrieve model" — {id...} matches slashed HuggingFace-style ids;
	// the literal /v1/models/openrouter and /v1/models/capacity routes win.
	s.mux.HandleFunc("GET /v1/models/{id...}", s.requireAuth(modelCatalog.GetModel))

	// Sender encryption — public key publication for sender→coordinator E2E.
	// Optional: senders may use this to encrypt request bodies; plaintext path
	// continues to work unchanged when this header isn't set.
	s.mux.HandleFunc("GET /v1/encryption-key", s.handleEncryptionKey)

	// MDM webhook — MicroMDM sends command responses here.
	s.mux.HandleFunc("POST /v1/mdm/webhook", s.HandleMDMWebhook)

	// Payment endpoints — API key auth required.
	s.mux.HandleFunc("GET /v1/payments/balance", s.requireAuth(s.handleBalance))
	s.mux.HandleFunc("GET /v1/payments/usage", s.requireAuth(s.handleUsage))

	// Provider earnings — no API key auth (providers identify by provider address).
	s.mux.HandleFunc("GET /v1/provider/earnings", s.handleProviderEarnings)

	s.mux.HandleFunc("GET /v1/provider/account-earnings", s.requireAuth(billingHandlers.AccountEarnings))

	// Account-scoped provider dashboard.
	s.mux.HandleFunc("GET /v1/me/providers", s.requirePrivyAuth(s.accountFleet.Providers))
	s.mux.HandleFunc("GET /v1/me/summary", s.requirePrivyAuth(s.accountFleet.Summary))
	// Alias-aware owned live-model ids for the console's self-route key picker.
	s.mux.HandleFunc("GET /v1/me/self-route-models", s.requirePrivyAuth(s.handleMySelfRouteModels))
	// Ownership-checked hard delete of a retired/offline machine's record(s).
	s.mux.HandleFunc("DELETE /v1/me/providers/{id}", s.requirePrivyAuth(s.rateLimitFinancial(s.accountFleet.DeleteProvider)))

	// MDM enrollment — generates the per-device .mobileconfig (SCEP + MDM).
	// No auth needed — trust comes from MDM SecurityInfo verification after
	// enrollment, not from possession of the profile.
	s.mux.HandleFunc("POST /v1/enroll", s.handleEnroll)

	// Attestation status — public, no auth needed. Raw device identity and MDA
	// certificates remain coordinator-private because the leaf embeds serial/UDID.
	s.mux.HandleFunc("GET /v1/providers/attestation", s.handleProviderAttestation)

	// Capacity snapshot — no auth needed. Upstream routers poll this.
	s.mux.HandleFunc("GET /v1/models/capacity", s.handleModelsCapacity)

	// Platform stats — no auth needed. Frontend dashboard uses this.
	s.mux.HandleFunc("GET /v1/stats", s.networkViews.Stats)

	// Public leaderboard + network totals — no auth, pseudonymized,
	// five-minute caches.
	s.mux.HandleFunc("GET /v1/leaderboard", s.networkViews.Leaderboard)
	s.mux.HandleFunc("GET /v1/network/totals", s.networkViews.Totals)
	s.mux.HandleFunc("GET /v1/network/series", s.networkViews.Series)

	// Provider version check — no auth needed. Providers call this to check for updates.
	s.mux.HandleFunc("GET /api/version", s.handleVersion)

	// Releases — versioned provider binary distribution.
	s.mux.HandleFunc("POST /v1/releases", releaseAPI.Register)     // scoped release key (GitHub Action)
	s.mux.HandleFunc("GET /v1/releases/latest", releaseAPI.Latest) // public (install.sh)

	// Device authorization flow — providers link to user accounts.
	s.mux.HandleFunc("POST /v1/device/code", accountHandlers.DeviceCode)   // no auth — provider not yet authenticated
	s.mux.HandleFunc("POST /v1/device/token", accountHandlers.DeviceToken) // no auth — polls with device_code secret
	// Device approve issues a long-lived provider→account linking token —
	// same risk class as /v1/auth/keys, so financial-tier limit applies.
	// Uses requirePrivyAuth to reject API keys (interactive session only).
	s.mux.HandleFunc("POST /v1/device/approve", s.requirePrivyAuth(s.rateLimitFinancial(accountHandlers.ApproveDevice)))

	// --- Billing endpoints (Stripe payments + referrals) ---

	// Stripe — financial limiter on session creation (creates a checkout
	// intent, hits external API). Read-only status endpoint not throttled.
	s.mux.HandleFunc("POST /v1/billing/stripe/create-session", s.requireAuth(s.rateLimitFinancial(billingHandlers.StripeCreateSession)))
	s.mux.HandleFunc("POST /v1/billing/stripe/webhook", billingHandlers.StripeWebhook) // no auth — Stripe signs it
	s.mux.HandleFunc("GET /v1/billing/stripe/session", s.requireAuth(billingHandlers.StripeSessionStatus))

	// Wallet balance
	s.mux.HandleFunc("GET /v1/billing/wallet/balance", s.requireAuth(billingHandlers.WalletBalance))

	// A single bank withdrawal experience, with separate payout lifecycles.
	s.mux.HandleFunc("POST /v1/billing/stripe/quote", s.requirePrivyAuth(s.rateLimitFinancial(billingHandlers.GlobalPayoutQuote)))
	s.mux.HandleFunc("POST /v1/billing/stripe/global/webhook", billingHandlers.GlobalPayoutWebhook)
	// Stripe Payouts (Connect Express) — bank/card withdrawals.
	s.mux.HandleFunc("POST /v1/billing/stripe/onboard", s.requirePrivyAuth(s.rateLimitFinancial(billingHandlers.StripeOnboard)))
	s.mux.HandleFunc("GET /v1/billing/stripe/status", s.requireAuth(billingHandlers.StripeStatus))
	s.mux.HandleFunc("POST /v1/billing/withdraw/stripe", s.requirePrivyAuth(s.rateLimitFinancial(billingHandlers.StripeWithdraw)))
	s.mux.HandleFunc("GET /v1/billing/stripe/withdrawals", s.requireAuth(billingHandlers.StripeWithdrawals))
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
	s.mux.HandleFunc("POST /v1/billing/stripe/dashboard", s.requirePrivyAuth(s.rateLimitFinancial(billingHandlers.StripeDashboardLink)))
	s.mux.HandleFunc("DELETE /v1/billing/stripe/account", s.requirePrivyAuth(billingHandlers.StripeUnlink))
	s.mux.HandleFunc("POST /v1/billing/stripe/connect/webhook", billingHandlers.StripeConnectWebhook) // no auth — Stripe signs it

	// Pricing — GET is public, PUT/DELETE require auth
	s.mux.HandleFunc("GET /v1/pricing", billingHandlers.GetPricing)                        // public
	s.mux.HandleFunc("PUT /v1/pricing", s.requireAuth(billingHandlers.SetPricing))         // provider sets own prices
	s.mux.HandleFunc("DELETE /v1/pricing", s.requireAuth(billingHandlers.DeletePricing))   // revert to default
	s.mux.HandleFunc("PUT /v1/admin/pricing", s.requireAuth(billingHandlers.AdminPricing)) // platform sets defaults

	// Admin account management (service-role + per-account platform fee)
	s.mux.HandleFunc("PUT /v1/admin/users/role", s.requireAuth(billingHandlers.AdminSetUserRole))
	s.mux.HandleFunc("PUT /v1/admin/users/platform-fee", s.requireAuth(billingHandlers.AdminSetUserPlatformFee))

	// Admin model registry (manifest-backed). The legacy supported_models CRUD
	// (bare GET/POST/DELETE /v1/admin/models) was removed; the model_registry is
	// the single source of truth. Use register + the per-model action endpoints.
	s.mux.HandleFunc("POST /v1/admin/models/register", modelCatalog.RegisterModel)
	// OpenRouter-only feed aliases clone a standard alias while exposing custom
	// provider id, marketplace slug, and Hugging Face identity.
	s.mux.HandleFunc("GET /v1/admin/models/openrouter-aliases", modelCatalog.ListOpenRouterAliases)
	s.mux.HandleFunc("POST /v1/admin/models/openrouter-aliases", modelCatalog.UpsertOpenRouterAlias)
	s.mux.HandleFunc("DELETE /v1/admin/models/openrouter-aliases/{aliasID}", modelCatalog.DeleteOpenRouterAlias)
	// Public model aliases (stable names → concrete builds). More-specific
	// patterns take precedence over the POST /v1/admin/models/ subtree below.
	s.mux.HandleFunc("GET /v1/admin/models/aliases", modelCatalog.ListAliases)
	s.mux.HandleFunc("POST /v1/admin/models/aliases", modelCatalog.UpsertAlias)
	s.mux.HandleFunc("DELETE /v1/admin/models/aliases/{aliasID}", modelCatalog.DeleteAlias)
	s.mux.HandleFunc("POST /v1/admin/models/", modelCatalog.AdminModelAction)
	s.mux.HandleFunc("GET /v1/admin/releases", releaseAPI.List)      // admin key or Privy admin
	s.mux.HandleFunc("DELETE /v1/admin/releases", releaseAPI.Delete) // admin key or Privy admin

	// Historical admin state export (DAR-70) — streams the TEE-sealed /data
	// archive used for the completed EigenCloud migration. Always registered, but
	// inert (404) unless EIGENINFERENCE_STATE_EXPORT_ENABLED=true; admin-gated;
	// encrypted to an age recipient by default. Auth + output protection are
	// enforced inside the handler.
	s.mux.HandleFunc("GET /v1/admin/state-export", s.newStateArchiveAPI().Download)

	// Admin CLI auth — Privy email OTP for getting admin tokens without a browser.
	s.mux.HandleFunc("POST /v1/admin/auth/init", s.handleAdminAuthInit)     // no auth (sends OTP)
	s.mux.HandleFunc("POST /v1/admin/auth/verify", s.handleAdminAuthVerify) // no auth (returns token)

	// Public model catalog — providers and install script fetch this
	s.mux.HandleFunc("GET /v1/models/catalog", modelCatalog.ListInstallCatalog)
	s.mux.HandleFunc("GET /v1/models/catalog/manifest/", modelCatalog.GetInstallManifest)
	s.mux.HandleFunc("GET /v1/models/catalog/", modelCatalog.GetInstallModel)

	// Runtime manifest — providers and users can inspect accepted runtime hashes.
	s.mux.HandleFunc("GET /v1/runtime/manifest", releaseAPI.RuntimeManifest)

	// Payment methods info
	s.mux.HandleFunc("GET /v1/billing/methods", billingHandlers.BillingMethods) // no auth needed

	// Referral system — register/apply mutate referral graph (financial
	// limiter); stats/info are read-only.
	s.mux.HandleFunc("POST /v1/referral/register", s.requireAuth(s.rateLimitFinancial(billingHandlers.ReferralRegister)))
	s.mux.HandleFunc("POST /v1/referral/apply", s.requireAuth(s.rateLimitFinancial(billingHandlers.ReferralApply)))
	s.mux.HandleFunc("GET /v1/referral/stats", s.requireAuth(billingHandlers.ReferralStats))
	s.mux.HandleFunc("GET /v1/referral/info", s.requireAuth(billingHandlers.ReferralInfo))

	// Invite codes (admin)
	// Invite code creation accepts amount_usd and produces a credit-bearing
	// code; redemption is already financial-tier so the issuance side must
	// match (otherwise an admin-key holder could spam codes anyway, but
	// keeping symmetry).
	s.mux.HandleFunc("POST /v1/admin/invite-codes", s.requireAuth(s.rateLimitFinancial(accountHandlers.CreateInvite)))
	s.mux.HandleFunc("GET /v1/admin/invite-codes", s.requireAuth(accountHandlers.ListInvites))
	s.mux.HandleFunc("DELETE /v1/admin/invite-codes", s.requireAuth(accountHandlers.DeactivateInvite))

	// Invite code redemption (user) — credits the redeemer's balance, so
	// it's a financial-tier endpoint.
	s.mux.HandleFunc("POST /v1/invite/redeem", s.requireAuth(s.rateLimitFinancial(accountHandlers.RedeemInvite)))

	// Admin credit & reward
	s.mux.HandleFunc("POST /v1/admin/credit", s.requireAuth(billingHandlers.AdminCredit))
	s.mux.HandleFunc("POST /v1/admin/reward", s.requireAuth(billingHandlers.AdminReward))

	// Retain the client-telemetry route for mixed-version compatibility. The
	// handler returns 410 before reading a request body; coordinator-owned
	// operational telemetry remains separate.
	s.mux.HandleFunc("POST /v1/telemetry/events", s.handleTelemetryIngest)

	// Explicit provider log reports
	s.mux.HandleFunc("POST /v1/provider/log-report", s.requireAuth(s.handleUploadLogReport))
	s.mux.HandleFunc("GET /v1/admin/log-reports/{id}", s.requireAuth(s.handleGetLogReport))

	// Metrics snapshot (admin only)
	s.mux.HandleFunc("GET /v1/admin/metrics", operations.Metrics)
	s.mux.HandleFunc("GET /v1/admin/base-rewards", billingHandlers.AdminBaseRewards)

	// Network utilization snapshot (admin only) — handler enforces admin auth
	// internally via requireAdminKey.
	s.mux.HandleFunc("GET /v1/admin/utilization", operations.Utilization)

	// Graceful drain toggle (admin only) — sets the coordinator into drain mode
	// before a restart/upgrade so new inference requests get 429 while in-flight
	// ones finish. Wrapped with requireAuth (the SAME pattern as the other
	// isAdminAuthorized/requireAdminKey endpoints, e.g. invite codes) so a Privy
	// admin JWT is parsed into the request context AND the admin key is accepted
	// as a pseudo-account; readinessAPI.Drain then authorizes via isAdminAuthorized
	// (admin key OR Privy admin). Registered before the /v1/ catch-all. Note:
	// /readyz stays unauthenticated. See drain.go (DAR-327 Phase 1).
	s.mux.HandleFunc("POST /v1/admin/drain", s.requireAuth(readinessAPI.Drain))

	// Routing telemetry (admin-gated; metadata only — no prompt/response content).
	// Browse as JSON or stream a CSV/NDJSON download for offline analysis.
	// See docs/design/routing-telemetry-and-calibration.md §6. Handlers
	// enforce admin auth internally via requireAdminKey.
	s.mux.HandleFunc("GET /v1/admin/routes", operations.Routes)
	s.mux.HandleFunc("GET /v1/admin/routes/export", operations.RoutesExport)
	s.mux.HandleFunc("GET /v1/admin/profiles", operations.Profiles)
	s.mux.HandleFunc("GET /v1/admin/request-outcomes", operations.RequestOutcomes)
	s.mux.HandleFunc("GET /v1/admin/profiles/export", operations.ProfilesExport)
	s.mux.HandleFunc("GET /v1/admin/snapshots", operations.Snapshots)
	s.mux.HandleFunc("GET /v1/admin/snapshots/export", operations.SnapshotsExport)
	s.mux.HandleFunc("GET /v1/admin/rejections", operations.Rejections)
	s.mux.HandleFunc("GET /v1/admin/rejections/export", operations.RejectionsExport)

	// Catch-all for unimplemented OpenAI-compatible endpoints.
	// Registered last (old-style pattern) so explicit method+path routes
	// take precedence. Any /v1/* path not handled above gets a structured
	// JSON error instead of the mux default text/plain 404.
	s.mux.HandleFunc("/v1/", s.handleUnimplementedEndpoint)
}

// handleUnimplementedEndpoint returns a structured JSON error for any /v1/*
// path not registered as an explicit route. This prevents OpenAI SDK clients
// from crashing on raw text/plain 404s when hitting unimplemented endpoints
// like /v1/embeddings or /v1/moderations.
func (s *Server) handleUnimplementedEndpoint(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotFound, errorResponse(
		"invalid_request_error",
		fmt.Sprintf("endpoint %s %s is not implemented", r.Method, r.URL.Path),
	))
}
