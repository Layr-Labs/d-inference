package registry

import (
	"encoding/binary"
	"math"
	"sync"
	"time"
)

const cacheActivationBucketCount = uint64(1_000_000)

type cacheActivationDecision string

const (
	cacheActivationAdmitted   cacheActivationDecision = "admitted"
	cacheActivationSampledOut cacheActivationDecision = "sampled_out"
	cacheActivationThrottled  cacheActivationDecision = "throttled"
)

// CacheRoutingActivationStatus is aggregate operational state only. It never
// contains the activation HMAC key, request identifiers, accounts, models,
// prompt material, or sampling buckets.
type CacheRoutingActivationStatus struct {
	Percent     float64 `json:"percent"`
	MaxPlanQPS  float64 `json:"max_plan_qps"`
	Evaluated   uint64  `json:"evaluated"`
	SampledIn   uint64  `json:"sampled_in"`
	SampledOut  uint64  `json:"sampled_out"`
	RateLimited uint64  `json:"rate_limited"`
	Admitted    uint64  `json:"admitted"`
	Planned     uint64  `json:"planned"`
	ColdOnly    uint64  `json:"cold_only"`
	PlanEmpty   uint64  `json:"plan_empty"`
	PlanFailed  uint64  `json:"plan_failed"`
}

// cacheActivationGate applies two independent operational controls after the
// public cache-routing mode has been switched on:
//   - deterministic HMAC sampling for a stable account/model/request-body cohort;
//   - a process-local token bucket that bounds sidecar plan QPS.
//
// Both controls only decline cache participation. They never reject, delay, or
// otherwise change ordinary inference.
type cacheActivationGate struct {
	mu sync.Mutex

	percent float64
	maxQPS  float64
	burst   float64
	tokens  float64
	last    time.Time

	evaluated  uint64
	sampledIn  uint64
	sampledOut uint64
	throttled  uint64
	admitted   uint64
	planned    uint64
	coldOnly   uint64
	planEmpty  uint64
	planFailed uint64
}

func newCacheActivationGate(percent, maxQPS float64) *cacheActivationGate {
	burst := 0.0
	if maxQPS > 0 {
		// One second of configured capacity is the largest instantaneous burst.
		// Sub-1 QPS rollouts still get one initial token.
		burst = math.Max(1, math.Ceil(maxQPS))
	}
	return &cacheActivationGate{
		percent: percent,
		maxQPS:  maxQPS,
		burst:   burst,
		tokens:  burst,
	}
}

func cacheActivationSampledIn(cohort []byte, percent float64) bool {
	if len(cohort) < 8 || percent <= 0 {
		return false
	}
	if percent >= 100 {
		return true
	}
	bucket := binary.BigEndian.Uint64(cohort[:8]) % cacheActivationBucketCount
	threshold := uint64(math.Ceil(percent / 100 * float64(cacheActivationBucketCount)))
	return bucket < threshold
}

func cacheActivationCohort(key []byte, account, model string, body []byte) []byte {
	if len(key) == 0 || account == "" || model == "" || len(body) == 0 {
		return nil
	}
	return hmacBytes(
		key,
		[]byte("cohort-v1"),
		[]byte(account),
		[]byte(model),
		body,
	)
}

func (g *cacheActivationGate) allow(cohort []byte, now time.Time) cacheActivationDecision {
	if g == nil {
		return cacheActivationSampledOut
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.evaluated++
	if !cacheActivationSampledIn(cohort, g.percent) {
		g.sampledOut++
		return cacheActivationSampledOut
	}
	g.sampledIn++
	if g.maxQPS > 0 {
		g.refillLocked(now)
		if g.tokens < 1 {
			g.throttled++
			return cacheActivationThrottled
		}
		g.tokens--
	}
	g.admitted++
	return cacheActivationAdmitted
}

func (g *cacheActivationGate) refillLocked(now time.Time) {
	if g.last.IsZero() {
		g.last = now
		return
	}
	if !now.After(g.last) {
		return
	}
	g.tokens = math.Min(g.burst, g.tokens+now.Sub(g.last).Seconds()*g.maxQPS)
	g.last = now
}

func (g *cacheActivationGate) recordPlan(outcome CachePlanOutcome) {
	if g == nil {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	switch outcome {
	case CachePlanPlanned:
		g.planned++
	case CachePlanColdOnly:
		g.coldOnly++
	case CachePlanNoBoundaries:
		g.planEmpty++
	case CachePlanSidecarError, CachePlanInvalid:
		g.planFailed++
	}
}

func (g *cacheActivationGate) snapshot() CacheRoutingActivationStatus {
	if g == nil {
		return CacheRoutingActivationStatus{}
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	return CacheRoutingActivationStatus{
		Percent: g.percent, MaxPlanQPS: g.maxQPS,
		Evaluated: g.evaluated, SampledIn: g.sampledIn,
		SampledOut: g.sampledOut, RateLimited: g.throttled,
		Admitted: g.admitted, Planned: g.planned,
		ColdOnly:  g.coldOnly,
		PlanEmpty: g.planEmpty, PlanFailed: g.planFailed,
	}
}

func (r *Registry) CacheRoutingActivationStatus() CacheRoutingActivationStatus {
	if r == nil {
		return CacheRoutingActivationStatus{}
	}
	r.mu.RLock()
	gate := r.cacheActivation
	r.mu.RUnlock()
	return gate.snapshot()
}
