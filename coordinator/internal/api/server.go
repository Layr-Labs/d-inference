// Package api provides the HTTP and WebSocket server for the DGInf coordinator.
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
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/dginf/coordinator/internal/mdm"
	"github.com/dginf/coordinator/internal/payments"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/dginf/coordinator/internal/store"
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

// Server is the main HTTP/WS server for the coordinator. It ties together
// the provider registry, key store, payment ledger, and HTTP routing.
type Server struct {
	registry          *registry.Registry
	store             store.Store
	ledger            *payments.Ledger
	logger            *slog.Logger
	mux               *http.ServeMux
	challengeInterval time.Duration // 0 means use DefaultChallengeInterval
	settlementURL     string        // URL of the settlement sidecar (e.g. "http://localhost:8090")
	mdmClient         *mdm.Client   // MicroMDM client for provider security verification
	processedTxHashes map[string]bool // prevents double-crediting the same on-chain tx
}

// NewServer creates a configured Server with all routes mounted.
func NewServer(reg *registry.Registry, st store.Store, logger *slog.Logger) *Server {
	s := &Server{
		registry:          reg,
		store:             st,
		ledger:            payments.NewLedger(st),
		logger:            logger,
		mux:               http.NewServeMux(),
		settlementURL:     "http://localhost:8090",
		processedTxHashes: make(map[string]bool),
	}
	s.routes()
	return s
}

// SetSettlementURL configures the settlement service URL.
func (s *Server) SetSettlementURL(url string) {
	s.settlementURL = url
}

// SetMDMClient configures the MicroMDM client for provider verification.
// When set, providers are verified against MDM on registration.
func (s *Server) SetMDMClient(client *mdm.Client) {
	s.mdmClient = client
}

// HandleMDMWebhook processes a MicroMDM webhook callback.
// Mount this on the webhook URL configured in MicroMDM.
func (s *Server) HandleMDMWebhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
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

	// Admin endpoints — admin key auth required.
	s.mux.HandleFunc("POST /v1/auth/keys", s.requireAuth(s.handleCreateKey))

	// Consumer endpoints — API key auth required.
	s.mux.HandleFunc("POST /v1/chat/completions", s.requireAuth(s.handleChatCompletions))
	s.mux.HandleFunc("GET /v1/models", s.requireAuth(s.handleListModels))

	// MDM webhook — MicroMDM sends command responses here.
	s.mux.HandleFunc("POST /v1/mdm/webhook", s.HandleMDMWebhook)

	// Payment endpoints — API key auth required.
	s.mux.HandleFunc("POST /v1/payments/deposit", s.requireAuth(s.handleDeposit))
	s.mux.HandleFunc("GET /v1/payments/balance", s.requireAuth(s.handleBalance))
	s.mux.HandleFunc("GET /v1/payments/usage", s.requireAuth(s.handleUsage))
	s.mux.HandleFunc("POST /v1/payments/withdraw", s.requireAuth(s.handleWithdraw))
}

// Handler returns the root http.Handler with global middleware applied.
func (s *Server) Handler() http.Handler {
	return s.corsMiddleware(s.loggingMiddleware(s.mux))
}

// requireAuth wraps a handler with API key validation. It extracts the
// Bearer token from the Authorization header, validates it against the
// key store, and stores the key in the request context for downstream use.
func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := extractBearerToken(r)
		if key == "" {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing API key — use Authorization: Bearer <key>"))
			return
		}
		if !s.store.ValidateKey(key) {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid API key"))
			return
		}

		ctx := context.WithValue(r.Context(), ctxKeyConsumer, key)
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
