package api

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Handler returns the root http.Handler with global middleware applied.
// Middleware order (outside-in):
//
//	cors → recover → logging → body-limit → mux
//
// Recover must sit outside logging so a panic during logging doesn't leak.
func (s *Server) Handler() http.Handler {
	return s.corsMiddleware(s.recoverMiddleware(s.loggingMiddleware(s.bodyLimitMiddleware(s.mux))))
}

// maxRequestBodyBytes is the global ceiling bodyLimitMiddleware applies to every
// request body so no endpoint can be OOM'd by an unbounded POST. It's a coarse
// outer bound that clears every legitimate body with headroom; the hot paths
// self-cap tighter on top (the plaintext-inference path at 16 MiB, sized to the
// provider WS frame budget — see maxInferenceBodyBytes).
const maxRequestBodyBytes = 64 << 20 // 64 MiB

// maxControlPlaneBodyBytes is the tight cap for small unauthenticated
// control-plane JSON (enroll, device token, admin auth) — far below the global
// ceiling so these exposed endpoints buffer at most a few KiB.
const maxControlPlaneBodyBytes = 64 << 10 // 64 KiB

// bodyLimitMiddleware caps every request body at maxRequestBodyBytes so an
// unbounded POST can't OOM the coordinator (the trusted TEE component).
// Per-handler MaxBytesReader caps (tighter) layer on top. The provider
// WebSocket upgrade is exempt: it hijacks the connection and reads framed
// messages (bounded separately), not r.Body.
func (s *Server) bodyLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && r.URL.Path != "/ws/provider" {
			r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
		}
		next.ServeHTTP(w, r)
	})
}

// decodeCappedJSON JSON-decodes the request body under a hard size cap, writing
// a 413 (too large) or 400 (bad JSON) and returning false on failure. For small
// unauthenticated control-plane endpoints that must not buffer an unbounded body.
func decodeCappedJSON(w http.ResponseWriter, r *http.Request, maxBytes int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeJSON(w, http.StatusRequestEntityTooLarge,
				errorResponse("invalid_request_error", "request body too large"))
			return false
		}
		writeJSON(w, http.StatusBadRequest,
			errorResponse("invalid_request_error", "invalid JSON"))
		return false
	}
	return true
}

// recoverMiddleware catches panics in any handler, emits a telemetry event
// with the stack trace, and returns 500 to the client. Without this, a single
// nil deref takes down the whole coordinator — panics from tests have hit us
// in production more than once.
func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				if recErr, ok := rec.(error); ok && errors.Is(recErr, http.ErrAbortHandler) {
					panic(rec)
				}
				stack := string(debug.Stack())
				s.logger.Error("panic in HTTP handler",
					"error", fmt.Sprintf("%v", rec),
					"path", r.URL.Path,
					"method", r.Method,
					"stack", stack,
				)
				s.emitPanic(r.Context(),
					fmt.Sprintf("panic in handler %s %s: %v", r.Method, r.URL.Path, rec),
					stack,
					map[string]any{
						"handler":  r.URL.Path,
						"endpoint": r.URL.Path,
					},
				)
				// Write a 500 if the response hasn't started yet. If the
				// handler already flushed headers (e.g. streaming SSE), we
				// can't do anything useful — the client will see the stream
				// truncated.
				defer func() { _ = recover() }() // guard against double-write
				writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "internal server error"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// lookupAPIKeyCache returns a cached ValidateKeyFull result if present and
// not expired. Returns false on miss or expiry.
func (s *Server) lookupAPIKeyCache(token string) (apiKeyCacheEntry, bool) {
	s.apiKeyCacheMu.RLock()
	entry, ok := s.apiKeyCache[token]
	gen := s.apiKeyCacheGen
	s.apiKeyCacheMu.RUnlock()
	// Miss on absence, TTL expiry, or a stale generation (a key mutation has
	// occurred since the entry was cached).
	if !ok || entry.gen != gen || time.Since(entry.cachedAt) > apiKeyCacheTTL {
		return apiKeyCacheEntry{}, false
	}
	return entry, true
}

// storeAPIKeyCache inserts an auth result into the cache, stamped with the
// current generation. If the cache is at capacity, the oldest entry is evicted.
func (s *Server) storeAPIKeyCache(token string, entry apiKeyCacheEntry) {
	s.apiKeyCacheMu.Lock()
	defer s.apiKeyCacheMu.Unlock()
	entry.gen = s.apiKeyCacheGen
	if len(s.apiKeyCache) >= apiKeyCacheMaxSize {
		var oldest string
		var oldestTime time.Time
		for k, v := range s.apiKeyCache {
			if oldest == "" || v.cachedAt.Before(oldestTime) {
				oldest = k
				oldestTime = v.cachedAt
			}
		}
		delete(s.apiKeyCache, oldest)
	}
	s.apiKeyCache[token] = entry
}

// invalidateAPIKeyCache removes a single key from the API key cache. Called
// when a key is revoked so stale positive results don't grant access.
func (s *Server) invalidateAPIKeyCache(token string) {
	s.apiKeyCacheMu.Lock()
	delete(s.apiKeyCache, token)
	s.apiKeyCacheMu.Unlock()
}

// invalidateAllAPIKeyCache atomically invalidates every cached auth result by
// bumping the cache generation (entries cached under an older generation are
// ignored). Called BEFORE and AFTER a by-ID key mutation (update/revoke/rotate)
// where we don't hold the raw token: the pre-bump drops any pre-existing entry,
// and the post-bump drops any entry a concurrent request re-cached from
// pre-commit state during the mutation — closing the read-stale race.
func (s *Server) invalidateAllAPIKeyCache() {
	s.apiKeyCacheMu.Lock()
	s.apiKeyCacheGen++
	s.apiKeyCache = make(map[string]apiKeyCacheEntry)
	s.apiKeyCacheMu.Unlock()
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
		// Check cache first to skip DB on repeat requests with the same key.
		var keyRec *store.APIKey
		if cached, ok := s.lookupAPIKeyCache(token); ok {
			keyRec = cached.key
		} else {
			// Cache miss — resolve the key (with its per-key limits) in one
			// query. A disabled/expired/unknown key returns an error and falls
			// through to the provider-token path below.
			if k, err := s.store.AuthenticateKey(token); err == nil {
				keyRec = k
				// Throttled last-used update: cache misses happen at most once
				// per TTL per active key, so this naturally rate-limits writes.
				if k.ID != "" {
					id := k.ID
					saferun.Go(s.logger, "touch_api_key", func() {
						s.store.TouchAPIKey(id, time.Now())
					})
				}
				// Unlinked legacy key: its identity used to be the raw bearer
				// token; it is now LegacyAccountID(token). Carry any balance from
				// the old raw-token identity to the new one so a pre-existing
				// funded legacy key doesn't suddenly read a zero balance. One-time
				// and a no-op once moved; runs only on a cache miss (≈ once per
				// TTL). The raw token is never logged.
				if k.OwnerAccountID == "" {
					if _, err := s.store.MigrateAccountBalance(token, store.LegacyAccountID(token)); err != nil {
						s.logger.Warn("legacy key balance migration failed", "error", err)
					}
				}
				// Cache the API-key result (positive or negative). Provider-token
				// fallbacks are deliberately NOT cached below.
				s.storeAPIKeyCache(token, apiKeyCacheEntry{key: keyRec, cachedAt: time.Now()})
			} else if pt, err := s.store.GetProviderToken(token); err == nil && pt != nil && pt.Active {
				// Provider device-login tokens authenticate as an account-scoped
				// identity with no per-key limits (ID left empty). These are NOT
				// cached: provider-token revocation has no api-key-cache
				// invalidation hook, so caching would let a revoked token live
				// until TTL. GetProviderToken is cheap and provider-token traffic
				// is low-volume.
				keyRec = &store.APIKey{OwnerAccountID: pt.AccountID}
			} else {
				// Unknown token — negative-cache to avoid hammering the DB.
				s.storeAPIKeyCache(token, apiKeyCacheEntry{key: nil, cachedAt: time.Now()})
			}
		}

		// Re-check time-based expiry / disable on the cache-hit path: a key can
		// expire while a positive entry is still within its TTL, and no mutation
		// event clears the cache on a time-based expiry.
		if keyRec != nil && (keyRec.Disabled || (keyRec.ExpiresAt != nil && time.Now().After(*keyRec.ExpiresAt))) {
			keyRec = nil
		}

		if keyRec == nil {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid API key"))
			return
		}

		// Resolve key → account. If the key is linked to a Privy account, use
		// that account ID and load the user. Unlinked legacy keys derive a
		// stable, non-secret identity (legacy:<sha256>) instead of using the raw
		// bearer token, so the secret never reaches balances.account_id, ledger
		// references, or logs.
		accountID := keyRec.OwnerAccountID
		ctx := r.Context()
		if accountID != "" {
			if user, err := s.store.GetUserByAccountID(accountID); err == nil {
				ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			}
		} else {
			accountID = store.LegacyAccountID(token)
		}

		ctx = context.WithValue(ctx, ctxKeyConsumer, accountID)
		ctx = context.WithValue(ctx, ctxKeyAPIKey, keyRec)
		next(w, r.WithContext(ctx))
	}
}

// requirePrivyAuth wraps a handler requiring a Privy JWT session. Unlike
// requireAuth, API keys are rejected. Use for sensitive account operations
// (key creation, device approval) that must not be triggerable by a leaked
// API key.
func (s *Server) requirePrivyAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := extractBearerToken(r)
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing credentials"))
			return
		}
		if s.privyAuth == nil || !strings.HasPrefix(token, "eyJ") {
			writeJSON(w, http.StatusForbidden, errorResponse("forbidden",
				"this endpoint requires an interactive session — API keys are not accepted"))
			return
		}
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
		// Per-key RPM override applies to inference (consumer) traffic and is
		// enforced regardless of whether the account-level limiter is set.
		if tier == "consumer" {
			if !s.applyKeyRPMLimit(w, r) {
				return
			}
		}
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
		// Service-role accounts (e.g. OpenRouter) get the elevated limiter (or
		// bypass when none is configured) — but ONLY on the consumer/inference
		// tier. Financial endpoints (deposits, withdrawals, key/invite/referral
		// mutations) keep their stricter limiter for every account, since those
		// are higher-value abuse targets regardless of role.
		if tier == "consumer" {
			if user := auth.UserFromContext(r.Context()); user != nil && user.Role == store.RoleService {
				if s.serviceRateLimiter == nil {
					next(w, r)
					return
				}
				rl = s.serviceRateLimiter
			}
		}
		if allowed, retryAfter := rl.Allow(accountID); !allowed {
			seconds := int(retryAfter.Seconds())
			if seconds < 1 {
				seconds = 1
			}
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(time.Now().Add(retryAfter).Unix(), 10))
			setRequestRateLimitHeaders(w, rl.Stat(accountID))
			s.ddIncr("ratelimit.rejections", []string{"tier:" + tier})
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				"too many requests — slow down and retry after the Retry-After interval", withCode("rate_limit_exceeded")))
			return
		}
		setRequestRateLimitHeaders(w, rl.Stat(accountID))
		next(w, r)
	}
}

// publicCORSPaths are endpoints whose GET is unauthenticated, read-only public
// data. Their GET is served with a wildcard CORS origin so the marketing site
// (darkbloom.dev) and any third party can read them from the browser. NOTE:
// some of these paths (e.g. /v1/pricing) ALSO serve authenticated PUT/DELETE —
// the wildcard applies only to GET; non-GET methods fall through to the
// credentialed, single-origin CORS below.
var publicCORSPaths = map[string]bool{
	"/v1/models/catalog": true,
	"/v1/pricing":        true,
	"/v1/stats":          true,
}

// corsMiddleware sets CORS headers. Authenticated/credentialed requests are
// locked to a single origin derived from the CORS_ORIGIN environment variable
// (defaulting to the production console domain); a wildcard is never used for
// those. A GET to a public read-only endpoint (see publicCORSPaths) is readable
// from any origin, without credentials, so a wildcard is safe and intended.
func (s *Server) corsMiddleware(next http.Handler) http.Handler {
	origin := s.corsOrigin
	if origin == "" {
		origin = "https://console.darkbloom.dev"
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Resolve the effective method: for a preflight, the actual request
		// method is in Access-Control-Request-Method (default GET if absent).
		effectiveMethod := r.Method
		if r.Method == http.MethodOptions {
			if reqMethod := r.Header.Get("Access-Control-Request-Method"); reqMethod != "" {
				effectiveMethod = reqMethod
			} else {
				effectiveMethod = http.MethodGet
			}
		}

		if publicCORSPaths[r.URL.Path] && effectiveMethod == http.MethodGet {
			// Public, non-credentialed GET — any origin may read it.
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.Header().Set("Vary", "Origin")
		} else {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		}

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// loggingMiddleware logs each request using slog and updates HTTP metrics.
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

		dur := time.Since(start)

		// Resolve the route pattern that matched (Go 1.22+ method+path).
		// Falls back to URL.Path when no pattern matched (404).
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}

		// User correlation: if requireAuth attached an account, include
		// it in the access log. Empty for unauthenticated paths.
		userID := consumerKeyFromContext(ctx)

		s.logger.Info("request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"route", route,
			"status", sw.status,
			"duration_ms", dur.Milliseconds(),
			"remote", r.RemoteAddr,
			"user_id", userID,
		)

		pathLabel := httpPathLabel(route)
		statusStr := strconvItoa(sw.status)

		if s.metrics != nil {
			s.metrics.IncCounter("http_requests_total",
				MetricLabel{"method", r.Method},
				MetricLabel{"path", pathLabel},
				MetricLabel{"status", statusStr},
			)
			s.metrics.ObserveHistogram("http_request_duration_ms",
				float64(dur.Milliseconds()),
				MetricLabel{"method", r.Method},
				MetricLabel{"path", pathLabel},
			)
		}

		// DogStatsD — emit request counter and latency histogram.
		if s.dd != nil {
			tags := []string{
				"method:" + r.Method,
				"path:" + pathLabel,
				"status_code:" + statusStr,
			}
			s.dd.Incr("http.requests", tags)
			s.dd.Histogram("http.latency_ms", float64(dur.Milliseconds()), tags)
		}
	})
}

// httpPathLabel returns a bounded label for HTTP metrics.
// We use the mux route pattern (e.g. "POST-/v1/chat/completions")
// instead of URL.Path so attacker-controlled unmatched paths cannot create
// unbounded metric cardinality. Dashes replace spaces so DogStatsD tags
// parse cleanly (spaces break tag parsing).
func httpPathLabel(route string) string {
	if route == "" {
		return "unmatched"
	}
	return strings.ReplaceAll(route, " ", "-")
}

// strconvItoa is a shim to avoid pulling strconv into every middleware file.
func strconvItoa(i int) string { return strconv.Itoa(i) }

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
	return nil, nil, errors.New("underlying ResponseWriter does not implement http.Hijacker")
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
