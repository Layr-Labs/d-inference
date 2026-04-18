// Package api provides the HTTP and WebSocket server for the Darkbloom coordinator.
//
// This package is the network-facing layer of the coordinator. It handles:
//   - Consumer HTTP endpoints (OpenAI-compatible chat completions, model listing)
//   - Provider WebSocket connections (registration, heartbeats, inference relay)
//   - Payment endpoints (deposit, balance, usage)
//   - Authentication via API keys (Bearer token)
//   - CORS middleware for development
//   - Request logging
//
// The coordinator runs in a GCP Confidential VM (AMD SEV-SNP). Consumer traffic
// arrives over HTTPS/TLS. The coordinator reads requests for routing but never
// logs prompt content.
package api

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/x509"
	_ "embed"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/mdm"
	"github.com/eigeninference/coordinator/internal/metrics"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/ratelimit"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// contextKey is an unexported type for context keys in this package.
// Using a distinct type prevents collisions with context keys from other packages.
type contextKey int

const (
	ctxKeyConsumer contextKey = iota
	ctxKeyRequestID
)

// requestIDFromContext returns the per-request correlation ID set by
// the logging middleware. Empty if the request didn't pass through the
// middleware (e.g. raw test handlers).
func requestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyRequestID).(string); ok {
		return v
	}
	return ""
}

// cryptoRand is a small wrapper to read random bytes. Defined as a var
// so tests can stub it if needed; production uses crypto/rand.Read.
var cryptoRand = rand.Read

// consumerKeyFromContext retrieves the authenticated consumer's API key
// from the request context. The key is stored by requireAuth middleware
// and used as the consumer's identity for billing and usage tracking.
func consumerKeyFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyConsumer).(string); ok {
		return v
	}
	return ""
}

// LatestProviderVersion is the current version of the provider CLI.
// Update this when uploading a new provider bundle.
var LatestProviderVersion = "0.3.10"

// Server is the main HTTP/WS server for the coordinator. It ties together
// the provider registry, key store, payment ledger, billing service, and HTTP routing.
type Server struct {
	registry               *registry.Registry
	store                  store.Store
	ledger                 *payments.Ledger
	billing                *billing.Service
	logger                 *slog.Logger
	mux                    *http.ServeMux
	challengeInterval      time.Duration     // 0 means use DefaultChallengeInterval
	privyAuth              *auth.PrivyAuth   // Privy JWT authentication (nil if not configured)
	adminEmails            map[string]bool   // emails that have admin access
	adminKey               string            // EIGENINFERENCE_ADMIN_KEY for admin endpoints
	mdmClient              *mdm.Client       // MicroMDM client for provider security verification
	stepCARootCert         *x509.Certificate // step-ca root CA for ACME cert verification
	stepCAIntermediateCert *x509.Certificate // step-ca intermediate CA

	// knownBinaryHashes is the set of accepted provider binary SHA-256 hashes.
	// When non-empty, providers whose binary hash doesn't match are rejected.
	// Auto-populated from active releases via SyncBinaryHashes().
	knownBinaryHashes map[string]bool

	// knownRuntimeManifest holds accepted runtime component hashes.
	// When set, providers whose runtime hashes don't match are marked as
	// unverified and excluded from routing (but not disconnected).
	knownRuntimeManifest *RuntimeManifest

	// minProviderVersion is the minimum provider version accepted for routing.
	// Providers below this version are excluded and told to update.
	// Set from EIGENINFERENCE_MIN_PROVIDER_VERSION env var or derived from latest release.
	minProviderVersion string

	// releaseKey is a scoped credential for the GitHub Action to register releases.
	// It can only POST /v1/releases — no admin access.
	releaseKey string

	// consoleURL is the frontend URL (e.g. "https://console.darkbloom.dev").
	// Used for device auth verification_uri so the browser opens the console, not the coordinator.
	consoleURL string

	// imageUploads stores generated images keyed by request_id.
	// Providers upload images via HTTP POST, then send a small WebSocket
	// completion message. The consumer handler retrieves images from here.
	imageUploads   map[string][][]byte // request_id → list of PNG images
	imageUploadsMu sync.Mutex

	// storedProviders is a lookup table of persisted provider records, indexed
	// by serial number and SE public key. When a provider reconnects after a
	// coordinator restart, this table is checked to restore trust/reputation.
	// Populated once at startup from the store.
	storedProviders map[string]*store.ProviderRecord

	// rateLimiter applies per-account token-bucket rate limits to consumer
	// inference endpoints. Nil means unlimited (compatibility with old call
	// sites and tests). Set via SetRateLimiter.
	rateLimiter *ratelimit.Limiter

	// financialRateLimiter is a separate, stricter limiter for endpoints
	// that touch on-chain state or mutate balances (deposit, withdraw, key
	// creation, referral apply, invite redemption). These are higher-value
	// targets for spam/abuse than inference, so we throttle them harder.
	// Nil means unlimited.
	financialRateLimiter *ratelimit.Limiter
}

// SetRateLimiter configures the per-account rate limiter applied to
// consumer inference endpoints. Pass nil to disable.
func (s *Server) SetRateLimiter(rl *ratelimit.Limiter) {
	s.rateLimiter = rl
}

// SetFinancialRateLimiter configures a stricter per-account limiter for
// balance-mutating endpoints. Pass nil to disable.
func (s *Server) SetFinancialRateLimiter(rl *ratelimit.Limiter) {
	s.financialRateLimiter = rl
}

// NewServer creates a configured Server with all routes mounted.
func NewServer(reg *registry.Registry, st store.Store, logger *slog.Logger) *Server {
	// Wire the store into the registry for provider fleet persistence.
	reg.SetStore(st)

	s := &Server{
		registry:     reg,
		store:        st,
		ledger:       payments.NewLedger(st),
		logger:       logger,
		mux:          http.NewServeMux(),
		imageUploads: make(map[string][][]byte),
	}
	s.routes()

	// Load stored provider records into a lookup table for matching
	// reconnecting providers to their persisted state.
	s.storedProviders = reg.LoadStoredProviders()

	return s
}

// SetAdminKey configures the admin API key for admin-only endpoints.
func (s *Server) SetAdminKey(key string) {
	s.adminKey = key
}

// SetStepCACerts configures the step-ca CA certificates for ACME client cert verification.
func (s *Server) SetStepCACerts(root, intermediate *x509.Certificate) {
	s.stepCARootCert = root
	s.stepCAIntermediateCert = intermediate
}

// SetBilling configures the billing service for multi-chain payments and referrals.
func (s *Server) SetBilling(svc *billing.Service) {
	s.billing = svc
}

// SetPrivyAuth configures Privy JWT authentication for consumer endpoints.
func (s *Server) SetPrivyAuth(pa *auth.PrivyAuth) {
	s.privyAuth = pa
}

// SetAdminEmails configures which Privy accounts have admin access.
func (s *Server) SetAdminEmails(emails []string) {
	s.adminEmails = make(map[string]bool, len(emails))
	for _, e := range emails {
		s.adminEmails[strings.ToLower(strings.TrimSpace(e))] = true
	}
}

// SetMDMClient configures the MicroMDM client for provider verification.
// When set, providers are verified against MDM on registration.
func (s *Server) SetMDMClient(client *mdm.Client) {
	s.mdmClient = client
}

// SyncModelCatalog reads active models from the store and updates the
// registry's model catalog. Call this at startup and after admin catalog changes.
func (s *Server) SyncModelCatalog() {
	models := s.store.ListSupportedModels()
	entries := make([]registry.CatalogEntry, 0, len(models))
	for _, m := range models {
		if m.Active {
			entries = append(entries, registry.CatalogEntry{
				ID:         m.ID,
				WeightHash: m.WeightHash,
			})
		}
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model catalog synced to registry", "active_models", len(entries))
}

// SetKnownBinaryHashes configures the set of accepted provider binary hashes.
// Providers whose binary SHA-256 doesn't match any known hash are rejected.
func (s *Server) SetKnownBinaryHashes(hashes []string) {
	s.knownBinaryHashes = make(map[string]bool, len(hashes))
	for _, h := range hashes {
		if h != "" {
			s.knownBinaryHashes[h] = true
		}
	}
}

// AddKnownBinaryHashes adds hashes to the existing known set (for env var fallback).
func (s *Server) AddKnownBinaryHashes(hashes []string) {
	if s.knownBinaryHashes == nil {
		s.knownBinaryHashes = make(map[string]bool)
	}
	for _, h := range hashes {
		if h != "" {
			s.knownBinaryHashes[h] = true
		}
	}
}

// SetConsoleURL sets the frontend URL for device auth verification links.
func (s *Server) SetConsoleURL(url string) {
	s.consoleURL = url
}

// SetReleaseKey configures the scoped release key for GitHub Actions.
func (s *Server) SetReleaseKey(key string) {
	s.releaseKey = key
}

// SyncBinaryHashes rebuilds knownBinaryHashes from all active releases.
// Called at startup and after release changes.
func (s *Server) SyncBinaryHashes() {
	releases := s.store.ListReleases()
	hashes := make(map[string]bool)
	for _, r := range releases {
		if r.Active && r.BinaryHash != "" {
			hashes[r.BinaryHash] = true
		}
	}
	s.knownBinaryHashes = hashes
	s.logger.Info("binary hashes synced from releases", "known_hashes", len(hashes))
}

// SyncRuntimeManifest builds the runtime manifest from active releases.
// Called after a release is registered to auto-update the expected hashes.
func (s *Server) SyncRuntimeManifest() {
	releases := s.store.ListReleases()

	// Set minimum provider version to the latest active release version.
	// This forces older providers to update before they can serve traffic.
	latestVersion := ""
	for _, r := range releases {
		if r.Active && semverGreater(r.Version, latestVersion) {
			latestVersion = r.Version
		}
	}
	if latestVersion != "" {
		s.minProviderVersion = latestVersion
		s.logger.Info("minimum provider version set from latest release", "min_version", latestVersion)
	} else {
		s.minProviderVersion = ""
	}

	manifest := &RuntimeManifest{
		PythonHashes:      make(map[string]bool),
		RuntimeHashes:     make(map[string]bool),
		TemplateHashes:    make(map[string]string),
		GrpcBinaryHashes:  make(map[string]bool),
		ImageBridgeHashes: make(map[string]bool),
	}

	hasAny := false
	for _, r := range releases {
		if !r.Active || r.Version != latestVersion {
			continue
		}
		if r.PythonHash != "" {
			manifest.PythonHashes[r.PythonHash] = true
			hasAny = true
		}
		if r.RuntimeHash != "" {
			manifest.RuntimeHashes[r.RuntimeHash] = true
			hasAny = true
		}
		if r.TemplateHashes != "" {
			// Parse "name=hash,name=hash" format
			for _, pair := range strings.Split(r.TemplateHashes, ",") {
				parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
				if len(parts) == 2 {
					manifest.TemplateHashes[parts[0]] = parts[1]
					hasAny = true
				}
			}
		}
		if r.GrpcBinaryHash != "" {
			manifest.GrpcBinaryHashes[r.GrpcBinaryHash] = true
			hasAny = true
		}
		if r.ImageBridgeHash != "" {
			manifest.ImageBridgeHashes[r.ImageBridgeHash] = true
			hasAny = true
		}
	}

	if hasAny {
		s.knownRuntimeManifest = manifest
		s.logger.Info("runtime manifest synced from releases",
			"version", latestVersion,
			"python_hashes", len(manifest.PythonHashes),
			"runtime_hashes", len(manifest.RuntimeHashes),
			"template_hashes", len(manifest.TemplateHashes),
			"grpc_binary_hashes", len(manifest.GrpcBinaryHashes),
			"image_bridge_hashes", len(manifest.ImageBridgeHashes),
		)
	} else {
		s.knownRuntimeManifest = nil
	}
}

// RuntimeManifest holds the set of accepted hashes for provider runtime components.
// When configured, the coordinator verifies provider-reported hashes against
// this manifest at registration and during periodic attestation challenges.
type RuntimeManifest struct {
	PythonHashes      map[string]bool   `json:"python_hashes"`       // set of accepted Python runtime hashes
	RuntimeHashes     map[string]bool   `json:"runtime_hashes"`      // set of accepted inference runtime hashes
	TemplateHashes    map[string]string `json:"template_hashes"`     // template_name -> expected hash
	GrpcBinaryHashes  map[string]bool   `json:"grpc_binary_hashes"`  // set of accepted gRPCServerCLI hashes
	ImageBridgeHashes map[string]bool   `json:"image_bridge_hashes"` // set of accepted image bridge hashes
}

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to disable runtime verification (all providers pass).
// semverGreater returns true if version a is greater than version b.
// Compares numeric components (e.g. "0.2.31" > "0.2.9" = true).
func semverGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		return true
	}
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")
	for i := 0; i < len(aParts) || i < len(bParts); i++ {
		var ai, bi int
		if i < len(aParts) {
			fmt.Sscanf(aParts[i], "%d", &ai)
		}
		if i < len(bParts) {
			fmt.Sscanf(bParts[i], "%d", &bi)
		}
		if ai > bi {
			return true
		}
		if ai < bi {
			return false
		}
	}
	return false // equal
}

// semverLess returns true if version a is less than version b.
func semverLess(a, b string) bool {
	return semverGreater(b, a)
}

func (s *Server) SetRuntimeManifest(m *RuntimeManifest) {
	s.knownRuntimeManifest = m
}

// verifyRuntimeHashes checks provider-reported runtime hashes against the
// known-good manifest. Returns (true, nil) if all hashes match or no manifest
// is configured. Returns (false, mismatches) if any component fails verification.
func (s *Server) verifyRuntimeHashes(pythonHash, runtimeHash string, templateHashes map[string]string, grpcBinaryHash, imageBridgeHash string) (bool, []protocol.RuntimeMismatch) {
	if s.knownRuntimeManifest == nil {
		return true, nil // no manifest configured, pass by default
	}

	var mismatches []protocol.RuntimeMismatch

	// Check Python runtime hash.
	if pythonHash != "" && len(s.knownRuntimeManifest.PythonHashes) > 0 {
		if !s.knownRuntimeManifest.PythonHashes[pythonHash] {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: "python",
				Expected:  "one of known-good hashes",
				Got:       pythonHash,
			})
		}
	}

	// Check inference runtime hash.
	if runtimeHash != "" && len(s.knownRuntimeManifest.RuntimeHashes) > 0 {
		if !s.knownRuntimeManifest.RuntimeHashes[runtimeHash] {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: "runtime",
				Expected:  "one of known-good hashes",
				Got:       runtimeHash,
			})
		}
	}

	// Check template hashes.
	if len(templateHashes) > 0 && len(s.knownRuntimeManifest.TemplateHashes) > 0 {
		for name, got := range templateHashes {
			expected, ok := s.knownRuntimeManifest.TemplateHashes[name]
			if ok && got != expected {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
	}

	// Check gRPCServerCLI binary hash (warn only — backward compat with older providers).
	if grpcBinaryHash != "" && len(s.knownRuntimeManifest.GrpcBinaryHashes) > 0 {
		if !s.knownRuntimeManifest.GrpcBinaryHashes[grpcBinaryHash] {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: "grpc_binary",
				Expected:  "one of known-good hashes",
				Got:       grpcBinaryHash,
			})
		}
	}

	// Check image bridge hash (warn only — backward compat with older providers).
	if imageBridgeHash != "" && len(s.knownRuntimeManifest.ImageBridgeHashes) > 0 {
		if !s.knownRuntimeManifest.ImageBridgeHashes[imageBridgeHash] {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: "image_bridge",
				Expected:  "one of known-good hashes",
				Got:       imageBridgeHash,
			})
		}
	}

	return len(mismatches) == 0, mismatches
}

// handleRuntimeManifest returns the current runtime manifest as JSON.
// No auth required — hashes are not secrets.
func (s *Server) handleRuntimeManifest(w http.ResponseWriter, r *http.Request) {
	if s.knownRuntimeManifest == nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"configured": false,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"configured":          true,
		"python_hashes":       s.knownRuntimeManifest.PythonHashes,
		"runtime_hashes":      s.knownRuntimeManifest.RuntimeHashes,
		"template_hashes":     s.knownRuntimeManifest.TemplateHashes,
		"grpc_binary_hashes":  s.knownRuntimeManifest.GrpcBinaryHashes,
		"image_bridge_hashes": s.knownRuntimeManifest.ImageBridgeHashes,
	})
}

// HandleMDMWebhook processes a MicroMDM webhook callback.
// Mount this on the webhook URL configured in MicroMDM.
func (s *Server) HandleMDMWebhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.logger.Debug("mdm webhook received", "body_size", len(body), "body_preview", string(body[:min(len(body), 500)]))
	if s.mdmClient != nil {
		s.mdmClient.HandleWebhook(body)
	}
	w.WriteHeader(http.StatusOK)
}

//go:embed install.sh
var installScript []byte

// routes mounts all HTTP and WebSocket handlers.
func (s *Server) routes() {
	// Install script — served directly from embedded binary.
	s.mux.HandleFunc("GET /install.sh", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(installScript)
	})

	// Health check — no auth required.
	s.mux.HandleFunc("GET /health", s.handleHealth)

	// Prometheus metrics — exposed unauthenticated by convention. In a
	// production deploy this should be reachable only from the metrics
	// scraper's network (e.g. via firewall rule or a reverse proxy that
	// strips it from the public listener). The data here is operational
	// (request counts, latency histograms, queue depth) — no PII or keys.
	s.mux.Handle("GET /metrics", promhttp.Handler())

	// Provider WebSocket — no API key auth (providers authenticate differently).
	s.mux.HandleFunc("GET /ws/provider", s.handleProviderWS)

	// Key generation — requires Privy auth, key is linked to account.
	// Stricter financial limiter applied because key creation is a high-value
	// operation (each key is a credential).
	s.mux.HandleFunc("POST /v1/auth/keys", s.requireAuth(s.rateLimitFinancial(s.handleCreateKey)))

	// Consumer endpoints — API key auth required + per-account rate limit.
	// rateLimitConsumer is chained inside requireAuth so the accountID is in
	// context. Read-only endpoints (GET /v1/models) skip rate limiting since
	// they're cheap and clients poll them.
	s.mux.HandleFunc("POST /v1/chat/completions", s.requireAuth(s.rateLimitConsumer(s.handleChatCompletions)))
	s.mux.HandleFunc("POST /v1/responses", s.requireAuth(s.rateLimitConsumer(s.handleChatCompletions))) // Responses API — same handler, auto-detects input vs messages
	s.mux.HandleFunc("POST /v1/completions", s.requireAuth(s.rateLimitConsumer(s.handleCompletions)))
	s.mux.HandleFunc("POST /v1/messages", s.requireAuth(s.rateLimitConsumer(s.handleAnthropicMessages)))
	s.mux.HandleFunc("POST /v1/audio/transcriptions", s.requireAuth(s.rateLimitConsumer(s.handleTranscriptions)))
	s.mux.HandleFunc("POST /v1/images/generations", s.requireAuth(s.rateLimitConsumer(s.handleImageGenerations)))
	s.mux.HandleFunc("GET /v1/models", s.requireAuth(s.handleListModels))

	// Provider image upload — providers POST generated images here (no API key auth,
	// providers authenticate via request_id which is a secret between coordinator and provider).
	s.mux.HandleFunc("POST /v1/provider/image-upload", s.handleImageUpload)

	// MDM webhook — MicroMDM sends command responses here.
	s.mux.HandleFunc("POST /v1/mdm/webhook", s.HandleMDMWebhook)

	// Payment endpoints — API key auth required.
	s.mux.HandleFunc("GET /v1/payments/balance", s.requireAuth(s.handleBalance))
	s.mux.HandleFunc("GET /v1/payments/usage", s.requireAuth(s.handleUsage))

	// Provider earnings — no API key auth (providers identify by wallet address).
	s.mux.HandleFunc("GET /v1/provider/earnings", s.handleProviderEarnings)

	// Per-node provider earnings — public by provider_key, or auth'd by account.
	s.mux.HandleFunc("GET /v1/provider/node-earnings", s.handleNodeEarnings)
	s.mux.HandleFunc("GET /v1/provider/account-earnings", s.requireAuth(s.handleAccountEarnings))

	// ACME enrollment — generates per-device .mobileconfig for device-attest-01.
	// No auth needed — security comes from Apple's attestation during ACME challenge.
	s.mux.HandleFunc("POST /v1/enroll", s.handleEnroll)

	// Attestation verification — public, no auth needed.
	// Users can independently verify Apple's MDA certificate chain.
	s.mux.HandleFunc("GET /v1/providers/attestation", s.handleProviderAttestation)

	// Platform stats — no auth needed. Frontend dashboard uses this.
	s.mux.HandleFunc("GET /v1/stats", s.handleStats)

	// Provider version check — no auth needed. Providers call this to check for updates.
	s.mux.HandleFunc("GET /api/version", s.handleVersion)

	// Releases — versioned provider binary distribution.
	s.mux.HandleFunc("POST /v1/releases", s.handleRegisterRelease)     // scoped release key (GitHub Action)
	s.mux.HandleFunc("GET /v1/releases/latest", s.handleLatestRelease) // public (install.sh)

	// Device authorization flow — providers link to user accounts.
	s.mux.HandleFunc("POST /v1/device/code", s.handleDeviceCode)   // no auth — provider not yet authenticated
	s.mux.HandleFunc("POST /v1/device/token", s.handleDeviceToken) // no auth — polls with device_code secret
	// Device approve issues a long-lived provider→account linking token —
	// same risk class as /v1/auth/keys, so financial-tier limit applies.
	s.mux.HandleFunc("POST /v1/device/approve", s.requireAuth(s.rateLimitFinancial(s.handleDeviceApprove))) // Privy auth — user approves in browser

	// --- Billing endpoints (multi-chain payments + referrals) ---

	// Stripe — financial limiter on session creation (creates a checkout
	// intent, hits external API). Read-only status endpoint not throttled.
	s.mux.HandleFunc("POST /v1/billing/stripe/create-session", s.requireAuth(s.rateLimitFinancial(s.handleStripeCreateSession)))
	s.mux.HandleFunc("POST /v1/billing/stripe/webhook", s.handleStripeWebhook) // no auth — Stripe signs it
	s.mux.HandleFunc("GET /v1/billing/stripe/session", s.requireAuth(s.handleStripeSessionStatus))

	// Solana deposits and withdrawals — both hit on-chain RPCs and mutate
	// balances, so the stricter financial limiter applies.
	s.mux.HandleFunc("POST /v1/billing/deposit", s.requireAuth(s.rateLimitFinancial(s.handleSolanaDeposit)))
	s.mux.HandleFunc("POST /v1/billing/withdraw/solana", s.requireAuth(s.rateLimitFinancial(s.handleSolanaWithdraw)))
	s.mux.HandleFunc("GET /v1/billing/wallet/balance", s.requireAuth(s.handleWalletBalance))

	// Pricing — GET is public, PUT/DELETE require auth
	s.mux.HandleFunc("GET /v1/pricing", s.handleGetPricing)                        // public
	s.mux.HandleFunc("PUT /v1/pricing", s.requireAuth(s.handleSetPricing))         // provider sets own prices
	s.mux.HandleFunc("DELETE /v1/pricing", s.requireAuth(s.handleDeletePricing))   // revert to default
	s.mux.HandleFunc("PUT /v1/admin/pricing", s.requireAuth(s.handleAdminPricing)) // platform sets defaults

	// Admin model catalog
	s.mux.HandleFunc("GET /v1/admin/models", s.requireAuth(s.handleAdminListModels))
	s.mux.HandleFunc("POST /v1/admin/models", s.requireAuth(s.handleAdminSetModel))
	s.mux.HandleFunc("DELETE /v1/admin/models", s.requireAuth(s.handleAdminDeleteModel))
	s.mux.HandleFunc("GET /v1/admin/releases", s.handleAdminListReleases)     // admin key or Privy admin
	s.mux.HandleFunc("DELETE /v1/admin/releases", s.handleAdminDeleteRelease) // admin key or Privy admin

	// Admin CLI auth — Privy email OTP for getting admin tokens without a browser.
	s.mux.HandleFunc("POST /v1/admin/auth/init", s.handleAdminAuthInit)     // no auth (sends OTP)
	s.mux.HandleFunc("POST /v1/admin/auth/verify", s.handleAdminAuthVerify) // no auth (returns token)

	// Public model catalog — providers and install script fetch this
	s.mux.HandleFunc("GET /v1/models/catalog", s.handleModelCatalog)

	// Runtime manifest — providers and users can inspect accepted runtime hashes.
	s.mux.HandleFunc("GET /v1/runtime/manifest", s.handleRuntimeManifest)

	// Payment methods info
	s.mux.HandleFunc("GET /v1/billing/methods", s.handleBillingMethods) // no auth needed

	// Referral system — register/apply mutate referral graph (financial
	// limiter); stats/info are read-only.
	s.mux.HandleFunc("POST /v1/referral/register", s.requireAuth(s.rateLimitFinancial(s.handleReferralRegister)))
	s.mux.HandleFunc("POST /v1/referral/apply", s.requireAuth(s.rateLimitFinancial(s.handleReferralApply)))
	s.mux.HandleFunc("GET /v1/referral/stats", s.requireAuth(s.handleReferralStats))
	s.mux.HandleFunc("GET /v1/referral/info", s.requireAuth(s.handleReferralInfo))

	// Invite codes (admin)
	// Invite code creation accepts amount_usd and produces a credit-bearing
	// code; redemption is already financial-tier so the issuance side must
	// match (otherwise an admin-key holder could spam codes anyway, but
	// keeping symmetry).
	s.mux.HandleFunc("POST /v1/admin/invite-codes", s.requireAuth(s.rateLimitFinancial(s.handleAdminCreateInviteCode)))
	s.mux.HandleFunc("GET /v1/admin/invite-codes", s.requireAuth(s.handleAdminListInviteCodes))
	s.mux.HandleFunc("DELETE /v1/admin/invite-codes", s.requireAuth(s.handleAdminDeactivateInviteCode))

	// Invite code redemption (user) — credits the redeemer's balance, so
	// it's a financial-tier endpoint.
	s.mux.HandleFunc("POST /v1/invite/redeem", s.requireAuth(s.rateLimitFinancial(s.handleRedeemInviteCode)))
}

// Handler returns the root http.Handler with global middleware applied.
func (s *Server) Handler() http.Handler {
	return s.corsMiddleware(s.loggingMiddleware(s.mux))
}

// requireAuth wraps a handler with authentication. It tries Privy JWT first
// (if configured), then falls back to API key validation. The authenticated
// identity is stored in the request context for downstream use.
func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := extractBearerToken(r)
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing credentials — use Authorization: Bearer <token>"))
			return
		}

		// Try Privy JWT first (JWTs start with "eyJ").
		if s.privyAuth != nil && strings.HasPrefix(token, "eyJ") {
			privyUserID, err := s.privyAuth.VerifyToken(token)
			if err != nil {
				writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid Privy token"))
				return
			}
			user, err := s.privyAuth.GetOrCreateUser(privyUserID)
			if err != nil {
				s.logger.Error("privy: user resolution failed", "error", err)
				writeJSON(w, http.StatusInternalServerError, errorResponse("auth_error", "failed to resolve user"))
				return
			}
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
			ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			next(w, r.WithContext(ctx))
			return
		}

		// Accept admin key (admin endpoints handle further authorization in-handler).
		if s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, "admin")
			next(w, r.WithContext(ctx))
			return
		}

		// Fall back to API key auth.
		if !s.store.ValidateKey(token) {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid API key"))
			return
		}

		// Resolve key → account. If the key is linked to a Privy account,
		// use that account ID and load the user.
		accountID := token
		ctx := r.Context()
		if ownerID := s.store.GetKeyAccount(token); ownerID != "" {
			accountID = ownerID
			if user, err := s.store.GetUserByAccountID(ownerID); err == nil {
				ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			}
		}

		ctx = context.WithValue(ctx, ctxKeyConsumer, accountID)
		next(w, r.WithContext(ctx))
	}
}

// rateLimitConsumer wraps a consumer-facing handler with per-account rate
// limiting. It must be chained AFTER requireAuth so the accountID is in
// the context. Admin key requests bypass the limiter (they show up as the
// "admin" pseudo-account from requireAuth — we let those through unmetered
// so admin scripts and ops tooling aren't throttled).
//
// Note: Privy users with admin emails (s.adminEmails) currently do NOT
// bypass — they receive a real accountID from requireAuth. This is
// intentional: human admins shouldn't generate enough traffic to hit
// limits, and treating them as untrusted callers preserves the invariant
// that the limiter sees one identity per real user.
//
// Returns 429 with a Retry-After header on rejection. The Retry-After
// duration is the time until at least one token replenishes, clamped to a
// sane maximum to avoid pathological values.
func (s *Server) rateLimitConsumer(next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWith(s.rateLimiterFn, next)
}

// rateLimitFinancial wraps a balance-mutating handler with the stricter
// financial-endpoint limiter. Chain inside requireAuth.
func (s *Server) rateLimitFinancial(next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(s.financialRateLimiterFn, "financial", next)
}

// The two getter methods exist so rateLimitWith can read the *current*
// limiter at request time. Routes are registered in routes() during
// NewServer, but SetRateLimiter / SetFinancialRateLimiter are called
// AFTER NewServer in main.go. Capturing the field directly at registration
// time would close over a nil pointer.
func (s *Server) rateLimiterFn() *ratelimit.Limiter          { return s.rateLimiter }
func (s *Server) financialRateLimiterFn() *ratelimit.Limiter { return s.financialRateLimiter }

func (s *Server) rateLimitWith(getLimiter func() *ratelimit.Limiter, next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(getLimiter, "consumer", next)
}

// rateLimitWithTier is the actual implementation; callers thread a label
// for the metrics counter so we can distinguish consumer vs financial
// rejections in dashboards.
func (s *Server) rateLimitWithTier(getLimiter func() *ratelimit.Limiter, tier string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rl := getLimiter()
		if rl == nil {
			next(w, r)
			return
		}
		accountID := consumerKeyFromContext(r.Context())
		if accountID == "admin" {
			next(w, r)
			return
		}
		if allowed, retryAfter := rl.Allow(accountID); !allowed {
			seconds := int(retryAfter.Seconds())
			if seconds < 1 {
				seconds = 1
			}
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(time.Now().Add(retryAfter).Unix(), 10))
			metrics.RateLimitRejections.WithLabelValues(tier).Inc()
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				"too many requests — slow down and retry after the Retry-After interval"))
			return
		}
		next(w, r)
	}
}

// corsMiddleware adds permissive CORS headers for development.
// In production, this should be restricted to the actual frontend origin.
func (s *Server) corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// loggingMiddleware logs each request using slog.
func (s *Server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}

		// Generate (or honor) a request_id and stash it in context +
		// response headers so logs and the client can correlate.
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" {
			reqID = newRequestID()
		}
		w.Header().Set("X-Request-ID", reqID)
		ctx := context.WithValue(r.Context(), ctxKeyRequestID, reqID)
		r = r.WithContext(ctx)

		next.ServeHTTP(sw, r)

		// Resolve the route pattern that matched (Go 1.22+ method+path).
		// Falls back to URL.Path when no pattern matched (404). Pattern
		// label keeps cardinality bounded — never user input.
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}
		statusLabel := strconv.Itoa(sw.status)
		metrics.HTTPRequests.WithLabelValues(route, r.Method, statusLabel).Inc()
		metrics.HTTPRequestDuration.WithLabelValues(route, r.Method).Observe(time.Since(start).Seconds())

		// User correlation: if requireAuth attached an account, include
		// it in the access log. Empty for unauthenticated paths.
		userID := consumerKeyFromContext(ctx)

		s.logger.Info("request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"route", route,
			"status", sw.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"remote", r.RemoteAddr,
			"user_id", userID,
		)
	})
}

// newRequestID returns a short, URL-safe request identifier. We avoid
// uuid here because request_id is hot-path and we don't need the entropy
// of a UUID — 12 base32 chars (~60 bits) is plenty to distinguish
// concurrent requests for trace correlation.
func newRequestID() string {
	const alphabet = "0123456789abcdefghijklmnopqrstuv"
	var b [12]byte
	if _, err := cryptoRand(b[:]); err != nil {
		// Fall back to a time-based id; collision risk is negligible for
		// log-correlation purposes.
		t := time.Now().UnixNano()
		return strconv.FormatInt(t, 36)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])&31]
	}
	return string(b[:])
}

// statusWriter wraps http.ResponseWriter to capture the status code
// for logging. It also implements http.Flusher and http.Hijacker by
// delegating to the underlying writer, which is required for SSE
// streaming and WebSocket upgrade respectively.
type statusWriter struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (sw *statusWriter) WriteHeader(code int) {
	if !sw.wroteHeader {
		sw.status = code
		sw.wroteHeader = true
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *statusWriter) Flush() {
	if f, ok := sw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack implements http.Hijacker by delegating to the underlying writer.
// This is required for WebSocket upgrade to work through middleware.
func (sw *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := sw.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, fmt.Errorf("underlying ResponseWriter does not implement http.Hijacker")
}

// Unwrap returns the underlying ResponseWriter, allowing the http package
// and websocket libraries to discover interfaces like http.Hijacker.
func (sw *statusWriter) Unwrap() http.ResponseWriter {
	return sw.ResponseWriter
}

// extractBearerToken extracts the token from "Authorization: Bearer <token>".
func extractBearerToken(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return ""
	}
	parts := strings.SplitN(auth, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}

// handleImageUpload accepts image data uploaded by providers via HTTP POST.
// This avoids sending large base64 images over the WebSocket (which has size limits).
// The provider uploads images here after generating them, then sends a small
// image_generation_complete message over the WebSocket with just usage metadata.
func (s *Server) handleImageUpload(w http.ResponseWriter, r *http.Request) {
	requestID := r.URL.Query().Get("request_id")
	if requestID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "request_id is required"))
		return
	}

	// Read image data (limit to 20 MB)
	r.Body = http.MaxBytesReader(w, r.Body, 20<<20)
	imageData, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read image data"))
		return
	}

	s.imageUploadsMu.Lock()
	s.imageUploads[requestID] = append(s.imageUploads[requestID], imageData)
	s.imageUploadsMu.Unlock()

	s.logger.Debug("image uploaded", "request_id", requestID, "size", len(imageData))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// getUploadedImages retrieves and removes stored images for a request.
func (s *Server) getUploadedImages(requestID string) [][]byte {
	s.imageUploadsMu.Lock()
	defer s.imageUploadsMu.Unlock()
	images := s.imageUploads[requestID]
	delete(s.imageUploads, requestID)
	return images
}
