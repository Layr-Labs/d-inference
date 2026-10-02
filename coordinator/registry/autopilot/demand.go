package autopilot

import (
	"math"
	"sort"
	"sync"
	"time"
)

// DemandSample is one validated PUBLIC logical HTTP request, never a
// dispatch attempt. The API's request-owned terminal consumer enforces once-only
// delivery; this tracker deliberately retains no identity or deduplication set.
// Terminal delivery enriches the original arrival's window. It cannot see an
// unfinished request: the planner must independently use live occupancy as a
// lower bound on demand, not add occupancy to this same workload a second time.
type DemandSample struct {
	Requirements
	DeadlineKnown        bool
	FirstContentDeadline time.Duration
	Model                string
	ReceivedAt           time.Time
	PromptTokens         int
	RequestedMaxTokens   int
	CapacityShed         bool
	Completed            bool
	ServiceTime          time.Duration
	ObservedPromptTokens int
	ObservedOutputTokens int
	Reason               string
}

const (
	autopilotDemandBucketWidth = 10 * time.Second
	autopilotDemandMaxWindow   = 30 * time.Minute
	autopilotDemandMaxModels   = 256
	autopilotDemandMaxTokens   = 1048576
	autopilotDemandMinSamples  = 8
)

var autopilotPromptBounds = [...]int{64, 256, 1024, 4096, 16384, 65536, 262144, autopilotDemandMaxTokens}

type autopilotDemandBucket struct {
	deadlineKnown                                    bool
	deadlineSeconds                                  float64
	at                                               time.Time
	requests, shed, completed, serviceSamples        int
	promptSum, requestedOutputSum, observedOutputSum float64
	serviceSeconds                                   float64
	prompts                                          [8]int
	requirements                                     Requirements
}
type autopilotModelDemand struct {
	first, last time.Time               // accepted arrival times, never terminal refresh times
	buckets     []autopilotDemandBucket // sorted; one entry per ten-second interval
}
type DemandTracker struct {
	cohort bool
	shapes map[string]*DemandTracker
	mu     sync.Mutex
	models map[string]*autopilotModelDemand
}
type DemandView struct {
	InFlight int // current qualified public reservations, not logical arrivals
	Queued   int // ephemeral qualified queue occupancy, never an arrival count
	Requirements
	DeadlineKnown                                     bool
	DeadlineSeconds                                   float64
	Sustained                                         bool
	Rate                                              float64
	PromptTokens, TailPromptTokens                    int
	OutputTokens, RequestedMaxTokens                  int
	ServiceSeconds                                    float64
	Requests, CapacityShed, Completed, ServiceSamples int
	LastDemand                                        time.Time
}

// ValidEnvelope checks the bounded, content-free metadata used by all demand sources.
func (s DemandSample) ValidEnvelope() bool {
	return s.Requirements.valid() && s.Model != "" && len(s.Model) <= 256 &&
		s.PromptTokens > 0 && s.PromptTokens <= autopilotDemandMaxTokens &&
		s.RequestedMaxTokens >= 0 && s.RequestedMaxTokens <= autopilotDemandMaxTokens
}

func (d *DemandTracker) Record(s DemandSample, now time.Time, window time.Duration) {
	if !s.ValidEnvelope() || window <= 0 || window > autopilotDemandMaxWindow || now.IsZero() {
		return
	}
	// Intrinsically invalid work and scheduler lock exhaustion are not demand
	// that another loaded model can serve. Short input alone is never excluded.
	if s.Reason == "intrinsic_unservable" || s.Reason == "routing_saturated" {
		return
	}
	arrival := s.ReceivedAt
	if arrival.IsZero() {
		// Compatibility fallback for callers without an arrival clock. Known old
		// or future timestamps are never rewritten into fresh demand.
		arrival = now
	}
	if arrival.After(now) || arrival.Before(now.Add(-window)) {
		return
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	if d.models == nil {
		d.models = make(map[string]*autopilotModelDemand)
	}
	m := d.models[s.Model]
	if m != nil && m.last.Before(now.Add(-2*window)) {
		delete(d.models, s.Model)
		m = nil
	}
	if m == nil {
		d.pruneModels(now, window)
		if len(d.models) >= autopilotDemandMaxModels {
			return
		}
		m = &autopilotModelDemand{first: arrival, last: arrival}
		d.models[s.Model] = m
	}
	if arrival.Before(m.first) {
		m.first = arrival
	}
	if arrival.After(m.last) {
		m.last = arrival
	}
	m.pruneBuckets(now.Add(-window))

	at := arrival.Truncate(autopilotDemandBucketWidth)
	// Completions arrive out of order. Insert into the arrival interval rather
	// than append another copy or attribute its work to the terminal interval.
	i := sort.Search(len(m.buckets), func(i int) bool { return !m.buckets[i].at.Before(at) })
	if i == len(m.buckets) || !m.buckets[i].at.Equal(at) {
		m.buckets = append(m.buckets, autopilotDemandBucket{})
		copy(m.buckets[i+1:], m.buckets[i:])
		m.buckets[i] = autopilotDemandBucket{at: at}
	}
	if !d.cohort {
		if d.shapes == nil {
			d.shapes = make(map[string]*DemandTracker)
		}
		key := ShapeKey(s)
		tracker := d.shapes[key]
		if tracker == nil && len(d.shapes) < 2048 {
			tracker = &DemandTracker{cohort: true}
			d.shapes[key] = tracker
		}
		if tracker != nil {
			tracker.Record(s, now, window)
		}
	}
	b := &m.buckets[i]
	b.requests++
	b.deadlineKnown = b.deadlineKnown || s.DeadlineKnown
	if seconds := s.FirstContentDeadline.Seconds(); s.DeadlineKnown && seconds > 0 && (b.deadlineSeconds == 0 || seconds < b.deadlineSeconds) {
		b.deadlineSeconds = seconds
	}
	if s.CapacityShed {
		b.shed++
	}
	b.promptSum += float64(s.PromptTokens)
	b.requestedOutputSum += float64(s.RequestedMaxTokens)
	for i, bound := range autopilotPromptBounds {
		if s.PromptTokens <= bound {
			b.prompts[i]++
			break
		}
	}
	b.requirements.merge(s.Requirements)
	if s.Completed && s.ObservedOutputTokens >= 0 && s.ObservedOutputTokens <= autopilotDemandMaxTokens {
		// A real completion supplies output even when cold loading, unknown
		// timing, or a very long request makes warm service time unusable.
		b.completed++
		b.observedOutputSum += float64(s.ObservedOutputTokens)
		if s.ServiceTime > 0 && s.ServiceTime <= 10*time.Minute {
			b.serviceSamples++
			b.serviceSeconds += s.ServiceTime.Seconds()
		}
	}
}

// pruneModels runs under d.mu. Arrival-based expiry prevents delayed terminals
// from keeping stale demand alive or filling the bounded model map forever.
func (d *DemandTracker) pruneModels(now time.Time, window time.Duration) {
	for model, m := range d.models {
		if m.last.Before(now.Add(-2 * window)) {
			delete(d.models, model)
		}
	}
}

// Keep the interval intersecting the cutoff. Counts therefore have ten-second
// resolution: an unaligned snapshot can retain <10s of old work, but never loses
// the valid part of that interval. At aligned ticks the cutoff is exact. New
// samples still pass the exact arrival cutoff before insertion. There are at
// most ceil(window/10s)+1 occupied intervals, independent of request volume.
func (m *autopilotModelDemand) pruneBuckets(cutoff time.Time) {
	at := cutoff.Truncate(autopilotDemandBucketWidth)
	i := sort.Search(len(m.buckets), func(i int) bool { return !m.buckets[i].at.Before(at) })
	if i > 0 {
		copy(m.buckets, m.buckets[i:])
		clear(m.buckets[len(m.buckets)-i:])
		m.buckets = m.buckets[:len(m.buckets)-i]
	}
}

func (d *DemandTracker) Snapshot(now time.Time, window time.Duration) map[string]DemandView {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make(map[string]DemandView)
	if window <= 0 || window > autopilotDemandMaxWindow || now.IsZero() {
		return out
	}
	d.pruneModels(now, window)
	for model, m := range d.models {
		m.pruneBuckets(now.Add(-window))
		var sum autopilotDemandBucket
		fast := 0
		observedBuckets := 0
		fastCutoff := now.Add(-time.Minute).Truncate(autopilotDemandBucketWidth)
		for _, b := range m.buckets {
			if b.at.After(now) {
				continue // a backwards clock adjustment must not count future work
			}
			if b.requests > 0 {
				observedBuckets++
			}
			sum.deadlineKnown = sum.deadlineKnown || b.deadlineKnown
			if b.deadlineSeconds > 0 && (sum.deadlineSeconds == 0 || b.deadlineSeconds < sum.deadlineSeconds) {
				sum.deadlineSeconds = b.deadlineSeconds
			}
			sum.requests += b.requests
			sum.shed += b.shed
			sum.completed += b.completed
			sum.serviceSamples += b.serviceSamples
			sum.promptSum += b.promptSum
			sum.requestedOutputSum += b.requestedOutputSum
			sum.observedOutputSum += b.observedOutputSum
			sum.serviceSeconds += b.serviceSeconds
			sum.requirements.merge(b.requirements)
			for i, count := range b.prompts {
				sum.prompts[i] += count
			}
			if !b.at.Before(fastCutoff) {
				fast += b.requests
			}
		}
		v := DemandView{
			DeadlineKnown: sum.deadlineKnown, DeadlineSeconds: sum.deadlineSeconds,
			Sustained:  observedBuckets >= 3 && sum.requests >= autopilotDemandMinSamples,
			LastDemand: m.last, Requests: sum.requests, CapacityShed: sum.shed,
			Completed: sum.completed, ServiceSamples: sum.serviceSamples,
			Requirements: sum.requirements,
		}
		if sum.requests > 0 {
			elapsed := math.Max(autopilotDemandBucketWidth.Seconds(), math.Min(window.Seconds(), now.Sub(m.first).Seconds()))
			v.Rate = math.Max(float64(sum.requests)/elapsed, float64(fast)/math.Min(60, elapsed))
			// Arithmetic mean prices throughput work. The histogram tail must
			// not inflate every arrival's expected prefill cost.
			v.PromptTokens = int(math.Ceil(sum.promptSum / float64(sum.requests)))
			v.RequestedMaxTokens = int(math.Ceil(sum.requestedOutputSum / float64(sum.requests)))
			v.OutputTokens = min(256, max(1, v.RequestedMaxTokens))
			if sum.completed >= autopilotDemandMinSamples {
				v.OutputTokens = max(1, int(math.Ceil(sum.observedOutputSum/float64(sum.completed))))
			}
			if sum.serviceSamples >= autopilotDemandMinSamples {
				v.ServiceSeconds = sum.serviceSeconds / float64(sum.serviceSamples)
			}
			// Deadline fit uses the p90 histogram upper bound, at least the
			// mean. This is a conservative shape, not an observed token count.
			quantile := int(math.Ceil(float64(sum.requests) * .9))
			for i, count := range sum.prompts {
				quantile -= count
				if quantile <= 0 {
					v.TailPromptTokens = max(v.PromptTokens, autopilotPromptBounds[i])
					break
				}
			}
		}
		out[model] = v
	}
	return out
}
