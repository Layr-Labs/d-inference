package autopilot

import (
	"math"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/demandwindow"
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
	shed, completed, serviceSamples                  int
	promptSum, requestedOutputSum, observedOutputSum float64
	serviceSeconds                                   float64
	prompts                                          [8]int
	requirements                                     Requirements
}
type DemandTracker struct {
	cohort  bool
	shapes  map[string]*DemandTracker
	mu      sync.Mutex
	history *demandwindow.Window[autopilotDemandBucket]
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

	b := &autopilotDemandBucket{deadlineKnown: s.DeadlineKnown, requirements: s.Requirements}
	if seconds := s.FirstContentDeadline.Seconds(); s.DeadlineKnown && seconds > 0 {
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
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.history == nil {
		d.history = NewDemandHistory()
	}
	if !d.history.Record(s.Model, arrival, now, window, *b) {
		return
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
}

func (d *DemandTracker) Snapshot(now time.Time, window time.Duration) map[string]DemandView {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make(map[string]DemandView)
	if window <= 0 || window > autopilotDemandMaxWindow || now.IsZero() {
		return out
	}
	if d.history == nil {
		return out
	}
	for model, m := range d.history.Snapshot(now, window) {
		var sum autopilotDemandBucket
		requests := 0
		fast := 0
		observedBuckets := 0
		fastCutoff := now.Add(-time.Minute).Truncate(autopilotDemandBucketWidth)
		for _, interval := range m.Intervals {
			b := interval.Value
			if interval.At.After(now) {
				continue // a backwards clock adjustment must not count future work
			}
			if interval.Count > 0 {
				observedBuckets++
			}
			requests += interval.Count
			sum = mergeDemandBucket(sum, b)
			if !interval.At.Before(fastCutoff) {
				fast += interval.Count
			}
		}
		v := DemandView{
			DeadlineKnown: sum.deadlineKnown, DeadlineSeconds: sum.deadlineSeconds,
			Sustained:  observedBuckets >= 3 && requests >= autopilotDemandMinSamples,
			LastDemand: m.Last, Requests: requests, CapacityShed: sum.shed,
			Completed: sum.completed, ServiceSamples: sum.serviceSamples,
			Requirements: sum.requirements,
		}
		if requests > 0 {
			elapsed := math.Max(autopilotDemandBucketWidth.Seconds(), math.Min(window.Seconds(), now.Sub(m.First).Seconds()))
			v.Rate = math.Max(float64(requests)/elapsed, float64(fast)/math.Min(60, elapsed))
			// Arithmetic mean prices throughput work. The histogram tail must
			// not inflate every arrival's expected prefill cost.
			v.PromptTokens = int(math.Ceil(sum.promptSum / float64(requests)))
			v.RequestedMaxTokens = int(math.Ceil(sum.requestedOutputSum / float64(requests)))
			v.OutputTokens = min(256, max(1, v.RequestedMaxTokens))
			if sum.completed >= autopilotDemandMinSamples {
				v.OutputTokens = max(1, int(math.Ceil(sum.observedOutputSum/float64(sum.completed))))
			}
			if sum.serviceSamples >= autopilotDemandMinSamples {
				v.ServiceSeconds = sum.serviceSeconds / float64(sum.serviceSamples)
			}
			// Deadline fit uses the p90 histogram upper bound, at least the
			// mean. This is a conservative shape, not an observed token count.
			quantile := int(math.Ceil(float64(requests) * .9))
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

// NewDemandHistory constructs the bounded arrival history retained by trackers.
func NewDemandHistory() *demandwindow.Window[autopilotDemandBucket] {
	return demandwindow.New(autopilotDemandMaxModels, autopilotDemandBucketWidth, mergeDemandBucket)
}

// NewDemandTracker retains an independently owned arrival history. The zero
// value also initializes this same history lazily on its first accepted sample.
func NewDemandTracker(history *demandwindow.Window[autopilotDemandBucket]) *DemandTracker {
	if history == nil {
		history = NewDemandHistory()
	}
	return &DemandTracker{history: history}
}

func mergeDemandBucket(sum, b autopilotDemandBucket) autopilotDemandBucket {
	sum.deadlineKnown = sum.deadlineKnown || b.deadlineKnown
	if b.deadlineSeconds > 0 && (sum.deadlineSeconds == 0 || b.deadlineSeconds < sum.deadlineSeconds) {
		sum.deadlineSeconds = b.deadlineSeconds
	}
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
	return sum
}
