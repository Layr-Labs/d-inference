// Package cacheactivation owns deterministic cache participation sampling and
// the process-local plan-rate limit. It never gates ordinary inference.
package cacheactivation

import (
	"encoding/binary"
	"math"
	"sync"
	"time"
)

const cacheActivationBucketCount = uint64(1_000_000)

type cacheActivationDecision string

const (
	Admitted   cacheActivationDecision = "admitted"
	SampledOut cacheActivationDecision = "sampled_out"
	Throttled  cacheActivationDecision = "throttled"
)

// Gate applies two independent operational controls after the
// public cache-routing mode has been switched on:
//   - deterministic HMAC sampling for a stable account/model/request-body cohort;
//   - a process-local token bucket that bounds sidecar plan QPS.
//
// Both controls only decline cache participation. They never reject, delay, or
// otherwise change ordinary inference.
type Gate struct {
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
	firstSight uint64
}

// New creates a limiter with immutable sampling and rate policy.
func New(percent, maxQPS float64) *Gate {
	burst := 0.0
	if maxQPS > 0 {
		// One second of configured capacity is the largest instantaneous burst.
		// Sub-1 QPS rollouts still get one initial token.
		burst = math.Max(1, math.Ceil(maxQPS))
	}
	return &Gate{
		percent: percent,
		maxQPS:  maxQPS,
		burst:   burst,
		tokens:  burst,
	}
}

// SampledIn applies the configured percentage to an authenticated cohort.
func SampledIn(cohort []byte, percent float64) bool {
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

// Cohort derives the stable, domain-separated cache participation sample.
func Cohort(key []byte, account, model string, body []byte) []byte {
	if len(key) == 0 || account == "" || model == "" || len(body) == 0 {
		return nil
	}
	return HMACBytes(
		key,
		[]byte("cohort-v1"),
		[]byte(account),
		[]byte(model),
		body,
	)
}

// Allow atomically samples and charges the plan-rate bucket at now.
func (g *Gate) Allow(cohort []byte, now time.Time) cacheActivationDecision {
	if g == nil {
		return SampledOut
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.evaluated++
	if !SampledIn(cohort, g.percent) {
		g.sampledOut++
		return SampledOut
	}
	g.sampledIn++
	if g.maxQPS > 0 {
		g.refillLocked(now)
		if g.tokens < 1 {
			g.throttled++
			return Throttled
		}
		g.tokens--
	}
	g.admitted++
	return Admitted
}

func (g *Gate) refillLocked(now time.Time) {
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

// RecordPlan records only the bounded outcome, never request identity or content.
func (g *Gate) RecordPlan(outcome CachePlanOutcome) {
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

// RecordPlanned counts one planned request and, in the same critical section,
// whether it was a novel prompt that first sight prepared for its own
// follow-up, so no snapshot shows FirstSight above Planned.
func (g *Gate) RecordPlanned(firstSight bool) {
	if g == nil {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.planned++
	if firstSight {
		g.firstSight++
	}
}

// Snapshot returns detached configuration and aggregate operational counters.
func (g *Gate) Snapshot() CacheRoutingActivationStatus {
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
		FirstSight: g.firstSight,
	}
}
