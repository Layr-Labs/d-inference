package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	warmWorkFreshness  = 10 * time.Minute
	warmWorkMinSamples = 8
	warmWorkMaxTokens  = 1 << 20
)

// Work counters are slot-lifetime totals, not completed-success counters.
// Prefill includes actual computation before a later cancellation; generation
// includes partial output at every engine retirement. Requested maxima remain
// exclusively physical reservations and never become measured service demand.
type warmWorkCounters struct {
	epoch                                 string
	prompt, prefills, output, generations int64
	lastWorkAt                            time.Time
	observedAt                            time.Time
}

type warmWorkMean struct {
	tokens float64
	count  int64
	at     time.Time
}

func (m *warmWorkMean) add(tokens, count int64, now time.Time) {
	if count <= 0 || tokens < 0 || float64(tokens)/float64(count) > warmWorkMaxTokens {
		return
	}
	mean := float64(tokens) / float64(count)
	if m.at.IsZero() || now.Sub(m.at) > warmWorkFreshness {
		m.tokens, m.count = mean, min(count, 1000)
	} else {
		// A heartbeat with 100 observations has more weight than one with 1;
		// cap the effective history so sustained shape changes can take over.
		weight := 1 - math.Pow(0.95, float64(min(count, 1000)))
		m.tokens += weight * (mean - m.tokens)
		m.count = min(1000, m.count+min(count, 1000))
	}
	m.at = now
}

func (m warmWorkMean) measured(now time.Time) bool {
	return m.count >= warmWorkMinSamples && !m.at.IsZero() && now.Sub(m.at) >= 0 && now.Sub(m.at) <= warmWorkFreshness
}

// Caller holds p.mu and has already rejected stale capacity sequences. Each
// new slot epoch starts with a baseline: old work with unknown age cannot be
// presented as fresh load. Missing capacity, eviction and decreases also reset.
func (p *Provider) reconcileWarmPoolWorkLocked(capacity *protocol.BackendCapacity, now time.Time, c *warmPoolController) {
	if capacity == nil || c == nil {
		p.warmWorkCounters = nil
		return
	}
	next := make(map[string]warmWorkCounters, len(capacity.Slots))
	for _, slot := range capacity.Slots {
		t := slot.Telemetry
		if !slotStateModelLoaded(slot.State) || t == nil || slot.PerformanceMeasurements == nil || slot.PerformanceMeasurements.Epoch == "" ||
			t.PrefillTokensTotal == nil || t.PrefillRequestsTotal == nil ||
			t.GeneratedTokensTotal == nil || t.GenerationRequestsTotal == nil {
			continue
		}
		v := warmWorkCounters{epoch: slot.PerformanceMeasurements.Epoch, prompt: *t.PrefillTokensTotal, prefills: *t.PrefillRequestsTotal, output: *t.GeneratedTokensTotal, generations: *t.GenerationRequestsTotal, observedAt: now}
		if v.prompt < 0 || v.prefills < 0 || v.output < 0 || v.generations < 0 {
			continue
		}
		next[slot.Model] = v
		old, ok := p.warmWorkCounters[slot.Model]
		if !ok || old.epoch != v.epoch || now.Before(old.observedAt) || now.Sub(old.observedAt) > firstContentPerformanceFreshness || v.prompt < old.prompt || v.prefills < old.prefills || v.output < old.output || v.generations < old.generations {
			continue
		}
		v.lastWorkAt = old.lastWorkAt
		if v.prefills > old.prefills || v.generations > old.generations {
			v.lastWorkAt = now
		}
		next[slot.Model] = v
		c.state.recordWork(slot.Model, v.prompt-old.prompt, v.prefills-old.prefills, v.output-old.output, v.generations-old.generations, now)
	}
	p.warmWorkCounters = next
}

func (s *warmPoolState) recordWork(model string, prompt, prefills, output, generations int64, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketLocked(model)
	b.promptWork.add(prompt, prefills, now)
	b.outputWork.add(output, generations, now)
	if prefills > 0 && prompt >= 0 && float64(prompt)/float64(prefills) <= warmWorkMaxTokens {
		b.promptWorkAccum += float64(prompt)
	}
	if generations > 0 && output >= 0 && float64(output)/float64(generations) <= warmWorkMaxTokens {
		b.outputWorkAccum += float64(output)
	}
	if b.workRateAt.IsZero() {
		b.workRateAt = now
	}
}

// Rates use a common elapsed planning interval after all providers have
// contributed. Averaging provider rates would hide fleet demand; treating each
// heartbeat as one interval would amplify event-driven heartbeats.
func (s *warmPoolState) foldWorkRates(now time.Time, interval time.Duration) {
	if interval <= 0 {
		interval = time.Second
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range s.models {
		elapsed := now.Sub(b.workRateAt)
		if b.workRateAt.IsZero() || elapsed < interval {
			continue
		}
		prompt, output := b.promptWorkAccum/elapsed.Seconds(), b.outputWorkAccum/elapsed.Seconds()
		if !b.workRateInitialized {
			b.promptWorkRate, b.outputWorkRate = prompt, output
			b.workRateInitialized = true
		} else {
			b.promptWorkRate = 0.3*prompt + 0.7*b.promptWorkRate
			b.outputWorkRate = 0.3*output + 0.7*b.outputWorkRate
		}
		b.promptWorkAccum, b.outputWorkAccum = 0, 0
		b.workRateAt = now
	}
}

func measuredWorkProviders(f warmPoolModelSnapshot, b warmPoolPressureBucket, now time.Time) float64 {
	work := 0.0
	if b.promptWork.measured(now) && f.prefillTPS > 0 {
		work += b.promptWorkRate / f.prefillTPS
	}
	if b.outputWork.measured(now) && f.aggregateDecodeTPS > 0 {
		work += b.outputWorkRate / f.aggregateDecodeTPS
	}
	return work
}

func measuredWarmServiceParams(p warmTargetParams, b warmPoolPressureBucket, now time.Time) warmTargetParams {
	if b.promptWork.measured(now) {
		p.AssumedPromptTokens = int(math.Ceil(b.promptWork.tokens))
	}
	if b.outputWork.measured(now) {
		p.AssumedCompletionTokens = int(math.Ceil(b.outputWork.tokens))
	}
	return p
}
