package inference

import (
	_ "embed"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// SetTokenLimiters configures the per-account input/output token-per-minute
// limiters for the consumer and service tiers. Pass nil for a tier to disable
// token limiting for it.
func (s *Owner) SetTokenLimiters(consumer, service *ratelimit.TokenLimiter) {
	s.consumerTokenLimiter = consumer
	s.serviceTokenLimiter = service
}

func (s *Owner) SetOutputAdmissionEstimator(estimator *ratelimit.OutputAdmissionEstimator) {
	s.outputAdmissionEstimator = estimator
}

// SetKeyLimiters configures the per-key (variable-rate) RPM and ITPM/OTPM
// limiters used for per-key overrides. Pass nil to disable per-key limiting.
func (s *Owner) SetKeyLimiters(rpm *ratelimit.Limiter, tokens *ratelimit.KeyTokenLimiter) {
	s.access.SetKeyRPMLimiter(rpm)
	s.keyTokenLimiter = tokens
}

// applyTokenRateLimit enforces per-account ITPM/OTPM limits at request
// admission using the upfront input estimate and the bounded max_tokens
// (OpenAI-style upfront charge). It returns true when the request may proceed;
// on rejection it writes a 429 naming the tripped dimension (with Retry-After)
// and returns false. Admin bypasses. Standard x-ratelimit-*-{input,output}-tokens
// headers are set on both success and rejection.
func (s *Owner) applyTokenRateLimit(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) bool {
	_, ok := s.applyTokenRateLimitWithAdmission(w, r, inputTokens, outputTokens)
	return ok
}

func (s *Owner) applyTokenRateLimitWithAdmission(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) (registry.TokenAdmission, bool) {
	admission := registry.TokenAdmission{AdmittedOutputTokens: outputTokens}
	accountID := access.ConsumerKeyFromContext(r.Context())
	if accountID == "admin" {
		return admission, true
	}

	// Resolve the account-tier token limiter (nil = no account-level token limit
	// for this caller, e.g. a service account with no service token limiter).
	tl := s.consumerTokenLimiter
	tier := "consumer"
	serviceAccount := false
	if user := auth.UserFromContext(r.Context()); user != nil && user.Role == store.RoleService {
		serviceAccount = true
		tier = "service"
		if s.serviceTokenLimiter != nil {
			tl = s.serviceTokenLimiter
		} else {
			tl = nil
		}
	}
	admission.AccountTier = tier
	if serviceAccount {
		if estimatedOutput, estimated := s.outputAdmissionEstimator.Estimate(outputTokens); estimated {
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
		s.observation.Histogram("ratelimit.output_admission.estimated_tokens", float64(admission.AdmittedOutputTokens), outputAdmissionTags(tier, admission.EstimatedOutput))
	}

	// Peek BOTH the per-key override and the account-level limiter before
	// consuming either. Only commit when both have capacity, so a rejection in
	// one limiter never debits the other (a per-key request that the account
	// bucket rejects must not drain the key's quota, and vice-versa).
	if keyEnforced {
		if ok, dim, retry := s.keyTokenLimiter.Peek(keyID, inputTokens, admission.AdmittedOutputTokens, inRPS, inBurst, outRPS, outBurst); !ok {
			s.access.WriteTokenRateLimited(w, "key", dim, retry)
			return admission, false
		}
	}
	if tl != nil {
		if ok, dim, retry := tl.Peek(accountID, inputTokens, admission.AdmittedOutputTokens); !ok {
			setTokenRateLimitHeaders(w, tl, accountID)
			s.access.WriteTokenRateLimited(w, tier, dim, retry)
			return admission, false
		}
	}

	// Both dimensions have capacity — commit to each.
	if keyEnforced {
		s.keyTokenLimiter.Commit(keyID, inputTokens, admission.AdmittedOutputTokens, inRPS, inBurst, outRPS, outBurst)
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

func (s *Owner) reconcileOutputAdmission(pr *registry.PendingRequest, actualOutputTokens int) {
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
	s.observation.Histogram("ratelimit.output_admission.actual_tokens", float64(actualOutputTokens), tags)
	s.observation.Histogram("ratelimit.output_admission.delta_tokens", float64(delta), tags)
	if delta == 0 {
		return
	}
	if admission.AccountOutputLimited {
		var tl *ratelimit.TokenLimiter
		switch admission.AccountTier {
		case "service":
			tl = s.serviceTokenLimiter
		default:
			tl = s.consumerTokenLimiter
		}
		if tl != nil {
			tl.DebitOutput(pr.ConsumerKey, delta)
		}
	}
	if admission.KeyOutputLimited && s.keyTokenLimiter != nil {
		s.keyTokenLimiter.DebitOutput(pr.KeyID, delta, admission.KeyOutputRPS, admission.KeyOutputBurst)
	}
	s.observation.Count("ratelimit.output_admission.delta_tokens_total", int64(delta), tags)
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
func (s *Owner) keyTokenParams(r *http.Request) (keyID string, inRPS float64, inBurst int, outRPS float64, outBurst int, enforced bool) {
	if s.keyTokenLimiter == nil {
		return "", 0, 0, 0, 0, false
	}
	k := access.APIKeyFromContext(r.Context())
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

// SetTTFTHardReject toggles the per-request TTFT admission ceiling between a
// hard 429 (true, legacy) and a soft routing preference (false, default). See
// the ttftHardReject field for rationale. Call before serving starts.
func (s *Owner) SetTTFTHardReject(enabled bool) {
	s.ttftHardReject = enabled
}

// SetRejectModels sets the requested/resolved model IDs to 429 at public
// admission. Call before serving starts.
func (s *Owner) SetRejectModels(models map[string]bool) {
	if len(models) == 0 {
		s.rejectModels = nil
		return
	}
	copy := make(map[string]bool, len(models))
	for model, reject := range models {
		if !reject {
			continue
		}
		model = strings.TrimSpace(model)
		if model == "" {
			continue
		}
		copy[model] = true
	}
	if len(copy) == 0 {
		s.rejectModels = nil
		return
	}
	s.rejectModels = copy
}

func (s *Owner) modelShed(resolved, requested string) bool {
	if len(s.rejectModels) == 0 {
		return false
	}
	return s.rejectModels[resolved] || s.rejectModels[requested]
}

// SetMinDecodeTPS sets the per-request sustained-decode floor (tokens/sec) the
// scheduler uses as a soft routing preference. <= 0 disables it. See the
// minDecodeTPS field. Call before serving starts.
func (s *Owner) SetMinDecodeTPS(tps float64) {
	if tps < 0 {
		tps = 0
	}
	s.minDecodeTPS = tps
}

// DefaultRoutingConcurrency is the built-in routing-scan semaphore capacity:
// one scan per CPU (a scan is pure CPU under the registry read lock), floored
// at 2 so a tiny container never serializes routing entirely. Exported so
// main.go can log the effective default alongside the env override.
func DefaultRoutingConcurrency() int {
	n := runtime.NumCPU()
	if n < 2 {
		n = 2
	}
	return n
}

// SetRoutingConcurrency replaces the routing-scan semaphore with one of the
// given capacity (EIGENINFERENCE_ROUTING_CONCURRENCY). Values < 2 clamp to 2.
// Call before serving starts — replacing the channel while scans are in
// flight would strand slots.
func (s *Owner) SetRoutingConcurrency(n int) {
	if n < 2 {
		n = 2
	}
	s.routingScanSem = make(chan struct{}, n)
}

// scanSlotResult is the outcome of acquireRoutingScanSlot. Client
// disconnection is distinguished from acquisition timeout so callers route a
// vanished caller onto the existing client-gone terminal (cancelled outcome,
// refund, no response body) and NEVER onto the routing_saturated 429 /
// rejection-ledger path.
type scanSlotResult int

const (
	scanSlotAcquired scanSlotResult = iota
	scanSlotTimeout
	scanSlotClientGone
)

// acquireRoutingScanSlot blocks until a provider-selection scan slot is free,
// the wait budget elapses, or done fires (client gone). On scanSlotTimeout the
// caller sheds the attempt as capacity-shaped (errRoutingScanSaturated)
// instead of piling another scan onto saturated CPUs; on scanSlotClientGone it
// takes its ordinary client-gone path. A nil semaphore (a &Server{} built
// directly in tests) admits immediately, preserving legacy behavior for bare
// fixtures; a nil done channel never fires.
func (s *Owner) acquireRoutingScanSlot(wait time.Duration, done <-chan struct{}) scanSlotResult {
	if s.routingScanSem == nil {
		return scanSlotAcquired
	}
	select {
	case s.routingScanSem <- struct{}{}:
		return scanSlotAcquired
	default:
	}
	clientGone := func() bool {
		select {
		case <-done:
			return true
		default:
			return false
		}
	}
	if wait <= 0 {
		if clientGone() {
			return scanSlotClientGone
		}
		return scanSlotTimeout
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case s.routingScanSem <- struct{}{}:
		return scanSlotAcquired
	case <-timer.C:
		if clientGone() {
			return scanSlotClientGone
		}
		return scanSlotTimeout
	case <-done:
		return scanSlotClientGone
	}
}

// releaseRoutingScanSlot returns a slot taken by acquireRoutingScanSlot.
func (s *Owner) releaseRoutingScanSlot() {
	if s.routingScanSem == nil {
		return
	}
	<-s.routingScanSem
}

// SetServabilityGate toggles the smart early-429 admission gate. See the
// servabilityGate field. Call before serving starts.
func (s *Owner) SetServabilityGate(enabled bool) {
	s.servabilityGate = enabled
}

// SetDisableClientErrorStop is the kill switch for the C1 client-shape failover
// stop. true restores pre-fix behavior (deterministic provider 4xx fails over up
// to maxDispatchAttempts). Default (false) = stop enabled. Call before serving.
func (s *Owner) SetDisableClientErrorStop(disabled bool) {
	s.disableClientErrorStop = disabled
}

// SetLongPromptThreshold configures the estimated-prompt-token count at/above
// which the scheduler applies the long-prompt fastest-tier routing preference.
// 0 disables it (behavior-neutral). It is a package-level scheduler knob (like
// the prefill/decode ratio), so this delegates to the registry. Call before
// serving starts. SOFT bias only — no TTFT 429 is introduced.
func (s *Owner) SetLongPromptThreshold(tokens int) {
	registry.SetLongPromptThreshold(tokens)
}

// SetLongPromptPrefillWeight configures the prefill-term multiplier the scheduler
// applies to long prompts. Values < 1 clamp to 1.0 (no amplification).
// Delegates to the registry; call before serving starts.
func (s *Owner) SetLongPromptPrefillWeight(weight float64) {
	registry.SetLongPromptPrefillWeight(weight)
}

// SetCoordinatorKey installs the X25519 keypair the coordinator publishes
// for sender-to-coordinator request encryption. Pass nil to disable.
func (s *Owner) SetCoordinatorKey(k *e2e.CoordinatorKey) {
	s.coordinatorKey = k
}
