package warmpool

import (
	"sync"
	"time"
)

type Event string

const (
	CapacityReject     Event = "capacity_reject"
	TTFTMiss           Event = "ttft_miss"
	SpeculativeStarted Event = "speculative_started"
	SpeculativeWon     Event = "speculative_won"
	ColdDispatch       Event = "cold_dispatch"
)

// ArrivalEWMAAlpha smooths the per-model spill arrival rate. 0.3 weights
// the latest interval enough to track a rising demand wave within a few control
// ticks while damping single-tick noise.
const ArrivalEWMAAlpha = 0.3

type Pressure struct {
	CapacityRejects     int
	TTFTMisses          int
	SpeculativeStarted  int
	SpeculativeWon      int
	ColdDispatches      int
	loadSuccesses       int
	loadFailures        int
	LoadDurationEWMA    time.Duration
	lastEventAt         time.Time
	LastTarget          int
	LastTargetChangedAt time.Time

	// arrivalAccum counts spill arrivals (capacity_reject + ttft_miss +
	// cold_dispatch) since the last rate fold. ArrivalRateEWMA is the smoothed
	// arrivals/sec derived from it by FoldArrivalRates; it feeds the Little's Law
	// target so the controller sizes capacity to demand it is currently shedding.
	arrivalAccum    int
	ArrivalRateEWMA float64
	lastRateAt      time.Time

	// OccupancyRampEWMA is the smoothed RISE in occupied slots (running +
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
	// observation rather than on lastEventAt (see Snapshot).
	OccupancyRampEWMA float64
	lastOccupancy     int
	lastOccupancyAt   time.Time
	haveOccupancy     bool
}

type State struct {
	mu      sync.Mutex
	models  map[string]*Pressure
	lastNow time.Time
}

func NewState() *State {
	return &State{models: make(map[string]*Pressure)}
}

func (s *State) RecordEvent(model string, event Event, now time.Time) {
	if model == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketLocked(model)
	s.recordEventLocked(b, event, now)
}

func (s *State) RecordLoad(model string, success bool, duration time.Duration, now time.Time) {
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
		if b.LoadDurationEWMA == 0 {
			b.LoadDurationEWMA = duration
		} else {
			b.LoadDurationEWMA = (b.LoadDurationEWMA*3 + duration) / 4
		}
	}
	b.lastEventAt = now
}

// Snapshot returns a copy of every model's bucket, first expiring state that is
// older than recentWindow.
//
// The two families of state expire on DIFFERENT clocks, which is load-bearing:
//
//   - PRESSURE counters and the spill-arrival rate are keyed on lastEventAt, the
//     last capacity_reject / ttft_miss / cold_dispatch / load result. No events
//     for a window means there is no pressure, so zeroing them is correct.
//   - The OCCUPANCY baseline is keyed on lastOccupancyAt, which FoldOccupancyRamp
//     advances every planning pass whether or not anything failed. Keying it on
//     lastEventAt instead would clear haveOccupancy on EVERY pass once pressure
//     aged out (lastEventAt stays stale, and plan() snapshots twice per pass), so
//     FoldOccupancyRamp could only ever re-seed the baseline and never measure a
//     rise again until a new failure arrived — i.e. proactive warming would
//     silently switch itself off about two minutes after the last shed request,
//     reverting to exactly the failure-triggered behaviour the headroom floor
//     exists to replace.
func (s *State) Snapshot(now time.Time, recentWindow time.Duration) map[string]Pressure {
	s.mu.Lock()
	defer s.mu.Unlock()
	if recentWindow <= 0 {
		recentWindow = time.Minute
	}
	out := make(map[string]Pressure, len(s.models))
	for model, b := range s.models {
		if !b.lastEventAt.IsZero() && now.Sub(b.lastEventAt) > recentWindow {
			b.CapacityRejects = 0
			b.TTFTMisses = 0
			b.SpeculativeStarted = 0
			b.SpeculativeWon = 0
			b.ColdDispatches = 0
			b.loadSuccesses = 0
			b.loadFailures = 0
			b.LoadDurationEWMA = 0
			b.arrivalAccum = 0
			b.ArrivalRateEWMA = 0
		}
		// Occupancy is observed by the planning loop, not by failures, so it has
		// its own staleness clock. Expiring it drops a baseline no longer worth
		// differencing against (the controller stopped reporting this model), and
		// resets the ramp so a stale growth figure cannot keep warming providers.
		if !b.lastOccupancyAt.IsZero() && now.Sub(b.lastOccupancyAt) > recentWindow {
			b.OccupancyRampEWMA = 0
			b.haveOccupancy = false
			b.lastOccupancyAt = time.Time{}
		}
		out[model] = *b
	}
	return out
}

// FoldArrivalRates converts each model's accumulated spill arrivals into a
// per-second EWMA. It is called once per planning tick. To keep coalesced
// hot-path trigger ticks (RequestWarmPoolTrigger) from spiking the rate, a fold
// only happens once at least minInterval has elapsed since the last one; until
// then the accumulator keeps counting, so the next real fold sees the full count
// over the true elapsed time.
func (s *State) FoldArrivalRates(now time.Time, minInterval time.Duration, alpha float64) {
	if alpha <= 0 || alpha > 1 {
		alpha = ArrivalEWMAAlpha
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
		if b.ArrivalRateEWMA <= 0 {
			b.ArrivalRateEWMA = inst
		} else {
			b.ArrivalRateEWMA = alpha*inst + (1-alpha)*b.ArrivalRateEWMA
		}
		b.arrivalAccum = 0
		b.lastRateAt = now
	}
}

// FoldOccupancyRamp updates each model's occupancy-growth EWMA from the occupancy
// observed this tick. Called once per planning pass, before targets are computed.
// occupancy is running + waiting + coordinator-queued for that model.
//
// The EWMA is defined in slots per CONTROL INTERVAL, and planning passes are NOT
// evenly spaced: RequestWarmPoolTrigger coalesces hot-path kicks from the queue and
// rejection paths, so a burst can drive many passes inside one interval. Folding
// the raw delta from each pass would then split one interval's growth into several
// small samples and understate the ramp by roughly the trigger frequency — under-
// warming precisely during a burst, the case this floor exists for. So, mirroring
// FoldArrivalRates:
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
// Only positive deltas are folded (see OccupancyRampEWMA). Models absent from the
// map this tick are left untouched rather than decayed, so a model that stops
// being reported does not silently lose its measured ramp.
func (s *State) FoldOccupancyRamp(occupancy map[string]int, now time.Time, interval, minInterval time.Duration, alpha float64) {
	if alpha <= 0 || alpha > 1 {
		alpha = ArrivalEWMAAlpha
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
		if b.OccupancyRampEWMA <= 0 {
			b.OccupancyRampEWMA = rise
		} else {
			b.OccupancyRampEWMA = alpha*rise + (1-alpha)*b.OccupancyRampEWMA
		}
	}
}

func (s *State) RememberTarget(model string, target int, now time.Time) {
	if model == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.bucketLocked(model)
	if b.LastTarget != target {
		b.LastTarget = target
		b.LastTargetChangedAt = now
	}
}

func (s *State) bucketLocked(model string) *Pressure {
	b := s.models[model]
	if b == nil {
		b = &Pressure{}
		s.models[model] = b
	}
	return b
}

func (s *State) recordEventLocked(b *Pressure, event Event, now time.Time) {
	s.decayLocked(now)
	s.lastNow = now
	switch event {
	case CapacityReject:
		b.CapacityRejects++
		b.arrivalAccum++
	case TTFTMiss:
		b.TTFTMisses++
		b.arrivalAccum++
	case SpeculativeStarted:
		b.SpeculativeStarted++
	case SpeculativeWon:
		b.SpeculativeWon++
	case ColdDispatch:
		b.ColdDispatches++
		b.arrivalAccum++
	}
	b.lastEventAt = now
}

func (s *State) decayLocked(now time.Time) {
	if s.lastNow.IsZero() || now.Sub(s.lastNow) < time.Minute {
		return
	}
	for _, b := range s.models {
		b.CapacityRejects /= 2
		b.TTFTMisses /= 2
		b.SpeculativeStarted /= 2
		b.SpeculativeWon /= 2
		b.ColdDispatches /= 2
		b.loadSuccesses /= 2
		b.loadFailures /= 2
	}
}
