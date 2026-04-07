// Package api provides the HTTP and WebSocket server for the EigenInference coordinator.
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
	"crypto/subtle"
	"crypto/x509"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/mdm"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// contextKey is an unexported type for context keys in this package.
// Using a distinct type prevents collisions with context keys from other packages.
type contextKey int

const (
	ctxKeyConsumer contextKey = iota
)

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
var LatestProviderVersion = "0.2.20"

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

	// releaseKey is a scoped credential for the GitHub Action to register releases.
	// It can only POST /v1/releases — no admin access.
	releaseKey string

	// consoleURL is the frontend URL (e.g. "https://private-inference.openinnovation.dev").
	// Used for device auth verification_uri so the browser opens the console, not the coordinator.
	consoleURL string

	// imageUploads stores generated images keyed by request_id.
	// Providers upload images via HTTP POST, then send a small WebSocket
	// completion message. The consumer handler retrieves images from here.
	imageUploads   map[string][][]byte // request_id → list of PNG images
	imageUploadsMu sync.Mutex
}

// NewServer creates a configured Server with all routes mounted.
func NewServer(reg *registry.Registry, st store.Store, logger *slog.Logger) *Server {
	s := &Server{
		registry:     reg,
		store:        st,
		ledger:       payments.NewLedger(st),
		logger:       logger,
		mux:          http.NewServeMux(),
		imageUploads: make(map[string][][]byte),
	}
	s.routes()
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

// routes mounts all HTTP and WebSocket handlers.
func (s *Server) routes() {
	// Health check — no auth required.
	s.mux.HandleFunc("GET /health", s.handleHealth)

	// Provider WebSocket — no API key auth (providers authenticate differently).
	s.mux.HandleFunc("GET /ws/provider", s.handleProviderWS)

	// Key generation — requires Privy auth, key is linked to account.
	s.mux.HandleFunc("POST /v1/auth/keys", s.requireAuth(s.handleCreateKey))

	// Consumer endpoints — API key auth required.
	s.mux.HandleFunc("POST /v1/chat/completions", s.requireAuth(s.handleChatCompletions))
	s.mux.HandleFunc("POST /v1/completions", s.requireAuth(s.handleCompletions))
	s.mux.HandleFunc("POST /v1/messages", s.requireAuth(s.handleAnthropicMessages))
	s.mux.HandleFunc("POST /v1/audio/transcriptions", s.requireAuth(s.handleTranscriptions))
	s.mux.HandleFunc("POST /v1/images/generations", s.requireAuth(s.handleImageGenerations))
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
	s.mux.HandleFunc("POST /v1/device/code", s.handleDeviceCode)                      // no auth — provider not yet authenticated
	s.mux.HandleFunc("POST /v1/device/token", s.handleDeviceToken)                    // no auth — polls with device_code secret
	s.mux.HandleFunc("POST /v1/device/approve", s.requireAuth(s.handleDeviceApprove)) // Privy auth — user approves in browser

	// --- Billing endpoints (multi-chain payments + referrals) ---

	// Stripe
	s.mux.HandleFunc("POST /v1/billing/stripe/create-session", s.requireAuth(s.handleStripeCreateSession))
	s.mux.HandleFunc("POST /v1/billing/stripe/webhook", s.handleStripeWebhook) // no auth — Stripe signs it
	s.mux.HandleFunc("GET /v1/billing/stripe/session", s.requireAuth(s.handleStripeSessionStatus))

	// Solana deposits and withdrawals
	s.mux.HandleFunc("POST /v1/billing/deposit", s.requireAuth(s.handleSolanaDeposit))
	s.mux.HandleFunc("POST /v1/billing/withdraw/solana", s.requireAuth(s.handleSolanaWithdraw))
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

	// Payment methods info
	s.mux.HandleFunc("GET /v1/billing/methods", s.handleBillingMethods) // no auth needed

	// Referral system
	s.mux.HandleFunc("POST /v1/referral/register", s.requireAuth(s.handleReferralRegister))
	s.mux.HandleFunc("POST /v1/referral/apply", s.requireAuth(s.handleReferralApply))
	s.mux.HandleFunc("GET /v1/referral/stats", s.requireAuth(s.handleReferralStats))
	s.mux.HandleFunc("GET /v1/referral/info", s.requireAuth(s.handleReferralInfo))

	// Invite codes (admin)
	s.mux.HandleFunc("POST /v1/admin/invite-codes", s.requireAuth(s.handleAdminCreateInviteCode))
	s.mux.HandleFunc("GET /v1/admin/invite-codes", s.requireAuth(s.handleAdminListInviteCodes))
	s.mux.HandleFunc("DELETE /v1/admin/invite-codes", s.requireAuth(s.handleAdminDeactivateInviteCode))

	// Invite code redemption (user)
	s.mux.HandleFunc("POST /v1/invite/redeem", s.requireAuth(s.handleRedeemInviteCode))
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

		next.ServeHTTP(sw, r)

		s.logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", sw.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"remote", r.RemoteAddr,
		)
	})
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
