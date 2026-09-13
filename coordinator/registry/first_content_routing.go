package registry

import (
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	FirstContentRoutingOff    = "off"
	FirstContentRoutingShadow = "shadow"
	FirstContentRoutingPrefer = "prefer"
	firstContentFreshness     = 5 * time.Second
	firstContentHandoffMs     = 1000.0
	// A policy allowance for early decode/detokenization, not a reconstruction
	// of the provider's scheduler or a bound on reasoning before visible text.
	firstContentDecodeAllowance = 33
)

// FirstContentEstimate is an advisory service-time estimate. Feasible means
// the estimate fits this attempt's remaining clock, never guaranteed admission
// or completion. Unknown candidates remain available as fallbacks.
type FirstContentEstimate struct {
	Status       string  `json:"status"`
	Reason       string  `json:"reason,omitempty"`
	PredictedMs  float64 `json:"predicted_ms,omitempty"`
	BudgetMs     float64 `json:"budget_ms,omitempty"`
	PromptTokens int     `json:"prompt_tokens,omitempty"`
	CachedTokens float64 `json:"cached_tokens,omitempty"`
	RestoreMs    float64 `json:"restore_ms,omitempty"`
}

func normalizeFirstContentRoutingMode(mode string) (string, error) {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "" {
		mode = FirstContentRoutingOff
	}
	switch mode {
	case FirstContentRoutingOff, FirstContentRoutingShadow, FirstContentRoutingPrefer:
		return mode, nil
	default:
		return "", fmt.Errorf("registry: invalid first content routing mode %q", mode)
	}
}

// ConfigureFirstContentRouting changes preference only, never eligibility.
func (r *Registry) ConfigureFirstContentRouting(mode string) error {
	mode, err := normalizeFirstContentRoutingMode(mode)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.firstContentRoutingMode = mode
	r.mu.Unlock()
	return nil
}

// firstContentIdleSlot requires explicit measurements, including for other
// resident models: their work competes for the same GPU. A missing counter is
// unknown, not zero. This deliberately excludes loading and partially prefilled
// work whose remaining cost cannot be reconstructed from a heartbeat.
func firstContentIdleSlot(s protocol.BackendSlotCapacity) bool {
	t := s.Telemetry
	return s.State == "idle" && s.NumRunning == 0 && s.NumWaiting == 0 &&
		s.EvalInFlightMs == 0 && s.IdleClearInFlightMs == 0 && !s.WedgeSuspected &&
		t != nil && t.QueuedPrefillTokens != nil && *t.QueuedPrefillTokens == 0 &&
		t.PartialPrefillRows != nil && *t.PartialPrefillRows == 0
}

// estimateFirstContent uses copied values only, with no extra clock, lock,
// tokenizer, RPC, or calibration lookup per candidate. Caller holds r.mu.
func (r *Registry) estimateFirstContent(c *routingCandidate, pr *PendingRequest, now time.Time) {
	c.firstContent = FirstContentEstimate{}
	if r.firstContentRoutingMode == "" || r.firstContentRoutingMode == FirstContentRoutingOff {
		return
	}
	e := FirstContentEstimate{Status: "unknown"}
	defer func() { c.firstContent = e }()
	if pr.FirstContentDeadline.IsZero() {
		e.Reason = "no_deadline"
		return
	}
	e.BudgetMs = math.Max(0, float64(pr.FirstContentDeadline.Sub(now))/float64(time.Millisecond))
	if pr.RequiresVision {
		e.Reason = "vision"
		return
	}
	s := &c.snapshot
	if !s.modelLoaded {
		e.Reason = "cold"
		return
	}
	if s.hbAgeMs < 0 || time.Duration(s.hbAgeMs)*time.Millisecond > firstContentFreshness {
		e.Reason = "stale"
		return
	}
	if !s.firstContentIdle || s.totalPending != 0 {
		e.Reason = "work_unknown"
		return
	}
	if !s.isolatedPrefillInitialized || !finitePositive(s.isolatedPrefillTPS) || !finitePositive(s.observedDecodeTPS) {
		e.Reason = "unmeasured"
		return
	}
	prompt := pr.FirstContentPromptTokens
	if prompt <= 0 {
		prompt = pr.EstimatedPromptTokens
	}
	// Route derivation supplies exact tokens only for a live, authenticated
	// prompt contract. Affinity and repeated-prefix demand never supply credit.
	if r.cacheRouting != nil && pr.CachePlan.generation == r.cacheRouting.generation &&
		pr.CachePlan.generation != nil && !pr.CachePlan.generation.revoked.Load() && pr.CachePlan.present() {
		prompt = pr.CachePlan.PromptTokenCount
	}
	if prompt <= 0 {
		e.Reason = "prompt_unknown"
		return
	}
	e.PromptTokens = prompt
	if now.Before(c.firstContentCacheExpiresAt) {
		e.CachedTokens = math.Min(float64(prompt), c.firstContentCachedTokens) * c.firstContentCacheWeight
		e.RestoreMs = c.firstContentRestoreMs
	}
	decode := min(max(1, pr.RequestedMaxTokens), firstContentDecodeAllowance)
	// Match the provider admission rate haircut without using the completion-
	// trained TTFT ratio. Cache work was validated under p.mu and is charged at
	// this rate, independently of the ordinary ranking discount/caps.
	e.PredictedMs = (float64(prompt)-e.CachedTokens)/(s.isolatedPrefillTPS*0.5)*1000 +
		float64(decode)/(s.observedDecodeTPS*0.5)*1000 + e.RestoreMs + firstContentHandoffMs
	if !finitePositive(e.PredictedMs) {
		e.PredictedMs = 0
		e.Reason = "unmeasured"
		return
	}
	e.Status = "infeasible"
	if e.PredictedMs <= e.BudgetMs {
		e.Status = "feasible"
	}
}

func applyFirstContentDecision(d *RoutingDecision, c *routingCandidate, mode string) {
	if mode == "" || mode == FirstContentRoutingOff {
		return
	}
	d.FirstContentMode = mode
	d.FirstContent = c.firstContent
	if !d.Top[0].Present {
		d.Top[0] = candidateSummaryOf(c)
	}
	// Keep the persisted winner's estimate at the commit-time clock.
	for i := range d.Top {
		if d.Top[i].ProviderID == c.provider.ID {
			d.Top[i].FirstContent = c.firstContent
		}
	}
}

// preferFirstContentPool preserves owner scope, fallback identities and scan diagnostics.
// Caller holds r.mu.
func (r *Registry) preferFirstContentPool(scan *candidateScan, pool []*routingCandidate) []*routingCandidate {
	// Retain fallback identities for retries before advisory/soft preferences.
	// No candidate becomes a rejection solely because this estimate misses.
	if r.firstContentRoutingMode == FirstContentRoutingPrefer {
		scan.planPool = append([]*routingCandidate(nil), pool...)
	}
	for _, c := range pool {
		if c.firstContent.Status == "feasible" {
			scan.firstContentFeasibleCount++
			best := scan.firstContentBestFeasible
			if !best.Present || c.costMs < best.CostMs || (c.costMs == best.CostMs && c.provider.ID < best.ProviderID) {
				scan.firstContentBestFeasible = candidateSummaryOf(c)
			}
		}
	}
	if r.firstContentRoutingMode == FirstContentRoutingPrefer {
		pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool { return c.firstContent.Status == "feasible" })
	}

	return pool
}

// fillFirstContentSnapshot copies optional telemetry during the existing provider
// snapshot. Callers hold r.mu and p.mu; no telemetry pointers escape the lock.
func (r *Registry) fillFirstContentSnapshot(snap *routingSnapshot, capacity *protocol.BackendCapacity) {
	if r.firstContentRoutingMode != "" && r.firstContentRoutingMode != FirstContentRoutingOff {
		snap.firstContentIdle = len(capacity.Slots) > 0
		for _, slot := range capacity.Slots {
			snap.firstContentIdle = snap.firstContentIdle && firstContentIdleSlot(slot)
			if slot.Model == snap.model && slot.Telemetry != nil {
				t := slot.Telemetry
				if t.IsolatedPrefillTPS != nil {
					snap.isolatedPrefillTPS = *t.IsolatedPrefillTPS
				}
				snap.isolatedPrefillInitialized = t.EWMAInitialized != nil && *t.EWMAInitialized
			}
		}
	}
}
