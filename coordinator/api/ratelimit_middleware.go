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

// applyTokenRateLimit enforces per-account ITPM/OTPM limits at request
// admission using the upfront input estimate and the bounded max_tokens
// (OpenAI-style upfront charge). It returns true when the request may proceed;
// on rejection it writes a 429 naming the tripped dimension (with Retry-After)
// and returns false. Admin bypasses. Standard x-ratelimit-*-{input,output}-tokens
// headers are set on both success and rejection.
func (s *Server) applyTokenRateLimit(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) bool {
	accountID := consumerKeyFromContext(r.Context())
	if accountID == "admin" {
		return true
	}

	// Resolve the account-tier token limiter (nil = no account-level token limit
	// for this caller, e.g. a service account with no service token limiter).
	tl := s.consumerTokenLimiter
	tier := "consumer"
	if user := auth.UserFromContext(r.Context()); user != nil && user.Role == store.RoleService {
		if s.serviceTokenLimiter != nil {
			tl = s.serviceTokenLimiter
			tier = "service"
		} else {
			tl = nil
		}
	}

	keyID, inRPS, inBurst, outRPS, outBurst, keyEnforced := s.keyTokenParams(r)

	// Peek BOTH the per-key override and the account-level limiter before
	// consuming either. Only commit when both have capacity, so a rejection in
	// one limiter never debits the other (a per-key request that the account
	// bucket rejects must not drain the key's quota, and vice-versa).
	if keyEnforced {
		if ok, dim, retry := s.keyTokenLimiter.Peek(keyID, inputTokens, outputTokens, inRPS, inBurst, outRPS, outBurst); !ok {
			s.writeTokenRateLimited(w, "key", dim, retry)
			return false
		}
	}
	if tl != nil {
		if ok, dim, retry := tl.Peek(accountID, inputTokens, outputTokens); !ok {
			setTokenRateLimitHeaders(w, tl, accountID)
			s.writeTokenRateLimited(w, tier, dim, retry)
			return false
		}
	}

	// Both dimensions have capacity — commit to each.
	if keyEnforced {
		s.keyTokenLimiter.Commit(keyID, inputTokens, outputTokens, inRPS, inBurst, outRPS, outBurst)
	}
	if tl != nil {
		tl.Commit(accountID, inputTokens, outputTokens)
		setTokenRateLimitHeaders(w, tl, accountID)
	}
	return true
}

// writeTokenRateLimited writes a 429 for a token-dimension rejection with a
// Retry-After header and a dimension-specific message. tier is "consumer",
// "service", or "key".
func (s *Server) writeTokenRateLimited(w http.ResponseWriter, tier, dimension string, retryAfter time.Duration) {
	seconds := int(retryAfter.Seconds())
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	s.ddIncr("ratelimit.rejections", []string{"tier:" + tier, "dimension:" + dimension})
	msg := fmt.Sprintf("%s rate limit exceeded — retry after %ds", dimension, seconds)
	if tier == "key" {
		msg = fmt.Sprintf("API key %s rate limit exceeded — retry after %ds", dimension, seconds)
	}
	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded", msg, withCode("rate_limit_exceeded")))
}

// setTokenRateLimitHeaders emits the standard input/output token rate-limit
// headers from the limiter's current state.
func setTokenRateLimitHeaders(w http.ResponseWriter, tl *ratelimit.TokenLimiter, accountID string) {
	h := w.Header()
	if in, ok := tl.InputStat(accountID); ok {
		h.Set("x-ratelimit-limit-input-tokens", strconv.Itoa(in.LimitPerMinute))
		h.Set("x-ratelimit-remaining-input-tokens", strconv.Itoa(in.Remaining))
		h.Set("x-ratelimit-reset-input-tokens", strconv.Itoa(in.ResetSeconds)+"s")
	}
	if out, ok := tl.OutputStat(accountID); ok {
		h.Set("x-ratelimit-limit-output-tokens", strconv.Itoa(out.LimitPerMinute))
		h.Set("x-ratelimit-remaining-output-tokens", strconv.Itoa(out.Remaining))
		h.Set("x-ratelimit-reset-output-tokens", strconv.Itoa(out.ResetSeconds)+"s")
	}
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

// keyTokenParams resolves the per-key ITPM/OTPM override for the calling key.
// enforced is false when no per-key token limit applies (no key, no limiter, or
// no override set), in which case the other return values are zero.
func (s *Server) keyTokenParams(r *http.Request) (keyID string, inRPS float64, inBurst int, outRPS float64, outBurst int, enforced bool) {
	if s.keyTokenLimiter == nil {
		return "", 0, 0, 0, 0, false
	}
	k := apiKeyFromContext(r.Context())
	if k == nil || k.ID == "" {
		return "", 0, 0, 0, 0, false
	}
	if k.ITPMLimit != nil && *k.ITPMLimit > 0 {
		inRPS = float64(*k.ITPMLimit) / 60.0
		inBurst = int(*k.ITPMLimit)
	}
	if k.OTPMLimit != nil && *k.OTPMLimit > 0 {
		outRPS = float64(*k.OTPMLimit) / 60.0
		outBurst = int(*k.OTPMLimit)
	}
	if inRPS <= 0 && outRPS <= 0 {
		return "", 0, 0, 0, 0, false
	}
	return k.ID, inRPS, inBurst, outRPS, outBurst, true
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
