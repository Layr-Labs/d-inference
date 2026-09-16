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

	keyLimits := s.keyTokenLimits(r)
	admission.AccountOutputLimited = tl != nil && tl.HasOutputLimit()
	if keyLimits != nil {
		admission.KeyOutputLimited = keyLimits.outputRPS > 0 && keyLimits.outputBurst > 0
		admission.KeyOutputRPS = keyLimits.outputRPS
		admission.KeyOutputBurst = keyLimits.outputBurst
	}
	if admission.TracksOutput() {
		s.deps.Metrics.Histogram("ratelimit.output_admission.estimated_tokens", float64(admission.AdmittedOutputTokens), outputAdmissionTags(tier, admission.EstimatedOutput))
	}

	deniedTier, dimension, retry := s.admitTokenBuckets(accountID, tl, keyLimits, inputTokens, admission.AdmittedOutputTokens)
	if dimension != "" {
		if deniedTier == "account" {
			deniedTier = tier
			setTokenRateLimitHeaders(w, tl, accountID)
		}
		s.WriteTokenRateLimited(w, deniedTier, dimension, retry)
		return admission, false
	}
	if tl != nil {
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
	s.debitAdmissionOutput(pr, delta)
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
