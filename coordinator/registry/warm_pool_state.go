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

	// arrivalAccum counts spill arrivals (capacity_reject + ttft_miss +
	// cold_dispatch) since the last rate fold. arrivalRateEWMA is the smoothed
	// arrivals/sec derived from it by foldArrivalRates; it feeds the Little's Law
	// target so the controller sizes capacity to demand it is currently shedding.
	arrivalAccum    int
	arrivalRateEWMA float64
	lastRateAt      time.Time

	// occupancyRampEWMA is the smoothed RISE in occupied slots (running +
	// waiting + coordinator-queued) observed between planning ticks, in slots
	// per tick, floored at zero. It is the measured demand-growth rate the
	// proactive headroom floor is sized from: headroom must cover the arrivals
	// that land while a cold provider is still loading, and that is a growth
	// rate, NOT the absolute arrival rate (which would size headroom to total
	// traffic and demand far more hardware than exists).
	//
	// Only INCREASES are folded. A falling occupancy is not negative demand
	// growth, and letting it pull the EWMA down would shrink headroom fastest
	// right after a spike drains — exactly when the next one is most likely.
	//
	// lastOccupancyAt timestamps the baseline so a fold can normalize the delta
	// to one control interval, and so staleness is judged on the OCCUPANCY
	// observation rather than on lastEventAt (see snapshot).
	occupancyRampEWMA float64
	lastOccupancy     int
	lastOccupancyAt   time.Time
	haveOccupancy     bool
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

// snapshot returns a copy of every model's bucket, first expiring state that is
// older than recentWindow.
//
// The two families of state expire on DIFFERENT clocks, which is load-bearing:
//
//   - PRESSURE counters and the spill-arrival rate are keyed on lastEventAt, the
//     last capacity_reject / ttft_miss / cold_dispatch / load result. No events
//     for a window means there is no pressure, so zeroing them is correct.
//   - The OCCUPANCY baseline is keyed on lastOccupancyAt, which foldOccupancyRamp
//     advances every planning pass whether or not anything failed. Keying it on
//     lastEventAt instead would clear haveOccupancy on EVERY pass once pressure
//     aged out (lastEventAt stays stale, and plan() snapshots twice per pass), so
//     foldOccupancyRamp could only ever re-seed the baseline and never measure a
//     rise again until a new failure arrived — i.e. proactive warming would
//     silently switch itself off about two minutes after the last shed request,
//     reverting to exactly the failure-triggered behaviour the headroom floor
//     exists to replace.
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
			b.arrivalAccum = 0
			b.arrivalRateEWMA = 0
		}
		// Occupancy is observed by the planning loop, not by failures, so it has
		// its own staleness clock. Expiring it drops a baseline no longer worth
		// differencing against (the controller stopped reporting this model), and
		// resets the ramp so a stale growth figure cannot keep warming providers.
		if !b.lastOccupancyAt.IsZero() && now.Sub(b.lastOccupancyAt) > recentWindow {
			b.occupancyRampEWMA = 0
			b.haveOccupancy = false
			b.lastOccupancyAt = time.Time{}
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

// foldOccupancyRamp updates each model's occupancy-growth EWMA from the occupancy
// observed this tick. Called once per planning pass, before targets are computed.
// occupancy is running + waiting + coordinator-queued for that model.
//
// The EWMA is defined in slots per CONTROL INTERVAL, and planning passes are NOT
// evenly spaced: RequestWarmPoolTrigger coalesces hot-path kicks from the queue and
// rejection paths, so a burst can drive many passes inside one interval. Folding
// the raw delta from each pass would then split one interval's growth into several
// small samples and understate the ramp by roughly the trigger frequency — under-
// warming precisely during a burst, the case this floor exists for. So, mirroring
// foldArrivalRates:
//
//   - a fold only happens once at least minInterval has elapsed since the last
//     one; until then the baseline is left alone, so the next real fold sees the
//     WHOLE rise over the true elapsed time rather than a fragment of it;
//   - the rise is then scaled to one control interval:
//     rise_per_interval = rise · interval / elapsed.
//
// interval <= 0 or minInterval <= 0 disables the normalization and gate (every
// call folds its raw delta), which keeps the pure-unit-test path simple.
//
// Only positive deltas are folded (see occupancyRampEWMA). Models absent from the
// map this tick are left untouched rather than decayed, so a model that stops
// being reported does not silently lose its measured ramp.
func (s *warmPoolState) foldOccupancyRamp(occupancy map[string]int, now time.Time, interval, minInterval time.Duration, alpha float64) {
	if alpha <= 0 || alpha > 1 {
		alpha = warmPoolArrivalEWMAAlpha
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for model, occ := range occupancy {
		if occ < 0 {
			occ = 0
		}
		b := s.bucketLocked(model)
		if !b.haveOccupancy {
			b.lastOccupancy = occ
			b.lastOccupancyAt = now
			b.haveOccupancy = true
			continue
		}
		elapsed := now.Sub(b.lastOccupancyAt)
		// Gate coalesced trigger ticks: keep the older baseline so the next fold
		// measures the full rise across the whole interval.
		if minInterval > 0 && !b.lastOccupancyAt.IsZero() && elapsed < minInterval {
			continue
		}
		rise := float64(occ - b.lastOccupancy)
		b.lastOccupancy = occ
		b.lastOccupancyAt = now
		if rise < 0 {
			rise = 0
		}
		// Normalize to one control interval so an early or late pass does not
		// change the measured growth RATE.
		if interval > 0 && elapsed > 0 {
			rise *= interval.Seconds() / elapsed.Seconds()
		}
		if b.occupancyRampEWMA <= 0 {
			b.occupancyRampEWMA = rise
		} else {
			b.occupancyRampEWMA = alpha*rise + (1-alpha)*b.occupancyRampEWMA
		}
	}
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
