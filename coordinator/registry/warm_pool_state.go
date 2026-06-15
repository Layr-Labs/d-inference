package registry

import (
	"sync"
	"time"
)

type warmPoolPressureEvent string

const (
	warmPoolEventCapacityReject     warmPoolPressureEvent = "capacity_reject"
	warmPoolEventTTFTMiss           warmPoolPressureEvent = "ttft_miss"
	warmPoolEventSpeculativeStarted warmPoolPressureEvent = "speculative_started"
	warmPoolEventSpeculativeWon     warmPoolPressureEvent = "speculative_won"
	warmPoolEventColdDispatch       warmPoolPressureEvent = "cold_dispatch"
)

type warmPoolPressureBucket struct {
	capacityRejects     int
	ttftMisses          int
	speculativeStarted  int
	speculativeWon      int
	coldDispatches      int
	loadSuccesses       int
	loadFailures        int
	loadDurationEWMA    time.Duration
	lastEventAt         time.Time
	lastTarget          int
	lastTargetChangedAt time.Time
}

type warmPoolState struct {
	mu      sync.Mutex
	models  map[string]*warmPoolPressureBucket
	lastNow time.Time
}

func newWarmPoolState() *warmPoolState {
	return &warmPoolState{models: make(map[string]*warmPoolPressureBucket)}
}

func (s *warmPoolState) recordEvent(model string, event warmPoolPressureEvent, now time.Time) {
	if model == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketLocked(model)
	s.recordEventLocked(b, event, now)
}

func (s *warmPoolState) recordLoad(model string, success bool, duration time.Duration, now time.Time) {
	if model == "" {
		return
	}
	if duration < 0 {
		duration = 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketLocked(model)
	if success {
		b.loadSuccesses++
	} else {
		b.loadFailures++
	}
	if duration > 0 {
		if b.loadDurationEWMA == 0 {
			b.loadDurationEWMA = duration
		} else {
			b.loadDurationEWMA = (b.loadDurationEWMA*3 + duration) / 4
		}
	}
	b.lastEventAt = now
}

func (s *warmPoolState) snapshot(now time.Time, recentWindow time.Duration) map[string]warmPoolPressureBucket {
	s.mu.Lock()
	defer s.mu.Unlock()
	if recentWindow <= 0 {
		recentWindow = time.Minute
	}
	out := make(map[string]warmPoolPressureBucket, len(s.models))
	for model, b := range s.models {
		if !b.lastEventAt.IsZero() && now.Sub(b.lastEventAt) > recentWindow {
			b.capacityRejects = 0
			b.ttftMisses = 0
			b.speculativeStarted = 0
			b.speculativeWon = 0
			b.coldDispatches = 0
			b.loadSuccesses = 0
			b.loadFailures = 0
			b.loadDurationEWMA = 0
		}
		out[model] = *b
	}
	return out
}

func (s *warmPoolState) rememberTarget(model string, target int, now time.Time) {
	if model == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketLocked(model)
	if b.lastTarget != target {
		b.lastTarget = target
		b.lastTargetChangedAt = now
	}
}

func (s *warmPoolState) bucketLocked(model string) *warmPoolPressureBucket {
	b := s.models[model]
	if b == nil {
		b = &warmPoolPressureBucket{}
		s.models[model] = b
	}
	return b
}

func (s *warmPoolState) recordEventLocked(b *warmPoolPressureBucket, event warmPoolPressureEvent, now time.Time) {
	s.decayLocked(now)
	s.lastNow = now
	switch event {
	case warmPoolEventCapacityReject:
		b.capacityRejects++
	case warmPoolEventTTFTMiss:
		b.ttftMisses++
	case warmPoolEventSpeculativeStarted:
		b.speculativeStarted++
	case warmPoolEventSpeculativeWon:
		b.speculativeWon++
	case warmPoolEventColdDispatch:
		b.coldDispatches++
	}
	b.lastEventAt = now
}

func (s *warmPoolState) decayLocked(now time.Time) {
	if s.lastNow.IsZero() || now.Sub(s.lastNow) < time.Minute {
		return
	}
	for _, b := range s.models {
		b.capacityRejects /= 2
		b.ttftMisses /= 2
		b.speculativeStarted /= 2
		b.speculativeWon /= 2
		b.coldDispatches /= 2
		b.loadSuccesses /= 2
		b.loadFailures /= 2
	}
}

func (r *Registry) RecordWarmPoolCapacityReject(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.recordEvent(model, warmPoolEventCapacityReject, time.Now())
}

func (r *Registry) RecordWarmPoolQueueEnqueued(model string, depth int, oldestAge time.Duration) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.recordQueuePressure(model, depth, oldestAge, time.Now())
}

func (r *Registry) RecordWarmPoolQueueTimeout(model string, age time.Duration) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.recordQueuePressure(model, 1, age, time.Now())
}

func (r *Registry) RecordWarmPoolTTFTMiss(model string, duration time.Duration) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.recordEvent(model, warmPoolEventTTFTMiss, time.Now())
}

func (r *Registry) RecordWarmPoolSpeculativeStarted(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.recordEvent(model, warmPoolEventSpeculativeStarted, time.Now())
}

func (r *Registry) RecordWarmPoolSpeculativeWon(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.recordEvent(model, warmPoolEventSpeculativeWon, time.Now())
}

func (r *Registry) RecordWarmPoolColdDispatch(model string) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.recordEvent(model, warmPoolEventColdDispatch, time.Now())
}

func (r *Registry) RecordWarmPoolLoadResult(model string, success bool, duration time.Duration) {
	if r.warmPool == nil {
		return
	}
	r.warmPool.state.recordLoad(model, success, duration, time.Now())
}
