package ingress

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// applyTokenRateLimit enforces per-account ITPM/OTPM limits at request
// admission using the upfront input estimate and the bounded max_tokens
// (OpenAI-style upfront charge). It returns true when the request may proceed;
// on rejection it writes a 429 naming the tripped dimension (with Retry-After)
// and returns false. Admin bypasses. Standard x-ratelimit-*-{input,output}-tokens
// headers are set on both success and rejection.
func (s *Controller) applyTokenRateLimit(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) bool {
	_, ok := s.applyTokenRateLimitWithAdmission(w, r, inputTokens, outputTokens)
	return ok
}

func (s *Controller) applyTokenRateLimitWithAdmission(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) (registry.TokenAdmission, bool) {
	admission := registry.TokenAdmission{AdmittedOutputTokens: outputTokens}
	accountID := requestcontext.AccountID(r.Context())
	if accountID == "admin" {
		return admission, true
	}

	// Resolve the account-tier token limiter (nil = no account-level token limit
	// for this caller, e.g. a service account with no service token limiter).
	tl := s.deps.ConsumerTokens()
	tier := "consumer"
	serviceAccount := false
	if user := auth.UserFromContext(r.Context()); user != nil && user.Role == store.RoleService {
		serviceAccount = true
		tier = "service"
		if s.deps.ServiceTokens() != nil {
			tl = s.deps.ServiceTokens()
		} else {
			tl = nil
		}
	}
	admission.AccountTier = tier
	if serviceAccount {
		if estimatedOutput, estimated := s.deps.OutputAdmissionEstimator().Estimate(outputTokens); estimated {
			admission.AdmittedOutputTokens = estimatedOutput
			admission.EstimatedOutput = true
		}
	}

	keyID, inRPS, inBurst, outRPS, outBurst, keyEnforced := s.keyTokenParams(r)
	admission.AccountOutputLimited = tl != nil && tl.HasOutputLimit()
	admission.KeyOutputLimited = keyEnforced && outRPS > 0 && outBurst > 0
	admission.KeyOutputRPS = outRPS
	admission.KeyOutputBurst = outBurst
	if admission.TracksOutput() {
		s.deps.Metrics.Histogram("ratelimit.output_admission.estimated_tokens", float64(admission.AdmittedOutputTokens), outputAdmissionTags(tier, admission.EstimatedOutput))
	}

	// Peek BOTH the per-key override and the account-level limiter before
	// consuming either. Only commit when both have capacity, so a rejection in
	// one limiter never debits the other (a per-key request that the account
	// bucket rejects must not drain the key's quota, and vice-versa).
	if keyEnforced {
		if ok, dim, retry := s.deps.KeyTokens().Peek(keyID, inputTokens, admission.AdmittedOutputTokens, inRPS, inBurst, outRPS, outBurst); !ok {
			s.WriteTokenRateLimited(w, "key", dim, retry)
			return admission, false
		}
	}
	if tl != nil {
		if ok, dim, retry := tl.Peek(accountID, inputTokens, admission.AdmittedOutputTokens); !ok {
			setTokenRateLimitHeaders(w, tl, accountID)
			s.WriteTokenRateLimited(w, tier, dim, retry)
			return admission, false
		}
	}

	// Both dimensions have capacity — commit to each.
	if keyEnforced {
		s.deps.KeyTokens().Commit(keyID, inputTokens, admission.AdmittedOutputTokens, inRPS, inBurst, outRPS, outBurst)
	}
	if tl != nil {
		tl.Commit(accountID, inputTokens, admission.AdmittedOutputTokens)
		setTokenRateLimitHeaders(w, tl, accountID)
	}
	return admission, true
}

func outputAdmissionTags(tier string, estimated bool) []string {
	if tier == "" {
		tier = "none"
	}
	return []string{"tier:" + tier, "estimated:" + strconv.FormatBool(estimated)}
}

func (s *Controller) ReconcileOutputAdmission(pr *registry.PendingRequest, actualOutputTokens int) {
	if pr == nil || !pr.TokenAdmission.TracksOutput() {
		return
	}
	admission := pr.TokenAdmission
	if actualOutputTokens < 0 {
		actualOutputTokens = 0
	}
	admittedOutputTokens := admission.AdmittedOutputTokens
	if admittedOutputTokens < 0 {
		admittedOutputTokens = 0
	}
	delta := actualOutputTokens - admittedOutputTokens
	if delta < 0 {
		delta = 0
	}
	tags := append(outputAdmissionTags(admission.AccountTier, admission.EstimatedOutput), "model:"+pr.Model)
	s.deps.Metrics.Histogram("ratelimit.output_admission.actual_tokens", float64(actualOutputTokens), tags)
	s.deps.Metrics.Histogram("ratelimit.output_admission.delta_tokens", float64(delta), tags)
	if delta == 0 {
		return
	}
	if admission.AccountOutputLimited {
		var tl *ratelimit.TokenLimiter
		switch admission.AccountTier {
		case "service":
			tl = s.deps.ServiceTokens()
		default:
			tl = s.deps.ConsumerTokens()
		}
		if tl != nil {
			tl.DebitOutput(pr.ConsumerKey, delta)
		}
	}
	if admission.KeyOutputLimited && s.deps.KeyTokens() != nil {
		s.deps.KeyTokens().DebitOutput(pr.KeyID, delta, admission.KeyOutputRPS, admission.KeyOutputBurst)
	}
	s.deps.Metrics.Count("ratelimit.output_admission.delta_tokens_total", int64(delta), tags)
}

// writeTokenRateLimited writes a 429 for a token-dimension rejection with a
// Retry-After header and a dimension-specific message. tier is "consumer",
// "service", or "key".
func (s *Controller) WriteTokenRateLimited(w http.ResponseWriter, tier, dimension string, retryAfter time.Duration) {
	seconds := int(retryAfter.Seconds())
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	s.deps.Metrics.Incr("ratelimit.rejections", []string{"tier:" + tier, "dimension:" + dimension})
	msg := fmt.Sprintf("%s rate limit exceeded — retry after %ds", dimension, seconds)
	if tier == "key" {
		msg = fmt.Sprintf("API key %s rate limit exceeded — retry after %ds", dimension, seconds)
	}
	httpresponse.WriteJSON(w, http.StatusTooManyRequests, httpresponse.ErrorBody("rate_limit_exceeded", msg, httpresponse.WithCode("rate_limit_exceeded")))
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

// keyTokenParams resolves the per-key ITPM/OTPM override for the calling key.
// enforced is false when no per-key token limit applies (no key, no limiter, or
// no override set), in which case the other return values are zero.
func (s *Controller) keyTokenParams(r *http.Request) (keyID string, inRPS float64, inBurst int, outRPS float64, outBurst int, enforced bool) {
	if s.deps.KeyTokens() == nil {
		return "", 0, 0, 0, 0, false
	}
	k := requestcontext.APIKey(r.Context())
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
