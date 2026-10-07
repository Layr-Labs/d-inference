package warmplan

import (
	"math"
	"time"
)

const (
	WarmWorkFreshness  = 10 * time.Minute
	WarmWorkMinSamples = 8
	WarmWorkMaxTokens  = 1 << 20
)

type WorkMean struct {
	Tokens float64
	Count  int64
	At     time.Time
}

func (m *WorkMean) Add(tokens, count int64, now time.Time) {
	if count <= 0 || tokens < 0 || float64(tokens)/float64(count) > WarmWorkMaxTokens {
		return
	}
	mean := float64(tokens) / float64(count)
	if m.At.IsZero() || now.Sub(m.At) > WarmWorkFreshness {
		m.Tokens, m.Count = mean, min(count, 1000)
	} else {
		// A heartbeat with 100 observations has more weight than one with 1;
		// cap the effective history so sustained shape changes can take over.
		weight := 1 - math.Pow(0.95, float64(min(count, 1000)))
		m.Tokens += weight * (mean - m.Tokens)
		m.Count = min(1000, m.Count+min(count, 1000))
	}
	m.At = now
}

func (m WorkMean) Measured(now time.Time) bool {
	return m.Count >= WarmWorkMinSamples && !m.At.IsZero() && now.Sub(m.At) >= 0 && now.Sub(m.At) <= WarmWorkFreshness
}

func (s *State) RecordWork(model string, prompt, prefills, output, generations int64, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketLocked(model)
	b.PromptWork.Add(prompt, prefills, now)
	b.OutputWork.Add(output, generations, now)
	if prefills > 0 && prompt >= 0 && float64(prompt)/float64(prefills) <= WarmWorkMaxTokens {
		b.PromptWorkAccum += float64(prompt)
	}
	if generations > 0 && output >= 0 && float64(output)/float64(generations) <= WarmWorkMaxTokens {
		b.OutputWorkAccum += float64(output)
	}
	if b.WorkRateAt.IsZero() {
		b.WorkRateAt = now
	}
}

// Rates use a common elapsed planning interval after all providers have
// contributed. Averaging provider rates would hide fleet demand; treating each
// heartbeat as one interval would amplify event-driven heartbeats.
func (s *State) FoldWorkRates(now time.Time, interval time.Duration) {
	if interval <= 0 {
		interval = time.Second
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range s.models {
		elapsed := now.Sub(b.WorkRateAt)
		if b.WorkRateAt.IsZero() || elapsed < interval {
			continue
		}
		prompt, output := b.PromptWorkAccum/elapsed.Seconds(), b.OutputWorkAccum/elapsed.Seconds()
		if !b.WorkRateInitialized {
			b.PromptWorkRate, b.OutputWorkRate = prompt, output
			b.WorkRateInitialized = true
		} else {
			b.PromptWorkRate = 0.3*prompt + 0.7*b.PromptWorkRate
			b.OutputWorkRate = 0.3*output + 0.7*b.OutputWorkRate
		}
		b.PromptWorkAccum, b.OutputWorkAccum = 0, 0
		b.WorkRateAt = now
	}
}

func MeasuredWorkProviders(f Fleet, b Pressure, now time.Time) float64 {
	work := 0.0
	if b.PromptWork.Measured(now) && f.PrefillTPS > 0 {
		work += b.PromptWorkRate / f.PrefillTPS
	}
	if b.OutputWork.Measured(now) && f.AggregateDecodeTPS > 0 {
		work += b.OutputWorkRate / f.AggregateDecodeTPS
	}
	return work
}

func MeasuredWarmServiceParams(p TargetParams, b Pressure, now time.Time) TargetParams {
	if b.PromptWork.Measured(now) {
		p.AssumedPromptTokens = int(math.Ceil(b.PromptWork.Tokens))
	}
	if b.OutputWork.Measured(now) {
		p.AssumedCompletionTokens = int(math.Ceil(b.OutputWork.Tokens))
	}
	return p
}
