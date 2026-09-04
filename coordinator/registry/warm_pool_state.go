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

// warmPoolArrivalEWMAAlpha smooths the per-model spill arrival rate. 0.3 weights
// the latest interval enough to track a rising demand wave within a few control
// ticks while damping single-tick noise.
const warmPoolArrivalEWMAAlpha = 0.3

type warmPoolPressureBucket struct {
	capacityRejects    int
	ttftMisses         int
	speculativeStarted int
	speculativeWon     int
	coldDispatches     int
	loadSuccesses      int
	loadFailures       int
	loadDurationEWMA   time.Duration
	// lastEventAt is the last DEMAND event (capacity reject, TTFT miss,
	// speculative start/win, cold dispatch); lastLoadAt the last load_model
	// terminal. They age separately: a load completing must not extend the
	// demand window, or a single reject kept the pool growing for as long
	// as its own loads kept landing (the self-sustaining ratchet).
	lastEventAt         time.Time
	lastLoadAt          time.Time
	lastTarget          int
	lastTargetChangedAt time.Time
	// reactiveAppliedAt is the last tick that evaluated the reactive warm+1
	// floor — a tick under demand pressure with the floor armed
	// (reactiveFloorConsumed); a tick without demand pressure leaves the pool
	// as-is and does not touch it. The floor re-arms only for a demand event
	// newer than this.
	reactiveAppliedAt time.Time

	// arrivalAccum counts spill arrivals (capacity_reject + ttft_miss +
	// cold_dispatch) since the last rate fold. arrivalRateEWMA is the smoothed
	// arrivals/sec derived from it by foldArrivalRates; it feeds the Little's Law
	// target so the controller sizes capacity to demand it is currently shedding.
	arrivalAccum    int
	arrivalRateEWMA float64
	lastRateAt      time.Time
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
	b.lastLoadAt = now
}

// loadDurationEWMA returns the model's smoothed load duration (0 = unknown).
func (s *warmPoolState) loadDurationEWMA(model string) time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	if b := s.models[model]; b != nil {
		return b.loadDurationEWMA
	}
	return 0
}

func (s *warmPoolState) snapshot(now time.Time, recentWindow time.Duration) map[string]warmPoolPressureBucket {
	s.mu.Lock()
	defer s.mu.Unlock()
	if recentWindow <= 0 {
		recentWindow = time.Minute
	}
	out := make(map[string]warmPoolPressureBucket, len(s.models))
	for model, b := range s.models {
		eventsQuiet := b.lastEventAt.IsZero() || now.Sub(b.lastEventAt) > recentWindow
		loadsQuiet := b.lastLoadAt.IsZero() || now.Sub(b.lastLoadAt) > recentWindow
		// Demand counters age on the demand clock alone.
		if !b.lastEventAt.IsZero() && eventsQuiet {
			b.capacityRejects = 0
			b.ttftMisses = 0
			b.speculativeStarted = 0
			b.speculativeWon = 0
			b.coldDispatches = 0
			b.arrivalAccum = 0
			b.arrivalRateEWMA = 0
		}
		// Load stats age once BOTH clocks are quiet.
		if eventsQuiet && loadsQuiet && (!b.lastEventAt.IsZero() || !b.lastLoadAt.IsZero()) {
			b.loadSuccesses = 0
			b.loadFailures = 0
			b.loadDurationEWMA = 0
		}
		out[model] = *b
	}
	return out
}

// foldArrivalRates converts each model's accumulated spill arrivals into a
// per-second EWMA. It is called once per planning tick. To keep coalesced
// hot-path trigger ticks (RequestWarmPoolTrigger) from spiking the rate, a fold
// only happens once at least minInterval has elapsed since the last one; until
// then the accumulator keeps counting, so the next real fold sees the full count
// over the true elapsed time.
func (s *warmPoolState) foldArrivalRates(now time.Time, minInterval time.Duration, alpha float64) {
	if alpha <= 0 || alpha > 1 {
		alpha = warmPoolArrivalEWMAAlpha
	}
	if minInterval <= 0 {
		minInterval = time.Second
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range s.models {
		if b.lastRateAt.IsZero() {
			b.lastRateAt = now
			continue
		}
		elapsed := now.Sub(b.lastRateAt)
		if elapsed < minInterval {
			continue
		}
		inst := 0.0
		if secs := elapsed.Seconds(); secs > 0 {
			inst = float64(b.arrivalAccum) / secs
		}
		if b.arrivalRateEWMA <= 0 {
			b.arrivalRateEWMA = inst
		} else {
			b.arrivalRateEWMA = alpha*inst + (1-alpha)*b.arrivalRateEWMA
		}
		b.arrivalAccum = 0
		b.lastRateAt = now
	}
}

// rememberTarget records the tick's target for the dwell guard and, when the
// tick evaluated the reactive floor (reactiveConsumed: armed AND under demand
// pressure), consumes it (reactiveAppliedAt).
func (s *warmPoolState) rememberTarget(model string, target int, now time.Time, reactiveConsumed bool) {
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
	if reactiveConsumed {
		b.reactiveAppliedAt = now
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
		b.arrivalAccum++
	case warmPoolEventTTFTMiss:
		b.ttftMisses++
		b.arrivalAccum++
	case warmPoolEventSpeculativeStarted:
		b.speculativeStarted++
	case warmPoolEventSpeculativeWon:
		b.speculativeWon++
	case warmPoolEventColdDispatch:
		b.coldDispatches++
		b.arrivalAccum++
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

func (r *Registry) RecordWarmPoolQueueCleared(model string) {
	if r.warmPool == nil || model == "" {
		return
	}
	r.warmPool.recordQueuePressure(model, 0, 0, time.Now())
}

// RecordWarmPoolQueueTimeout refreshes the model's queue pressure after a
// waiter timed out of the queue. The waiter has already left, so the LIVE
// depth is recorded (possibly zero) rather than a phantom Depth=1 stamped with
// the timed-out age, which kept demand pressure — and a warm+1 target — alive
// for a full window after the queue had emptied.
func (r *Registry) RecordWarmPoolQueueTimeout(model string) {
	if r.warmPool == nil || model == "" {
		return
	}
	depth, oldest := 0, time.Duration(0)
	if q := r.Queue(); q != nil {
		depth, oldest = q.QueueStats(model)
	}
	r.warmPool.recordQueuePressure(model, depth, oldest, time.Now())
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
