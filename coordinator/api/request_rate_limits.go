package api

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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

// SetServiceRateLimiter configures the elevated limiter used for service-role
// accounts (e.g. OpenRouter). Pass nil to let service accounts bypass limits.
func (s *Server) SetServiceRateLimiter(rl *ratelimit.Limiter) {
	s.serviceRateLimiter = rl
}

// applyKeyRPMLimit enforces a per-key requests-per-minute override when the
// authenticated key sets RPMLimit. Returns true (allow) when no key override
// applies. On rejection it writes a 429 with Retry-After and returns false.
func (s *Server) applyKeyRPMLimit(w http.ResponseWriter, r *http.Request) bool {
	if s.keyRPMLimiter == nil {
		return true
	}
	k := apiKeyFromContext(r.Context())
	if k == nil || k.ID == "" || k.RPMLimit == nil || *k.RPMLimit <= 0 {
		return true
	}
	rpm := *k.RPMLimit
	burst := int(rpm)
	if burst < 1 {
		burst = 1
	}
	allowed, retryAfter := s.keyRPMLimiter.AllowNWithRate(k.ID, 1, float64(rpm)/60.0, burst)
	if !allowed {
		seconds := int(retryAfter.Seconds())
		if seconds < 1 {
			seconds = 1
		}
		w.Header().Set("Retry-After", strconv.Itoa(seconds))
		s.ddIncr("ratelimit.rejections", []string{"tier:key", "dimension:requests"})
		writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
			fmt.Sprintf("API key request rate limit exceeded — retry after %ds", seconds),
			withCode("rate_limit_exceeded")))
		return false
	}
	return true
}

// setRequestRateLimitHeaders emits the standard request-dimension rate-limit
// headers.
func setRequestRateLimitHeaders(w http.ResponseWriter, st ratelimit.Stat) {
	h := w.Header()
	h.Set("x-ratelimit-limit-requests", strconv.Itoa(st.LimitPerMinute))
	h.Set("x-ratelimit-remaining-requests", strconv.Itoa(st.Remaining))
	h.Set("x-ratelimit-reset-requests", strconv.Itoa(st.ResetSeconds)+"s")
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
func (s *Server) rateLimiterFn() *ratelimit.Limiter { return s.rateLimiter }

func (s *Server) financialRateLimiterFn() *ratelimit.Limiter { return s.financialRateLimiter }

func (s *Server) rateLimitWith(getLimiter func() *ratelimit.Limiter, next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(getLimiter, "consumer", next)
}

// rateLimitWithTier is the actual implementation; callers thread a label
// for the metrics counter so we can distinguish consumer vs financial
// rejections in dashboards.
func (s *Server) rateLimitWithTier(getLimiter func() *ratelimit.Limiter, tier string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		setOutcomeStage(r, "rate_limit")
		// Per-key RPM override applies to inference (consumer) traffic and is
		// enforced regardless of whether the account-level limiter is set.
		if tier == "consumer" {
			if !s.applyKeyRPMLimit(w, r) {
				return
			}
		}
		rl := getLimiter()
		if rl == nil {
			stampRateLimit(r)
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
		stampRateLimit(r)
		next(w, r)
	}
}
