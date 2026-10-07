package inference

import (
	_ "embed"
	"runtime"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/scangate"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
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
	if s.scanGate == nil {
		s.scanGate = scangate.New(n)
	} else {
		s.scanGate.Configure(n)
	}
}

// scanSlotResult is the outcome of acquireRoutingScanSlot. Client
// disconnection is distinguished from acquisition timeout so callers route a
// vanished caller onto the existing client-gone terminal (cancelled outcome,
// refund, no response body) and NEVER onto the routing_saturated 429 /
// rejection-ledger path.
type scanSlotResult = scangate.Result

const (
	scanSlotAcquired   = scangate.Acquired
	scanSlotTimeout    = scangate.Timeout
	scanSlotClientGone = scangate.ClientGone
)

// acquireRoutingScanSlot blocks until a provider-selection scan slot is free,
// the wait budget elapses, or done fires (client gone). On scanSlotTimeout the
// caller sheds the attempt as capacity-shaped (errRoutingScanSaturated)
// instead of piling another scan onto saturated CPUs; on scanSlotClientGone it
// takes its ordinary client-gone path. A nil semaphore (a &Server{} built
// directly in tests) admits immediately, preserving legacy behavior for bare
// fixtures; a nil done channel never fires.
func (s *Owner) acquireRoutingScanSlot(wait time.Duration, done <-chan struct{}) scanSlotResult {
	return s.scanGate.Acquire(wait, done)
}

// releaseRoutingScanSlot returns a slot taken by acquireRoutingScanSlot.
func (s *Owner) releaseRoutingScanSlot() {
	s.scanGate.Release()
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
