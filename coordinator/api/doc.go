// Package api is the HTTP + WebSocket network layer of the Darkbloom
// coordinator. It exposes the OpenAI-compatible consumer endpoints, the
// provider WebSocket (registration, attestation, inference relay), billing and
// payout handlers, the model registry, and the operator/observability surface.
// All handlers hang off a single *Server; the coordinator routes consumer
// requests across the provider fleet end-to-end encrypted and never logs
// plaintext prompts.
//
// This package was split from a handful of monoliths (consumer.go, server.go,
// provider.go, billing_handlers.go, …) into focused per-domain files. Go pins a
// method to its receiver's package, so the *Server methods all live here; files
// are grouped by concern, not into subpackages. File map:
//
//	Server bootstrap & wiring
//	  server.go               Server struct, ListenAndServe, NewServer, WS upgrade
//	  server_config.go        ServerConfig (coordinator URL, Stripe/Datadog/MDM)
//	  server_setters.go       SetLogger/SetStore/SetRegistry/SetBilling/… setters
//	  routes.go               mux wiring, //go:embed install.sh, baseURL resolver
//	  consumer.go             package/inference overview doc (endpoints split out)
//
//	HTTP response, caching & request context
//	  httpresp.go             writeJSON, decodeJSONBody, errorResponse builders
//	  cache.go                ttlCache: pre-serialized JSON, 60s TTL for hot GETs
//	  context_keys.go         ctxKey consumer/request-id/api-key + extractors
//
//	Auth & authorization
//	  auth_middleware.go      requireAuth/requirePrivyAuth + API-key cache
//	  auth_helpers.go         resolveAccountID, isAdmin, adminKeyMatches, gates
//	  device_auth.go          RFC 8628 device code flow (code/token/approve)
//
//	Middleware, metrics & telemetry
//	  middleware.go           logging, panic recovery, request-id, CORS
//	  ratelimit_middleware.go applyTokenRateLimit (ITPM/OTPM + per-key caps)
//	  observability.go        emit helper → telemetry.Emitter (Datadog)
//	  metrics.go              in-process metric registry + GET /v1/admin/metrics
//	  telemetry_handlers.go   POST /v1/telemetry/events (allowlist + forwarding)
//
//	Consumer inference path
//	  inference_dispatch.go   chat/completions/messages handlers, TTFT, dispatch
//	  inference_stream.go     SSE streaming response writer
//	  inference_nonstream.go  non-streaming response assembly
//	  request_estimate.go     token estimation, max-tokens bounds, field parsing
//	  responses_translate.go  Responses API → chat completions translation
//	  response_normalize.go   SSE/complete normalization (null fields, <think>)
//	  response_build.go       response assembly from streamed chunks
//	  reservation.go          billing reservation top-up/refund on commit/rollback
//	  models_handler.go       GET /v1/models (dedup + attestation + capacity)
//	  sender_encryption.go    optional sender→coordinator NaCl-box decrypt layer
//
//	Consumer account & misc
//	  account_handlers.go     health, version, balance, usage, node-earnings
//	  log_report_handlers.go  provider log-report upload + admin retrieval
//	  keys_handler.go         GET /v1/encryption-key + API-key CRUD
//	  pseudonym.go            stable human-readable names from account IDs
//
//	Provider WebSocket lifecycle
//	  provider.go             WS dispatcher + provider lifecycle state machine
//	  provider_register.go    registration handling + location attach
//	  provider_inference.go   relays InferenceResponseChunk to the consumer
//	  provider_complete.go    disconnect cleanup, pending abort, reputation
//	  provider_geo.go         GeoIP (MaxMind GeoLite2) location enrichment
//	  provider_trust_status.go push current trust level to the provider
//
//	Provider attestation & trust
//	  provider_challenge.go        periodic challenge generation
//	  provider_challenge_verify.go Secure-Enclave challenge-response verify
//	  provider_attestation.go      verify SE P-256 attestation, set trust
//	  provider_attestation_handler.go GET /v1/providers/attestation proofs
//	  acme_verify.go               ACME client-cert / Apple cert-chain verify
//	  provider_acme_trust.go       applyACMETrust trust upgrade
//	  provider_mdm.go              MDM/MDA cert chain + hardware security checks
//	  mdm_webhook.go               MicroMDM webhook callback handler
//
//	"Me" dashboard (provider/account view)
//	  me_handlers.go          GET /v1/me/providers + /v1/me/summary
//	  me_types.go             myProvider/myReputation/… wire types
//	  me_identity.go          stable identity from serial / SE pubkey
//	  me_fleet.go             merge persisted records with live registry snapshot
//	  me_enrich.go            attach lifetime earnings to merged providers
//	  me_counts.go            fleet aggregate counts (serving/offline/…)
//	  me_build_provider.go    hydrate myProvider from record + live Provider
//
//	Billing — deposits & admin
//	  billing_handlers.go         consumer payment-flow overview doc
//	  billing_stripe_handlers.go  Stripe Checkout + webhook, wallet, methods
//	  admin_billing_handlers.go   admin pricing/role/fee/credit/reward
//	  earnings_handlers.go        provider/account earnings
//	  referral_handlers.go        referral register/apply/stats
//	  pricing_handlers.go         GET /v1/pricing (+ provider self-serve)
//	  invite_handlers.go          invite send/redeem
//	  enroll.go                   POST /v1/enroll onboarding
//
//	Stripe payouts (Connect Express withdrawals)
//	  stripe_payouts.go           overview doc for the split
//	  stripe_payouts_onboard.go   onboard + status handlers
//	  stripe_payouts_withdraw.go  POST /v1/billing/withdraw/stripe + list
//	  stripe_payouts_webhook.go   Connect webhook dispatch + per-event handlers
//	  stripe_payouts_status.go    status enum + account-status mapping
//	  stripe_payouts_helpers.go   pure helpers + compile-time anchors
//
//	Model registry
//	  model_registry_handlers.go         overview doc for the split
//	  model_registry_catalog_handlers.go GET /v1/models/catalog (60s cache)
//	  model_registry_auth.go             publishing actor / API-key validation
//	  model_registry_write_handlers.go   publish + admin archive handlers
//	  model_registry_validate.go         request/manifest validation predicates
//	  model_registry_manifest.go         manifest fetch/HEAD verify from CDN
//	  model_registry_projection.go       record → SupportedModel projection
//
//	OpenRouter proxy
//	  openrouter_endpoint.go  GET /v1/models/openrouter
//	  openrouter_models.go    OpenRouter ↔ Darkbloom catalog mapping
//
//	Releases, runtime & binary policy
//	  release_handlers.go     GET /v1/release/:version download
//	  runtime_manifest.go     GET /v1/runtime-manifest
//	  catalog_sync.go         provider version catalog + LatestProviderVersion
//	  binary_hash_policy.go   known-binary-hash policy set/add/sync
//
//	Stats & leaderboards
//	  stats.go                GET /v1/stats/models + /v1/stats/providers
//	  capacity.go             GET /v1/models/capacity live snapshot
//	  leaderboard.go          GET /v1/leaderboard earnings windows
package api
